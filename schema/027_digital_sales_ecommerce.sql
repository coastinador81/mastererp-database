CREATE SCHEMA IF NOT EXISTS ventas_digitales;

INSERT INTO plataforma.modules(
 code,name,description,category,module_type,requires_company,requires_country,
 requires_subscription,status
) VALUES(
 'digital_sales.ecommerce','E-commerce','Storefront multi-tenant configurable.',
 'digital_sales','module',true,false,true,'active'
) ON CONFLICT(code) DO UPDATE SET
 name=EXCLUDED.name,description=EXCLUDED.description,status='active',updated_at=now();

CREATE TABLE IF NOT EXISTS ventas_digitales.tiendas(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 empresa_id uuid NOT NULL,
 nodo_id uuid NOT NULL,
 dominio text NOT NULL CHECK(dominio=lower(dominio) AND dominio~'^[a-z0-9.-]+$'),
 nombre text NOT NULL CHECK(length(btrim(nombre)) BETWEEN 1 AND 160),
 estado text NOT NULL DEFAULT 'DRAFT' CHECK(estado IN('DRAFT','ACTIVE','PAUSED')),
 marca jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(marca)='object'),
 configuracion jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(configuracion)='object'),
 modulos jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(modulos)='array'),
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 version bigint NOT NULL DEFAULT 1,
 UNIQUE(dominio),UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,nodo_id)
  REFERENCES operaciones.nodos(tenant_id,empresa_id,id)
);
ALTER TABLE ventas_digitales.tiendas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ventas_digitales.tiendas FROM PUBLIC,mastererp_app;
GRANT USAGE ON SCHEMA ventas_digitales TO mastererp_app;

INSERT INTO plataforma.permissions(code,description) VALUES
 ('digital_sales.ecommerce.read','Read e-commerce configuration'),
 ('digital_sales.ecommerce.write','Configure e-commerce storefront')
ON CONFLICT(code) DO NOTHING;

CREATE OR REPLACE FUNCTION ventas_digitales.tiendas_leer(
 p_empresa uuid,p_id uuid DEFAULT NULL,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_limit NOT BETWEEN 1 AND 101 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability(
  'digital_sales.ecommerce','digital_sales.ecommerce.read',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Store access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
  'id',id,'company_id',empresa_id,'node_id',nodo_id,'domain',dominio,
  'name',nombre,'status',estado,'branding',marca,'configuration',configuracion,
  'modules',modulos,'version',version,'updated_at',actualizado_en)
  ORDER BY nombre,id),'[]') INTO result
 FROM ventas_digitales.tiendas
 WHERE tenant_id=plataforma.current_app_tenant_id() AND empresa_id=p_empresa
 AND (p_id IS NULL OR id=p_id) LIMIT p_limit;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN
  RAISE EXCEPTION 'Store not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION ventas_digitales.tienda_configurar(
 p_empresa uuid,p_id uuid,p_nodo uuid,p_dominio text,p_nombre text,
 p_version bigint,p_cambios jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id();
 actor uuid:=plataforma.current_app_user_id(); sid uuid:=COALESCE(p_id,gen_random_uuid());
 current ventas_digitales.tiendas%ROWTYPE; corr uuid;
