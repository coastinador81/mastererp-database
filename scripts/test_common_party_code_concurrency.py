"""Run only against a disposable loopback PostgreSQL with schema/seeds through 041.

Requires existing pg8000; never installs tools. QA database must be discarded after
the test: committed synthetic fixtures allow independent sessions to see them.
"""
import concurrent.futures
import os
from pathlib import Path
import threading
import unittest

try:
    import pg8000.dbapi as pg
except ImportError:
    pg = None


@unittest.skipUnless(pg and os.getenv('MASTERERP_LOCAL_QA_DATABASE'),
                     'Requires existing pg8000 and disposable local database')
class CodeConcurrency(unittest.TestCase):
    def test_two_updates(self):
        database = os.environ['MASTERERP_LOCAL_QA_DATABASE']
        self.assertTrue(database.startswith('qa_'), 'Disposable qa_ database required')
        def connect():
            return pg.connect(host='127.0.0.1', database=database,
                              user=os.environ['MASTERERP_LOCAL_QA_USER'],
                              password=os.environ['MASTERERP_LOCAL_QA_PASSWORD'],
                              port=int(os.getenv('MASTERERP_LOCAL_QA_PORT', '5432')))
        conn = connect()
        setup = (Path(__file__).parents[1] / 'tests/common_party_code_test.sql').read_text(encoding='utf-8').split('DO $$')[0]
        cur = conn.cursor()
        cur.execute(setup)
        cur.execute("SELECT set_config('app.current_operation','administration.proveedor.create',true)")
        cur.execute("SELECT administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','create',NULL,'QA-RACE','QA race',NULL,'qa-code-race','{}',NULL,NULL)")
        party = cur.fetchone()[0]
        cur.execute("SELECT set_config('app.current_operation','administration.cliente.create',true)")
        cur.execute("SELECT administracion.party_write_v2('00008003-0000-0000-0000-000000000001','cliente','create',%s,NULL,NULL,NULL,'qa-code-race-client','{}',NULL,NULL)",(party['id'],))
        cur.execute('SET CONSTRAINTS ALL IMMEDIATE')
        conn.commit()
        conn.close()
        barrier = threading.Barrier(2)
        def update(spec):
            code,role,contacts = spec
            c = connect()
            try:
                q = c.cursor()
                q.execute("SET LOCAL ROLE mastererp_app")
                q.execute("SET LOCAL lock_timeout='5s'")
                q.execute("SELECT current_user")
                self.assertEqual(q.fetchone()[0], 'mastererp_app')
                for key, value in {
                    'app.current_user_id':'00008001-0000-0000-0000-000000000001',
                    'app.current_tenant_id':'00008002-0000-0000-0000-000000000001',
                    'app.current_operation':('catalog.suppliers.update' if role=='catalog' else 'administration.'+role+'.update'),
                    'app.correlation_id':'00008004-0000-0000-0000-000000000001',
                }.items():
                    q.execute('SELECT set_config(%s,%s,true)', (key,value))
                barrier.wait(timeout=10)
                if role=='catalog':
                    q.execute("SELECT catalogo.proveedor_actualizar(%s,%s,'{\"name\":\"QA catalog race\"}'::jsonb)",(party['id'],party['catalog_version']))
                else:
                    payload='{"contactos":[{"nombre":"QA race contact","principal":false}]}' if contacts else '{}'
                    q.execute("SELECT administracion.party_write_v2('00008003-0000-0000-000000000001',%s,'update',%s,%s,'QA race',%s,NULL,%s::jsonb,NULL,%s)", (role,party['id'],code,party['version'],payload,party['catalog_version'] if contacts else None))
                q.execute('SET CONSTRAINTS ALL IMMEDIATE')
                c.commit()
                return 'committed'
            except Exception as error:
                c.rollback()
                detail = error.args[0] if error.args and isinstance(error.args[0],dict) else {}
                if detail.get('C') == '40001':
                    return 'stale'
                raise
            finally:
                c.close()
        for index,roles in enumerate([('proveedor','catalog'),('cliente','proveedor'),('proveedor','proveedor')]):
            with self.subTest(roles=roles):
                conn=connect()
                q=conn.cursor()
                q.execute('SELECT t.version,s.version FROM catalogo.terceros t JOIN catalogo.proveedores_catalogo s ON (s.tenant_id,s.tercero_id)=(t.tenant_id,t.id) WHERE t.id=%s',(party['id'],))
                party['version'],party['catalog_version']=q.fetchone()
                conn.rollback();conn.close()
                specs=[('QA-RACE-'+str(index)+'-'+str(i),role,role=='proveedor') for i,role in enumerate(roles)]
                with concurrent.futures.ThreadPoolExecutor(2) as pool:
                    results=list(pool.map(update,specs))
                self.assertCountEqual(results,['committed','stale'])
                conn=connect()
                try:
                    q=conn.cursor()
                    q.execute('SELECT t.codigo,s.codigo,t.version,s.version FROM catalogo.terceros t JOIN catalogo.proveedores_catalogo s ON (s.tenant_id,s.tercero_id)=(t.tenant_id,t.id) WHERE t.id=%s',(party['id'],))
                    master,supplier,mv,sv=q.fetchone()
                    self.assertEqual(master,supplier)
                    self.assertEqual(mv,party['version']+1)
                    self.assertEqual(sv,party['catalog_version']+1)
                finally:
                    conn.rollback();conn.close()



if __name__ == '__main__':
    unittest.main()
