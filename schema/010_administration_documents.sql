-- Local candidate; dependency order follows the reviewed model.

CREATE TABLE IF NOT EXISTS administracion.condiciones_comerciales (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 codigo text NOT NULL, edicion integer NOT NULL DEFAULT 1 CHECK(edicion>0), descripcion text NOT NULL, dias_plazo integer CHECK(dias_plazo>=0), UNIQUE(tenant_id,empresa_id,codigo,edicion),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.descuentos_pronto_pago (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 condicion_id uuid NOT NULL, hasta_dias integer NOT NULL CHECK(hasta_dias>=0),
 porcentaje numeric CHECK(porcentaje>=0 AND porcentaje<=100 AND scale(porcentaje)<=6),
 importe administracion.positivo, moneda char(3) REFERENCES catalogo.monedas(codigo),
 CHECK(num_nonnulls(porcentaje,importe)=1), CHECK((importe IS NOT NULL)=(moneda IS NOT NULL)),
 UNIQUE(tenant_id,empresa_id,condicion_id,hasta_dias),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,condicion_id) REFERENCES administracion.condiciones_comerciales(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.perfiles_tercero (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 tercero_id uuid NOT NULL, rol text NOT NULL, condicion_id uuid,
 UNIQUE(tenant_id,empresa_id,tercero_id,rol),
 FOREIGN KEY(tenant_id,tercero_id,rol) REFERENCES catalogo.roles_tercero(tenant_id,tercero_id,rol),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,condicion_id) REFERENCES administracion.condiciones_comerciales(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.documentos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 clase text NOT NULL CHECK(clase IN ('cotizacion','venta','factura_cliente','solicitud_compra','orden_compra','factura_proveedor','devolucion_cliente','devolucion_proveedor','credito_cliente','credito_proveedor','debito_cliente','debito_proveedor','gasto','anticipo','rendicion','reposicion')),
 tercero_id uuid, rol_tercero text, condicion_id uuid, documento_origen_id uuid,
 fecha date NOT NULL, serie text NOT NULL DEFAULT '', numero text,
 moneda char(3) NOT NULL REFERENCES catalogo.monedas(codigo),
 moneda_base char(3) NOT NULL REFERENCES catalogo.monedas(codigo), tipo_cambio administracion.cambio NOT NULL,
 cambio_fecha date NOT NULL, cambio_fuente text NOT NULL CHECK(length(btrim(cambio_fuente))>0),
 total administracion.importe NOT NULL DEFAULT 0, total_base numeric GENERATED ALWAYS AS (total*tipo_cambio) STORED,
 cerrado boolean NOT NULL DEFAULT false,
 origen_sistema text, referencia_externa text, idempotency_key varchar(128) UNIQUE,
 CHECK((tercero_id IS NULL)=(rol_tercero IS NULL)),
 CHECK(clase NOT IN ('cotizacion','venta','factura_cliente','devolucion_cliente','credito_cliente','debito_cliente') OR (tercero_id IS NOT NULL AND rol_tercero='cliente')),
 CHECK(clase NOT IN ('orden_compra','factura_proveedor','devolucion_proveedor','credito_proveedor','debito_proveedor') OR (tercero_id IS NOT NULL AND rol_tercero='proveedor')),
 CHECK(clase NOT IN ('devolucion_cliente','devolucion_proveedor','credito_cliente','credito_proveedor','debito_cliente','debito_proveedor') OR documento_origen_id IS NOT NULL),
 CHECK(documento_origen_id IS DISTINCT FROM id), CHECK(moneda<>moneda_base OR tipo_cambio=1),
 CHECK((origen_sistema IS NULL)=(referencia_externa IS NULL)), UNIQUE(tenant_id,empresa_id,clase,origen_sistema,referencia_externa),
 FOREIGN KEY(tenant_id,tercero_id,rol_tercero) REFERENCES catalogo.roles_tercero(tenant_id,tercero_id,rol),
 FOREIGN KEY(idempotency_key) REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,condicion_id) REFERENCES administracion.condiciones_comerciales(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_origen_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id)
);
CREATE UNIQUE INDEX IF NOT EXISTS documentos_numero_propio_uidx ON administracion.documentos(tenant_id,empresa_id,clase,serie,numero)
 WHERE numero IS NOT NULL AND clase NOT IN ('factura_proveedor','credito_proveedor','debito_proveedor');
CREATE UNIQUE INDEX IF NOT EXISTS documentos_numero_proveedor_uidx ON administracion.documentos(tenant_id,empresa_id,clase,tercero_id,serie,numero)
 WHERE numero IS NOT NULL AND clase IN ('factura_proveedor','credito_proveedor','debito_proveedor');
CREATE INDEX IF NOT EXISTS documentos_fecha_idx ON administracion.documentos(tenant_id,empresa_id,fecha,clase);

CREATE TABLE IF NOT EXISTS administracion.detalles_documento (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 documento_id uuid NOT NULL, posicion integer NOT NULL CHECK(posicion>0), producto_id uuid, detalle_origen_id uuid,
 descripcion text NOT NULL, cantidad administracion.cantidad NOT NULL, precio_unitario administracion.importe NOT NULL,
 subtotal administracion.importe NOT NULL, descuento administracion.importe NOT NULL DEFAULT 0,
 recargo administracion.importe NOT NULL DEFAULT 0, tributos administracion.importe NOT NULL DEFAULT 0,
 total administracion.importe GENERATED ALWAYS AS (subtotal-descuento+recargo+tributos) STORED,
 CHECK(subtotal=cantidad*precio_unitario), CHECK(descuento<=subtotal), CHECK(detalle_origen_id IS DISTINCT FROM id),
 UNIQUE(tenant_id,empresa_id,documento_id,posicion),
 FOREIGN KEY(tenant_id,producto_id) REFERENCES catalogo.productos(tenant_id,id),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,documento_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,detalle_origen_id) REFERENCES administracion.detalles_documento(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.relaciones_documento (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 origen_id uuid NOT NULL, destino_id uuid NOT NULL, relacion text NOT NULL CHECK(relacion IN ('deriva','agrupa','sustituye')),
 CHECK(origen_id<>destino_id), UNIQUE(tenant_id,empresa_id,origen_id,destino_id,relacion),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,origen_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,destino_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.destinos_compra (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 codigo text NOT NULL, nombre text NOT NULL, sucursal_destino_id uuid,
 direccion_snapshot jsonb NOT NULL DEFAULT '{}', referencia_inventario text,
 CHECK(jsonb_typeof(direccion_snapshot)='object'), UNIQUE(tenant_id,empresa_id,codigo),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_destino_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id)
);

CREATE TABLE IF NOT EXISTS administracion.detalle_destinos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, sucursal_id uuid,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT now(), version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 detalle_id uuid NOT NULL, destino_id uuid NOT NULL, cantidad administracion.cantidad NOT NULL, UNIQUE(tenant_id,empresa_id,detalle_id,destino_id),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,empresa_id,detalle_id) REFERENCES administracion.detalles_documento(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,destino_id) REFERENCES administracion.destinos_compra(tenant_id,empresa_id,id)
);
CREATE INDEX IF NOT EXISTS detalles_documento_documento_id_idx ON administracion.detalles_documento(tenant_id,empresa_id,documento_id);
CREATE INDEX IF NOT EXISTS detalle_destinos_detalle_id_idx ON administracion.detalle_destinos(tenant_id,empresa_id,detalle_id);
CREATE INDEX IF NOT EXISTS documentos_tercero_id_idx ON administracion.documentos(tenant_id,empresa_id,tercero_id,fecha);
