-- Operational driver profiles. Cognito authenticates; routes own active route state.
CREATE SCHEMA IF NOT EXISTS transporte;

CREATE TABLE IF NOT EXISTS transporte.repartidores (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 usuario_id uuid REFERENCES plataforma.users(id),
 codigo text NOT NULL CHECK(length(btrim(codigo)) BETWEEN 1 AND 80),
 nombre text NOT NULL CHECK(length(btrim(nombre)) BETWEEN 1 AND 200),
 telefono text NOT NULL CHECK(length(btrim(telefono)) BETWEEN 5 AND 40),
 email citext,
 estado text NOT NULL DEFAULT 'ACTIVE' CHECK(estado IN ('ACTIVE','INACTIVE','SUSPENDED')),
 disponibilidad text NOT NULL DEFAULT 'OFFLINE' CHECK(disponibilidad IN ('OFFLINE','AVAILABLE','ON_ROUTE')),
 acceso_estado text NOT NULL DEFAULT 'PENDING' CHECK(acceso_estado IN ('PENDING','LINKED','ERROR','DISABLED')),
 vehiculo jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(vehiculo)='object'),
 licencia jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(licencia)='object'),
 referencia_externa text,
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 UNIQUE(tenant_id,id), UNIQUE(tenant_id,codigo), UNIQUE(tenant_id,usuario_id),
 UNIQUE(tenant_id,email), UNIQUE(tenant_id,referencia_externa)
);

CREATE TABLE IF NOT EXISTS transporte.repartidor_nodos (
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, nodo_id uuid NOT NULL,
 repartidor_id uuid NOT NULL, activo boolean NOT NULL DEFAULT true,
 asignado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(tenant_id,empresa_id,nodo_id,repartidor_id),
 FOREIGN KEY(tenant_id,empresa_id,nodo_id) REFERENCES operaciones.nodos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,repartidor_id) REFERENCES transporte.repartidores(tenant_id,id)
);

ALTER TABLE transporte.repartidores ENABLE ROW LEVEL SECURITY;
ALTER TABLE transporte.repartidor_nodos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA transporte FROM PUBLIC,mastererp_app;
GRANT USAGE ON SCHEMA transporte TO mastererp_app;

INSERT INTO plataforma.modules (
 code,name,description,category,module_type,requires_company,requires_country,requires_subscription,status
) VALUES (
 'erp.transport','ERP Transport','Repartidores, preparación y rutas.','erp','module',true,false,true,'active'
) ON CONFLICT(code) DO UPDATE SET
 name=EXCLUDED.name,description=EXCLUDED.description,category=EXCLUDED.category,
 module_type=EXCLUDED.module_type,requires_company=EXCLUDED.requires_company,
 requires_country=EXCLUDED.requires_country,requires_subscription=EXCLUDED.requires_subscription,
 status=EXCLUDED.status,updated_at=now();

INSERT INTO plataforma.permissions(code,description) VALUES
 ('transport.drivers.read','Read driver profiles'),
 ('transport.drivers.write','Create and update driver profiles'),
 ('transport.drivers.assign','Assign drivers to operational nodes')
ON CONFLICT(code) DO NOTHING;

CREATE OR REPLACE FUNCTION transporte.repartidores_leer(
 p_empresa uuid,p_nodo uuid DEFAULT NULL,p_id uuid DEFAULT NULL,
 p_estado text DEFAULT NULL,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,transporte,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_limit NOT BETWEEN 1 AND 101 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.transport','transport.drivers.read',p_empresa,p_nodo) IS NOT TRUE THEN
  RAISE EXCEPTION 'Driver access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY nombre,id),'[]') INTO result FROM (
  SELECT r.nombre,r.id,jsonb_build_object(
   'id',r.id,'code',r.codigo,'name',r.nombre,'phone',r.telefono,'email',r.email,
   'status',r.estado,'availability',r.disponibilidad,'access_status',r.acceso_estado,
   'user_id',r.usuario_id,'vehicle',r.vehiculo,'license',r.licencia,
   'external_reference',r.referencia_externa,'version',r.version,'updated_at',r.actualizado_en,
   'node_ids',(SELECT COALESCE(jsonb_agg(a.nodo_id),'[]') FROM transporte.repartidor_nodos a
    WHERE a.tenant_id=r.tenant_id AND a.repartidor_id=r.id AND a.activo)) item
  FROM transporte.repartidores r WHERE r.tenant_id=plataforma.current_app_tenant_id()
  AND (p_id IS NULL OR r.id=p_id) AND (p_estado IS NULL OR r.estado=p_estado)
  AND (p_nodo IS NULL OR EXISTS(SELECT 1 FROM transporte.repartidor_nodos a
   WHERE a.tenant_id=r.tenant_id AND a.empresa_id=p_empresa AND a.nodo_id=p_nodo
   AND a.repartidor_id=r.id AND a.activo))
  ORDER BY r.nombre,r.id LIMIT p_limit
 ) q;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN
  RAISE EXCEPTION 'Driver not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION transporte.repartidor_crear(
 p_empresa uuid,p_nombre text,p_telefono text,p_email citext,p_vehiculo jsonb,
 p_licencia jsonb,p_referencia text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,transporte,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 correlation uuid; driver_id uuid:=gen_random_uuid(); fingerprint text;
 cached plataforma.idempotency_keys%ROWTYPE; response jsonb;
