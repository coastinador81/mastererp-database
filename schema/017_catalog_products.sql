-- Canonical product master. Stock, reservations and node availability belong to Inventory.
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS descripcion text NOT NULL DEFAULT '';
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS precio administracion.importe;
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS estado text NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS categoria_ref text;
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS imagen_url text;
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS atributos jsonb NOT NULL DEFAULT '{}';
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS referencia_externa text;
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS creado_por uuid REFERENCES plataforma.users(id);
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS creado_en timestamptz NOT NULL DEFAULT transaction_timestamp();
ALTER TABLE catalogo.productos ADD COLUMN IF NOT EXISTS actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp();
ALTER TABLE catalogo.productos DROP CONSTRAINT IF EXISTS productos_estado_check;
ALTER TABLE catalogo.productos ADD CONSTRAINT productos_estado_check CHECK(estado IN ('ACTIVE','INACTIVE','DRAFT','DISCONTINUED'));
ALTER TABLE catalogo.productos DROP CONSTRAINT IF EXISTS productos_descripcion_check;
ALTER TABLE catalogo.productos ADD CONSTRAINT productos_descripcion_check CHECK(length(descripcion)<=2000);
ALTER TABLE catalogo.productos DROP CONSTRAINT IF EXISTS productos_imagen_url_check;
ALTER TABLE catalogo.productos ADD CONSTRAINT productos_imagen_url_check CHECK(imagen_url IS NULL OR imagen_url ~ '^(https://|/images/)');
ALTER TABLE catalogo.productos DROP CONSTRAINT IF EXISTS productos_atributos_check;
ALTER TABLE catalogo.productos ADD CONSTRAINT productos_atributos_check CHECK(jsonb_typeof(atributos)='object');
CREATE UNIQUE INDEX IF NOT EXISTS productos_referencia_externa_uidx ON catalogo.productos(tenant_id,referencia_externa) WHERE referencia_externa IS NOT NULL;
CREATE INDEX IF NOT EXISTS productos_busqueda_idx ON catalogo.productos(tenant_id,estado,nombre,id);

INSERT INTO plataforma.permissions(code,description) VALUES
 ('catalog.products.read','Read products in the enabled Catalog module'),
 ('catalog.products.write','Create and update products in the enabled Catalog module')
ON CONFLICT(code) DO NOTHING;

CREATE OR REPLACE FUNCTION catalogo.productos_leer(
 p_id uuid DEFAULT NULL,p_estado text DEFAULT NULL,p_busqueda text DEFAULT NULL,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_limit NOT BETWEEN 1 AND 101 OR (p_estado IS NOT NULL AND p_estado NOT IN ('ACTIVE','INACTIVE','DRAFT','DISCONTINUED'))
 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.products.read') IS NOT TRUE THEN
  RAISE EXCEPTION 'Product access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY nombre,id),'[]') INTO result FROM (
  SELECT p.nombre,p.id,jsonb_build_object('id',p.id,'code',p.codigo,'name',p.nombre,
   'description',p.descripcion,'price',p.precio,'status',p.estado,'category_ref',p.categoria_ref,
   'image_url',p.imagen_url,'attributes',p.atributos,'external_reference',p.referencia_externa,
   'created_at',p.creado_en,'updated_at',p.actualizado_en,'version',p.version) item
  FROM catalogo.productos p WHERE p.tenant_id=plataforma.current_app_tenant_id()
  AND (p_id IS NULL OR p.id=p_id) AND (p_estado IS NULL OR p.estado=p_estado)
  AND (NULLIF(btrim(p_busqueda),'') IS NULL OR p.nombre ILIKE '%'||btrim(p_busqueda)||'%' OR p.codigo ILIKE '%'||btrim(p_busqueda)||'%')
  ORDER BY p.nombre,p.id LIMIT p_limit
 ) q;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Product not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION catalogo.producto_crear(
 p_nombre text,p_descripcion text,p_precio administracion.importe,p_estado text,p_categoria_ref text,
 p_imagen_url text,p_atributos jsonb,p_referencia_externa text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 operation text:='catalog.products.create'; correlation uuid; product_id uuid:=gen_random_uuid();
 fingerprint text; cached plataforma.idempotency_keys%ROWTYPE; response jsonb;
BEGIN
 IF length(btrim(p_nombre)) NOT BETWEEN 1 AND 200 OR COALESCE(length(p_descripcion),0)>2000
 OR p_precio IS NULL OR p_precio<=0 OR p_estado NOT IN ('ACTIVE','INACTIVE','DRAFT','DISCONTINUED')
 OR jsonb_typeof(COALESCE(p_atributos,'{}'))<>'object' OR length(p_idempotency_key) NOT BETWEEN 1 AND 128
 OR (p_imagen_url IS NOT NULL AND p_imagen_url !~ '^(https://|/images/)')
 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.products.write') IS NOT TRUE THEN
  RAISE EXCEPTION 'Product creation denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 fingerprint:=encode(public.digest(jsonb_build_object('name',btrim(p_nombre),'description',COALESCE(btrim(p_descripcion),''),
  'price',p_precio,'status',p_estado,'category_ref',p_categoria_ref,'image_url',p_imagen_url,
  'attributes',COALESCE(p_atributos,'{}'),'external_reference',p_referencia_externa)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>operation OR cached.request_fingerprint<>fingerprint
  THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,operation,product_id,fingerprint,tenant);
 INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre,descripcion,precio,estado,categoria_ref,imagen_url,atributos,referencia_externa,creado_por)
 VALUES(product_id,tenant,'PRD-'||upper(substr(replace(product_id::text,'-',''),1,12)),btrim(p_nombre),COALESCE(btrim(p_descripcion),''),p_precio,p_estado,
  NULLIF(btrim(p_categoria_ref),''),NULLIF(btrim(p_imagen_url),''),COALESCE(p_atributos,'{}'),NULLIF(btrim(p_referencia_externa),''),actor);
 response:=catalogo.productos_leer(product_id);
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.1.1-products','producto',product_id,operation,correlation,jsonb_build_object('resultado','succeeded'));
 RETURN response;
