# Órdenes ficticias de Tumandaito — DEV

Autorización del propietario, 18-11-2026: los ejemplos persistidos se cargan en Tumandaito. No se concede acceso a identidades QA a ese tenant. No hay migraciones ni nuevas tablas, permisos o funciones de negocio en esta entrega.

El migrador oficial incluye `business_order_samples.py`, despachado por la acción existente `seed_tumandaito_suppliers` y operaciones explícitas `inspect_orders` / `seed_orders`. Solo DEV, cuenta 277352717693, us-west-1. Se comprueban tenant/empresa activos y propietario activo por issuer + sub; las lecturas y escrituras de negocio ejecutan `SET LOCAL ROLE mastererp_app`, contexto transaccional y comandos canónicos `purchase_options`, `purchase_read` y `purchase_write`.

Se reutilizan exclusivamente DEMO-PROV-001/002/003. Se crean tres compras de origen `PRUEBA-SOL-UONIFY-001..003` y tres órdenes `PRUEBA-OC-UONIFY-001..003`, serie PRUEBA, fecha 2026-11-18, moneda base real y cambio 1. Son borradores ficticios sin emisión, aprobación, inventario, facturas, pagos ni obligaciones. Totales previstos: 300, 425 y 240. Descripciones identificadas como PRUEBA.

## Publicación y ejecución

1. Publicar únicamente helper, despacho, empaquetador, workflow y documentación revisados en dev. El workflow `Apply DEV database model` actualiza el migrador; su clasificador debe omitir el job apply porque no cambia schema/, seeds/ ni tests/. No ejecutar manualmente ese workflow con apply_model.
2. Esperar actualización exitosa del migrador del commit publicado. El workflow de muestras no actualiza por sí solo el paquete: no invocarlo antes.
3. Ejecutar `Tumandaito DEV order samples` en dev, primero `inspect_orders`, con el sub de la identidad propietaria existente. Nunca introducir contraseñas.
4. Ejecutar `seed_orders`, luego repetirlo y comprobar created=0, replayed=3 e IDs iguales. Finalmente inspeccionar y comprobar los tres registros.

Las claves estables de idempotencia vinculan actor, tenant, empresa, operación y contenido mediante el comando existente. Un bloqueo consultivo serializa el lote; los seis documentos se confirman juntos tras comprobar restricciones diferidas. Cualquier error revierte el lote; no se concilian discrepancias ni se sobrescriben registros existentes. La inspección usa READ ONLY y ROLLBACK. No contiene SQL de esquema ni aplica archivos del manifiesto.

## Recuperación y límites

Repetir el lote es seguro mientras actor, moneda base, proveedores y contenido no cambien; ante conflicto se detiene, sin cambiar permisos ni generar otra clave para evadirlo. La transacción de inspección o de pruebas no revierte una carga ya confirmada. No borrar por prefijo: si se solicita retirar ejemplos, inventariar los IDs devueltos, referencias de origen y dependencias, y revisar una limpieza acotada por separado. Revertir el código no elimina muestras persistidas.

La comprobación HTTP y de navegador utiliza fixtures QA separadas y limpiables. Su éxito demuestra el recorrido frontend/API/Lambda/RDS bajo permisos reales; no equivale a haber iniciado sesión como el propietario de Tumandaito ni a disponer de aprobación o recepción de compras.
