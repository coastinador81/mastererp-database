-- Canonical tenant category tree. Product category_ref remains text during backfill/cutover.
CREATE TABLE IF NOT EXISTS catalogo.categorias (
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 slug text NOT NULL CHECK(slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' AND length(slug)<=80),
 nombre text NOT NULL CHECK(length(btrim(nombre)) BETWEEN 1 AND 160),
 descripcion text NOT NULL DEFAULT '' CHECK(length(descripcion)<=1000),
 padre_slug text,
 estado text NOT NULL DEFAULT 'ACTIVE' CHECK(estado IN ('ACTIVE','INACTIVE')),
 imagen_url text CHECK(imagen_url IS NULL OR imagen_url ~ '^(https://|/images/)'),
 orden integer NOT NULL DEFAULT 0 CHECK(orden BETWEEN 0 AND 1000000),
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 PRIMARY KEY(tenant_id,slug),
 FOREIGN KEY(tenant_id,padre_slug) REFERENCES catalogo.categorias(tenant_id,slug),
 CHECK(padre_slug IS NULL OR padre_slug<>slug)
);
CREATE INDEX IF NOT EXISTS categorias_orden_idx ON catalogo.categorias(tenant_id,estado,orden,nombre);
ALTER TABLE catalogo.categorias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON catalogo.categorias FROM PUBLIC,mastererp_app;

INSERT INTO plataforma.permissions(code,description) VALUES
 ('catalog.categories.read','Read categories in the enabled Catalog module'),
 ('catalog.categories.write','Create and update categories in the enabled Catalog module')
ON CONFLICT(code) DO NOTHING;

CREATE OR REPLACE FUNCTION catalogo.categorias_leer(
 p_slug text DEFAULT NULL,p_estado text DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_limit NOT BETWEEN 1 AND 101 OR (p_estado IS NOT NULL AND p_estado NOT IN ('ACTIVE','INACTIVE'))
 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.categories.read') IS NOT TRUE THEN
  RAISE EXCEPTION 'Category access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY orden,nombre,slug),'[]') INTO result FROM (
  SELECT c.orden,c.nombre,c.slug,jsonb_build_object(
   'slug',c.slug,'name',c.nombre,'description',c.descripcion,'parent_slug',c.padre_slug,
   'status',c.estado,'image_url',c.imagen_url,'sort_order',c.orden,'version',c.version,
   'product_count',(SELECT count(*) FROM catalogo.productos p WHERE p.tenant_id=c.tenant_id AND p.categoria_ref=c.slug),
   'updated_at',c.actualizado_en) item
  FROM catalogo.categorias c WHERE c.tenant_id=plataforma.current_app_tenant_id()
  AND (p_slug IS NULL OR c.slug=p_slug) AND (p_estado IS NULL OR c.estado=p_estado)
  ORDER BY c.orden,c.nombre,c.slug LIMIT p_limit
 ) q;
 IF p_slug IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Category not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_slug IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION catalogo.categoria_crear(
 p_slug text,p_nombre text,p_descripcion text,p_padre_slug text,p_imagen_url text,
 p_orden integer,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 operation text:='catalog.categories.create'; correlation uuid; fingerprint text;
 cached plataforma.idempotency_keys%ROWTYPE; response jsonb;
BEGIN
 IF p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' OR length(p_slug)>80
 OR length(btrim(p_nombre)) NOT BETWEEN 1 AND 160 OR COALESCE(length(p_descripcion),0)>1000
 OR COALESCE(p_orden,0) NOT BETWEEN 0 AND 1000000 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128
 OR (p_imagen_url IS NOT NULL AND p_imagen_url !~ '^(https://|/images/)')
 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.categories.write') IS NOT TRUE THEN RAISE EXCEPTION 'Category creation denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 IF p_padre_slug IS NOT NULL AND NOT EXISTS(SELECT 1 FROM catalogo.categorias WHERE tenant_id=tenant AND slug=p_padre_slug) THEN RAISE EXCEPTION 'Parent category not found' USING ERRCODE='P0002'; END IF;
 fingerprint:=encode(public.digest(jsonb_build_object('slug',p_slug,'name',btrim(p_nombre),'description',COALESCE(btrim(p_descripcion),''),'parent_slug',p_padre_slug,'image_url',p_imagen_url,'sort_order',COALESCE(p_orden,0))::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>operation OR cached.request_fingerprint<>fingerprint THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 INSERT INTO catalogo.categorias(tenant_id,slug,nombre,descripcion,padre_slug,imagen_url,orden,creado_por)
 VALUES(tenant,p_slug,btrim(p_nombre),COALESCE(btrim(p_descripcion),''),p_padre_slug,NULLIF(btrim(p_imagen_url),''),COALESCE(p_orden,0),actor);
 response:=catalogo.categorias_leer(p_slug);
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_fingerprint,request_tenant_id,response_payload)
 VALUES(p_idempotency_key,actor,operation,fingerprint,tenant,response);
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.1.2-categories','categoria',gen_random_uuid(),operation,correlation,jsonb_build_object('slug',p_slug,'resultado','succeeded'));
 RETURN response;
END $$;

CREATE OR REPLACE FUNCTION catalogo.categoria_actualizar(p_slug text,p_version bigint,p_cambios jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 current catalogo.categorias%ROWTYPE; correlation uuid; key text; new_parent text;
BEGIN
 IF p_slug IS NULL OR p_version IS NULL OR jsonb_typeof(p_cambios)<>'object' OR p_cambios='{}' THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 FOR key IN SELECT jsonb_object_keys(p_cambios) LOOP
  IF key NOT IN ('name','description','parent_slug','status','image_url','sort_order') THEN RAISE EXCEPTION 'Unsupported category field' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.categories.write') IS NOT TRUE THEN RAISE EXCEPTION 'Category update denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.categories.update' THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 SELECT * INTO current FROM catalogo.categorias WHERE tenant_id=tenant AND slug=p_slug FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Category not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale category version' USING ERRCODE='40001'; END IF;
 new_parent:=CASE WHEN p_cambios?'parent_slug' THEN NULLIF(btrim(p_cambios->>'parent_slug'),'') ELSE current.padre_slug END;
 IF new_parent=p_slug OR (new_parent IS NOT NULL AND NOT EXISTS(SELECT 1 FROM catalogo.categorias WHERE tenant_id=tenant AND slug=new_parent)) THEN RAISE EXCEPTION 'Invalid parent category' USING ERRCODE='23514'; END IF;
 IF new_parent IS NOT NULL AND EXISTS(WITH RECURSIVE descendants(slug) AS (SELECT slug FROM catalogo.categorias WHERE tenant_id=tenant AND padre_slug=p_slug UNION ALL SELECT c.slug FROM catalogo.categorias c JOIN descendants d ON c.padre_slug=d.slug WHERE c.tenant_id=tenant) SELECT 1 FROM descendants WHERE slug=new_parent) THEN RAISE EXCEPTION 'Category cycle' USING ERRCODE='23514'; END IF;
 UPDATE catalogo.categorias SET
  nombre=CASE WHEN p_cambios?'name' THEN btrim(p_cambios->>'name') ELSE nombre END,
  descripcion=CASE WHEN p_cambios?'description' THEN COALESCE(btrim(p_cambios->>'description'),'') ELSE descripcion END,
  padre_slug=new_parent,estado=CASE WHEN p_cambios?'status' THEN p_cambios->>'status' ELSE estado END,
  imagen_url=CASE WHEN p_cambios?'image_url' THEN NULLIF(btrim(p_cambios->>'image_url'),'') ELSE imagen_url END,
  orden=CASE WHEN p_cambios?'sort_order' THEN (p_cambios->>'sort_order')::integer ELSE orden END,
  version=version+1,actualizado_en=transaction_timestamp() WHERE tenant_id=tenant AND slug=p_slug;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.1.2-categories','categoria',gen_random_uuid(),'catalog.categories.update',correlation,jsonb_build_object('slug',p_slug,'resultado','succeeded'));
 RETURN catalogo.categorias_leer(p_slug);
END $$;

REVOKE ALL ON FUNCTION catalogo.categorias_leer(text,text,integer),catalogo.categoria_crear(text,text,text,text,text,integer,varchar),catalogo.categoria_actualizar(text,bigint,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.categorias_leer(text,text,integer),catalogo.categoria_crear(text,text,text,text,text,integer,varchar),catalogo.categoria_actualizar(text,bigint,jsonb) TO mastererp_app;
