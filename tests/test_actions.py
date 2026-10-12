import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace as NS
import unittest
from unittest.mock import MagicMock, patch
import oci

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('actions_a1',ROOT/'actions_a1.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)

class Store:
    def __init__(self,fail=False): self.states=[];self.fail=fail
    def save(self,value):
        if self.fail: raise RuntimeError('GitHub unavailable')
        self.states.append(value)

class ActionsTests(unittest.TestCase):
    def test_state_before_launch_and_success(self):
        store=Store();compute=MagicMock()
        def launch(*args,**kwargs):
            self.assertEqual(store.states[-1]['status'],'pending')
            self.assertIsInstance(kwargs['retry_strategy'],oci.retry.NoneRetryStrategy)
            return NS(data=NS(id='instance'))
        compute.launch_instance.side_effect=launch
        self.assertEqual(a.attempt(compute,object(),store,(2,12),'AD'),'created')
        self.assertEqual(store.states[-1]['status'],'created')
    def test_state_write_failure_prevents_launch(self):
        compute=MagicMock()
        with self.assertRaises(RuntimeError): a.attempt(compute,object(),Store(True),(2,12),'AD')
        compute.launch_instance.assert_not_called()
    def test_uncertain_stops_retry(self):
        store=Store();compute=MagicMock();compute.launch_instance.side_effect=TimeoutError()
        self.assertEqual(a.attempt(compute,object(),store,(2,12),'AD'),'uncertain')
        self.assertEqual(store.states[-1]['status'],'uncertain')
        self.assertIn('uncertain',a.TERMINAL)
    def test_quota_fatal(self):
        store=Store();compute=MagicMock()
        compute.launch_instance.side_effect=oci.exceptions.ServiceError(400,'LimitExceeded',{},'quota')
        self.assertEqual(a.attempt(compute,object(),store,(2,12),'AD'),'fatal')
    def test_capacity_can_try_later(self):
        store=Store();compute=MagicMock()
        compute.launch_instance.side_effect=oci.exceptions.ServiceError(500,'InternalError',{},'Out of host capacity')
        self.assertEqual(a.attempt(compute,object(),store,(2,12),'AD'),'capacity')
        self.assertEqual(store.states[-1]['status'],'retry')
    def test_missing_persistent_file_fails_closed(self):
        with patch.dict(os.environ,{'GH_TOKEN':'test','GITHUB_REPOSITORY':'owner/repo'}):
            store=a.GitHubState()
        with patch.object(store,'request',side_effect=[{'object':{'sha':'head'}},None]):
            with self.assertRaises(RuntimeError): store.load()
    def cycle(self,statuses,child_usage=False):
        identity=MagicMock();compute=MagicMock();network=MagicMock();store=Store()
        identity.list_region_subscriptions.return_value=NS(data=[NS(region_name='sa-saopaulo-1',is_home_region=True)])
        identity.list_availability_domains.return_value=NS(data=[NS(name='AD-1')])
        network.get_subnet.return_value=NS(data=NS(prohibit_public_ip_on_vnic=False,lifecycle_state='AVAILABLE'))
        compute.create_compute_capacity_report.side_effect=[NS(data=NS(shape_availabilities=[NS(availability_status=s)])) for s in statuses]
        compute.launch_instance.return_value=NS(data=NS(id='instance'))
        compartments=[]
        def pages(fn,*args,**kwargs):
            if fn is identity.list_compartments: return NS(data=[NS(id='child',lifecycle_state='ACTIVE')])
            if fn is compute.list_instances:
                compartments.append(kwargs['compartment_id'])
                return NS(data=[NS(shape=a.SHAPE,lifecycle_state='RUNNING',display_name='other',shape_config=NS(ocpus=2,memory_in_gbs=12))] if child_usage and kwargs['compartment_id']=='child' else [])
            if fn is compute.list_images: return NS(data=[NS(id='image',lifecycle_state='AVAILABLE')])
            raise AssertionError('Unexpected call')
        env={'OCI_CONFIG':'[DEFAULT]\ntenancy=tenancy\nregion=region','OCI_PRIVATE_KEY':'dummy','SSH_PUBLIC_KEY':'ssh-ed25519 dummy','A1_SUBNET_ID':'subnet','A1_DISPLAY_NAME':'test'}
        with patch.dict(os.environ,env),patch.object(oci.config,'from_file',return_value={'tenancy':'tenancy'}),patch.object(oci.config,'validate_config'),patch.object(oci.identity,'IdentityClient',return_value=identity),patch.object(oci.core,'ComputeClient',return_value=compute),patch.object(oci.core,'VirtualNetworkClient',return_value=network),patch.object(oci.pagination,'list_call_get_all_results',side_effect=pages):
            result=a.run_cycle(store)
        return result,store,compute,compartments
    def test_full_cycle_fallback_real_sdk_models(self):
        result,store,compute,compartments=self.cycle(['OUT_OF_HOST_CAPACITY','AVAILABLE'])
        self.assertEqual(result,0);self.assertEqual(compartments,['tenancy','child'])
        details=compute.launch_instance.call_args.args[0]
        self.assertEqual(details.shape_config.ocpus,1)
        self.assertEqual(details.shape_config.memory_in_gbs,6)
        self.assertEqual(store.states[-1]['status'],'created')
    def test_usage_in_child_blocks_launch(self):
        result,store,compute,_=self.cycle([],child_usage=True)
        self.assertEqual(result,0);compute.launch_instance.assert_not_called()
        self.assertEqual(store.states[-1]['status'],'existing')
    def test_no_capacity_never_launches_or_writes_pending(self):
        result,store,compute,_=self.cycle(['OUT_OF_HOST_CAPACITY','OUT_OF_HOST_CAPACITY'])
        self.assertEqual(result,0);compute.launch_instance.assert_not_called();self.assertEqual(store.states,[])

if __name__=='__main__': unittest.main()
