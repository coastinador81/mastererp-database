"""Explicitly approved DEV sample orders; canonical commands, no schema changes."""
import json
from uuid import UUID, uuid4
from dev_validation import ISSUER, _dev_guard

SAMPLES = (
    ('DEMO-PROV-001', 'PRUEBA: materiales de oficina, sin compra real', '2', '150.00'),
    ('DEMO-PROV-002', 'PRUEBA: empaques, sin compra real', '5', '85.00'),
    ('DEMO-PROV-003', 'PRUEBA: mantenimiento, sin compra real', '1', '240.00'),
)
PREFIX = 'PRUEBA-OC-UONIFY-'


def _all(connection, company, kind):
    items, after = [], None
    for _ in range(200):
        batch = connection.run(
            'SELECT administracion.purchase_read(:company,:kind,NULL,100,:after)',
            company=company, kind=kind, after=after)[0][0]
        items.extend(batch)
        if len(batch) < 100:
            return items
        after = batch[-1]['id']
    raise ValueError('Sample inspection page bound exceeded')


def orders(connection, event, context):
    _dev_guard(context)
    if event.get('name') != 'Tumandaito':
        raise ValueError('Only the explicitly approved business may be seeded')
    operation = event.get('operation')
    if operation not in ('inspect_orders', 'seed_orders'):
        raise ValueError('Unsupported order sample operation')
    subject = str(UUID(str(event.get('owner_subject', ''))))
    correlation, phase = str(uuid4()), 'scope'
    connection.run('BEGIN READ ONLY' if operation == 'inspect_orders' else 'BEGIN')
    try:
        connection.run("SELECT pg_advisory_xact_lock(hashtextextended('mastererp-dev:tumandaito:sample-orders:v1',0))")
        scope = connection.run("""SELECT t.id,c.id,e.user_id FROM plataforma.tenants t
            JOIN organizacion.companies c ON c.tenant_id=t.id
            JOIN plataforma.external_identities e ON e.issuer=:issuer AND e.subject=:subject
            JOIN plataforma.users u ON u.id=e.user_id
            WHERE t.code='tumandaito' AND t.slug='tumandaito' AND t.status='active'
            AND c.legal_name='Tumandaito' AND c.status='active'
            AND e.status='active' AND u.status='active'""", issuer=ISSUER, subject=subject)
        if len(scope) != 1:
            raise ValueError('Approved scope not uniquely identified')
        tenant, company, actor = map(str, scope[0])
        connection.run('SET LOCAL ROLE mastererp_app')
        if connection.run('SELECT current_user')[0][0] != 'mastererp_app':
            raise ValueError('Application role required')
        connection.run("""SELECT set_config('app.current_user_id',:actor,true),
            set_config('app.current_tenant_id',:tenant,true),
            set_config('app.current_company_id',:company,true),
            set_config('app.correlation_id',:correlation,true)""",
            actor=actor, tenant=tenant, company=company, correlation=correlation)
        if connection.run('SELECT plataforma.user_owns_current_tenant(:tenant)', tenant=tenant)[0][0] is not True:
            raise ValueError('Only the approved owner may seed this business')
        phase = 'inspect'
        before = _all(connection, company, 'orden_compra')
        expected = {PREFIX + str(i).zfill(3) for i in range(1, 4)}
        if operation == 'inspect_orders':
            samples = [r for r in before if r['numero'] in expected]
            connection.run('ROLLBACK')
            return {'status': 'succeeded', 'inspection_only': True, 'application_role': 'mastererp_app',
                    'tenant_id': tenant, 'company_id': company, 'synthetic': True,
                    'total_company_orders': len(before), 'orders': samples}
        phase = 'suppliers'
        suppliers, after, base = {}, None, None
        for _ in range(200):
            options = connection.run('SELECT administracion.purchase_options(:company,:after,100)',
                                     company=company, after=after)[0][0]
            base = options['moneda_base']
            batch = options['proveedores']
            for supplier in batch:
                if supplier['codigo'] in {s[0] for s in SAMPLES}:
                    if supplier['codigo'] in suppliers:
                        raise ValueError('Ambiguous sample supplier')
                    suppliers[supplier['codigo']] = supplier['id']
            if len(batch) < 100:
                break
            after = batch[-1]['id']
        else:
            raise ValueError('Supplier page bound exceeded')
        if len(suppliers) != len(SAMPLES) or not base:
            raise ValueError('Approved synthetic suppliers unavailable')
        phase, created, replayed, result = 'seed', 0, 0, []
        for index, (code, description, quantity, price) in enumerate(SAMPLES, 1):
            suffix = str(index).zfill(3)
            payload = {'proveedor_id': suppliers[code], 'origen_id': '', 'fecha': '2026-11-18',
                       'numero': 'PRUEBA-SOL-UONIFY-' + suffix, 'serie': 'PRUEBA', 'moneda': base,
                       'tipo_cambio': '1', 'cambio_fecha': '2026-11-18',
                       'cambio_fuente': 'Misma moneda base; ejemplo ficticio',
                       'lineas': [{'descripcion': description, 'cantidad': quantity, 'precio_unitario': price}]}
            for kind in ('solicitud_compra', 'orden_compra'):
                connection.run("SELECT set_config('app.current_operation',:operation,true)",
                               operation='administracion.documento.' + kind + '.crear')
                row = connection.run(
                    'SELECT administracion.purchase_write(:company,:kind,NULL,NULL,:key,CAST(:payload AS jsonb))',
                    company=company, kind=kind, key='sample:tumandaito:orders:v1:' + kind + ':' + suffix,
                    payload=json.dumps(payload))[0][0]
                if kind == 'solicitud_compra':
                    payload['origen_id'] = row['id']
                    payload['numero'] = PREFIX + suffix
                else:
                    created += not row['replayed']
                    replayed += bool(row['replayed'])
                    result.append({'id': row['id'], 'reference': row['numero'], 'total': row['total'],
                                   'currency': row['moneda'], 'source_id': row['origen_id']})
        connection.run('SET CONSTRAINTS ALL IMMEDIATE')
        connection.run('COMMIT')
        return {'status': 'succeeded', 'application_role': 'mastererp_app', 'synthetic': True,
                'tenant_id': tenant, 'company_id': company, 'created': created, 'replayed': replayed,
                'orders': result, 'committed': True, 'correlation_id': correlation}
    except Exception as error:
        connection.run('ROLLBACK')
        data = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
        raise RuntimeError('Tumandaito orders failed; phase=' + phase + '; sqlstate=' + data.get('C', 'unknown')) from None
