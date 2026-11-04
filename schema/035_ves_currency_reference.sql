-- Canonical currency required by the approved Tumandaito company configuration.
INSERT INTO catalogo.monedas(codigo, nombre, decimales)
VALUES ('VES', 'Bolivar venezolano', 2)
ON CONFLICT (codigo) DO NOTHING;

