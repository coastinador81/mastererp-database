# Ventas desde pedidos — contrato y validación DEV

Estado al 7 noviembre 2026: 046 y 047 aplicadas/reaplicadas en RDS DEV; confirmación eCommerce conectada y validada por API Gateway. Región us-west-1, cuenta 277352717693. No se implementó frontend, CRUD propio de Ventas, facturación ni cobros.

## Modelo y propiedad

Finanzas → Administración → Gestión comercial → Ventas posee `administracion.documentos` clase venta y sus detalles; `administracion.ventas` continúa como vista histórica. Operaciones posee pedidos, eCommerce checkout y la identidad de canal, e Inventario sus reservas. Se reutilizan terceros, roles de cliente, productos y monedas existentes.

`administracion.ventas_origen` vincula un pedido con una sola venta mediante claves compuestas de tenant/empresa y unicidad en ambos sentidos. Guarda snapshot del cliente del pedido y estado ACTIVE/CANCELLED. El documento conserva origen_sistema=ecommerce y referencia_externa=pedido UUID. Otros orígenes no están habilitados; un origen futuro necesita adaptación autorizada, no un valor libre del navegador.

## Operación transaccional

`administracion.venta_desde_pedido(p_empresa uuid,p_pedido uuid,p_version bigint,p_idempotency_key varchar,p_fecha date DEFAULT NULL,p_tipo_cambio numeric DEFAULT NULL,p_cambio_fecha date DEFAULT NULL,p_cambio_fuente text DEFAULT NULL)`.

Autoriza actor/tenant/pertenencia/empresa/sucursal activos, Finanzas habilitado, administration.sales.write y lectura operativa habilitada. El origen se resuelve mediante eventos servidor. Bloquea empresa → clave → pedido, valida versión y perfil de cliente por empresa. Confirma PENDING→CONFIRMED mediante helper privado acotado, copia cabecera/líneas, representa la tarifa de entrega existente como línea sin producto ficticio, sella el documento, crea vínculo y audita. Todo confirma o revierte junto. Las restricciones de agregado son diferidas y deben forzarse antes de cerrar las pruebas, no entre cabecera y detalles.

No toma precios actuales ni inventa impuestos, descuentos o tipos de cambio. Misma moneda base: cambio 1; moneda distinta: cambio, fecha y fuente explícitos. Fecha omitida: fecha de la empresa según su zona horaria. La aplicación verifica la procedencia de esos datos; no usa una tasa ficticia para desbloquear la confirmación.

Misma clave y contenido devuelve el resultado original; actor/tenant/operación o contenido distintos provocan conflicto. Otra clave no genera segunda venta. 047 incluye reason/detail del contrato HTTP en la huella cuando existen y los conserva en el evento. Las llamadas antiguas sin esos campos mantienen su huella compatible.

## Autorización aprobada

El propietario aprobó Administradores de Finanzas. No existía rol de Finanzas en DEV: 047 creó `tenant.finance_admin` con administration.sales.write, administration.read y operations.orders.read. No recibe operations.orders.write. El helper de confirmación no es ejecutable directamente por mastererp_app; solo el comando autorizado puede usarlo. Los overrides de denegación prevalecen. No hay grupos Cognito ni plataforma.admin como acceso universal.

No se alteraron pertenencias de usuarios reales. Asignar este rol a personas reales requiere conservar sus responsabilidades actuales; no reemplazar silenciosamente el rol de propietario. Las pruebas HTTP reutilizaron actores Cognito sintéticos existentes, con el rol aprobado solo en su tenant de fixture.

## Contrato HTTP desplegado

Lambda mastererp-dev-orders, stack propietario mastererp-dev-operations, API administrativa qx8nmypdhi. Rutas, JWT y CORS existentes conservados.

```http
POST /v1/companies/{company_id}/orders/{order_id}/transitions
Authorization: Bearer <access-token>
X-Tenant-Id: <tenant-uuid>
Idempotency-Key: <clave-estable>
Content-Type: application/json

{"version":1,"status":"CONFIRMED","reason":"ORDER_APPROVED","detail":"Detalle opcional"}
```

El adapter identifica eCommerce en PostgreSQL y llama al comando de Ventas usando mastererp_app y SSL verify-full. Otros orígenes/transiciones conservan el comando operativo anterior. Campos opcionales: sale_date, exchange_rate, exchange_date, exchange_source. Sin Idempotency-Key se deriva `sv:<pedido_id>:<version>`, conservando el contrato anterior. La respuesta mantiene el pedido y añade `sale: {id,pedido_id,estado,version}`. La versión del vínculo comercial y la del pedido son distintas.

Sin token: 401; identidad ajena, permiso revocado, módulo deshabilitado o pertenencia inactiva: 403; conflicto de contenido/versión: 409. Entradas inválidas: 400. Errores SQL sanitizados, sin tokens ni connection strings.

## Pagos y cancelación básica

047 acepta cash/PENDING_COLLECTION o los métodos mobile/transfer y alias legacy cuando el estado almacenado es VALIDATED. Rechaza pagos pendientes de verificación, métodos desconocidos y valores ausentes. La validación real de un pago bancario NO está implementada por esta entrega; las pruebas SQL configuran ese estado exclusivamente en fixtures.

