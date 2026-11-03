-- Local candidate only. Canonical references absent from the baseline; no data seeded.
CREATE SCHEMA IF NOT EXISTS catalogo;
CREATE SCHEMA IF NOT EXISTS administracion;
DO $$ BEGIN
 IF to_regtype('administracion.importe') IS NULL THEN
  CREATE DOMAIN administracion.importe AS numeric CHECK (VALUE>=0 AND VALUE<1000000000000000000 AND scale(VALUE)<=6);
  CREATE DOMAIN administracion.positivo AS administracion.importe CHECK (VALUE>0);
  CREATE DOMAIN administracion.cantidad AS numeric CHECK (VALUE>0 AND VALUE<1000000000000000000 AND scale(VALUE)<=6);
  CREATE DOMAIN administracion.cambio AS numeric CHECK (VALUE>0 AND VALUE<1000000000000 AND scale(VALUE)<=12);
  CREATE DOMAIN administracion.firmado AS numeric CHECK (abs(VALUE)<1000000000000000000 AND scale(VALUE)<=6);
 END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS branches_scope_uidx ON organizacion.branches(tenant_id,company_id,id);
CREATE TABLE IF NOT EXISTS catalogo.monedas (
 codigo char(3) PRIMARY KEY CHECK (codigo ~ '^[A-Z]{3}$'), nombre text NOT NULL CHECK (length(btrim(nombre))>0),
 decimales smallint NOT NULL CHECK(decimales BETWEEN 0 AND 6)
);
CREATE TABLE IF NOT EXISTS catalogo.terceros (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 codigo text NOT NULL CHECK(length(btrim(codigo))>0), nombre text NOT NULL CHECK(length(btrim(nombre))>0),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0), UNIQUE(tenant_id,id), UNIQUE(tenant_id,codigo)
);
CREATE TABLE IF NOT EXISTS catalogo.roles_tercero (
 tenant_id uuid NOT NULL, tercero_id uuid NOT NULL, rol text NOT NULL CHECK(rol IN ('cliente','proveedor')),
 PRIMARY KEY(tenant_id,tercero_id,rol), FOREIGN KEY(tenant_id,tercero_id) REFERENCES catalogo.terceros(tenant_id,id)
);
CREATE TABLE IF NOT EXISTS catalogo.productos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 codigo text NOT NULL CHECK(length(btrim(codigo))>0), nombre text NOT NULL CHECK(length(btrim(nombre))>0),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0), UNIQUE(tenant_id,id), UNIQUE(tenant_id,codigo)
);
