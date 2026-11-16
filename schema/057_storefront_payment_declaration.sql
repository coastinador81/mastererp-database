-- Persist the server-derived bank payment declaration for Finance review.
CREATE OR REPLACE FUNCTION ventas_digitales.pago_declaracion_registrar(p_pedido uuid,p_declaracion jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,ventas_digitales,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id(); current operaciones.pedidos%ROWTYPE;
BEGIN
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.storefront.checkout'
  OR jsonb_typeof(p_declaracion)<>'object' OR jsonb_typeof(p_declaracion->'payer')<>'object'
  OR COALESCE(p_declaracion->>'paymentDate','')!~'^\d{4}-\d{2}-\d{2}$'
  OR (p_declaracion->>'amountUSD')::numeric<=0 OR (p_declaracion->>'amountVES')::numeric<=0
  OR (p_declaracion->>'exchangeRate')::numeric<=0 OR COALESCE(p_declaracion->>'exchangeRateSource','')=''
 THEN RAISE EXCEPTION 'Invalid payment declaration' USING ERRCODE='22023'; END IF;
 SELECT * INTO current FROM operaciones.pedidos WHERE tenant_id=tenant AND id=p_pedido AND creado_por=actor FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF current.estado<>'PENDING' OR current.pago_snapshot->>'method' NOT IN ('mobile','transfer')
 THEN RAISE EXCEPTION 'Payment declaration not allowed' USING ERRCODE='22023'; END IF;
 UPDATE operaciones.pedidos SET pago_snapshot=pago_snapshot||p_declaracion,actualizado_en=transaction_timestamp()
 WHERE tenant_id=tenant AND id=p_pedido;
END $$;
REVOKE ALL ON FUNCTION ventas_digitales.pago_declaracion_registrar(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.pago_declaracion_registrar(uuid,jsonb) TO mastererp_app;
