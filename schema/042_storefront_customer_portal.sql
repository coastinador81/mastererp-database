-- Customer self-service projection. Identity and store scope are always server-derived.
CREATE TABLE IF NOT EXISTS ventas_digitales.cliente_perfiles (
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id), empresa_id uuid NOT NULL,
 cliente_id uuid NOT NULL, telefono text, fecha_nacimiento date, foto_url text,
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(tenant_id,empresa_id,cliente_id),
 FOREIGN KEY(tenant_id,cliente_id) REFERENCES catalogo.terceros(tenant_id,id),
 CHECK(telefono IS NULL OR telefono~'^\+58(412|414|416|424|426)[0-9]{7}$'),
 CHECK(fecha_nacimiento IS NULL OR fecha_nacimiento<=current_date-interval '13 years'),
 CHECK(foto_url IS NULL OR (foto_url~'^https://' AND length(foto_url)<=1000))
);
CREATE TABLE IF NOT EXISTS ventas_digitales.cliente_direcciones (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 empresa_id uuid NOT NULL,
 cliente_id uuid NOT NULL,
 etiqueta text NOT NULL CHECK(length(btrim(etiqueta)) BETWEEN 1 AND 60),
 direccion text NOT NULL CHECK(length(btrim(direccion)) BETWEEN 5 AND 500),
 zona text NOT NULL CHECK(length(btrim(zona)) BETWEEN 2 AND 120),
 unidad text CHECK(length(unidad)<=120),
 referencia text CHECK(length(referencia)<=300),
 latitud numeric(9,6) NOT NULL CHECK(latitud BETWEEN -90 AND 90),
 longitud numeric(9,6) NOT NULL CHECK(longitud BETWEEN -180 AND 180),
 predeterminada boolean NOT NULL DEFAULT false,
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,cliente_id) REFERENCES catalogo.terceros(tenant_id,id)
);
CREATE UNIQUE INDEX IF NOT EXISTS cliente_direccion_predeterminada_uidx
 ON ventas_digitales.cliente_direcciones(tenant_id,empresa_id,cliente_id)
 WHERE predeterminada;
ALTER TABLE ventas_digitales.cliente_direcciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE ventas_digitales.cliente_perfiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ventas_digitales.cliente_perfiles,ventas_digitales.cliente_direcciones FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_identidad_registrar(
 p_issuer text,p_subject text,p_email text,p_name text,p_domain text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,catalogo,administracion,plataforma,pg_temp AS $$
DECLARE store record; actor uuid; customer uuid; customer_code text;
BEGIN
 IF p_issuer !~ '^https://' OR length(p_subject) NOT BETWEEN 1 AND 255 OR length(p_email)>254
  OR length(btrim(p_name)) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Invalid registration' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.storefront.identity.register' THEN
  RAISE EXCEPTION 'Registration denied' USING ERRCODE='42501'; END IF;
 SELECT tenant_id,empresa_id,id INTO store FROM ventas_digitales.tiendas
 WHERE tenant_id=plataforma.current_app_tenant_id() AND dominio=lower(btrim(p_domain)) AND estado='ACTIVE';
 IF store IS NULL THEN RAISE EXCEPTION 'Store not found' USING ERRCODE='P0002'; END IF;
 SELECT e.user_id,i.cliente_id INTO actor,customer FROM plataforma.external_identities e
 LEFT JOIN ventas_digitales.cliente_identidades i ON i.user_id=e.user_id AND i.tenant_id=store.tenant_id AND i.empresa_id=store.empresa_id
 WHERE e.issuer=p_issuer AND e.subject=p_subject AND e.status='active';
 IF customer IS NOT NULL THEN RETURN jsonb_build_object('customer_id',customer,'created',false); END IF;
 IF actor IS NULL THEN
  actor:=gen_random_uuid();
  INSERT INTO plataforma.users(id,email,display_name,status) VALUES(actor,p_email,btrim(p_name),'active');
  INSERT INTO plataforma.external_identities(issuer,subject,user_id,status) VALUES(p_issuer,p_subject,actor,'active');
 END IF;
 customer:=gen_random_uuid();customer_code:='WEB-'||upper(substr(replace(customer::text,'-',''),1,12));
 INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre) VALUES(customer,store.tenant_id,customer_code,btrim(p_name));
 INSERT INTO catalogo.roles_tercero(tenant_id,tercero_id,rol) VALUES(store.tenant_id,customer,'cliente');
 INSERT INTO administracion.perfiles_tercero(tenant_id,empresa_id,tercero_id,rol,creado_por)
 VALUES(store.tenant_id,store.empresa_id,customer,'cliente',actor);
 INSERT INTO ventas_digitales.cliente_identidades(tenant_id,empresa_id,cliente_id,user_id)
 VALUES(store.tenant_id,store.empresa_id,customer,actor);
 INSERT INTO ventas_digitales.cliente_perfiles(tenant_id,empresa_id,cliente_id)
 VALUES(store.tenant_id,store.empresa_id,customer);
 RETURN jsonb_build_object('customer_id',customer,'created',true);
