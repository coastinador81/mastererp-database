# Compras basicas DEV

## Alcance

Solicitudes, ordenes desde una solicitud y facturas desde una orden. Una solicitud -> una orden -> una factura. Listado paginado, detalle, creacion y edicion de borradores. No incluye aprobacion, emision, impuestos automaticos, cuentas por pagar, contabilidad ni movimientos de inventario. Esos pasos siguen pendientes del Product Owner.

Reutiliza administracion.documentos y detalles_documento, terceros, proveedores canonicos, perfiles por empresa, monedas, permisos, auditoria e idempotencia. Las lineas capturan descripcion, cantidad y precio; seleccion de productos de catalogo pendiente. No crea otra Lambda ni maestros.

## Contrato

API administrativa qx8nmypdhi, propietario mastererp-dev-onboarding. Lambda mastererp-dev-adm-compras dentro del stack Administracion bajo mastererp-dev-finance. JWT y scope mastererp-dev/identity.spaces.read, identidad issuer + sub, cabecera X-MasterERP-Tenant-Id, company_id, rol mastererp_app, permisos administration.purchases.read/write y modulo erp.finance activo. Sin DML directo.

GET /v1/administration/compras/opciones?company_id=<uuid>&limit=100&after=<uuid>: proveedores activos paginados, monedas y moneda base de la empresa.

Cada coleccion solicitudes, ordenes, facturas tiene GET de listado (company_id, limit, after), GET /<uuid>, POST con Idempotency-Key y PATCH /<uuid> con version. Prefijo: /v1/administration/compras/.

Cuerpo POST: {"company_id":"<uuid>","documento":{"proveedor_id":"<uuid>","origen_id":"","fecha":"2026-11-05","numero":"BORRADOR-1","serie":"","moneda":"VES","tipo_cambio":"1","cambio_fecha":"2026-11-05","cambio_fuente":"misma moneda","lineas":[{"descripcion":"Servicio de ejemplo","cantidad":"2","precio_unitario":"12.35"}]}}. PATCH agrega version en la raiz. Orden/factura requieren origen_id de la misma empresa, proveedor y moneda. Se copian los detalles de origen para facilitar su captura.

Cantidades/importes viajan como cadenas decimales. PostgreSQL calcula en NUMERIC. No hay redondeo silencioso: el total de cada linea debe respetar los decimales de la moneda o se rechaza con 400. Conversion a moneda base exige tipo, fecha y fuente; misma moneda exige 1. No se inventan reglas fiscales.

Idempotencia por actor, tenant, empresa y operacion; contenido diferente: 409. Version obsoleta, origen ya utilizado o referencia duplicada: 409. Un documento con derivados no se edita; no existe borrado por API. La asociacion por empresa conserva el contrato actual de contencion por tenant, sin inventar ACL por empresa.

## Frontend y propiedad

https://finanzas-dev.uonify.com/?vista=solicitudes-compra, ?vista=ordenes-compra, ?vista=facturas-proveedores. Creacion/detalle/edicion conservan recarga y navegacion. App-dev Uonify no cambia.

Cada carpeta funcional numerada de Compras declara sus rutas y permisos exclusivos en su resources.yml raiz. Lambda, rol, integracion y opciones compartidas pertenecen a Gestion de compras. Composicion explicita en el stack existente; sin SAM/OpenAPI ni reimportacion.

## Publicacion, validacion y recuperacion

Respaldo DEV disponible -> workflow Database empaqueta el commit y actualiza migrador -> preflight 037 y pruebas con ROLLBACK -> aplica/reaplica solo 037 -> pruebas del modelo. La base confirmada 001-036 no se reaplica. SET LOCAL ROLE mastererp_app y current_user se comprueban realmente; ROLLBACK posterior no revierte una migracion confirmada. Un fallo SQL hace fallar Lambda/workflow.

Platform: python scripts/package_parties.py --dependencies <dependencias existentes> --output <artefactos> --capabilities compras. Infrastructure: python scripts/deploy_purchases.py --phase prepare-finance --artifacts <artefactos> --output <plan>; revisar change sets padre e hijo; ejecutar con --phase execute-finance --output <plan>. Frontend usa su workflow DEV existente.

Comprobar persistencia HTTP, secuencia, idempotencia concurrente, versiones, aislamiento y permisos. Fixtures identificadas separadas de Tumandaito, limpieza acotada. Build y health no acreditan funcionalidad. Evidencia real se registra al finalizar; no presentar pruebas locales como AWS.

Recuperacion: plantilla/paquete anterior mediante change set revisado; conservar datos y migracion aditiva durante diagnostico. Snapshot solo se restaura por decision explicita en instancia separada; no reemplazar RDS automaticamente.
