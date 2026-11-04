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

Respaldo DEV disponible -> workflow Database empaqueta el commit y actualiza migrador -> preflight del candidato y pruebas con ROLLBACK -> aplica/reaplica solo 038 -> pruebas del modelo. La base confirmada 001-037 no se reaplica. La migración 037 introdujo los comandos; 038 concilia la operación con el contrato de idempotencia del documento, sin modificar 037. SET LOCAL ROLE mastererp_app y current_user se comprueban realmente; ROLLBACK posterior no revierte una migracion confirmada. Un fallo SQL hace fallar Lambda/workflow.

Platform: python scripts/package_parties.py --dependencies <dependencias existentes> --output <artefactos> --capabilities compras. Infrastructure: python scripts/deploy_purchases.py --phase prepare-finance --artifacts <artefactos> --output <plan>; revisar change sets padre e hijo; ejecutar con --phase execute-finance --output <plan>. Frontend usa su workflow DEV existente.

Comprobar persistencia HTTP, secuencia, idempotencia concurrente, versiones, aislamiento y permisos. Fixtures identificadas separadas de Tumandaito, limpieza acotada. Build y health no acreditan funcionalidad. Evidencia real se registra al finalizar; no presentar pruebas locales como AWS.

Recuperacion: plantilla/paquete anterior mediante change set revisado; conservar datos y migracion aditiva durante diagnostico. Snapshot solo se restaura por decision explicita en instancia separada; no reemplazar RDS automaticamente.

## Estado tecnico y limites

Codigo visual propietario: frontend/modules/2.2-finance/2.2.1-administration/2.2.1.2-gestion-compras/screens/purchases/. Correspondencia documental en las cuatro capas; resources.yml de pantalla vacio y excluido del despliegue. La Lambda existente tiene 256 MB, timeout 15 segundos y runtime Python 3.12. ARN: arn:aws:lambda:us-west-1:277352717693:function:mastererp-dev-adm-compras.

La operacion canonica de creacion es administracion.documento.<clase>.crear; actualizacion usa .actualizar. La 038 conserva el contrato validado por las restricciones diferidas. Las pruebas nuevas fuerzan SET CONSTRAINTS ALL IMMEDIATE antes del ROLLBACK: evitar confundir una escritura dentro de una transaccion con un COMMIT valido. La primera version omitio esa comprobacion; el fallo propio se detecto por HTTP y quedo corregido mediante 038. Las etiquetas de selectores y el retorno de enlaces de compras por PKCE tambien se corrigieron durante la validacion, sin ampliar permisos.

La validacion usa roles QA con lectura de terceros y permisos de compras. El contrato actual de descubrimiento de empresas aun requiere administration.parties.read; no se ha definido ni asignado un rol aprobador nuevo. Administradores de Finanzas, aprobaciones, emision y obligacion automatica siguen pendientes del Product Owner. No afirmar que existe contabilidad, factura fiscal, inventario o pagos por guardar un borrador.

No se ejecuto PostgreSQL local ni se instalaron herramientas: la validacion SQL real corresponde a RDS DEV, mediante el migrador oficial, preflight con rollback y controles efectivos de mastererp_app. El snapshot mastererp-dev-before-purchase-drafts-20261105 quedo available antes de publicar SQL. No se ensayo su restauracion.

Referencias: [migracion 037](https://github.com/eticayservicios/mastererp-database/actions/runs/41932621408), [migracion 038 y pruebas diferidas](https://github.com/eticayservicios/mastererp-database/actions/runs/41935397004), [frontend y retorno PKCE](https://github.com/eticayservicios/mastererp-platform/actions/runs/41936494724). Las pruebas SQL no sustituyen el recorrido HTTP/visual.

## Resultado verificado en DEV (5 de noviembre de 2026)

20 comprobaciones HTTP/navegador aprobadas: login Cognito real; crear/editar solicitud, orden y factura; lectura independiente persistida; paginacion; precision; creacion idempotente concurrente (201/200) y conflicto por contenido (409); actualizacion concurrente (200/409); origen obligatorio y unico; precision invalida (400); sin token (401); aislamiento (403/404); overrides, modulo y contexto inactivos (403); recarga de enlace directo; cambio de empresa sin datos anteriores; movil; ocho health y proveedores conservados; ocho eventos reales de auditoria; logout. Limpieza QA confirmada. No se mezclaron fixtures con Tumandaito.

Las rutas anteriores conservaron identificadores y propiedades: 53 -> 66 rutas, 26 integraciones, ocho Lambdas con los mismos ARN/roles y las siete ajenas a Compras con el mismo codigo. CORS, autorizadores y entrada de app-dev.uonify.com sin cambios. Unicamente Compras actualizo su paquete y configuracion; se reutilizan RDS, secreto de aplicacion y red existentes.

Validadores de estructura y fase 5 en los tres repositorios, git diff --check, seis pruebas de navegacion, cinco pruebas del handler, siete pruebas de composicion/proyeccion y build aprobados. Las 30 rutas funcionales de Finanzas coinciden en las cuatro capas. No se ejecutaron pruebas de carga; la concurrencia comprobada usa dos solicitudes simultaneas.

[Evidencia HTTP y visual en Platform](https://github.com/eticayservicios/mastererp-platform/tree/dev/docs/purchase-evidence). El estado es borradores basicos funcionales; no una implementacion completa de Compras ni de Administracion.

Para preparar dependencias del paquete desde un checkout nuevo de Platform se puede usar la lista existente y fijada: python -m pip install --only-binary=:all: --no-compile --target ../mastererp-infrastructure/build/purchases/dependencies -r backend/modules/0-uonify/lambdas/uonify-google-connection-handler/requirements-package.txt. Ese directorio se pasa a --dependencies; el paquete solo incluye dependencias puras, handler, adaptadores y CA, sin .env ni credenciales. Este comando queda documentado; durante esta entrega se reutilizaron dependencias existentes.
