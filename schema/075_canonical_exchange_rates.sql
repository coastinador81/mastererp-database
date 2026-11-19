CREATE TABLE IF NOT EXISTS catalogo.tasas_cambio (
 moneda_base varchar(3) NOT NULL REFERENCES catalogo.monedas(codigo),
 moneda_cotizada varchar(3) NOT NULL REFERENCES catalogo.monedas(codigo),
 fecha_valor date NOT NULL,
 fuente text NOT NULL CHECK(length(btrim(fuente)) BETWEEN 2 AND 80),
 tasa numeric(20,8) NOT NULL CHECK(tasa>0),
 capturada_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(moneda_base,moneda_cotizada,fecha_valor,fuente),
 CHECK(moneda_base<>moneda_cotizada)
);
REVOKE ALL ON catalogo.tasas_cambio FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION catalogo.tasa_cambio_guardar(
 p_base text,p_cotizada text,p_tasa numeric,p_fecha date,p_fuente text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.exchange_rates.refresh'
 OR upper(COALESCE(p_base,'')) !~ '^[A-Z]{3}$' OR upper(COALESCE(p_cotizada,'')) !~ '^[A-Z]{3}$'
 OR upper(p_base)=upper(p_cotizada) OR p_tasa IS NULL OR p_tasa<=0
 OR p_fecha IS NULL OR p_fecha<CURRENT_DATE-7 OR p_fecha>CURRENT_DATE+1
 OR length(btrim(COALESCE(p_fuente,''))) NOT BETWEEN 2 AND 80 THEN
  RAISE EXCEPTION 'Invalid exchange rate refresh' USING ERRCODE='22023';
 END IF;
 INSERT INTO catalogo.tasas_cambio(moneda_base,moneda_cotizada,fecha_valor,fuente,tasa)
 VALUES(upper(p_base),upper(p_cotizada),p_fecha,btrim(p_fuente),p_tasa)
 ON CONFLICT(moneda_base,moneda_cotizada,fecha_valor,fuente) DO UPDATE
 SET tasa=EXCLUDED.tasa,capturada_en=transaction_timestamp();
 SELECT jsonb_build_object('base',moneda_base,'quote',moneda_cotizada,'rate',tasa,
  'effectiveDate',fecha_valor,'source',fuente,'updatedAt',capturada_en)
 INTO result FROM catalogo.tasas_cambio
 WHERE moneda_base=upper(p_base) AND moneda_cotizada=upper(p_cotizada)
 AND fecha_valor=p_fecha AND fuente=btrim(p_fuente);
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION catalogo.tasa_cambio_actual(p_base text DEFAULT 'USD',p_cotizada text DEFAULT 'VES')
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,catalogo,pg_temp AS $$
 SELECT jsonb_build_object('base',moneda_base,'quote',moneda_cotizada,'rate',tasa,
  'effectiveDate',fecha_valor,'source',fuente,'updatedAt',capturada_en)
 FROM catalogo.tasas_cambio
 WHERE moneda_base=upper(p_base) AND moneda_cotizada=upper(p_cotizada)
 ORDER BY fecha_valor DESC,capturada_en DESC LIMIT 1
$$;

REVOKE ALL ON FUNCTION catalogo.tasa_cambio_guardar(text,text,numeric,date,text),
 catalogo.tasa_cambio_actual(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.tasa_cambio_guardar(text,text,numeric,date,text),
 catalogo.tasa_cambio_actual(text,text) TO mastererp_app;

