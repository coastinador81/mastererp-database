-- Local candidate; dependency order follows the reviewed model.

CREATE TABLE IF NOT EXISTS administracion.cuentas_tesoreria (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 codigo text NOT NULL, nombre text NOT NULL, tipo text NOT NULL CHECK(tipo IN ('caja','banco')),
 moneda char(3) NOT NULL REFERENCES catalogo.monedas(codigo), referencia_bancaria text,
 UNIQUE(tenant_id,empresa_id,codigo), UNIQUE(tenant_id,empresa_id,id,moneda),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.operaciones_tesoreria (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 tipo text NOT NULL CHECK(tipo IN ('cobro','pago','transferencia','reverso','ajuste')),
 tercero_id uuid, fecha date NOT NULL, idempotency_key varchar(128) UNIQUE,
 origen_sistema text NOT NULL, referencia_externa text NOT NULL,
 CHECK(tipo NOT IN ('cobro','pago') OR tercero_id IS NOT NULL),
 UNIQUE(tenant_id,empresa_id,origen_sistema,referencia_externa),
 FOREIGN KEY(tenant_id,tercero_id) REFERENCES catalogo.terceros(tenant_id,id),
 FOREIGN KEY(idempotency_key) REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.movimientos_tesoreria (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 operacion_id uuid NOT NULL, cuenta_id uuid NOT NULL, sentido text NOT NULL CHECK(sentido IN ('entrada','salida')),
 moneda char(3) NOT NULL, importe administracion.positivo NOT NULL,
 moneda_base char(3) NOT NULL REFERENCES catalogo.monedas(codigo), tipo_cambio administracion.cambio NOT NULL,
 cambio_fecha date NOT NULL, cambio_fuente text NOT NULL CHECK(length(btrim(cambio_fuente))>0),
 importe_base numeric GENERATED ALWAYS AS (importe*tipo_cambio) STORED,
 reverso_de_id uuid UNIQUE, CHECK(reverso_de_id IS DISTINCT FROM id), CHECK(moneda<>moneda_base OR tipo_cambio=1),
 FOREIGN KEY(tenant_id,empresa_id,cuenta_id,moneda) REFERENCES administracion.cuentas_tesoreria(tenant_id,empresa_id,id,moneda),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,operacion_id) REFERENCES administracion.operaciones_tesoreria(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,reverso_de_id) REFERENCES administracion.movimientos_tesoreria(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.transferencias (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 operacion_id uuid NOT NULL UNIQUE, salida_id uuid NOT NULL UNIQUE, entrada_id uuid NOT NULL UNIQUE,
 cambio_entre_cuentas administracion.cambio NOT NULL, diferencia_base numeric NOT NULL DEFAULT 0,
 CHECK(abs(diferencia_base)<1e30 AND scale(diferencia_base)<=18), CHECK(salida_id<>entrada_id),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,operacion_id) REFERENCES administracion.operaciones_tesoreria(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,salida_id) REFERENCES administracion.movimientos_tesoreria(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,entrada_id) REFERENCES administracion.movimientos_tesoreria(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.extractos_bancarios (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 cuenta_id uuid NOT NULL, moneda char(3) NOT NULL, referencia_externa text NOT NULL,
 desde date NOT NULL, hasta date NOT NULL, saldo_inicial administracion.firmado NOT NULL, saldo_final administracion.firmado NOT NULL,
 CHECK(desde<=hasta), UNIQUE(tenant_id,empresa_id,cuenta_id,referencia_externa), UNIQUE(tenant_id,empresa_id,id,cuenta_id,moneda),
 FOREIGN KEY(tenant_id,empresa_id,cuenta_id,moneda) REFERENCES administracion.cuentas_tesoreria(tenant_id,empresa_id,id,moneda),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.lineas_extracto (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 extracto_id uuid NOT NULL, cuenta_id uuid NOT NULL, moneda char(3) NOT NULL,
 posicion integer NOT NULL CHECK(posicion>0), referencia_externa text NOT NULL, fecha date NOT NULL,
 importe administracion.firmado NOT NULL CHECK(importe<>0),
 UNIQUE(tenant_id,empresa_id,extracto_id,posicion), UNIQUE(tenant_id,empresa_id,cuenta_id,referencia_externa),
 FOREIGN KEY(tenant_id,empresa_id,extracto_id,cuenta_id,moneda) REFERENCES administracion.extractos_bancarios(tenant_id,empresa_id,id,cuenta_id,moneda),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.conciliaciones (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 cuenta_id uuid NOT NULL, referencia text NOT NULL, UNIQUE(tenant_id,empresa_id,cuenta_id,referencia),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,cuenta_id) REFERENCES administracion.cuentas_tesoreria(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.partidas_conciliacion (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 conciliacion_id uuid NOT NULL, linea_id uuid NOT NULL, movimiento_id uuid NOT NULL, importe administracion.positivo NOT NULL, reverso_de_id uuid UNIQUE, CHECK(reverso_de_id IS DISTINCT FROM id),
 idempotency_key varchar(128) UNIQUE,
 FOREIGN KEY(idempotency_key) REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,conciliacion_id) REFERENCES administracion.conciliaciones(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,linea_id) REFERENCES administracion.lineas_extracto(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,movimiento_id) REFERENCES administracion.movimientos_tesoreria(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,reverso_de_id) REFERENCES administracion.partidas_conciliacion(tenant_id,empresa_id,id)
);
CREATE INDEX IF NOT EXISTS movimientos_tesoreria_cuenta_id_idx ON administracion.movimientos_tesoreria(tenant_id,empresa_id,cuenta_id,creado_en);
CREATE INDEX IF NOT EXISTS movimientos_tesoreria_operacion_id_idx ON administracion.movimientos_tesoreria(tenant_id,empresa_id,operacion_id);
CREATE INDEX IF NOT EXISTS lineas_extracto_extracto_id_idx ON administracion.lineas_extracto(tenant_id,empresa_id,extracto_id);
CREATE INDEX IF NOT EXISTS partidas_conciliacion_linea_id_idx ON administracion.partidas_conciliacion(tenant_id,empresa_id,linea_id);
CREATE INDEX IF NOT EXISTS partidas_conciliacion_movimiento_id_idx ON administracion.partidas_conciliacion(tenant_id,empresa_id,movimiento_id);
CREATE UNIQUE INDEX IF NOT EXISTS movimiento_pierna_canonica_uidx
 ON administracion.movimientos_tesoreria(tenant_id,empresa_id,operacion_id,cuenta_id,sentido) WHERE reverso_de_id IS NULL;
