#!/usr/bin/env python3
"""Un ciclo A1 para Actions; estado durable previo a cualquier lanzamiento."""
import argparse
import base64
import configparser
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import tempfile
import urllib.error
import urllib.request
import uuid

BRANCH = 'a1-state'
STATE_PATH = 'estado-a1.json'
SHAPE = 'VM.Standard.A1.Flex'
TERMINAL = {'created', 'existing', 'uncertain', 'fatal', 'pending'}

class GitHubState:
    def __init__(self):
        self.repo = os.environ['GITHUB_REPOSITORY']
        self.token = os.environ['GH_TOKEN']
        self.sha = None
    def request(self, method, path, body=None, missing=False):
        request = urllib.request.Request(
            f'https://api.github.com/repos/{self.repo}/{path}',
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={'Authorization':f'Bearer {self.token}', 'Accept':'application/vnd.github+json',
                     'X-GitHub-Api-Version':'2022-11-28', 'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing and error.code == 404: return None
            raise RuntimeError(f'No se pudo guardar/leer estado GitHub (HTTP {error.code})') from None
    def load(self):
        ref = self.request('GET', f'git/ref/heads/{BRANCH}', missing=True)
        if ref is None: return {}
        file = self.request('GET', f'contents/{STATE_PATH}?ref={BRANCH}', missing=True)
        if file is None: raise RuntimeError('La rama de estado existe pero falta el archivo; revisar antes de continuar')
        self.sha = file['sha']
        state = json.loads(base64.b64decode(file['content']))
        if not isinstance(state,dict) or state.get('status') not in TERMINAL | {'retry'}:
            raise RuntimeError('Estado persistente inválido; no se creará una instancia')
        return state
    def save(self,state):
        if self.request('GET',f'git/ref/heads/{BRANCH}',missing=True) is None:
            head=self.request('GET','git/ref/heads/main')['object']['sha']
            self.request('POST','git/refs',{'ref':f'refs/heads/{BRANCH}','sha':head})
        state=dict(state,updated_at=datetime.now(timezone.utc).isoformat())
        body={'message':f"A1: {state['status']}",'branch':BRANCH,
              'content':base64.b64encode((json.dumps(state,indent=2)+'\n').encode()).decode()}
        if self.sha: body['sha']=self.sha
        result=self.request('PUT',f'contents/{STATE_PATH}',body)
        self.sha=result['content']['sha']

def note(text):
    print(text)
    summary=os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary,'a') as f: f.write(text+'\n\n')

def classify(error):
    code=getattr(error,'code','')
    status=getattr(error,'status',None)
    message=str(getattr(error,'message','')).lower()
    if code=='LimitExceeded' or status in (400,401,403): return 'fatal'
    if status==429 or code=='TooManyRequests': return 'retry'
    if code in ('OutOfHostCapacity','OutOfCapacity') or 'out of host capacity' in message: return 'capacity'
    return 'uncertain'

def select_size(used_cpu,used_memory,size):
    return used_cpu+size[0]<=2 and used_memory+size[1]<=12

def attempt(compute,details,store,size,ad):
    from oci.retry import NoneRetryStrategy
    token=str(uuid.uuid4())
    store.save({'status':'pending','request_token':token,'size':list(size)})
    # Never launch if durable pending could not be saved. No internal SDK retries.
    try:
        response=compute.launch_instance(details,opc_retry_token=token,retry_strategy=NoneRetryStrategy())
    except Exception as error:
        kind=classify(error)
        if kind in ('capacity','retry'):
            store.save({'status':'retry'})
            note('Oracle no ofrece capacidad.' if kind=='capacity' else 'Oracle limitó la frecuencia; se espera al próximo ciclo.')
            return kind
        store.save({'status':'fatal' if kind=='fatal' else 'uncertain'})
        note('Proceso pausado: cuota/autenticación/configuración.' if kind=='fatal' else
             'Lanzamiento incierto. Revisar la consola; no se repetirá automáticamente.')
        return kind
    instance=response.data
    if not getattr(instance,'id',None):
        store.save({'status':'uncertain'})
        return 'uncertain'
    store.save({'status':'created','size':list(size)})
    note(f'Instancia A1 creada: {size[0]} OCPU / {size[1]} GB. Finalizado. Revisá la consola Oracle.')
    return 'created'

def run_cycle(store):
    import oci
    config_text=os.environ['OCI_CONFIG']
    key_text=os.environ['OCI_PRIVATE_KEY']
    ssh=os.environ['SSH_PUBLIC_KEY'].strip()
    subnet=os.environ.get('A1_SUBNET_ID','').strip()
    if not subnet or not ssh.startswith(('ssh-','ecdsa-')):
        raise ValueError('Falta A1_SUBNET_ID o la clave pública SSH es inválida')
    with tempfile.TemporaryDirectory() as d:
        key=Path(d)/'key.pem';key.write_text(key_text);key.chmod(0o600)
        parser=configparser.ConfigParser();parser.read_string(config_text)
        if not parser.has_section('DEFAULT') and not parser.defaults():
            raise ValueError('OCI_CONFIG no contiene [DEFAULT]')
        parser['DEFAULT']['key_file']=str(key)
        cfg=Path(d)/'config'
        with cfg.open('w') as f: parser.write(f)
        cfg.chmod(0o600)
        config=oci.config.from_file(str(cfg));oci.config.validate_config(config)
        tenancy=config['tenancy']
        identity=oci.identity.IdentityClient(config,retry_strategy=oci.retry.NoneRetryStrategy())
        subscriptions=identity.list_region_subscriptions(tenancy).data
        home=next(r.region_name for r in subscriptions if r.is_home_region)
        config['region']=home
        identity=oci.identity.IdentityClient(config,retry_strategy=oci.retry.NoneRetryStrategy())
        compute=oci.core.ComputeClient(config,retry_strategy=oci.retry.NoneRetryStrategy())
        network=oci.core.VirtualNetworkClient(config,retry_strategy=oci.retry.NoneRetryStrategy())
        selected=network.get_subnet(subnet).data
        if selected.prohibit_public_ip_on_vnic or selected.lifecycle_state!='AVAILABLE':
            raise ValueError('La subred elegida no está disponible o es privada')
        compartments=[tenancy]+[c.id for c in oci.pagination.list_call_get_all_results(
            identity.list_compartments,tenancy,compartment_id_in_subtree=True,
            access_level='ACCESSIBLE').data if c.lifecycle_state=='ACTIVE']
        instances=[]
        for compartment in compartments:
            instances.extend(oci.pagination.list_call_get_all_results(
                compute.list_instances,compartment_id=compartment).data)
        active=[i for i in instances if i.shape==SHAPE and i.lifecycle_state!='TERMINATED']
        name=os.environ.get('A1_DISPLAY_NAME','').strip() or 'jolufasoft-a1'
        if any(i.display_name==name for i in active):
            store.save({'status':'existing'});note('Ya existe la A1 objetivo. Finalizado.');return 0
        cpu=sum(float(i.shape_config.ocpus) for i in active)
        memory=sum(float(i.shape_config.memory_in_gbs) for i in active)
        if not math.isfinite(cpu+memory) or min(cpu,memory)<0: raise ValueError('Uso A1 inválido')
        if cpu>=2 or memory>=12:
            store.save({'status':'existing'});note('El uso A1 ya alcanzó el límite 2/12. Finalizado.');return 0
        images=oci.pagination.list_call_get_all_results(compute.list_images,compartment_id=tenancy,
            shape=SHAPE,operating_system='Oracle Linux',operating_system_version='9',
            sort_by='TIMECREATED',sort_order='DESC').data
        images=[i for i in images if i.lifecycle_state=='AVAILABLE']
        if not images: raise ValueError('No hay imagen Oracle Linux 9 disponible para A1')
        ads=identity.list_availability_domains(tenancy).data
        if not ads: raise ValueError('No hay dominios de disponibilidad')
        for size in ((2,12),(1,6)):
            if not select_size(cpu,memory,size): continue
            for ad in ads:
                report=compute.create_compute_capacity_report(oci.core.models.CreateComputeCapacityReportDetails(
                    compartment_id=tenancy,availability_domain=ad.name,
                    shape_availabilities=[oci.core.models.CreateCapacityReportShapeAvailabilityDetails(
                        instance_shape=SHAPE,instance_shape_config=oci.core.models.CapacityReportInstanceShapeConfig(
                            ocpus=size[0],memory_in_gbs=size[1]))])).data
                if not report.shape_availabilities: raise ValueError('Informe de capacidad vacío')
                status=report.shape_availabilities[0].availability_status
                note(f'{size[0]} OCPU / {size[1]} GB: {status}')
                if status!='AVAILABLE': continue
                details=oci.core.models.LaunchInstanceDetails(compartment_id=tenancy,availability_domain=ad.name,
                    display_name=name,shape=SHAPE,
                    shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(ocpus=size[0],memory_in_gbs=size[1]),
                    source_details=oci.core.models.InstanceSourceViaImageDetails(image_id=images[0].id,boot_volume_size_in_gbs=50),
                    create_vnic_details=oci.core.models.CreateVnicDetails(subnet_id=subnet,assign_public_ip=True),
                    metadata={'ssh_authorized_keys':ssh})
                result=attempt(compute,details,store,size,ad.name)
                if result=='capacity': continue
                return 1 if result in ('fatal','uncertain') else 0
        note('Sin capacidad. Próximo ciclo programado en unos 15 minutos.');return 0

def main():
    args=argparse.ArgumentParser();args.add_argument('--check-state',action='store_true');options=args.parse_args()
    store=GitHubState();state=store.load()
    enabled=os.environ.get('A1_ENABLED','')=='true'
    proceed=enabled and state.get('status') not in TERMINAL
    if options.check_state:
        with open(os.environ['GITHUB_OUTPUT'],'a') as f: f.write(f'proceed={str(proceed).lower()}\n')
        note(f"A1: {'listo para consultar' if proceed else 'pausado o finalizado'}. Estado: {state.get('status','sin intentos')}.")
        return 0
    if not proceed: note('Proceso pausado o finalizado.');return 0
    try: return run_cycle(store)
    except Exception as error:
        # Read errors never trigger another launch; unknown errors retain pending.
        current=store.load()
        if current.get('status')=='pending':
            note('Estado pendiente conservado. Revisar consola antes de repetir.');return 1
        status=getattr(error,'status',None)
        if status==429 or (isinstance(status,int) and status>=500):
            note('Error temporal durante consulta; se espera el siguiente ciclo.');return 0
        store.save({'status':'fatal'})
        note('Proceso pausado tras un error de consulta/configuración. Revisar permisos, perfil y recursos.');return 1

if __name__=='__main__': raise SystemExit(main())
