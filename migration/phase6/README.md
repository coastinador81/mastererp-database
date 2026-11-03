# Transformación offline Tu Mandadito → MasterERP

Entrada: exportación JSONL inmutable de DynamoDB, en formato nativo o DynamoDB
JSON (`{"Item": ...}`). El proceso no consulta AWS ni escribe PostgreSQL.

`config.example.json` obliga a mapear tenant, empresa, actor y cada Nodo a una
sucursal UUID existente. Los demás IDs se generan con UUIDv5 estable. Cada
ejecución produce JSONL ordenado, errores y un manifiesto con conteos y SHA-256.

```text
python migration/phase6/transform_export.py \
  --source /ruta/export.jsonl --config /ruta/config.json --output /tmp/bundle
```

Repetir con la misma entrada/configuración debe producir hashes idénticos. Un
error devuelve código 2 y bloquea cualquier carga. Este bundle es candidato de
revisión; todavía no existe un loader autorizado ni cambia la fuente de verdad.

Después de una carga autorizada, exportar una instantánea canónica con el mismo
formato y reconciliarla:

```text
python migration/phase6/reconcile_bundle.py \
  --source-bundle /tmp/bundle --target-snapshot /tmp/target \
  --report /tmp/reconciliation.json
```

El comando devuelve código 3 ante faltantes, inesperados o diferencias. Una
reconciliación correcta sigue sin autorizar el cutover por sí sola.

## Loader de la primera oleada

`catalog_loader.py` valida hashes, referencias y unicidad. Confirma Categorías
primero y procesa Productos en lotes configurables (200 por defecto). Cada lote
es transaccional, serializado, reiniciable e idempotente. Usa exclusivamente
`catalogo.categoria_crear` y `catalogo.producto_crear` bajo `mastererp_app`, con
operación, actor, tenant, correlación, advisory lock e idempotencia estable. No
hace DML directo ni abre conexiones por sí mismo.

Sin `--emit-sql` solo muestra el plan. Con esa opción escribe un artefacto SQL
para revisión; tampoco lo ejecuta. La ejecución requiere una aprobación separada:

```text
python migration/phase6/catalog_loader.py --bundle /tmp/bundle \
  --config /ruta/config.json --expected-source-sha256 <sha256> \
  --batch-size 200 --emit-sql /tmp/catalog-loader.sql
```

`scripts/validate_phase6_catalog_loader.py` aplica el artefacto dos veces en
PostgreSQL local desechable y comprueba que no duplique datos ni auditoría.

## Loader de la segunda oleada

`operations_inventory_loader.py` carga Nodos e Inventario en lotes reiniciables.
Nodos exige el mapa a sucursales existentes, compara antes de configurar y usa
solo transiciones permitidas. Inventario resuelve Productos mediante la función
autorizada `catalogo.producto_id_por_referencia_externa` y llama únicamente a
`inventario_establecer`.

La prevalidación bloquea existencias negativas, ventas deshabilitadas, nodos sin
mapa y cualquier `reserved != 0`. Las reservas activas se migrarán junto con
Pedidos; ignorarlas produciría disponibilidad falsa. Validación local:

```text
PYTHONPATH=. python scripts/validate_phase6_nodes_inventory_loader.py
```

## Loader de Repartidores

`drivers_loader.py` conserva el módulo Transporte separado, reconstruye vínculos
desde `NODE_DRIVER` y opera solo con las funciones de Repartidores. Bloquea
perfiles `ON_ROUTE` o con `routeId`: esos estados se cargan junto con Rutas para
no crear asignaciones incoherentes. También trabaja por lotes reiniciables.

## Loader de Clientes

`customers_loader.py` migra cada `CUSTOMER` al maestro canónico de Terceros con
rol `cliente` y perfil de empresa. Usa `administracion.party_write`, conserva
`customerId` como código/referencia estable y verifica el resultado mediante
`administracion.cliente_id_por_referencia_externa`. Los clientes inactivos se
bloquean hasta definir explícitamente su ciclo de vida en el modelo destino.

## Preflight de Pedidos y reservas

`orders_preflight.py` separa pedidos activos con reserva de pedidos ya
preparados/históricos. Antes de generar SQL exige que la suma de cantidades de
`PENDING`, `CONFIRMED` y `PREPARING` coincida exactamente con `reserved` para
cada Producto/Nodo. También bloquea líneas huérfanas, estados desconocidos,
nodos o clientes ausentes y banderas de inventario incoherentes.

`active_orders_loader.py` compone Nodos/Inventario y luego crea, en lotes,
reservas y Pedidos activos mediante las funciones canónicas. Reproduce
`CONFIRMED` y `PREPARING`, incluido el avance de líneas ya preparadas. Los
pedidos `READY`, en ruta, entregados o cancelados se difieren deliberadamente a
la oleada histórica porque su stock ya fue consumido o liberado en origen.

`historical_orders_loader.py` reconstruye temporalmente el stock anterior de
pedidos ya preparados, reproduce reserva, creación y Preparación, y vuelve a
consumirlo mediante las funciones de dominio. Los cancelados reservan y liberan
sin cambiar stock. La reejecución consulta el estado actual antes de avanzar.
