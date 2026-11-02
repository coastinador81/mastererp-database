import unittest
from unittest.mock import patch
from types import SimpleNamespace
from database_apply_required import required
class ClassifierTests(unittest.TestCase):
    def test_explicit_dispatch(self):self.assertTrue(required('workflow_dispatch','','a'*40))
    def test_initial_push_fails_safe(self):self.assertTrue(required('push','0'*40,'a'*40))
    def test_code_only_skips_application(self):
        with patch('database_apply_required.subprocess.run',return_value=SimpleNamespace(stdout='')):self.assertFalse(required('push','a'*40,'b'*40))
    def test_sql_or_tests_require_application(self):
        for path in ('schema/009.sql','seeds/001.sql','tests/access.sql'):
            with patch('database_apply_required.subprocess.run',return_value=SimpleNamespace(stdout=path)):self.assertTrue(required('push','a'*40,'b'*40))
    def test_unknown_event_does_not_silently_skip(self):
        with self.assertRaises(ValueError):required('other','a'*40,'b'*40)
if __name__=='__main__':unittest.main()
