-- Operational profile over an existing organizational branch.
CREATE TABLE IF NOT EXISTS operaciones.nodos (
 id uuid PRIMARY KEY,
 tenant_id uuid NOT NULL,
 empresa_id uuid NOT NULL,
 estado text NOT NULL DEFAULT 'DRAFT' CHECK(estado IN ('DRAFT','ACTIVE','PAUSED','SUSPENDED')),
 acepta_pedidos boolean NOT NULL DEFAULT false,
 radio_cobertura_km numeric(8,2) NOT NULL DEFAULT 0 CHECK(radio_cobertura_km>=0),
 capacidad_diaria integer NOT NULL DEFAULT 0 CHECK(capacidad_diaria>=0),
 pedido_minimo administracion.importe NOT NULL DEFAULT 0,
 tarifa_entrega administracion.importe NOT NULL DEFAULT 0,
 apertura time,
 cierre time,
 ubicacion jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(ubicacion)='object'),
 configuracion jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(configuracion)='object'),
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,id) REFERENCES organizacion.branches(tenant_id,company_id,id)
);
CREATE INDEX IF NOT EXISTS nodos_empresa_estado_idx ON operaciones.nodos(tenant_id,empresa_id,estado,id);
ALTER TABLE operaciones.nodos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operaciones.nodos FROM PUBLIC,mastererp_app;
GRANT USAGE ON SCHEMA operaciones TO mastererp_app;

INSERT INTO plataforma.permissions(code,description) VALUES
 ('operations.nodes.read','Read operational nodes in authorized companies'),
 ('operations.nodes.write','Configure and transition operational nodes')
ON CONFLICT(code) DO NOTHING;

