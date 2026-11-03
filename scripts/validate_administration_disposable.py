"""Local-only Administration candidate validation; never AWS or host database."""
import argparse,json,subprocess,time,uuid
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT=Path(__file__).resolve().parents[1]
IMAGE='public.ecr.aws/docker/library/postgres:17.9-alpine'

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    name='mastererp-adm-local-'+uuid.uuid4().hex[:10];created=False;results=[]
    args.output.write_text(json.dumps({'status':'running','remote_sql_executed':False}),encoding='utf-8')
    def docker(*command,check=True):
        r=subprocess.run(['docker',*command],capture_output=True,text=True)
        if check and r.returncode:raise RuntimeError(r.stderr[-4000:])
        return r
    def sql(text,check=True):return docker('exec',name,'psql','-U','postgres','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-qAt','-c',text,check=check)
    def file(path):return docker('exec',name,'psql','-U','postgres','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-q','-f','/work/'+path)
    try:
        docker('info','--format','{{.ServerVersion}}');docker('image','inspect',IMAGE)
        docker('run','--detach','--rm','--network','none','--name',name,'-e','POSTGRES_HOST_AUTH_METHOD=trust',IMAGE);created=True
        for _ in range(100):
            if docker('exec',name,'pg_isready','-U','postgres',check=False).returncode==0:break
            time.sleep(.2)
        else:raise RuntimeError('PostgreSQL not ready')
        docker('exec',name,'mkdir','/work')
        for folder in ['schema','seeds','tests']:docker('cp',str(ROOT/folder),name+':/work/'+folder)
        for pass_no in range(2):
            for folder in ['schema','seeds']:
                for p in sorted((ROOT/folder).glob('*.sql')):
                    docker('exec',name,'psql','-U','postgres','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-q','--single-transaction','-f','/work/'+folder+'/'+p.name)
            results.append({'case':'migration_pass_'+str(pass_no+1),'result':'passed'})
        for p in sorted((ROOT/'tests').glob('*.sql')):
            file('tests/'+p.name);results.append({'case':'baseline_'+p.name,'result':'passed'})
        if (ROOT/'tests/administration/fixtures.sql').exists():
            file('tests/administration/fixtures.sql')
            for p in sorted((ROOT/'tests/administration').glob('*_test.sql')):
                file('tests/administration/'+p.name);results.append({'case':p.name,'result':'passed'})
        scope="BEGIN; SELECT set_config('app.current_user_id','00009001-0000-0000-0000-000000000001',true),set_config('app.current_tenant_id','00009101-0000-0000-0000-000000000001',true),set_config('app.correlation_id','00009999-0000-0000-0000-000000000001',true); "
        def apply_payment(_):
            return sql(scope+"INSERT INTO administracion.aplicaciones_cartera(tenant_id,empresa_id,vencimiento_id,movimiento_id,importe_origen,importe_destino,tipo_cambio,cambio_fecha,cambio_fuente) VALUES('00009101-0000-0000-0000-000000000001','00009201-0000-0000-0000-000000000001','00003200-0000-0000-0000-000000000001','00002300-0000-0000-0000-000000000001',70,70,1,'2026-01-01','local concurrency'); SELECT pg_sleep(0.5); COMMIT;",check=False)
        with ThreadPoolExecutor(max_workers=2) as pool:payments=list(pool.map(apply_payment,range(2)))
        assert sum(p.returncode==0 for p in payments)==1,[p.stderr for p in payments]
        assert any('23514' in p.stderr for p in payments if p.returncode),[p.stderr for p in payments]
        assert sql("SELECT pendiente FROM administracion.saldos_vencimientos WHERE vencimiento_id='00003200-0000-0000-0000-000000000001'").stdout.strip()=='10'
        assert sql("SELECT count(*) FROM administracion.aplicaciones_cartera WHERE movimiento_id='00002300-0000-0000-0000-000000000001'").stdout.strip()=='1'
        results.append({'case':'concurrent_over_application','transactions':2,'committed':1,'rejected_sqlstate':'23514','remaining':10,'result':'passed'})
        def update_version(label):
            return sql(scope+"UPDATE administracion.condiciones_comerciales SET descripcion='"+label+"',version=2 WHERE id='00001001-0000-0000-0000-000000000001'; SELECT pg_sleep(0.5); COMMIT;",check=False)
        with ThreadPoolExecutor(max_workers=2) as pool:versions=list(pool.map(update_version,['writer A','writer B']))
        assert sum(p.returncode==0 for p in versions)==1,[p.stderr for p in versions]
        assert any('40001' in p.stderr for p in versions if p.returncode),[p.stderr for p in versions]
        results.append({'case':'concurrent_stale_version','transactions':2,'committed':1,'rejected_sqlstate':'40001','result':'passed'})
        assert sql("SELECT count(*) FROM auditoria.events WHERE module_code='2.2.1-administration' AND entity_type='aplicaciones_cartera'").stdout.strip()=='2'
        results.append({'case':'failed_write_has_no_audit_or_allocation_effect','result':'passed'})
        sql("DELETE FROM plataforma.role_permissions WHERE permission_code='administration.read'")
        for migration in sorted((ROOT/'schema').glob('*.sql')):
            if int(migration.name[:3])>=9:file('schema/'+migration.name)
        assert sql("SELECT count(*) FROM plataforma.role_permissions WHERE permission_code='administration.read'").stdout.strip()=='0'
        assert sql("SELECT has_table_privilege('mastererp_app','administracion.documentos','INSERT')").stdout.strip()=='f'
        results.append({'case':'candidate_reapply_preserves_revoked_role_permissions_and_no_app_writes','result':'passed'})
        report={'status':'passed','postgres':sql('SHOW server_version').stdout.strip(),'environment':'disposable container, network none, no host ports','results':results,'remote_sql_executed':False,
            'administration_tables':sql("SELECT count(*) FROM information_schema.tables WHERE table_schema='administracion' AND table_type='BASE TABLE'").stdout.strip(),
            'canonical_tables':sql("SELECT count(*) FROM information_schema.tables WHERE table_schema='catalogo' AND table_type='BASE TABLE'").stdout.strip()}
        args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
    except Exception as error:
        args.output.write_text(json.dumps({'status':'failed','results':results,'error':str(error),'remote_sql_executed':False},indent=2)+'\n',encoding='utf-8')
        raise
    finally:
        if created:docker('rm','--force',name,check=False)
if __name__=='__main__':main()
