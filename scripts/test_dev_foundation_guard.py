"""The privileged QA action must reject non-DEV/non-fixture requests before SQL."""
import importlib.util,os,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock,patch
spec=importlib.util.spec_from_file_location('dev_validation',Path(__file__).resolve().parents[1]/'migrations/lambda/dev_validation.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
CONTEXT=SimpleNamespace(invoked_function_arn='arn:aws:lambda:us-west-1:277352717693:function:mastererp-dev-database-migrator')
class GuardTests(unittest.TestCase):
    def test_invalid_requests_never_touch_sql(self):
        with patch.dict(os.environ,{'ENVIRONMENT':'dev','DB_NAME':'mastererp'}):
            for event in ({'run':'real-tenant','case':'baseline'},
                          {'run':'qa-identity-123456abcdef','case':'arbitrary_sql'},
                          {'run':'qa-identity-123456abcdef','case':'baseline','actor_label':'customer'}):
                database=MagicMock()
                with self.assertRaises(ValueError): module.foundation_state(database,event,CONTEXT)
                database.run.assert_not_called()
    def test_cleanup_rejects_unidentified_session_before_delete(self):
        database=MagicMock();database.run.side_effect=[None,[["actor","tenant","active","active","active","module"]],None]
        with patch.dict(os.environ,{'ENVIRONMENT':'dev','DB_NAME':'mastererp'}),self.assertRaises(RuntimeError):
            module.foundation_state(database,{'run':'qa-identity-123456abcdef','case':'cleanup_session','session_id':'not-a-uuid','nonce':'not-a-uuid'},CONTEXT)
        self.assertEqual(database.run.call_args.args[0],'ROLLBACK')
        self.assertFalse(any('DELETE' in call.args[0] for call in database.run.call_args_list))

    def test_other_environment_never_touches_sql(self):
        database=MagicMock()
        with patch.dict(os.environ,{'ENVIRONMENT':'prod','DB_NAME':'mastererp'}),self.assertRaises(ValueError):
            module.foundation_state(database,{'run':'qa-identity-123456abcdef','case':'baseline'},CONTEXT)
        database.run.assert_not_called()
if __name__=='__main__':unittest.main()
