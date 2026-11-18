"""DEV-only prerequisites for one explicitly approved refund trace test."""
from uuid import UUID, uuid5, NAMESPACE_URL
from dev_validation import _dev_guard

TENANT='9095f990-c1f7-4ccb-953d-f84083331bd6'
COMPANY='8a13adba-1594-46e3-a41b-488fd91ea896'
ORDER='ceb56cf0-e25b-4152-a9e8-dfae1551286a'

def execute(connection,event,context):
    _dev_guard(context)
    if event != {'action':'seed_refund_trace_fixture','tenant_id':TENANT,'company_id':COMPANY,'order_id':ORDER}:
        raise ValueError('Exact approved refund fixture manifest required')
    account=str(uuid5(NAMESPACE_URL,'mastererp-dev:refund-account:'+COMPANY))
    invoice=str(uuid5(NAMESPACE_URL,'mastererp-dev:refund-invoice:'+ORDER))
    invoice_line=str(uuid5(NAMESPACE_URL,'mastererp-dev:refund-invoice-line:'+ORDER))
    credit=str(uuid5(NAMESPACE_URL,'mastererp-dev:refund-credit:'+ORDER))
    credit_line=str(uuid5(NAMESPACE_URL,'mastererp-dev:refund-credit-line:'+ORDER))
    connection.run('BEGIN')
    try:
        connection.run("SELECT pg_advisory_xact_lock(hashtextextended('mastererp-dev:refund-fixture:"+ORDER+"',0))")
        scope=connection.run("""SELECT p.tenant_id,p.empresa_id,p.id,p.numero,p.sucursal_id,p.cliente_id,p.moneda,p.total,
          c.base_currency_code,v.venta_id,d.tipo_cambio,d.cambio_fecha,d.cambio_fuente,
          (SELECT ut.user_id FROM plataforma.user_tenants ut JOIN plataforma.roles r ON r.id=ut.role_id
           WHERE ut.tenant_id=p.tenant_id AND ut.status='active' AND r.code='tenant.owner' ORDER BY ut.created_at LIMIT 1)
          FROM operaciones.pedidos p JOIN organizacion.companies c ON (c.tenant_id,c.id)=(p.tenant_id,p.empresa_id)
          JOIN administracion.ventas_origen v ON (v.tenant_id,v.empresa_id,v.pedido_id)=(p.tenant_id,p.empresa_id,p.id)
          JOIN administracion.documentos d ON (d.tenant_id,d.empresa_id,d.id)=(v.tenant_id,v.empresa_id,v.venta_id)
          WHERE p.tenant_id=:tenant AND p.empresa_id=:company AND p.id=:order_id AND p.numero='ORD-CEB56CF0E25B'
          AND p.estado='CANCELLED' AND p.pago_snapshot->>'status'='VALIDATED' AND p.moneda='USD' AND p.total=47""",
          tenant=TENANT,company=COMPANY,order_id=ORDER)
        if len(scope)!=1 or any(value is None for value in scope[0]):raise ValueError('Approved cancelled order scope not satisfied')
        tenant,company,order_id,number,branch,customer,currency,total,base,sale,rate,rate_date,rate_source,actor=map(str,scope[0])
        connection.run("SELECT set_config('app.current_user_id',:actor,true),set_config('app.current_tenant_id',:tenant,true),set_config('app.current_company_id',:company,true)",actor=actor,tenant=tenant,company=company)
        connection.run("""INSERT INTO administracion.cuentas_tesoreria(id,tenant_id,empresa_id,sucursal_id,creado_por,codigo,nombre,tipo,moneda,referencia_bancaria)
          VALUES(:id,:tenant,:company,:branch,:actor,'QA-USD-REFUNDS','Caja QA USD para reembolsos','caja','USD','PRUEBA DEV; no representa fondos reales')
          ON CONFLICT(tenant_id,empresa_id,codigo) DO NOTHING""",id=account,tenant=tenant,company=company,branch=branch,actor=actor)
        common=dict(tenant=tenant,company=company,branch=branch,actor=actor,customer=customer,currency=currency,base=base,total=total,rate=rate,rate_date=rate_date,rate_source='PRUEBA DEV sin validez fiscal; '+rate_source,order_id=order_id)
        connection.run("""INSERT INTO administracion.documentos(id,tenant_id,empresa_id,sucursal_id,creado_por,clase,tercero_id,rol_tercero,fecha,serie,numero,moneda,moneda_base,tipo_cambio,cambio_fecha,cambio_fuente,total,origen_sistema,referencia_externa)
          VALUES(:id,:tenant,:company,:branch,:actor,'factura_cliente',:customer,'cliente',CURRENT_DATE,'QA','QA-FAC-CEB56CF0E25B',:currency,:base,:rate,:rate_date,:rate_source,:total,'dev_refund_fixture','invoice:'||:order_id)
          ON CONFLICT(id) DO NOTHING""",id=invoice,**common)
        connection.run("""INSERT INTO administracion.detalles_documento(id,tenant_id,empresa_id,sucursal_id,creado_por,documento_id,posicion,descripcion,cantidad,precio_unitario,subtotal)
          VALUES(:id,:tenant,:company,:branch,:actor,:document,1,'Documento QA para probar trazabilidad de reembolso',1,:total,:total) ON CONFLICT(id) DO NOTHING""",id=invoice_line,document=invoice,**common)
        connection.run("UPDATE administracion.documentos SET cerrado=true,version=GREATEST(version,2) WHERE id=:id",id=invoice)
        connection.run("""INSERT INTO administracion.documentos(id,tenant_id,empresa_id,sucursal_id,creado_por,clase,tercero_id,rol_tercero,documento_origen_id,fecha,serie,numero,moneda,moneda_base,tipo_cambio,cambio_fecha,cambio_fuente,total,origen_sistema,referencia_externa)
          VALUES(:id,:tenant,:company,:branch,:actor,'credito_cliente',:customer,'cliente',:invoice,CURRENT_DATE,'QA','QA-NC-CEB56CF0E25B',:currency,:base,:rate,:rate_date,:rate_source,:total,'dev_refund_fixture',:order_id)
          ON CONFLICT(id) DO NOTHING""",id=credit,invoice=invoice,**common)
        connection.run("""INSERT INTO administracion.detalles_documento(id,tenant_id,empresa_id,sucursal_id,creado_por,documento_id,posicion,detalle_origen_id,descripcion,cantidad,precio_unitario,subtotal)
          VALUES(:id,:tenant,:company,:branch,:actor,:document,1,:origin,'Nota de crédito QA para probar trazabilidad de reembolso',1,:total,:total) ON CONFLICT(id) DO NOTHING""",id=credit_line,document=credit,origin=invoice_line,**common)
        connection.run("UPDATE administracion.documentos SET cerrado=true,version=GREATEST(version,2) WHERE id=:id",id=credit)
        connection.run('SET CONSTRAINTS ALL IMMEDIATE')
        connection.run('COMMIT')
        return {'status':'succeeded','synthetic':True,'committed':True,'order_id':order_id,'account_id':account,'credit_note_id':credit,'credit_note_number':'QA-NC-CEB56CF0E25B'}
    except Exception:
        connection.run('ROLLBACK')
        raise
