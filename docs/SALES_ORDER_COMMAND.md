# Ventas desde pedidos — candidato 046

Estado: implementación SQL local pendiente de revisión, pruebas PostgreSQL en AWS DEV e integración backend. No aplicada a RDS. No acredita operaciones de Ventas por API.

## Decisiones y propiedad

Decisión del propietario: generar la venta al confirmar el pedido; un pedido genera una sola venta. eCommerce es el único origen habilitado inicialmente. Cancelación básica, sin borrar historial ni automatizar reversos financieros.

Finanzas → Administración → Gestión comercial → Ventas (`2.2.1.1.3-ventas`) posee el registro comercial. Operaciones conserva el pedido y su estado. eCommerce conserva checkout e identidad del cliente; Inventario conserva reservas. No se duplican terceros, productos, monedas ni tablas de venta.

`administracion.documentos` con clase `venta` y `detalles_documento` conservan los importes. `administracion.ventas_origen` relaciona pedido y documento mediante claves foráneas compuestas de tenant/empresa, con unicidad en ambos sentidos y snapshot del cliente tomado del pedido. `origen_sistema` y `referencia_externa` del documento conservan la procedencia. El campo de origen admite futuras extensiones; el comando solo habilita eCommerce, comprobado por el evento servidor STOREFRONT_CHECKOUT. Otros canales deberán aportar un adaptador autorizado, no un origen elegido libremente por el navegador. La relación actual admite orígenes que generen pedidos de Operaciones; documentos externos sin pedido requerirán un diseño adicional.

## Comando de registro

Firma:

```sql
administracion.venta_desde_pedido(
 p_empresa uuid, p_pedido uuid, p_version bigint,
 p_idempotency_key varchar, p_fecha date,
 p_tipo_cambio numeric DEFAULT NULL,
 p_cambio_fecha date DEFAULT NULL, p_cambio_fuente text DEFAULT NULL
) RETURNS jsonb
```

Contexto establecido por backend después de autenticar y autorizar: `app.current_user_id`, `app.current_tenant_id`, `app.current_operation=administracion.documento.venta.crear`, `app.correlation_id`. Se usa mastererp_app, nunca credenciales administrativas para operaciones de aplicación.

Exige Finanzas habilitado y permiso nuevo `administration.sales.write`, además de Operaciones habilitado y permisos `operations.orders.read/write`. El permiso nuevo se declara sin asignarlo automáticamente a roles; su asignación explícita queda pendiente. Se conservan overrides y validación de usuario, tenant, pertenencia, empresa y sucursal activos. El contrato común comprueba contención por tenant/empresa; no se inventa una ACL por empresa que el modelo compartido no ofrece.

Secuencia transaccional:

1. Autorizar y validar parámetros; bloquear empresa → clave idempotente → pedido.
2. Resolver un reintento por actor, tenant, operación y huella de empresa/pedido/versión/fecha/cambio. El mismo contenido devuelve la respuesta original; otra huella o actor produce conflicto. No se reciclan claves expiradas.
3. Verificar versión, origen y perfil de cliente en la empresa. Otro comando con una clave distinta no puede generar una segunda venta.
4. Si está PENDING, utilizar la transición vigente a CONFIRMED y restaurar el contexto de operación. Si ya está CONFIRMED y aún no tiene venta, registrar explícitamente, sin backfill. Otros estados se rechazan.
5. Copiar precios, descripciones, cantidades y total del pedido. La tarifa de entrega existente se representa como línea de servicio separada sin producto ficticio. No recalcular precios actuales ni inventar impuestos/descuentos.
6. Moneda igual a la base: cambio 1. Distinta: exigir cambio positivo, fecha y fuente explícitos; no inventar tasa. El backend deberá validar su procedencia y la fecha comercial en la zona de la empresa.
7. Sellar el documento después de insertar sus detalles, crear vínculo, guardar respuesta idempotente y auditar identificadores/resultado/correlación. Las restricciones diferidas vigentes comprueban sumas, precisión y vínculo de idempotencia al confirmar la transacción.

Respuesta: `{ "id": "<venta-uuid>", "pedido_id": "<pedido-uuid>", "estado": "ACTIVE", "version": 1 }`. `version` es la del vínculo comercial; el documento sellado tiene su propia versión. No facturar, cobrar, contabilizar ni reservar inventario nuevamente. Un error o una restricción diferida fallida revierte también la confirmación del pedido dentro de esta transacción.

Errores previstos: 42501 autorización; P0002 no encontrado; 40001 versión obsoleta; 23505 conflicto de idempotencia o pedido ya registrado; 22023 parámetros/origen no soportado; 23514 incompatibilidad comercial, precisión o efectos posteriores. El backend mapeará estos códigos a HTTP sanitizado; esa adaptación aún no está implementada.

## Anulación básica

`administracion.venta_anular(p_empresa uuid,p_pedido uuid,p_version bigint,p_motivo text)` requiere operación `administracion.venta.anular` y permisos de escritura de Ventas/Operaciones.

