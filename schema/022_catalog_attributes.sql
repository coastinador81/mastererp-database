-- Attribute definitions. Product values remain in productos.atributos until reconciled.
CREATE TABLE IF NOT EXISTS catalogo.atributos_definiciones (
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 codigo text NOT NULL CHECK(codigo ~ '^[a-z][a-z0-9_]{0,79}$'),
 nombre text NOT NULL CHECK(length(btrim(nombre)) BETWEEN 1 AND 160),
 tipo text NOT NULL CHECK(tipo IN ('TEXT','NUMBER','BOOLEAN','SELECT','MULTISELECT')),
 requerido boolean NOT NULL DEFAULT false,
 opciones jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(opciones)='array'),
 unidad text CHECK(unidad IS NULL OR length(btrim(unidad)) BETWEEN 1 AND 40),
 estado text NOT NULL DEFAULT 'ACTIVE' CHECK(estado IN ('ACTIVE','INACTIVE')),
 orden integer NOT NULL DEFAULT 0 CHECK(orden BETWEEN 0 AND 1000000),
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 PRIMARY KEY(tenant_id,codigo),
 CHECK(tipo IN ('SELECT','MULTISELECT') OR opciones='[]'::jsonb),
 CHECK(tipo NOT IN ('SELECT','MULTISELECT') OR jsonb_array_length(opciones)>0)
);
CREATE TABLE IF NOT EXISTS catalogo.atributo_categorias (
 tenant_id uuid NOT NULL,codigo text NOT NULL,categoria_slug text NOT NULL,
 PRIMARY KEY(tenant_id,codigo,categoria_slug),
 FOREIGN KEY(tenant_id,codigo) REFERENCES catalogo.atributos_definiciones(tenant_id,codigo) ON DELETE CASCADE,
 FOREIGN KEY(tenant_id,categoria_slug) REFERENCES catalogo.categorias(tenant_id,slug)
);
ALTER TABLE catalogo.atributos_definiciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalogo.atributo_categorias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON catalogo.atributos_definiciones,catalogo.atributo_categorias FROM PUBLIC,mastererp_app;
INSERT INTO plataforma.permissions(code,description) VALUES ('catalog.attributes.read','Read Catalog attribute definitions'),('catalog.attributes.write','Create and update Catalog attribute definitions') ON CONFLICT(code) DO NOTHING;

CREATE OR REPLACE FUNCTION catalogo.atributos_leer(p_codigo text DEFAULT NULL,p_estado text DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE result jsonb; BEGIN
 IF p_limit NOT BETWEEN 1 AND 101 OR (p_estado IS NOT NULL AND p_estado NOT IN ('ACTIVE','INACTIVE')) THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.attributes.read') IS NOT TRUE THEN RAISE EXCEPTION 'Attribute access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY orden,nombre,codigo),'[]') INTO result FROM (
  SELECT a.orden,a.nombre,a.codigo,jsonb_build_object('code',a.codigo,'name',a.nombre,'type',a.tipo,'required',a.requerido,'options',a.opciones,'unit',a.unidad,'status',a.estado,'sort_order',a.orden,'category_slugs',(SELECT COALESCE(jsonb_agg(x.categoria_slug ORDER BY x.categoria_slug),'[]') FROM catalogo.atributo_categorias x WHERE x.tenant_id=a.tenant_id AND x.codigo=a.codigo),'version',a.version,'updated_at',a.actualizado_en) item
  FROM catalogo.atributos_definiciones a WHERE a.tenant_id=plataforma.current_app_tenant_id() AND (p_codigo IS NULL OR a.codigo=p_codigo) AND (p_estado IS NULL OR a.estado=p_estado) ORDER BY a.orden,a.nombre,a.codigo LIMIT p_limit) q;
 IF p_codigo IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Attribute not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_codigo IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION catalogo.atributo_crear(p_codigo text,p_nombre text,p_tipo text,p_requerido boolean,p_opciones jsonb,p_unidad text,p_orden integer,p_categorias jsonb,p_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id();tenant uuid:=plataforma.current_app_tenant_id();operation text:='catalog.attributes.create';correlation uuid;fingerprint text;cached plataforma.idempotency_keys%ROWTYPE;response jsonb;category text;
BEGIN
 IF p_codigo !~ '^[a-z][a-z0-9_]{0,79}$' OR length(btrim(p_nombre)) NOT BETWEEN 1 AND 160 OR p_tipo NOT IN ('TEXT','NUMBER','BOOLEAN','SELECT','MULTISELECT') OR jsonb_typeof(COALESCE(p_opciones,'[]'))<>'array' OR jsonb_typeof(COALESCE(p_categorias,'[]'))<>'array' OR length(p_key) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF (p_tipo IN ('SELECT','MULTISELECT'))<>(jsonb_array_length(COALESCE(p_opciones,'[]'))>0) THEN RAISE EXCEPTION 'Invalid options' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.attributes.write') IS NOT TRUE OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation THEN RAISE EXCEPTION 'Attribute creation denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;fingerprint:=encode(public.digest(jsonb_build_array(p_codigo,p_nombre,p_tipo,p_requerido,p_opciones,p_unidad,p_orden,p_categorias)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_key,0));SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_key;
 IF FOUND THEN IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>operation OR cached.request_fingerprint<>fingerprint THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505';END IF;RETURN cached.response_payload;END IF;
 INSERT INTO catalogo.atributos_definiciones(tenant_id,codigo,nombre,tipo,requerido,opciones,unidad,estado,orden,creado_por)
 VALUES(tenant,p_codigo,btrim(p_nombre),p_tipo,COALESCE(p_requerido,false),COALESCE(p_opciones,'[]'),NULLIF(btrim(p_unidad),''),'ACTIVE',COALESCE(p_orden,0),actor);
 FOR category IN SELECT jsonb_array_elements_text(COALESCE(p_categorias,'[]')) LOOP INSERT INTO catalogo.atributo_categorias VALUES(tenant,p_codigo,category);END LOOP;
 response:=catalogo.atributos_leer(p_codigo);INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_fingerprint,request_tenant_id,response_payload) VALUES(p_key,actor,operation,fingerprint,tenant,response);
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata) VALUES(tenant,actor,'2.1.3-attributes','atributo',gen_random_uuid(),operation,correlation,jsonb_build_object('codigo',p_codigo));RETURN response;
END $$;

