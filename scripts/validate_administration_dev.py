"""Invoke only explicit Administration validation actions on official DEV migrator."""
import json
from pathlib import Path
import boto3
from botocore.config import Config

def main():
    root=Path(__file__).resolve().parents[1]
    report_path=root/'docs/administration-dev-validation.json'
    report=json.loads(report_path.read_text(encoding='utf-8'))
    session=boto3.Session(profile_name='mastererp-admin',region_name='us-west-1')
    assert session.client('sts').get_caller_identity()['Account']=='277352717693'
    client=session.client('lambda',config=Config(read_timeout=310,retries={'max_attempts':0}))
    config=client.get_function_configuration(FunctionName='mastererp-dev-database-migrator')
    assert config['State']=='Active' and config['LastUpdateStatus']=='Successful'
    assert config['Environment']['Variables']['ENVIRONMENT']=='dev' and config['Environment']['Variables']['DB_NAME']=='mastererp'
    report['migrator_code_sha256']=config['CodeSha256']
    report['validation_results']=[]
    for mode in ('rollback_suites','concurrency'):
        event={'action':'validate_administration'}
        if mode=='concurrency':event['mode']=mode
        response=client.invoke(FunctionName='mastererp-dev-database-migrator',Payload=json.dumps(event).encode())
        result=json.load(response['Payload'])
        report['validation_results'].append({'mode':mode,'function_error':response.get('FunctionError'),'result':result})
        report['status']='failed' if response.get('FunctionError') or result.get('status')!='succeeded' else 'validation_in_progress'
        report_path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print(json.dumps(report['validation_results'][-1]))
        if report['status']=='failed':raise SystemExit(1)
    report['status']='SQL_validation_passed_with_documented_remote_coverage_limits'
    report_path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
