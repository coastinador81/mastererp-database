"""Read-only DEV regression probes; no QA state mutation or session creation."""
import argparse,json,sys,urllib.request,urllib.error
from pathlib import Path
import boto3

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--platform',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    sys.path.insert(0,str(args.platform/'scripts'))
    import identity_qa_client as qa
    s=boto3.Session(profile_name='mastererp-admin',region_name='us-west-1')
    assert s.client('sts').get_caller_identity()['Account']=='277352717693'
    bundle=json.loads(s.client('secretsmanager').get_secret_value(SecretId='mastererp/dev/qa/identity-validation')['SecretString'])
    tokens={k:qa.tokens(bundle['actors'][k])['access_token'] for k in ('admin_a','admin_b','member_a')}
    results=[]
    def probe(case,url,expected,label=None,tenant=None):
        headers={'Origin':qa.ORIGIN}
        if label:headers['Authorization']='Bearer '+tokens[label]
        if tenant:headers['X-MasterERP-Tenant-Id']=tenant
        try:r=urllib.request.urlopen(urllib.request.Request(url,headers=headers),timeout=30)
        except urllib.error.HTTPError as error:r=error
        body=json.load(r);valid=r.status==expected
        if expected==200 and url.endswith('/status'):valid=valid and body.get('status')=='not_configured'
        results.append({'case':case,'http':r.status,'expected':expected,'result':'passed' if valid else 'failed'})
    a,b=bundle['tenants']['a'],bundle['tenants']['b']
    for label,t in [('admin_a',a),('admin_b',b)]:
        probe('uonify_'+label,qa.API+qa.STATUS,200,label,t)
        probe('spaces_'+label,qa.API+qa.SPACES,200,label)
    probe('uonify_missing_token',qa.API+qa.STATUS,401,tenant=a)
    probe('uonify_member_denied',qa.API+qa.STATUS,403,'member_a',a)
    probe('uonify_foreign_tenant',qa.API+qa.STATUS,403,'admin_a',b)
    probe('uonify_context_return',qa.API+qa.STATUS,200,'admin_a',a)
    base='https://qx8nmypdhi.execute-api.us-west-1.amazonaws.com/v1/onboarding/sessions/ffffffff-ffff-ffff-ffff-ffffffffffff'
    probe('onboarding_missing_token',base,401)
    probe('onboarding_authenticated_unknown_session',base,404,'admin_a')
    report={'mode':'read_only_HTTP_no_existing_QA_state_changes','results':results,'onboarding_write_flows':'not_exercised; no existing data modified'}
    args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report))
    if any(r['result']!='passed' for r in results):raise SystemExit(1)
if __name__=='__main__':main()
