"""Pruebas sin credenciales ni acceso OCI real."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
FAKE='''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]; mode=os.environ['MOCK_MODE']
with open(os.environ['MOCK_CALLS'],'a') as f: f.write(json.dumps(a)+'\\n')
if 'tenancy' in a: print('Cuenta de prueba')
elif 'compute-capacity-report' in a:
    size=json.loads(a[a.index('--shape-availabilities')+1])[0]['instanceShapeConfig']['ocpus']
    print('OUT_OF_HOST_CAPACITY' if mode=='fallback' and size==2 else 'AVAILABLE')
elif 'list' in a: print('invalid' if mode=='bad-usage' else '[{"ocpus":2,"mem":12}]' if mode=='full' else '[]')
elif 'launch' in a:
    if mode=='uncertain': print('Respuesta incompleta')
    elif mode=='quota': print('LimitExceeded'); sys.exit(1)
    else: print('ocid1.instance.oc1.test')
else: sys.exit(9)
'''
class LaunchTests(unittest.TestCase):
 def run_case(self,mode):
  with tempfile.TemporaryDirectory() as d:
   d=Path(d); fake=d/'oci';fake.write_text(FAKE);fake.chmod(0o700)
   (d/'config').write_text('[DEFAULT]\n');(d/'ssh.pub').write_text('ssh-ed25519 test')
   vals=dict(TENANCY_NAME='prueba',COMPARTMENT_ID='ocid1.tenancy.oc1.test',OCI_CONFIG_FILE=str(d/'config'),SSH_KEY_FILE=str(d/'ssh.pub'),OCI_BIN=str(fake),SUBNET_ID='subnet',IMAGE_ID='image',ADS='AD-1',LOCK_FILE=str(d/'lock'),LOG_TO_FILE='0',NTP_CHECK_ENABLED='0',CAPACITY_REQUEST_DELAY_SECONDS='1',NETWORK_RECHECK_DELAYS='1')
   lines=[]
   for line in (ROOT/'.env.example').read_text().splitlines():
    k=line.partition('=')[0];lines.append(k+'='+shlex.quote(vals[k]) if k in vals else line)
   envfile=d/'.env';envfile.write_text('\n'.join(lines))
   env=dict(os.environ,ENV_FILE=str(envfile),MOCK_MODE=mode,MOCK_CALLS=str(d/'calls'))
   r=subprocess.run(['bash',str(ROOT/'oci_capacity_retry.sh')],env=env,text=True,capture_output=True,timeout=15)
   calls=[json.loads(l) for l in (d/'calls').read_text().splitlines()]
   launches=[a for a in calls if 'launch' in a]
   if mode=='fallback':
    self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertEqual(len(launches),1)
    self.assertEqual(json.loads(launches[0][launches[0].index('--shape-config')+1])['ocpus'],1)
   elif mode in ('bad-usage','quota','uncertain'):
    self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
    self.assertEqual(len(launches),0 if mode=='bad-usage' else 1)
   else:
    self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertEqual(len(launches),0 if mode=='full' else 1)
   if mode in ('success','fallback','uncertain','quota'):
    again=subprocess.run(['bash',str(ROOT/'oci_capacity_retry.sh')],env=env,capture_output=True,timeout=5)
    self.assertNotEqual(again.returncode,0)
    self.assertEqual(len((d/'calls').read_text().splitlines()),len(calls))
 def test_success(self): self.run_case('success')
 def test_fallback(self): self.run_case('fallback')
 def test_uncertain(self): self.run_case('uncertain')
 def test_quota(self): self.run_case('quota')
 def test_bad_usage(self): self.run_case('bad-usage')
 def test_full(self): self.run_case('full')

class CapacityTests(unittest.TestCase):
 def test_official_capacity_status(self):
  import sys
  from types import SimpleNamespace
  from unittest.mock import patch
  spec=importlib.util.spec_from_file_location('checker',ROOT/'oracle_free_tier_checker.py')
  module=importlib.util.module_from_spec(spec); sys.modules['checker']=module;spec.loader.exec_module(module)
  module.SETTINGS=module.Settings('test','tenancy','region',Path('/config'),'DEFAULT','oci','VM.Standard.A1.Flex',2,12,('AD-1',),30)
  for status,expected in [('AVAILABLE',True),('OUT_OF_HOST_CAPACITY',False),('UNKNOWN',None)]:
   payload={'data':{'shape-availabilities':[{'availability-status':status}]}}
   result=SimpleNamespace(returncode=0,stdout=json.dumps(payload),stderr='')
   with patch.object(module.subprocess,'run',return_value=result):
    self.assertIs(module.check_domain('AD-1')['available'],expected)

if __name__=='__main__': unittest.main()
