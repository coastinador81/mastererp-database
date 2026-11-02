"""Local fault injection: fail closed and report which schema commits survived."""
import importlib.util,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock,patch
spec=importlib.util.spec_from_file_location('migrator',Path(__file__).resolve().parents[1]/'migrations/lambda/handler.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class FailureTests(unittest.TestCase):
    def test_failure_is_propagated_for_every_phase(self):
        size=len(module.SCHEMA_FILES)+len(module.SEED_FILES)
        for threshold,phase,commits in ((1,'schema',0),(size+1,'reapply',1),(2*size+1,'tests',2)):
            with self.subTest(phase=phase):
                connection=MagicMock();seen=0
                def execute(sql):
                    nonlocal seen
                    if sql=='PACKAGED_SQL':
                        seen+=1
                        if seen==threshold:raise RuntimeError({'C':'42501','M':'sentinel_private_value'})
                    return []
                connection.run.side_effect=execute
                with patch.object(module,'_connection',return_value=connection),patch.object(module,'Path') as source:
                    directory=MagicMock();directory.__truediv__.return_value.read_text.return_value='PACKAGED_SQL'
                    source.return_value.parent.__truediv__.return_value=directory
                    with self.assertRaises(RuntimeError) as failed:
                        module.lambda_handler({},SimpleNamespace(aws_request_id='synthetic-correlation'))
                message=str(failed.exception)
                self.assertIn('phase='+phase,message);self.assertIn('committed_passes='+str(commits),message)
                self.assertIn('sqlstate=42501',message);self.assertNotIn('sentinel_private_value',message)
                self.assertTrue(any(call.args[0]=='ROLLBACK' for call in connection.run.call_args_list))
                connection.close.assert_called_once()
if __name__=='__main__':unittest.main()
