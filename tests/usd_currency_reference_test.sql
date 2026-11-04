DO $$
BEGIN
 IF NOT EXISTS (
  SELECT 1 FROM catalogo.monedas
  WHERE codigo = 'USD' AND nombre = 'Dolar estadounidense' AND decimales = 2
 ) THEN
  RAISE EXCEPTION 'USD canonical currency missing or inconsistent';
 END IF;
END $$;

