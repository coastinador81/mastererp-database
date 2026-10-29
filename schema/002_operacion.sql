-- Tablas de la operación inicial: organización, catálogo, página y empleados.
-- Una fila siempre lleva la organización. El script se puede correr otra vez.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS plataforma;
CREATE SCHEMA IF NOT EXISTS catalogo;
CREATE SCHEMA IF NOT EXISTS comercio;
CREATE SCHEMA IF NOT EXISTS personas;

CREATE TABLE IF NOT EXISTS plataforma.organizaciones (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre text NOT NULL,
    slug text NOT NULL UNIQUE,
    creado_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plataforma.modulos (
    organizacion_id uuid NOT NULL REFERENCES plataforma.organizaciones (id),
    codigo text NOT NULL,
    activo boolean NOT NULL DEFAULT true,
    PRIMARY KEY (organizacion_id, codigo)
);

CREATE TABLE IF NOT EXISTS plataforma.usuarios (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organizacion_id uuid NOT NULL REFERENCES plataforma.organizaciones (id),
    nombre text NOT NULL,
    correo text NOT NULL,
    rol text NOT NULL,
    UNIQUE (organizacion_id, correo)
);

CREATE TABLE IF NOT EXISTS catalogo.productos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organizacion_id uuid NOT NULL REFERENCES plataforma.organizaciones (id),
    sku text NOT NULL,
    nombre text NOT NULL,
    precio_centavos integer NOT NULL CHECK (precio_centavos >= 0),
    categoria text NOT NULL DEFAULT '',
    UNIQUE (organizacion_id, sku)
);

CREATE TABLE IF NOT EXISTS catalogo.inventario (
    organizacion_id uuid NOT NULL REFERENCES plataforma.organizaciones (id),
    sku text NOT NULL,
    cantidad integer NOT NULL DEFAULT 0 CHECK (cantidad >= 0),
    PRIMARY KEY (organizacion_id, sku)
);

CREATE TABLE IF NOT EXISTS comercio.paginas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organizacion_id uuid NOT NULL UNIQUE REFERENCES plataforma.organizaciones (id),
    host text NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS personas.empleados (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organizacion_id uuid NOT NULL REFERENCES plataforma.organizaciones (id),
    nombre text NOT NULL,
    puesto text NOT NULL,
    sucursal text NOT NULL DEFAULT ''
);
