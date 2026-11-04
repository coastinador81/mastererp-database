DO $$
BEGIN
 IF NOT EXISTS (
  SELECT 1 FROM catalogo.monedas
  WHERE codigo = 'VES' AND nombre = 'Bolivar venezolano' AND decimales = 2
 ) THEN
  RAISE EXCEPTION 'VES canonical currency missing or inconsistent';
 END IF;
END $$;