`administracion.venta_anular(p_empresa,p_pedido,p_version,p_motivo)` conserva documentos e importes, cambia el vínculo a CANCELLED y audita. Exige pedido ya CANCELLED y reserva identificada existente/RELEASED. Bloquea documentos posteriores, relaciones y cartera; no libera inventario, cancela el pedido ni genera reversos. Los consumidores de la vista histórica deben unir el vínculo para distinguir anuladas. Su exposición HTTP/UI queda pendiente.

## Evidencia real

| Comprobación | Resultado |
| --- | --- |
| 046 preflight/aplicación | 42315864514 / 42316033780; aplicación y reaplicación, solo 046 |
| 047 preflight/aplicación | 42317415678 / 42317791665; aplicación y reaplicación, solo 047 |
| Suites SQL | SET ROLE mastererp_app, rol efectivo comprobado, constraints inmediatos al final y rollback; éxito |
| Pagos actuales y fail-closed | Preflight 42319423025 aprobado: mobile/transfer validados aceptados, pendientes/desconocidos rechazados |
| Sesiones independientes con rollback | Dos escenarios con espera 0.725/0.727 s; ambas ventas revertidas y fixtures base limpiadas |
| API de Ventas por confirmación | 14 casos aprobados; 3 pedidos CONFIRMED versión 2, 3 ventas selladas de importe 10 |
| Concurrencia HTTP con commit | Misma clave: ambos 200 y mismo ID; claves distintas: 200/409 y una sola venta |
| Auditoría persistida | 3 eventos de creación de venta y 3 de transición, actor/tenant/correlación presentes |
| Regresiones SQL | Clientes, código común, Storefront y Pedidos aprobados, sin reaplicar esquemas |
| Regresiones HTTP | 33 comprobaciones de Clientes/Proveedores aprobadas; fixtures limpiadas |
| Uonify | Sesión Cognito existente y consulta de espacios: HTTP 200; no se afirma prueba completa de chat/Gemini |
| CI backend | 18 pruebas unitarias remotas, importación del módulo DB, ZIP ARM64 y dependencias comprobados |

Evidencia JSON sanitizada en [sales-046-evidence](sales-046-evidence/). No se ejecutó PostgreSQL ni Docker local. Los validadores estructurales/Phase 5 y git diff --check también pasaron, sin presentarlos como pruebas funcionales.

046 SHA-256: 4bd9dd64cfe5332cadef27d16f770563d2742e0dbfcb0b4a2586faaad6dca8dd. 047 SHA-256: 8e780a06ef989a094d30d0fcf30aacdd5c0624e49f8bfbb5823f028727857a70. El paquete anterior coincidía con HEAD 80989c6 para handler/SQL. No existe ledger de migraciones detectado en RDS: se verificaron catálogo, funciones, hashes y resultados de workflows; formalizar ese historial queda pendiente.

## Despliegue y recuperación

Workflows oficiales: deploy-migrator actualiza el paquete antes de aplicar; push hace preflight con rollback; aplicación explícita con batch=sales, apply_model=true. El selector actual aplica solo 047 y exige 046 existente; no reaplica Storefront ni 045. Mantener código/SQL del mismo commit y revisar el lote antes de futuras publicaciones.

Respaldos disponibles antes de aplicar: mastererp-dev-before-sales-046-20261107 y mastererp-dev-before-sales-contract-047-20261107. No editar migraciones aplicadas ni borrar datos para recuperar; correcciones posteriores mediante nueva migración y evaluación explícita de restauración.

Backend desplegado desde Platform e2013ad, workflow de artefacto 42318856201. ZIP SHA-256 61f69a11947e9fe16f0070f846f366c3d2d17a8801c2aa09d289e68c447aadc8. CloudFormation actualizó solo OrdersFunction.Code y reevaluó dinámicamente OrdersIntegration por el mismo ARN: sin reemplazos, IDs físicos/configuración/URI/rutas/JWT/CORS iguales antes/después. No se creó API, Lambda, migrador ni entorno adicional.

## Problemas encontrados y corregidos

Previo: la fixture Storefront enviaba cash como texto tras el cambio de contrato a JSON; se corrigió la prueba, no 039/040/043. Propio de esta entrega: fixtures usaron estados no admitidos y una prueba adicional dejó constraints inmediatos entre cabecera/detalles; los preflight fallidos confirmaron cero pasadas. Se corrigieron las fixtures sin ampliar permisos.

El primer artefacto x86 se bloqueó antes de desplegar al comprobar ARM64. La reevaluación dinámica de la integración se revisó expresamente. Un artefacto ARM64 omitía typing_extensions.py y produjo HTTP 500: se restauró el ZIP anterior verificado mediante change set, se corrigió el empaquetador y se añadió comprobación de importación/contenido. El paquete final pasó las pruebas HTTP. No se oculta ese fallo ni se atribuye a la infraestructura anterior.

## Fixtures y pendientes

Las ventas selladas de prueba se conservan como historia en un tenant DEV identificado y suspendido, con pertenencia inactiva; no se desactivaron triggers para borrarlas. No es un ambiente QA nuevo. El intento inicial, sin ventas, también quedó suspendido. Las fixtures de concurrencia con rollback y de Clientes/Proveedores sí se limpiaron.

Pendientes: asignaciones de personas reales al rol aprobado sin perder propiedad; frontend propio de Ventas; fuentes futuras; ingreso/verificación del cambio para monedas distintas en los consumidores; verificación real de pagos; cancelación coordinada y ajustes posteriores; ledger formal de migraciones. No se implementan Contabilidad, BI, cobros ni operaciones financieras adicionales.
