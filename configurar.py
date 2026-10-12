#!/usr/bin/env python3
"""Asistente en español. Consulta recursos existentes; no crea recursos."""
import configparser
import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path(__file__).resolve().parent
config_path = Path(input('Ruta de configuración OCI [~/.oci/config]: ').strip() or '~/.oci/config').expanduser().resolve()
profile = input('Perfil [DEFAULT]: ').strip() or 'DEFAULT'
p = configparser.ConfigParser()
with config_path.open() as f:
    p.read_file(f)
tenancy = p[profile]['tenancy']
region = p[profile].get('region', 'sa-saopaulo-1')
base = ['oci', '--config-file', str(config_path), '--profile', profile, '--region', region, '--no-retry']
def query(*args):
    return json.loads(subprocess.check_output(base + list(args), text=True))['data']
regions = query('iam', 'region-subscription', 'list', '--tenancy-id', tenancy)
home = next(r['region-name'] for r in regions if r['is-home-region'])
base[base.index('--region')+1] = home
region = home
ads = query('iam', 'availability-domain', 'list', '--compartment-id', tenancy)
subnets = query('network', 'subnet', 'list', '--compartment-id', tenancy, '--all')
subnets = [s for s in subnets if not s.get('prohibit-public-ip-on-vnic') and s.get('lifecycle-state') == 'AVAILABLE']
if not subnets:
    raise SystemExit('No hay subred pública en el compartimento raíz. Creala en Oracle y repetí el asistente.')
for i,s in enumerate(subnets,1):
    print(f"{i}. {s['display-name']} ({s['id']})")
choice = int(input('Subred [1]: ').strip() or '1')
if choice < 1 or choice > len(subnets): raise SystemExit('Selección inválida')
ssh = Path(input('Ruta de clave pública SSH [.pub]: ').strip()).expanduser().resolve()
if not ssh.is_file() or not ssh.read_text().startswith(('ssh-', 'ecdsa-')):
    raise SystemExit('Se requiere un archivo de clave pública SSH válido.')
name = input('Nombre de la instancia [jolufasoft-a1]: ').strip() or 'jolufasoft-a1'
values = dict(TENANCY_NAME='Oracle',COMPARTMENT_ID=tenancy,REGION=region,OCI_CONFIG_FILE=str(config_path),OCI_PROFILE=profile,SSH_KEY_FILE=str(ssh),DISPLAY_NAME=name,SUBNET_ID=subnets[choice-1]['id'],ADS=','.join(a['name'] for a in ads),LOCK_FILE=f'/tmp/oci-a1-{tenancy[-16:]}.lock',LOG_TO_FILE='0',NTP_CHECK_ENABLED='0')
# Android sincroniza el reloj del dispositivo; no requiere sntp dentro de Debian.
dest = root/'.env'
if dest.exists(): raise SystemExit('Ya existe .env; se conserva. Editalo si necesitás cambiarlo.')
lines=[]
for line in (root/'.env.example').read_text().splitlines():
    key=line.partition('=')[0]
    lines.append(f'{key}={shlex.quote(values[key])}' if key in values else line)
fd=os.open(dest,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f: f.write('\n'.join(lines)+'\n')
print(f'Configuración lista para {region}. Probá: DRY_RUN=1 bash oci_capacity_retry.sh')