Solo anula una venta cuyo pedido **ya esté CANCELLED en Operaciones** y cuya reserva identificada exista y esté RELEASED en Inventario. No cancela el pedido ni libera stock por sí misma. Bloquea documentos posteriores, relaciones documentales y partidas de cartera; tampoco puede anular reservas activas o consumidas. Los documentos y sus importes permanecen sellados, el vínculo cambia a CANCELLED, incrementa versión y registra actor/fecha/motivo y auditoría. Restricciones diferidas impiden añadir documentos financieros posteriormente a una venta anulada.

La vista histórica `administracion.ventas` no cambia: los consumidores deberán unir `ventas_origen` y consultar su estado para distinguir ventas activas/anuladas, sin contar una anulada como vigente. No afirmar que hoy existe un dashboard financiero que aplique esta distinción.

Pendiente: diseñar la orquestación de cancelación del pedido y liberación de inventario antes de exponer esta operación en UI/API. Si ya hay factura, cobro u otros efectos, se necesita el proceso de devolución/ajuste que se definirá posteriormente; no se elimina ni compensa automáticamente nada.

## Integración y problemas previos

La función `operaciones.pedido_transicionar` y sus consumidores actuales permanecen intactos. Por tanto, confirmar por el endpoint antiguo NO invoca el nuevo comando: el siguiente lote debe conectar la confirmación de eCommerce con este comando y su autorización, sin introducir dos escrituras independientes. Otros pedidos/orígenes siguen su flujo vigente.

Problema previo confirmado en el código: checkout 040 guarda métodos `mobile`/`transfer`, mientras que la transición 016 espera `mobile_payment`/`bank_transfer` con estado VALIDATED. El flujo de validación de pagos no está resuelto en este lote. El comando conserva la validación existente y no fuerza esos pedidos a confirmados ni transforma un pago pendiente en validado. Efectivo con PENDING_COLLECTION conserva el camino permitido.

## Archivos y publicación futura

- `schema/046_sales_order_command.sql`: nueva relación, permiso, comandos y restricciones diferidas.
- `tests/sales_order_command_test.sql`: fixtures identificadas QA-046 en transacción, rol efectivo mastererp_app, rollback final.
- Manifiesto del migrador: incluye los dos archivos para empaquetado. El lote activo `applied_schema` sigue siendo 045: agregar al ZIP NO activa ni valida 046.

No publicar todavía: push con schema/ o tests/ dispara Apply DEV database model. Antes de publicar, conciliar dev remoto y registro real de migraciones, confirmar que 046 sigue libre, revisar respaldo vigente y preparar un selector explícito de preflight/aplicación SOLO 046 mediante el migrador oficial. No volver a ejecutar indiscriminadamente 039/040/045. El preflight deberá aplicar 046 y ejecutar la fixture dentro de una misma transacción que termine en rollback; después, aplicar/reaplicar 046 en transacciones separadas y repetir pruebas rollback-only. Los fallos deben propagarse al workflow.

## Validación y recuperación

Preparado, no ejecutado en PostgreSQL: confirmación+venta, respuesta idempotente, contenido distinto, venta duplicada con otra clave, versión obsoleta, revocación, contexto ausente, RLS, escritura directa denegada, fallo monetario con rollback completo, cancelación bloqueada por reserva activa y cancelación conservando historial. Las pruebas verifican current_user, usan SET ROLE mastererp_app y fuerzan SET CONSTRAINTS ALL IMMEDIATE antes del ROLLBACK. La preparación de fixtures es privilegiada, las comprobaciones de aplicación no.

Pendiente en AWS DEV: ejecución real, moneda distinta, origen no permitido, empresa/tenant ajenos e inactivos, efectos financieros posteriores, regresiones de checkout/Clientes/Compras, y concurrencia con dos conexiones independientes. Para concurrencia se necesita fixture QA-046 previamente confirmada y aislada (no visible entre sesiones si toda su preparación queda sin commit): A ejecuta comando y mantiene la transacción; B ejecuta misma clave/contenido y espera; al confirmar A, B devuelve el mismo ID. Con distinta clave para el mismo pedido, solo una venta y conflicto en B; con rollback de A, B puede completar. Repetir con confirmación operativa simultánea para verificar versiones/bloqueos. Limpiar únicamente fixtures creadas para esta validación mediante un procedimiento revisado; no improvisar eliminaciones en datos existentes.

Solo frontend/build se valida localmente. No instalar PostgreSQL ni Docker. Validadores estructurales y revisión estática no certifican estas pruebas SQL. Recuperación previa a aplicar: descartar candidato sin efecto remoto. Tras aplicar DDL, detener consumo nuevo y diagnosticar; no borrar ventas, editar migraciones aplicadas ni restaurar una copia completa sobre datos posteriores. Si falla antes del COMMIT, rollback revierte el lote. Cualquier corrección posterior será una migración nueva y la restauración de respaldo requerirá evaluar los datos creados después.
