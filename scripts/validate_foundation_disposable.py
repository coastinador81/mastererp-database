"""Local-only PostgreSQL 17.9 model, RLS and real concurrent request probes.

No RDS connection, AWS SDK, host port, volume or external network in the container.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'public.ecr.aws/docker/library/postgres:17.9-alpine'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    name = 'mastererp-foundation-test-' + uuid.uuid4().hex[:10]
    created = False

    def docker(*cmd, check=True):
        run = subprocess.run(['docker', *cmd], capture_output=True, text=True)
        if check and run.returncode:
            # Only local PostgreSQL SQLSTATE/output, never registry URLs or real credentials.
            raise RuntimeError('Docker/local SQL command failed: ' + run.stderr[-1500:])
        return run

    def sql(statement, check=True):
        return docker('exec', name, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1',
                      '-qAt', '-c', statement, check=check)

    try:
        docker('info', '--format', '{{.ServerVersion}}')
        docker('image', 'inspect', IMAGE)  # Do not silently install/pull another version.
        docker('run', '--detach', '--rm', '--network', 'none', '--name', name,
               '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', IMAGE)
        created = True
        for _ in range(80):
            if docker('exec', name, 'pg_isready', '-U', 'postgres', check=False).returncode == 0:
                break
            time.sleep(.25)
        else:
            raise RuntimeError('Disposable PostgreSQL not ready')
        for folder in ['schema', 'seeds', 'tests']:
            docker('cp', str(ROOT / folder), name + ':/tmp/' + folder)
        for _ in range(2):
            for folder in ['schema', 'seeds']:
                for path in sorted((ROOT / folder).glob('*.sql')):
                    docker('exec', name, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1',
                           '--single-transaction', '-f', '/tmp/' + folder + '/' + path.name)
        tested = []
        for path in sorted((ROOT / 'tests').glob('*.sql')):
            docker('exec', name, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-f', '/tmp/tests/' + path.name)
            tested.append(path.name)
        # A complete reapplication must not resurrect an explicitly revoked role grant.
        sql("DELETE FROM plataforma.role_permissions WHERE permission_code='uonify.connections.manage';")
        for folder in ['schema', 'seeds']:
            for path in sorted((ROOT / folder).glob('*.sql')):
                docker('exec', name, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1',
                       '--single-transaction', '-f', '/tmp/' + folder + '/' + path.name)
        assert sql("SELECT count(*) FROM plataforma.role_permissions WHERE permission_code='uonify.connections.manage';").stdout.strip() == '0'
        actor = str(uuid.uuid4())
        code = 'foundation-concurrent-' + uuid.uuid4().hex[:10]
        key = str(uuid.uuid4())
        sql("INSERT INTO plataforma.users(id,email,display_name) VALUES('" + actor + "','" + code + "@example.invalid','Foundation concurrency');")
        def create(label):
            statement = "BEGIN; SET LOCAL ROLE mastererp_app; SELECT set_config('app.current_user_id','" + actor + "',true); "
            statement += "SELECT CASE WHEN current_user='mastererp_app' THEN 'effective_app' ELSE 'WRONG_ROLE' END; "
            statement += "SELECT plataforma.create_tenant_with_owner('" + code + "','" + code + "','" + label + "','individual','" + actor + "','" + key + "'); COMMIT;"
            return sql(statement, check=False)
        with ThreadPoolExecutor(max_workers=8) as pool:
            runs = list(pool.map(create, ['Concurrent tenant'] * 8))
        assert all(run.returncode == 0 and 'effective_app' in run.stdout for run in runs)
        tenant_ids = [run.stdout.strip().splitlines()[-1] for run in runs]
        assert len(set(tenant_ids)) == 1
        mismatch = create('Different content')
        assert mismatch.returncode != 0 and 'Idempotency request conflict' in mismatch.stderr
        counts = sql("SELECT (SELECT count(*) FROM plataforma.tenants WHERE code='" + code + "'),"
                     "(SELECT count(*) FROM plataforma.user_tenants WHERE user_id='" + actor + "'),"
                     "(SELECT count(*) FROM auditoria.events WHERE actor_user_id='" + actor + "'),"
                     "(SELECT count(*) FROM plataforma.idempotency_keys WHERE actor_user_id='" + actor + "');").stdout.strip()
        assert counts == '1|1|1|1', counts
        company_key = str(uuid.uuid4())
        tenant = tenant_ids[0]
        def company(label):
            statement = "BEGIN; SET LOCAL ROLE mastererp_app; SELECT set_config('app.current_user_id','" + actor + "',true); "
            statement += "SELECT set_config('app.current_tenant_id','" + tenant + "',true); "
            statement += "SELECT CASE WHEN current_user='mastererp_app' THEN 'effective_app' ELSE 'WRONG_ROLE' END; "
            statement += "SELECT organizacion.register_company_once('" + company_key + "','" + label + "','US','USD','UTC',NULL); COMMIT;"
            return sql(statement, check=False)
        with ThreadPoolExecutor(max_workers=8) as pool:
            companies = list(pool.map(company, ['Concurrent company'] * 8))
        assert all(run.returncode == 0 and 'effective_app' in run.stdout for run in companies)
        assert len({run.stdout.strip().splitlines()[-1] for run in companies}) == 1
        conflict = company('Different company')
        assert conflict.returncode != 0 and 'Idempotency request conflict' in conflict.stderr
        company_counts = sql("SELECT (SELECT count(*) FROM organizacion.companies WHERE tenant_id='" + tenant + "'),"
                             "(SELECT count(*) FROM auditoria.events WHERE tenant_id='" + tenant + "' AND action='company.created'),"
                             "(SELECT count(*) FROM plataforma.idempotency_keys WHERE actor_user_id='" + actor + "' AND operation='company.create');").stdout.strip()
        assert company_counts == '1|1|1'
        assert sql("SELECT count(*) FROM auditoria.events WHERE actor_user_id='" + actor + "' AND correlation_id IS NULL;").stdout.strip() == '0'
        report = {'postgresql': sql('SHOW server_version').stdout.strip(), 'model_applied_twice': True,
                  'sql_tests_passed': tested, 'effective_role': 'mastererp_app',
                  'concurrent_requests': 8, 'distinct_tenants': 1, 'different_content_conflict': True,
                  'no_partial_effects': counts == '1|1|1|1', 'remote_sql_executed': False,
                  'concurrent_company_requests': 8, 'distinct_companies': 1,
                  'company_content_conflict': True, 'company_no_partial_effects': True,
                  'write_audit_actor_tenant_entity_result_correlation': True,
                  'reapply_does_not_restore_revoked_role_grant': True,
                  'fixture_lifetime': 'ephemeral_container_only',
                  'scope_limit': 'SQL tenant/company primitives; HTTP concurrency pending'}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(report, indent=2))
    finally:
        if created:
            docker('rm', '--force', name, check=False)  # Only the container created above; no volumes.


if __name__ == '__main__':
    main()