CREATE OR REPLACE FUNCTION operaciones.nodos_leer(p_empresa uuid,p_id uuid DEFAULT NULL,p_estado text DEFAULT NULL,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,organizacion,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_limit NOT BETWEEN 1 AND 101 OR (p_estado IS NOT NULL AND p_estado NOT IN ('DRAFT','ACTIVE','PAUSED','SUSPENDED'))
 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.nodes.read',p_empresa) IS NOT TRUE THEN RAISE EXCEPTION 'Node access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY nombre,id),'[]') INTO result FROM (
  SELECT b.name nombre,n.id,jsonb_build_object('id',n.id,'company_id',n.empresa_id,'code',b.code,'name',b.name,
   'branch_type',b.branch_type,'country_code',b.country_code,'status',n.estado,'accepts_orders',n.acepta_pedidos,
   'coverage_radius_km',n.radio_cobertura_km,'daily_capacity',n.capacidad_diaria,'minimum_order',n.pedido_minimo,
   'delivery_fee',n.tarifa_entrega,'opening_time',n.apertura,'closing_time',n.cierre,'location',n.ubicacion,
   'configuration',n.configuracion,'created_at',n.creado_en,'updated_at',n.actualizado_en,'version',n.version) item
  FROM operaciones.nodos n JOIN organizacion.branches b ON b.id=n.id AND b.tenant_id=n.tenant_id AND b.company_id=n.empresa_id
  WHERE n.tenant_id=plataforma.current_app_tenant_id() AND n.empresa_id=p_empresa
  AND (p_id IS NULL OR n.id=p_id) AND (p_estado IS NULL OR n.estado=p_estado)
  ORDER BY b.name,n.id LIMIT p_limit
 ) q;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Node not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION operaciones.nodo_configurar(p_empresa uuid,p_sucursal uuid,p_cambios jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,organizacion,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id(); correlation uuid; current operaciones.nodos%ROWTYPE;
BEGIN
 IF p_empresa IS NULL OR p_sucursal IS NULL OR jsonb_typeof(p_cambios)<>'object' THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.nodes.write',p_empresa,p_sucursal) IS NOT TRUE THEN RAISE EXCEPTION 'Node configuration denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.nodes.configure' THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 INSERT INTO operaciones.nodos(id,tenant_id,empresa_id,creado_por) VALUES(p_sucursal,tenant,p_empresa,actor)
 ON CONFLICT(id) DO NOTHING;
 SELECT * INTO current FROM operaciones.nodos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_sucursal FOR UPDATE;
 IF p_cambios?'version' AND current.version<>(p_cambios->>'version')::bigint THEN RAISE EXCEPTION 'Stale node version' USING ERRCODE='40001'; END IF;
 UPDATE operaciones.nodos SET
  acepta_pedidos=COALESCE((p_cambios->>'accepts_orders')::boolean,acepta_pedidos),
  radio_cobertura_km=COALESCE((p_cambios->>'coverage_radius_km')::numeric,radio_cobertura_km),
  capacidad_diaria=COALESCE((p_cambios->>'daily_capacity')::integer,capacidad_diaria),
  pedido_minimo=COALESCE((p_cambios->>'minimum_order')::administracion.importe,pedido_minimo),
  tarifa_entrega=COALESCE((p_cambios->>'delivery_fee')::administracion.importe,tarifa_entrega),
  apertura=CASE WHEN p_cambios?'opening_time' THEN (p_cambios->>'opening_time')::time ELSE apertura END,
  cierre=CASE WHEN p_cambios?'closing_time' THEN (p_cambios->>'closing_time')::time ELSE cierre END,
  ubicacion=CASE WHEN p_cambios?'location' THEN p_cambios->'location' ELSE ubicacion END,
  configuracion=CASE WHEN p_cambios?'configuration' THEN p_cambios->'configuration' ELSE configuracion END,
  version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_sucursal;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.4-nodes','nodo',p_sucursal,'operations.nodes.configure',correlation,jsonb_build_object('empresa_id',p_empresa,'resultado','succeeded'));
 RETURN operaciones.nodos_leer(p_empresa,p_sucursal);
END $$;

CREATE OR REPLACE FUNCTION operaciones.nodo_transicionar(p_empresa uuid,p_id uuid,p_version bigint,p_estado text,p_motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id(); correlation uuid; current operaciones.nodos%ROWTYPE; allowed boolean;
BEGIN
 IF p_estado NOT IN ('ACTIVE','PAUSED','SUSPENDED') OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.nodes.write',p_empresa,p_id) IS NOT TRUE THEN RAISE EXCEPTION 'Node transition denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.nodes.transition' THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 SELECT * INTO current FROM operaciones.nodos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Node not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale node version' USING ERRCODE='40001'; END IF;
 allowed:=(current.estado,p_estado) IN (('DRAFT','ACTIVE'),('ACTIVE','PAUSED'),('ACTIVE','SUSPENDED'),('PAUSED','ACTIVE'),('PAUSED','SUSPENDED'),('SUSPENDED','ACTIVE'));
 IF NOT allowed THEN RAISE EXCEPTION 'Invalid node transition' USING ERRCODE='23514'; END IF;
 UPDATE operaciones.nodos SET estado=p_estado,acepta_pedidos=CASE WHEN p_estado='ACTIVE' THEN acepta_pedidos ELSE false END,version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_id;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.4-nodes','nodo',p_id,'operations.nodes.transition',correlation,jsonb_build_object('anterior',current.estado,'nuevo',p_estado,'motivo',btrim(p_motivo),'resultado','succeeded'));
 RETURN operaciones.nodos_leer(p_empresa,p_id);
END $$;

REVOKE ALL ON FUNCTION operaciones.nodos_leer(uuid,uuid,text,integer),operaciones.nodo_configurar(uuid,uuid,jsonb),operaciones.nodo_transicionar(uuid,uuid,bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.nodos_leer(uuid,uuid,text,integer),operaciones.nodo_configurar(uuid,uuid,jsonb),operaciones.nodo_transicionar(uuid,uuid,bigint,text,text) TO mastererp_app;
