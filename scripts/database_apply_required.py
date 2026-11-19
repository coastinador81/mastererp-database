"""Classify push paths without reapplying a model for code-only Lambda updates."""
import os,re,subprocess

OPERATIONS_PATHS={
    'schema/050_storefront_store_payment_methods.sql',
    'schema/052_operations_order_history_read.sql',
    'schema/053_operations_order_cancellation_notes.sql',
    'schema/054_finance_payment_review.sql',
    'schema/055_finance_receipts_history.sql',
    'schema/056_finance_receipt_exchange_rate.sql',
    'schema/057_storefront_payment_declaration.sql',
    'schema/057_operations_orders_search.sql',
    'schema/058_driver_delivery_flow.sql',
    'schema/059_delivery_contract_consistency.sql',
    'schema/068_finance_cancelled_payment_trace.sql',
    'schema/069_finance_cancelled_order_refunds.sql',
    'tests/operations_fulfillment_ecommerce_test.sql',
    'tests/storefront_store_payment_methods_test.sql',
}

def batch_for_paths(requested,paths):
    batch=requested or 'customer'
    if any(p in ('schema/078_finance_supplier_codes.sql','tests/finance_supplier_codes_test.sql') for p in paths):return 'supplier'
    if any(p in ('schema/071_catalog_product_relations.sql','tests/catalog_product_relations_test.sql','schema/072_catalog_pagination.sql','tests/catalog_pagination_test.sql','schema/073_catalog_inventory_product_visibility.sql','tests/catalog_inventory_product_visibility_test.sql','schema/074_storefront_nodes_variants.sql','tests/storefront_customer_identity_test.sql','schema/075_canonical_exchange_rates.sql','tests/canonical_exchange_rates_test.sql','schema/076_company_fiscal_frontend_context.sql','schema/077_company_fiscal_profile.sql','tests/company_fiscal_profile_test.sql') for p in paths):return 'catalog'
    if any(p in OPERATIONS_PATHS for p in paths):return 'operations'
    if any(p in ('schema/046_sales_order_command.sql','tests/sales_order_command_test.sql',
                 'schema/047_sales_confirmation_contract.sql','tests/sales_confirmation_contract_test.sql',
                 'schema/048_sales_read_model.sql','tests/sales_read_test.sql',
                 'schema/067_sales_administrative_order_origin.sql')
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
    if batch not in ('customer','sales','operations','catalog','supplier'):raise ValueError('Unknown migration batch')
    with open(os.environ['GITHUB_OUTPUT'],'a',encoding='utf-8') as out:
        out.write('required='+value+'\n'+'batch='+batch+'\n')
    print('Database apply required: '+value)