END $$;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_contexto(
 p_issuer text,p_subject text,p_domain text)
RETURNS TABLE(tenant_id uuid,empresa_id uuid,cliente_id uuid)
LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,plataforma,pg_temp AS $$
 SELECT i.tenant_id,i.empresa_id,i.cliente_id
 FROM plataforma.external_identities e
 JOIN ventas_digitales.cliente_identidades i ON i.user_id=e.user_id
 JOIN ventas_digitales.tiendas t ON (t.tenant_id,t.empresa_id)=(i.tenant_id,i.empresa_id)
 WHERE e.issuer=p_issuer AND e.subject=p_subject AND e.status='active'
  AND t.dominio=lower(btrim(p_domain)) AND t.estado='ACTIVE'
  AND i.tenant_id=plataforma.current_app_tenant_id()
 LIMIT 1
$$;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_portal_leer(
 p_issuer text,p_subject text,p_domain text,p_section text,p_id uuid DEFAULT NULL,p_limit integer DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,catalogo,operaciones,plataforma,pg_temp AS $$
DECLARE scope record; result jsonb;
BEGIN
 IF p_section NOT IN ('profile','addresses','orders') OR p_limit NOT BETWEEN 1 AND 100 THEN
  RAISE EXCEPTION 'Invalid portal request' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') NOT IN
  ('digital_sales.storefront.customer.read','digital_sales.storefront.customer.write') THEN
  RAISE EXCEPTION 'Portal access denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO scope FROM ventas_digitales.cliente_contexto(p_issuer,p_subject,p_domain);
 IF scope IS NULL THEN RAISE EXCEPTION 'Customer not found' USING ERRCODE='P0002'; END IF;
 IF p_section='profile' THEN
  SELECT jsonb_build_object('id',t.id,'name',t.nombre,'code',t.codigo,'phone',p.telefono,
   'birthDate',p.fecha_nacimiento,'photoUrl',p.foto_url) INTO result FROM catalogo.terceros t
  LEFT JOIN ventas_digitales.cliente_perfiles p ON (p.tenant_id,p.empresa_id,p.cliente_id)=(scope.tenant_id,scope.empresa_id,t.id)
  WHERE (t.tenant_id,t.id)=(scope.tenant_id,scope.cliente_id);
 ELSIF p_section='addresses' THEN
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',d.id,'label',d.etiqueta,'address',d.direccion,
   'zone',d.zona,'unit',d.unidad,'reference',d.referencia,'latitude',d.latitud,'longitude',d.longitud,
   'default',d.predeterminada,'version',d.version) ORDER BY d.predeterminada DESC,d.creado_en),'[]')
  INTO result FROM ventas_digitales.cliente_direcciones d
  WHERE (d.tenant_id,d.empresa_id,d.cliente_id)=(scope.tenant_id,scope.empresa_id,scope.cliente_id);
 ELSE
  SELECT COALESCE(jsonb_agg(item ORDER BY created_at DESC),'[]') INTO result FROM (
   SELECT p.creado_en created_at,jsonb_build_object('id',p.id,'number',p.numero,'status',p.estado,
    'currency',p.moneda,'total',p.total,'delivery',p.entrega_snapshot,'payment',p.pago_snapshot,
    'created_at',p.creado_en,'updated_at',p.actualizado_en,
    'items',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',l.id,'product_id',l.producto_id,
     'name',l.producto_nombre,'quantity',l.cantidad,'unit_price',l.precio_unitario,'subtotal',l.subtotal)
     ORDER BY l.posicion),'[]') FROM operaciones.pedido_lineas l
     WHERE (l.tenant_id,l.empresa_id,l.pedido_id)=(p.tenant_id,p.empresa_id,p.id))) item
   FROM operaciones.pedidos p WHERE (p.tenant_id,p.empresa_id,p.cliente_id)=(scope.tenant_id,scope.empresa_id,scope.cliente_id)
    AND (p_id IS NULL OR p.id=p_id) ORDER BY p.creado_en DESC LIMIT p_limit) q;
  IF p_id IS NOT NULL THEN
   IF jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
   result:=result->0;
  END IF;
 END IF;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_perfil_actualizar(
 p_issuer text,p_subject text,p_domain text,p_name text,p_phone text,p_birth_date date,p_photo_url text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,catalogo,plataforma,pg_temp AS $$
DECLARE scope record;
BEGIN
 IF length(btrim(p_name)) NOT BETWEEN 1 AND 200 OR p_phone!~'^\+58(412|414|416|424|426)[0-9]{7}$'
  OR p_birth_date>current_date-interval '13 years' OR (p_photo_url IS NOT NULL AND p_photo_url!~'^https://')
  THEN RAISE EXCEPTION 'Invalid profile' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.storefront.customer.write' THEN
  RAISE EXCEPTION 'Profile update denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO scope FROM ventas_digitales.cliente_contexto(p_issuer,p_subject,p_domain);
 IF scope IS NULL THEN RAISE EXCEPTION 'Customer not found' USING ERRCODE='P0002'; END IF;
 UPDATE catalogo.terceros SET nombre=btrim(p_name),version=version+1
 WHERE (tenant_id,id)=(scope.tenant_id,scope.cliente_id);
 INSERT INTO ventas_digitales.cliente_perfiles(tenant_id,empresa_id,cliente_id,telefono,fecha_nacimiento,foto_url)
 VALUES(scope.tenant_id,scope.empresa_id,scope.cliente_id,p_phone,p_birth_date,NULLIF(btrim(p_photo_url),''))
 ON CONFLICT(tenant_id,empresa_id,cliente_id) DO UPDATE SET telefono=excluded.telefono,
  fecha_nacimiento=excluded.fecha_nacimiento,foto_url=excluded.foto_url,actualizado_en=transaction_timestamp();
 RETURN ventas_digitales.cliente_portal_leer(p_issuer,p_subject,p_domain,'profile');
END $$;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_direccion_guardar(
 p_issuer text,p_subject text,p_domain text,p_id uuid,p_label text,p_address text,p_zone text,p_unit text,
 p_reference text,p_latitude numeric,p_longitude numeric,p_default boolean,p_version bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,plataforma,pg_temp AS $$
DECLARE scope record; address_id uuid:=COALESCE(p_id,gen_random_uuid()); next_version bigint;
BEGIN
 IF length(btrim(p_label)) NOT BETWEEN 1 AND 60 OR length(btrim(p_address)) NOT BETWEEN 5 AND 500
  OR length(btrim(p_zone)) NOT BETWEEN 2 AND 120 OR length(COALESCE(p_unit,''))>120
  OR length(COALESCE(p_reference,''))>300 OR p_latitude NOT BETWEEN -90 AND 90
  OR p_longitude NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'Invalid address' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.storefront.customer.write' THEN
  RAISE EXCEPTION 'Address update denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO scope FROM ventas_digitales.cliente_contexto(p_issuer,p_subject,p_domain);
 IF scope IS NULL THEN RAISE EXCEPTION 'Customer not found' USING ERRCODE='P0002'; END IF;
 IF COALESCE(p_default,false) THEN UPDATE ventas_digitales.cliente_direcciones SET predeterminada=false
  WHERE (tenant_id,empresa_id,cliente_id)=(scope.tenant_id,scope.empresa_id,scope.cliente_id); END IF;
 IF p_id IS NULL THEN
  INSERT INTO ventas_digitales.cliente_direcciones(id,tenant_id,empresa_id,cliente_id,etiqueta,direccion,zona,unidad,referencia,latitud,longitud,predeterminada)
  VALUES(address_id,scope.tenant_id,scope.empresa_id,scope.cliente_id,btrim(p_label),btrim(p_address),btrim(p_zone),NULLIF(btrim(p_unit),''),
   NULLIF(btrim(p_reference),''),p_latitude,p_longitude,COALESCE(p_default,false)) RETURNING version INTO next_version;
 ELSE
  UPDATE ventas_digitales.cliente_direcciones SET etiqueta=btrim(p_label),direccion=btrim(p_address),zona=btrim(p_zone),
   unidad=NULLIF(btrim(p_unit),''),referencia=NULLIF(btrim(p_reference),''),latitud=p_latitude,longitud=p_longitude,
   predeterminada=COALESCE(p_default,false),version=version+1,actualizado_en=transaction_timestamp()
  WHERE (tenant_id,empresa_id,cliente_id,id,version)=(scope.tenant_id,scope.empresa_id,scope.cliente_id,p_id,p_version)
  RETURNING version INTO next_version;
  IF next_version IS NULL THEN RAISE EXCEPTION 'Address changed' USING ERRCODE='40001'; END IF;
 END IF;
 RETURN jsonb_build_object('id',address_id,'version',next_version);
END $$;

REVOKE ALL ON FUNCTION ventas_digitales.cliente_contexto(text,text,text),
 ventas_digitales.cliente_identidad_registrar(text,text,text,text,text),
 ventas_digitales.cliente_portal_leer(text,text,text,text,uuid,integer),
 ventas_digitales.cliente_perfil_actualizar(text,text,text,text,text,date,text),
 ventas_digitales.cliente_direccion_guardar(text,text,text,uuid,text,text,text,text,text,numeric,numeric,boolean,bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.cliente_portal_leer(text,text,text,text,uuid,integer),
 ventas_digitales.cliente_identidad_registrar(text,text,text,text,text),
 ventas_digitales.cliente_perfil_actualizar(text,text,text,text,text,date,text),
 ventas_digitales.cliente_direccion_guardar(text,text,text,uuid,text,text,text,text,text,numeric,numeric,boolean,bigint) TO mastererp_app;
