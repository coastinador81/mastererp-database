-- Customer-owned payer details per store, remembered after a bank checkout and reused in later purchases.
CREATE TABLE IF NOT EXISTS ventas_digitales.cliente_metodos_pago (
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 empresa_id uuid NOT NULL,
 cliente_id uuid NOT NULL,
 metodo text NOT NULL CHECK(metodo IN ('mobile','transfer')),
 banco_codigo text NOT NULL CHECK(banco_codigo ~ '^[0-9]{4}$'),
 documento text NOT NULL CHECK(documento ~* '^[VEJGP]-?[0-9]{5,12}$'),
 telefono text CHECK(telefono ~ '^0[0-9]{10}$'),
 titular text CHECK(length(btrim(titular)) BETWEEN 2 AND 120),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(tenant_id,empresa_id,cliente_id,metodo),
 FOREIGN KEY(tenant_id,cliente_id) REFERENCES catalogo.terceros(tenant_id,id),
 CHECK(metodo<>'mobile' OR telefono IS NOT NULL)
);
ALTER TABLE ventas_digitales.cliente_metodos_pago ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ventas_digitales.cliente_metodos_pago FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_metodo_pago_guardar(
 p_issuer text,p_subject text,p_domain text,p_method text,p_bank_code text,p_document text,p_phone text,p_holder text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,plataforma,pg_temp AS $$
DECLARE scope record;
BEGIN
 IF NULLIF(current_setting('app.current_operation',true),'') NOT IN
  ('digital_sales.storefront.checkout','digital_sales.storefront.customer.write') THEN
  RAISE EXCEPTION 'Payment method update denied' USING ERRCODE='42501'; END IF;
 IF p_method NOT IN ('mobile','transfer') OR COALESCE(p_bank_code,'')!~'^[0-9]{4}$'
  OR COALESCE(p_document,'')!~*'^[VEJGP]-?[0-9]{5,12}$'
  OR (p_method='mobile' AND COALESCE(p_phone,'')!~'^0[0-9]{10}$')
  OR (p_phone IS NOT NULL AND p_phone!~'^0[0-9]{10}$')
  OR (p_holder IS NOT NULL AND length(btrim(p_holder)) NOT BETWEEN 2 AND 120) THEN
  RAISE EXCEPTION 'Invalid payment method' USING ERRCODE='22023'; END IF;
 SELECT * INTO scope FROM ventas_digitales.cliente_contexto(p_issuer,p_subject,p_domain);
 IF scope IS NULL THEN RAISE EXCEPTION 'Customer not found' USING ERRCODE='P0002'; END IF;
 INSERT INTO ventas_digitales.cliente_metodos_pago(tenant_id,empresa_id,cliente_id,metodo,banco_codigo,documento,telefono,titular)
 VALUES(scope.tenant_id,scope.empresa_id,scope.cliente_id,p_method,p_bank_code,upper(p_document),p_phone,NULLIF(btrim(p_holder),''))
 ON CONFLICT(tenant_id,empresa_id,cliente_id,metodo) DO UPDATE SET banco_codigo=EXCLUDED.banco_codigo,
  documento=EXCLUDED.documento,telefono=EXCLUDED.telefono,titular=EXCLUDED.titular,actualizado_en=transaction_timestamp();
 RETURN jsonb_build_object('method',p_method);
END $$;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_metodos_pago_leer(p_issuer text,p_subject text,p_domain text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,plataforma,pg_temp AS $$
DECLARE scope record; result jsonb;
BEGIN
 IF NULLIF(current_setting('app.current_operation',true),'') NOT IN
  ('digital_sales.storefront.customer.read','digital_sales.storefront.customer.write') THEN
  RAISE EXCEPTION 'Portal access denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO scope FROM ventas_digitales.cliente_contexto(p_issuer,p_subject,p_domain);
 IF scope IS NULL THEN RAISE EXCEPTION 'Customer not found' USING ERRCODE='P0002'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('method',m.metodo,'bankCode',m.banco_codigo,'document',m.documento,
  'phone',m.telefono,'holder',m.titular,'updatedAt',m.actualizado_en) ORDER BY m.actualizado_en DESC),'[]')
 INTO result FROM ventas_digitales.cliente_metodos_pago m
 WHERE (m.tenant_id,m.empresa_id,m.cliente_id)=(scope.tenant_id,scope.empresa_id,scope.cliente_id);
 RETURN result;
END $$;

REVOKE ALL ON FUNCTION ventas_digitales.cliente_metodo_pago_guardar(text,text,text,text,text,text,text,text),
 ventas_digitales.cliente_metodos_pago_leer(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.cliente_metodo_pago_guardar(text,text,text,text,text,text,text,text),
 ventas_digitales.cliente_metodos_pago_leer(text,text,text) TO mastererp_app;
