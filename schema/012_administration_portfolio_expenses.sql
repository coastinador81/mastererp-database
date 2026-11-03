-- Local candidate; dependency order follows the reviewed model.

CREATE TABLE IF NOT EXISTS administracion.partidas_cartera (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 documento_id uuid NOT NULL UNIQUE, lado text NOT NULL CHECK(lado IN ('cobrar','pagar')),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.vencimientos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 partida_id uuid NOT NULL, posicion integer NOT NULL CHECK(posicion>0), fecha date NOT NULL, importe administracion.importe NOT NULL, UNIQUE(tenant_id,empresa_id,partida_id,posicion),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,partida_id) REFERENCES administracion.partidas_cartera(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.aplicaciones_cartera (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 vencimiento_id uuid NOT NULL, movimiento_id uuid, credito_id uuid,
 importe_origen administracion.positivo NOT NULL, importe_destino administracion.positivo NOT NULL,
 tipo_cambio administracion.cambio NOT NULL, cambio_fecha date NOT NULL, cambio_fuente text NOT NULL CHECK(length(btrim(cambio_fuente))>0),
 reverso_de_id uuid UNIQUE, CHECK(num_nonnulls(movimiento_id,credito_id)=1), CHECK(reverso_de_id IS DISTINCT FROM id),
 CHECK(importe_destino=importe_origen*tipo_cambio),
 idempotency_key varchar(128) UNIQUE,
 FOREIGN KEY(idempotency_key) REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,vencimiento_id) REFERENCES administracion.vencimientos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,movimiento_id) REFERENCES administracion.movimientos_tesoreria(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,credito_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,reverso_de_id) REFERENCES administracion.aplicaciones_cartera(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.categorias_gasto (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 codigo text NOT NULL, nombre text NOT NULL, UNIQUE(tenant_id,empresa_id,codigo),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.gastos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 documento_id uuid NOT NULL UNIQUE, categoria_id uuid NOT NULL, responsable_id uuid NOT NULL, FOREIGN KEY(tenant_id,responsable_id) REFERENCES plataforma.user_tenants(tenant_id,user_id),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,categoria_id) REFERENCES administracion.categorias_gasto(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.fondos_caja_chica (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 cuenta_id uuid NOT NULL UNIQUE, responsable_id uuid NOT NULL, limite_autorizado administracion.importe, FOREIGN KEY(tenant_id,responsable_id) REFERENCES plataforma.user_tenants(tenant_id,user_id),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,cuenta_id) REFERENCES administracion.cuentas_tesoreria(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.reposiciones (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 fondo_id uuid NOT NULL, documento_id uuid NOT NULL UNIQUE, movimiento_id uuid NOT NULL UNIQUE,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,fondo_id) REFERENCES administracion.fondos_caja_chica(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,movimiento_id) REFERENCES administracion.movimientos_tesoreria(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.anticipos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 documento_id uuid NOT NULL UNIQUE, movimiento_id uuid NOT NULL UNIQUE, responsable_id uuid NOT NULL, FOREIGN KEY(tenant_id,responsable_id) REFERENCES plataforma.user_tenants(tenant_id,user_id),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,movimiento_id) REFERENCES administracion.movimientos_tesoreria(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.rendiciones (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 documento_id uuid NOT NULL UNIQUE, anticipo_id uuid NOT NULL,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,anticipo_id) REFERENCES administracion.anticipos(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.rendicion_gastos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 rendicion_id uuid NOT NULL, gasto_id uuid NOT NULL, detalle_id uuid NOT NULL UNIQUE,
 idempotency_key varchar(128) UNIQUE,
 FOREIGN KEY(idempotency_key) REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,rendicion_id) REFERENCES administracion.rendiciones(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,gasto_id) REFERENCES administracion.gastos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,detalle_id) REFERENCES administracion.detalles_documento(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.politicas_reserva (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 cuenta_id uuid NOT NULL UNIQUE, codigo text NOT NULL, habilitada boolean NOT NULL, tope administracion.importe, descripcion text NOT NULL,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,cuenta_id) REFERENCES administracion.cuentas_tesoreria(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.reservas_fondos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 politica_id uuid NOT NULL, documento_id uuid NOT NULL, importe administracion.positivo NOT NULL, origen_id uuid, CHECK(origen_id IS DISTINCT FROM id),
 idempotency_key varchar(128) UNIQUE,
 FOREIGN KEY(idempotency_key) REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,politica_id) REFERENCES administracion.politicas_reserva(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,origen_id) REFERENCES administracion.reservas_fondos(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.soportes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 documento_id uuid, extracto_id uuid, almacenamiento_ref text NOT NULL CHECK(length(btrim(almacenamiento_ref))>0),
 sha256 char(64) NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'), CHECK(num_nonnulls(documento_id,extracto_id)=1),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,extracto_id) REFERENCES administracion.extractos_bancarios(tenant_id,empresa_id,id)
);
CREATE INDEX IF NOT EXISTS vencimientos_partida_id_idx ON administracion.vencimientos(tenant_id,empresa_id,partida_id,fecha);
CREATE INDEX IF NOT EXISTS aplicaciones_cartera_vencimiento_id_idx ON administracion.aplicaciones_cartera(tenant_id,empresa_id,vencimiento_id);
CREATE INDEX IF NOT EXISTS aplicaciones_cartera_movimiento_id_idx ON administracion.aplicaciones_cartera(tenant_id,empresa_id,movimiento_id);
CREATE INDEX IF NOT EXISTS aplicaciones_cartera_credito_id_idx ON administracion.aplicaciones_cartera(tenant_id,empresa_id,credito_id);
CREATE INDEX IF NOT EXISTS reservas_fondos_politica_id_idx ON administracion.reservas_fondos(tenant_id,empresa_id,politica_id);
CREATE INDEX IF NOT EXISTS reservas_fondos_origen_id_idx ON administracion.reservas_fondos(tenant_id,empresa_id,origen_id);
CREATE INDEX IF NOT EXISTS rendicion_gastos_gasto_id_idx ON administracion.rendicion_gastos(tenant_id,empresa_id,gasto_id);
