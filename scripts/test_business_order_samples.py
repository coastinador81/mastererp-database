"""Unit transaction/dispatch tests with doubles; these are not PostgreSQL tests."""
import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
stub = types.ModuleType('dev_validation')
stub.ISSUER = 'https://example.invalid/issuer'
stub._dev_guard = lambda context: None
with patch.dict(sys.modules, {'dev_validation': stub}):
    spec = importlib.util.spec_from_file_location('samples', ROOT / 'migrations/lambda/business_order_samples.py')
    samples = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(samples)


class DatabaseDouble:
    def __init__(self, *, owner=True, fail=False, replay=False):
        self.calls, self.owner, self.fail, self.replay = [], owner, fail, replay

    def run(self, sql, **params):
        self.calls.append((sql, params))
        if 'FROM plataforma.tenants t' in sql:
            return [('tenant', 'company', 'actor')]
        if sql == 'SELECT current_user':
            return [('mastererp_app',)]
        if 'user_owns_current_tenant' in sql:
            return [(self.owner,)]
        if 'administracion.purchase_read' in sql:
            return [([],)]
        if 'administracion.purchase_options' in sql:
            return [({'moneda_base': 'VES', 'proveedores': [
                {'codigo': s[0], 'id': s[0]} for s in samples.SAMPLES]},)]
        if 'administracion.purchase_write' in sql:
            if self.fail:
                raise Exception({'C': '23505'})
            payload = json.loads(params['payload'])
            assert self.calls[-2][1]['operation'] == 'administracion.documento.' + params['kind'] + '.crear'
            return [({'id': params['key'], 'numero': payload['numero'], 'total': '300',
                      'moneda': 'VES', 'origen_id': payload['origen_id'], 'replayed': self.replay},)]
        return []


class SamplesTest(unittest.TestCase):
    event = dict(name='Tumandaito', operation='seed_orders', owner_subject='9989196e-f051-70d7-0af7-4d92b2e5db9c')

    def test_atomic_canonical_commands(self):
        db = DatabaseDouble()
        result = samples.orders(db, self.event, None)
        self.assertEqual((result['created'], result['replayed']), (3, 0))
        commands = [p for sql, p in db.calls if 'administracion.purchase_write' in sql]
        self.assertEqual([p['kind'] for p in commands], ['solicitud_compra', 'orden_compra'] * 3)
        self.assertEqual([sql for sql, _ in db.calls][-2:], ['SET CONSTRAINTS ALL IMMEDIATE', 'COMMIT'])
        self.assertIn('SET LOCAL ROLE mastererp_app', [s for s, _ in db.calls])

    def test_replay(self):
        result = samples.orders(DatabaseDouble(replay=True), self.event, None)
        self.assertEqual((result['created'], result['replayed']), (0, 3))

    def test_conflict_rolls_back(self):
        db = DatabaseDouble(fail=True)
        with self.assertRaisesRegex(RuntimeError, 'sqlstate=23505'):
            samples.orders(db, self.event, None)
        self.assertEqual(db.calls[-1][0], 'ROLLBACK')
        self.assertNotIn('COMMIT', [s for s, _ in db.calls])

    def test_owner_required(self):
        db = DatabaseDouble(owner=False)
        with self.assertRaises(RuntimeError):
            samples.orders(db, self.event, None)
        self.assertFalse(any('purchase_write' in s for s, _ in db.calls))
        self.assertEqual(db.calls[-1][0], 'ROLLBACK')

    def test_inspection_read_only(self):
        db = DatabaseDouble()
        result = samples.orders(db, dict(self.event, operation='inspect_orders'), None)
        self.assertTrue(result['inspection_only'])
        self.assertEqual(db.calls[0][0], 'BEGIN READ ONLY')
        self.assertFalse(any('purchase_write' in s for s, _ in db.calls))
        self.assertEqual(db.calls[-1][0], 'ROLLBACK')

    def test_scope_and_subject_validation(self):
        for event in [dict(self.event, name='other'), dict(self.event, owner_subject='invalid')]:
            db = DatabaseDouble()
            with self.assertRaises(ValueError):
                samples.orders(db, event, None)
            self.assertFalse(db.calls)


if __name__ == '__main__':
    unittest.main()