END $$;

CREATE OR REPLACE FUNCTION catalogo.producto_actualizar(p_id uuid,p_version bigint,p_cambios jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 current catalogo.productos%ROWTYPE; correlation uuid; key text;
BEGIN
 IF p_id IS NULL OR p_version IS NULL OR jsonb_typeof(p_cambios)<>'object' OR p_cambios='{}' THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 FOR key IN SELECT jsonb_object_keys(p_cambios) LOOP
  IF key NOT IN ('name','description','price','status','category_ref','image_url','attributes') THEN RAISE EXCEPTION 'Unsupported product field' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.products.write') IS NOT TRUE THEN RAISE EXCEPTION 'Product update denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.products.update' THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 SELECT * INTO current FROM catalogo.productos WHERE tenant_id=tenant AND id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Product not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale product version' USING ERRCODE='40001'; END IF;
 UPDATE catalogo.productos SET
  nombre=CASE WHEN p_cambios?'name' THEN btrim(p_cambios->>'name') ELSE nombre END,
  descripcion=CASE WHEN p_cambios?'description' THEN COALESCE(btrim(p_cambios->>'description'),'') ELSE descripcion END,
  precio=CASE WHEN p_cambios?'price' THEN (p_cambios->>'price')::administracion.importe ELSE precio END,
  estado=CASE WHEN p_cambios?'status' THEN p_cambios->>'status' ELSE estado END,
  categoria_ref=CASE WHEN p_cambios?'category_ref' THEN NULLIF(btrim(p_cambios->>'category_ref'),'') ELSE categoria_ref END,
  imagen_url=CASE WHEN p_cambios?'image_url' THEN NULLIF(btrim(p_cambios->>'image_url'),'') ELSE imagen_url END,
  atributos=CASE WHEN p_cambios?'attributes' THEN p_cambios->'attributes' ELSE atributos END,
  version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_id;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.1.1-products','producto',p_id,'catalog.products.update',correlation,jsonb_build_object('campos',(SELECT jsonb_agg(k) FROM jsonb_object_keys(p_cambios) k),'resultado','succeeded'));
 RETURN catalogo.productos_leer(p_id);
END $$;

REVOKE ALL ON FUNCTION catalogo.productos_leer(uuid,text,text,integer),catalogo.producto_crear(text,text,administracion.importe,text,text,text,jsonb,text,varchar),catalogo.producto_actualizar(uuid,bigint,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.productos_leer(uuid,text,text,integer),catalogo.producto_crear(text,text,administracion.importe,text,text,text,jsonb,text,varchar),catalogo.producto_actualizar(uuid,bigint,jsonb) TO mastererp_app;
