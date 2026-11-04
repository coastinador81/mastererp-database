"""Owner-approved synthetic supplier fixtures for the Tumandaito DEV business only."""
import json
from uuid import UUID,uuid4
from dev_validation import _dev_guard,ISSUER

SAMPLES=(
 ('Suministros Horizonte DEMO','productos'),('Empaques Río Claro DEMO','productos'),
 ('Tecnología Andina DEMO','productos'),('Limpieza Brisa DEMO','productos'),
 ('Servicios Contables Aurora DEMO','servicios'),('Logística Ruta Azul DEMO','servicios'),
 ('Mantenimiento Faro DEMO','servicios'),('Soluciones Integrales Nube DEMO','ambos'),
)

def seed(connection,event,context):
    _dev_guard(context)
    if event.get('name')!='Tumandaito':raise ValueError('Only the explicitly approved business may be seeded')
    subject=str(UUID(str(event.get('owner_subject',''))));correlation=str(uuid4());phase='scope'
    connection.run('BEGIN')
    try:
        connection.run("SELECT pg_advisory_xact_lock(hashtextextended('mastererp-dev:tumandaito:sample-suppliers',0))")
        scope=connection.run("""SELECT t.id,c.id,e.user_id FROM plataforma.tenants t
         JOIN organizacion.companies c ON c.tenant_id=t.id
         JOIN plataforma.external_identities e ON e.issuer=:issuer AND e.subject=:subject
         JOIN plataforma.users u ON u.id=e.user_id
         WHERE t.code='tumandaito' AND t.slug='tumandaito' AND t.status='active'
         AND c.legal_name='Tumandaito' AND c.status='active' AND e.status='active' AND u.status='active'""",issuer=ISSUER,subject=subject)
        if len(scope)!=1:raise ValueError('Approved scope not uniquely identified')
        tenant,company,actor=map(str,scope[0])
        connection.run('SET LOCAL ROLE mastererp_app')
        if connection.run('SELECT current_user')[0][0]!='mastererp_app':raise ValueError('Application role required')
        connection.run("SELECT set_config('app.current_user_id',:actor,true),set_config('app.current_tenant_id',:tenant,true),set_config('app.current_company_id',:company,true),set_config('app.current_operation','administration.proveedor.create',true),set_config('app.correlation_id',:correlation,true)",actor=actor,tenant=tenant,company=company,correlation=correlation)
        if connection.run('SELECT plataforma.user_owns_current_tenant(:tenant)',tenant=tenant)[0][0] is not True:raise ValueError('Only the approved owner may seed this business')
        phase='seed';created=replayed=0
        for index,(name,supply) in enumerate(SAMPLES,1):
            code='DEMO-PROV-'+str(index).zfill(3)
            details={'datos_generales':{'nombre_comercial':name,'tipo_persona':'juridica','pais_fiscal':'VE','tipo_identificacion':'DEMO','numero_identificacion':'DEMO-NO-FISCAL-'+str(index).zfill(3),'direccion':'Dirección ficticia para pruebas','ciudad':'Ciudad de prueba','pais':'VE','email':'proveedor'+str(index)+'@example.invalid','telefono':'000-000-0000','observaciones':'Proveedor ficticio de demostración. No usar para compras ni pagos reales.'},
              'contactos':[{'nombre':'Contacto de prueba '+str(index),'cargo':'Demostración','email':'contacto'+str(index)+'@example.invalid','telefono':'000-000-0000','principal':True}],
              'condiciones':{'tipo_suministro':supply,'moneda':'VES','condicion_pago':'por_acordar','medio_pago':'','plazo_pago_dias':'','descuento_pronto_pago':'','plazo_pronto_pago_dias':''}}
            result=connection.run("SELECT administracion.party_write_v2(:company,'proveedor','create',NULL,:code,:name,NULL,:key,CAST(:details AS jsonb),NULL,NULL)",company=company,code=code,name=name,key='demo:tumandaito:proveedor:'+str(index)+':v1',details=json.dumps(details))[0][0]
            if result['replayed']:replayed+=1
            else:created+=1
        connection.run('COMMIT')
        return {'status':'succeeded','tenant_id':tenant,'company_id':company,'created':created,'replayed':replayed,'application_role':'mastererp_app','synthetic':True,'correlation_id':correlation}
    except Exception as error:
        connection.run('ROLLBACK');data=error.args[0] if error.args and isinstance(error.args[0],dict) else {}
        raise RuntimeError('Tumandaito samples failed; phase='+phase+'; sqlstate='+data.get('C','unknown')) from None