CREATE OR REPLACE FUNCTION catalogo.atributo_actualizar(p_codigo text,p_version bigint,p_cambios jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id();actor uuid:=plataforma.current_app_user_id();current catalogo.atributos_definiciones%ROWTYPE;correlation uuid;key text;category text;BEGIN
 IF p_version IS NULL OR jsonb_typeof(p_cambios)<>'object' OR p_cambios='{}' THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023';END IF;
 FOR key IN SELECT jsonb_object_keys(p_cambios) LOOP IF key NOT IN ('name','required','options','unit','status','sort_order','category_slugs') THEN RAISE EXCEPTION 'Unsupported attribute field' USING ERRCODE='22023';END IF;END LOOP;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.attributes.write') IS NOT TRUE OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.attributes.update' THEN RAISE EXCEPTION 'Attribute update denied' USING ERRCODE='42501';END IF;
 SELECT * INTO current FROM catalogo.atributos_definiciones WHERE tenant_id=tenant AND codigo=p_codigo FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Attribute not found' USING ERRCODE='P0002';END IF;IF current.version<>p_version THEN RAISE EXCEPTION 'Stale attribute version' USING ERRCODE='40001';END IF;
 UPDATE catalogo.atributos_definiciones SET nombre=CASE WHEN p_cambios?'name' THEN btrim(p_cambios->>'name') ELSE nombre END,requerido=CASE WHEN p_cambios?'required' THEN (p_cambios->>'required')::boolean ELSE requerido END,opciones=CASE WHEN p_cambios?'options' THEN p_cambios->'options' ELSE opciones END,unidad=CASE WHEN p_cambios?'unit' THEN NULLIF(btrim(p_cambios->>'unit'),'') ELSE unidad END,estado=CASE WHEN p_cambios?'status' THEN p_cambios->>'status' ELSE estado END,orden=CASE WHEN p_cambios?'sort_order' THEN (p_cambios->>'sort_order')::integer ELSE orden END,version=version+1,actualizado_en=transaction_timestamp() WHERE tenant_id=tenant AND codigo=p_codigo;
 IF p_cambios?'category_slugs' THEN DELETE FROM catalogo.atributo_categorias WHERE tenant_id=tenant AND codigo=p_codigo;FOR category IN SELECT jsonb_array_elements_text(p_cambios->'category_slugs') LOOP INSERT INTO catalogo.atributo_categorias VALUES(tenant,p_codigo,category);END LOOP;END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata) VALUES(tenant,actor,'2.1.3-attributes','atributo',gen_random_uuid(),'catalog.attributes.update',correlation,jsonb_build_object('codigo',p_codigo));RETURN catalogo.atributos_leer(p_codigo);
END $$;
REVOKE ALL ON FUNCTION catalogo.atributos_leer(text,text,integer),catalogo.atributo_crear(text,text,text,boolean,jsonb,text,integer,jsonb,varchar),catalogo.atributo_actualizar(text,bigint,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.atributos_leer(text,text,integer),catalogo.atributo_crear(text,text,text,boolean,jsonb,text,integer,jsonb,varchar),catalogo.atributo_actualizar(text,bigint,jsonb) TO mastererp_app;
