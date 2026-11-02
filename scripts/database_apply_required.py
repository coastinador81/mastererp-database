"""Classify push paths without reapplying a model for code-only Lambda updates."""
import os,re,subprocess

def required(event,before,after):
    if event=='workflow_dispatch':return True  # Explicit Apply action retains its contract.
    if event!='push' or not re.fullmatch('[0-9a-f]{40}',before or '') or not re.fullmatch('[0-9a-f]{40}',after or ''):
        raise ValueError('Invalid workflow event or revision')
    if before=='0'*40:return True
    result=subprocess.run(['git','diff','--name-only',before,after,'--','schema/','seeds/','tests/'],capture_output=True,text=True,check=True)
    return bool(result.stdout.strip())

if __name__=='__main__':
    value='true' if required(os.environ['GITHUB_EVENT_NAME'],os.environ.get('BEFORE_SHA',''),os.environ['GITHUB_SHA']) else 'false'
    with open(os.environ['GITHUB_OUTPUT'],'a',encoding='utf-8') as out:out.write('required='+value+'\n')
    print('Database apply required: '+value)