BEGIN
 IF plataforma.has_current_tenant_capability(
  'digital_sales.ecommerce','digital_sales.ecommerce.write',p_empresa,p_nodo) IS NOT TRUE
 OR NULLIF(current_setting('app.current_operation',true),'')
  IS DISTINCT FROM 'digital_sales.ecommerce.configure' THEN
  RAISE EXCEPTION 'Store configuration denied' USING ERRCODE='42501'; END IF;
 IF jsonb_typeof(COALESCE(p_cambios,'{}'))<>'object' THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF p_id IS NULL THEN
  IF p_dominio IS NULL OR p_nombre IS NULL OR p_nodo IS NULL THEN
   RAISE EXCEPTION 'Required fields missing' USING ERRCODE='22023'; END IF;
  INSERT INTO ventas_digitales.tiendas(
   id,tenant_id,empresa_id,nodo_id,dominio,nombre,marca,configuracion,modulos,creado_por)
  VALUES(sid,tenant,p_empresa,p_nodo,lower(btrim(p_dominio)),btrim(p_nombre),
   COALESCE(p_cambios->'branding','{}'),COALESCE(p_cambios->'configuration','{}'),
   COALESCE(p_cambios->'modules','[]'),actor);
 ELSE
  SELECT * INTO current FROM ventas_digitales.tiendas
   WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Store not found' USING ERRCODE='P0002'; END IF;
  IF current.version<>p_version THEN
   RAISE EXCEPTION 'Stale store version' USING ERRCODE='40001'; END IF;
  UPDATE ventas_digitales.tiendas SET
   nodo_id=COALESCE(p_nodo,nodo_id),
   dominio=COALESCE(lower(NULLIF(btrim(p_dominio),'')),dominio),
   nombre=COALESCE(NULLIF(btrim(p_nombre),''),nombre),
   estado=COALESCE(p_cambios->>'status',estado),
   marca=CASE WHEN p_cambios?'branding' THEN p_cambios->'branding' ELSE marca END,
   configuracion=CASE WHEN p_cambios?'configuration'
    THEN p_cambios->'configuration' ELSE configuracion END,
   modulos=CASE WHEN p_cambios?'modules' THEN p_cambios->'modules' ELSE modulos END,
   version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_id;
 END IF;
 corr:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 INSERT INTO auditoria.events(
  tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.4.2-ecommerce','tienda',sid,
  'digital_sales.ecommerce.configure',corr,'{}');
 RETURN ventas_digitales.tiendas_leer(p_empresa,sid);
END $$;

CREATE OR REPLACE FUNCTION ventas_digitales.catalogo_publico(
 p_dominio text,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,catalogo,plataforma,pg_temp AS $$
DECLARE store ventas_digitales.tiendas%ROWTYPE;
BEGIN
 IF p_limit NOT BETWEEN 1 AND 201 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 SELECT * INTO store FROM ventas_digitales.tiendas
 WHERE tenant_id=plataforma.current_app_tenant_id()
 AND dominio=lower(p_dominio) AND estado='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Store not found' USING ERRCODE='P0002'; END IF;
 RETURN jsonb_build_object(
  'store',jsonb_build_object('id',store.id,'name',store.nombre,
   'branding',store.marca,'configuration',store.configuracion,'modules',store.modulos),
  'categories',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'slug',slug,'name',nombre,'image_url',imagen_url) ORDER BY orden,nombre),'[]')
   FROM catalogo.categorias WHERE tenant_id=store.tenant_id AND estado='ACTIVE'),
  'products',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'id',p.id,'name',p.nombre,'description',p.descripcion,'price',p.precio,
   'image_url',p.imagen_url,'category_ref',p.categoria_ref,'brand_ref',p.marca_ref,
   'attributes',p.atributos,'available',i.disponible) ORDER BY p.nombre),'[]')
   FROM catalogo.productos p JOIN catalogo.inventarios i
    ON i.tenant_id=p.tenant_id AND i.producto_id=p.id
   WHERE p.tenant_id=store.tenant_id AND p.estado='ACTIVE'
   AND i.empresa_id=store.empresa_id AND i.nodo_id=store.nodo_id
   AND i.ventas_habilitadas AND i.disponible>0 LIMIT p_limit));
END $$;

REVOKE ALL ON FUNCTION ventas_digitales.tiendas_leer(uuid,uuid,integer),
 ventas_digitales.tienda_configurar(uuid,uuid,uuid,text,text,bigint,jsonb),
 ventas_digitales.catalogo_publico(text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.tiendas_leer(uuid,uuid,integer),
 ventas_digitales.tienda_configurar(uuid,uuid,uuid,text,text,bigint,jsonb),
 ventas_digitales.catalogo_publico(text,integer) TO mastererp_app;