BEGIN
 IF length(btrim(p_nombre)) NOT BETWEEN 1 AND 200
 OR length(btrim(p_telefono)) NOT BETWEEN 5 AND 40
 OR jsonb_typeof(COALESCE(p_vehiculo,'{}'))<>'object'
 OR jsonb_typeof(COALESCE(p_licencia,'{}'))<>'object'
 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.transport','transport.drivers.write',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Driver creation denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'transport.drivers.create' THEN
  RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 fingerprint:=encode(public.digest(jsonb_build_object('name',btrim(p_nombre),'phone',btrim(p_telefono),
  'email',p_email,'vehicle',COALESCE(p_vehiculo,'{}'),'license',COALESCE(p_licencia,'{}'),
  'external',p_referencia)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant
  OR cached.operation<>'transport.drivers.create' OR cached.request_fingerprint<>fingerprint THEN
   RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'transport.drivers.create',driver_id,fingerprint,tenant);
 INSERT INTO transporte.repartidores(id,tenant_id,codigo,nombre,telefono,email,vehiculo,licencia,referencia_externa,creado_por)
 VALUES(driver_id,tenant,'DRV-'||upper(substr(replace(driver_id::text,'-',''),1,12)),btrim(p_nombre),
  btrim(p_telefono),lower(p_email),COALESCE(p_vehiculo,'{}'),COALESCE(p_licencia,'{}'),NULLIF(btrim(p_referencia),''),actor);
 response:=transporte.repartidores_leer(p_empresa,NULL,driver_id);
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.10.1-drivers','repartidor',driver_id,'transport.drivers.create',correlation,'{"resultado":"succeeded"}');
 RETURN response;
END $$;

CREATE OR REPLACE FUNCTION transporte.repartidor_actualizar(
 p_empresa uuid,p_id uuid,p_version bigint,p_cambios jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,transporte,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 current transporte.repartidores%ROWTYPE; correlation uuid;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.transport','transport.drivers.write',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Driver update denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'transport.drivers.update' THEN
  RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 SELECT * INTO current FROM transporte.repartidores WHERE tenant_id=tenant AND id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Driver not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale driver version' USING ERRCODE='40001'; END IF;
 UPDATE transporte.repartidores SET
  nombre=COALESCE(NULLIF(btrim(p_cambios->>'name'),''),nombre),
  telefono=COALESCE(NULLIF(btrim(p_cambios->>'phone'),''),telefono),
  email=CASE WHEN p_cambios?'email' THEN NULLIF(lower(btrim(p_cambios->>'email')),'')::public.citext ELSE email END,
  estado=COALESCE(p_cambios->>'status',estado),
  disponibilidad=COALESCE(p_cambios->>'availability',disponibilidad),
  acceso_estado=COALESCE(p_cambios->>'access_status',acceso_estado),
  usuario_id=CASE WHEN p_cambios?'user_id' THEN NULLIF(p_cambios->>'user_id','')::uuid ELSE usuario_id END,
  vehiculo=CASE WHEN p_cambios?'vehicle' THEN p_cambios->'vehicle' ELSE vehiculo END,
  licencia=CASE WHEN p_cambios?'license' THEN p_cambios->'license' ELSE licencia END,
  version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_id;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.10.1-drivers','repartidor',p_id,'transport.drivers.update',correlation,'{"resultado":"succeeded"}');
 RETURN transporte.repartidores_leer(p_empresa,NULL,p_id);
END $$;

CREATE OR REPLACE FUNCTION transporte.repartidor_asignar_nodo(
 p_empresa uuid,p_nodo uuid,p_repartidor uuid,p_activo boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,transporte,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id();
BEGIN
 IF plataforma.has_current_tenant_capability('erp.transport','transport.drivers.assign',p_empresa,p_nodo) IS NOT TRUE THEN
  RAISE EXCEPTION 'Driver assignment denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'transport.drivers.assign' THEN
  RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 INSERT INTO transporte.repartidor_nodos(tenant_id,empresa_id,nodo_id,repartidor_id,activo)
 VALUES(tenant,p_empresa,p_nodo,p_repartidor,p_activo)
 ON CONFLICT(tenant_id,empresa_id,nodo_id,repartidor_id)
 DO UPDATE SET activo=excluded.activo,asignado_en=transaction_timestamp();
 RETURN transporte.repartidores_leer(p_empresa,NULL,p_repartidor);
END $$;

REVOKE ALL ON FUNCTION transporte.repartidores_leer(uuid,uuid,uuid,text,integer),
 transporte.repartidor_crear(uuid,text,text,citext,jsonb,jsonb,text,varchar),
 transporte.repartidor_actualizar(uuid,uuid,bigint,jsonb),
 transporte.repartidor_asignar_nodo(uuid,uuid,uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION transporte.repartidores_leer(uuid,uuid,uuid,text,integer),
 transporte.repartidor_crear(uuid,text,text,citext,jsonb,jsonb,text,varchar),
 transporte.repartidor_actualizar(uuid,uuid,bigint,jsonb),
 transporte.repartidor_asignar_nodo(uuid,uuid,uuid,boolean) TO mastererp_app;
