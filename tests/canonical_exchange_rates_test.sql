BEGIN;
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES
 ('USD','US dollar',2),('VES','Bolívar',2) ON CONFLICT DO NOTHING;
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_operation','catalog.exchange_rates.refresh',true);
DO $$
DECLARE saved jsonb; current_rate jsonb;
BEGIN
 saved:=catalogo.tasa_cambio_guardar('USD','VES',916.6477,CURRENT_DATE,'bcv.today');
 IF saved->>'rate'<>'916.64770000' OR saved->>'effectiveDate'<>CURRENT_DATE::text THEN
  RAISE EXCEPTION 'Exchange rate was not persisted: %',saved; END IF;
 saved:=catalogo.tasa_cambio_guardar('USD','VES',917.25,CURRENT_DATE,'bcv.today');
 current_rate:=catalogo.tasa_cambio_actual('USD','VES');
 IF current_rate->>'rate'<>'917.25000000' THEN
  RAISE EXCEPTION 'Daily refresh is not idempotent: %',current_rate; END IF;
END $$;
RESET ROLE;
ROLLBACK;
