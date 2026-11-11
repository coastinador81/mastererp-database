"""Classify push paths without reapplying a model for code-only Lambda updates."""
import os,re,subprocess

OPERATIONS_PATHS={
    'schema/052_operations_order_history_read.sql',
    'schema/053_operations_order_cancellation_notes.sql',
    'schema/054_finance_payment_review.sql',
    'schema/055_finance_receipts_history.sql',
}

def batch_for_paths(requested,paths):
    batch=requested or 'customer'
    if any(p in OPERATIONS_PATHS for p in paths):return 'operations'
    if any(p in ('schema/046_sales_order_command.sql','tests/sales_order_command_test.sql',
                 'schema/047_sales_confirmation_contract.sql','tests/sales_confirmation_contract_test.sql',
                 'schema/048_sales_read_model.sql','tests/sales_read_test.sql')
           or p.startswith('migrations/lambda/sales_') for p in paths):return 'sales'
    return batch

def required(event,before,after):
    if event=='workflow_dispatch':return True  # Explicit Apply action retains its contract.
    if event!='push' or not re.fullmatch('[0-9a-f]{40}',before or '') or not re.fullmatch('[0-9a-f]{40}',after or ''):
        raise ValueError('Invalid workflow event or revision')
    if before=='0'*40:return True
    result=subprocess.run(['git','diff','--name-only',before,after,'--','schema/','seeds/','tests/'],capture_output=True,text=True,check=True)
    return bool(result.stdout.strip())

if __name__=='__main__':
    value='true' if required(os.environ['GITHUB_EVENT_NAME'],os.environ.get('BEFORE_SHA',''),os.environ['GITHUB_SHA']) else 'false'
    batch=os.environ.get('REQUESTED_BATCH') or 'customer'
    if os.environ['GITHUB_EVENT_NAME']=='push':
        before=os.environ['BEFORE_SHA']
        if before=='0'*40:raise ValueError('Initial push requires explicit reviewed batch')
        paths=subprocess.check_output(['git','diff','--name-only',before,os.environ['GITHUB_SHA']],text=True).splitlines()
        batch=batch_for_paths(batch,paths)
    if batch not in ('customer','sales','operations'):raise ValueError('Unknown migration batch')
    with open(os.environ['GITHUB_OUTPUT'],'a',encoding='utf-8') as out:
        out.write('required='+value+'\n'+'batch='+batch+'\n')
    print('Database apply required: '+value)
