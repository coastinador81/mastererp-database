-- Canonical currency used by historical Tumandaito order totals.
INSERT INTO catalogo.monedas(codigo, nombre, decimales)
VALUES ('USD', 'Dolar estadounidense', 2)
ON CONFLICT (codigo) DO NOTHING;

