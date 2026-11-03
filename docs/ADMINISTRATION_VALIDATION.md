# Validación local de Administración

Estado actual: [publicación y validación DEV](ADMINISTRATION_DEV.md). Las secciones locales documentan la preparación anterior a la autorización.

## Alcance y estado

Candidato de datos exclusivamente en mastererp-database/dev. No se ejecutó SQL remoto, no se modificó AWS, no hubo commit ni push. No se modificaron SQL 001–008, seeds, workflows ni el migrador publicado. Los cambios previos del equipo permanecen sin incluirlos en esta entrega. El intento de actualizar referencias Git falló por resolución DNS de github.com: no se certifica que el checkout local sea el último remoto.

No se utiliza documentación Algedis ni se declara cumplimiento de ella. No se implementan operaciones de Finanzas ni se habilita CRUD directo a mastererp_app.

## Migraciones candidatas

| Orden | Archivo | Responsabilidad |
| --- | --- | --- |
| 009 | schema/009_shared_master_references.sql | Referencias canónicas mínimas de Catálogo y ámbito sucursal |
| 010 | schema/010_administration_documents.sql | Condiciones, perfiles, documentos/detalles, orígenes y destinos |
| 011 | schema/011_administration_treasury.sql | Caja/bancos, dinero, transferencias, extractos y conciliación |
| 012 | schema/012_administration_portfolio_expenses.sql | Cartera, gastos, fondos menores, reservas y soportes |
| 013 | schema/013_administration_integrity_security.sql | Integridad diferida, auditoría, privilegios, RLS y vistas |

Estas migraciones se prueban por un runner explícito; aún no están en el manifiesto de la Lambda. NO publicar: los paths schema/** activan la aplicación automática del repositorio. Una entrega remota futura debe conciliar manifiesto, orden, respaldo y autorización antes del push.

## Tablas nuevas

Maestros canónicos (no existían tablas equivalentes en 001–008):

- `catalogo.monedas`
- `catalogo.terceros`
- `catalogo.roles_tercero`
- `catalogo.productos`

Administración:

- `administracion.condiciones_comerciales`
- `administracion.descuentos_pronto_pago`
- `administracion.perfiles_tercero`
- `administracion.documentos`
- `administracion.detalles_documento`
- `administracion.relaciones_documento`
- `administracion.destinos_compra`
- `administracion.detalle_destinos`
- `administracion.cuentas_tesoreria`
- `administracion.operaciones_tesoreria`
- `administracion.movimientos_tesoreria`
- `administracion.transferencias`
- `administracion.extractos_bancarios`
- `administracion.lineas_extracto`
- `administracion.conciliaciones`
- `administracion.partidas_conciliacion`
- `administracion.partidas_cartera`
- `administracion.vencimientos`
- `administracion.aplicaciones_cartera`
- `administracion.categorias_gasto`
- `administracion.gastos`
- `administracion.fondos_caja_chica`
- `administracion.reposiciones`
- `administracion.anticipos`
- `administracion.rendiciones`
- `administracion.rendicion_gastos`
- `administracion.politicas_reserva`
- `administracion.reservas_fondos`
- `administracion.soportes`

Se reutilizan tenants, empresas/sucursales, usuarios/pertenencias, permisos/overrides y capacidad erp.finance, auditoria.events e idempotency_keys. Clientes y proveedores comparten tercero con roles; cartera referencia facturas, y gastos clasifica documentos. Contabilidad e Inventario conservan sus responsabilidades; no se crean asientos ni movimientos de existencias.

## Reproducir y evidencia

Requiere Docker existente y la imagen ya disponible public.ecr.aws/docker/library/postgres:17.9-alpine; el script no instala herramientas ni descarga imágenes. Desde la raíz:

```powershell
py scripts/validate_administration_disposable.py --output docs/administration-local-validation.json
py scripts/validate_structure.py
git diff --check
```

El contenedor propio usa --network none, sin puertos publicados ni volúmenes de datos del host. Se elimina al finalizar. Se aplican 001–013 y seeds dos veces, seis archivos de pruebas anteriores y tres de Administración. Las fixtures identificables se crean solo dentro del contenedor; las tres suites de Administración terminan con ROLLBACK. Las dos carreras concurrentes confirman transacciones de prueba dentro de ese contenedor, que finalmente se destruye.

Las pruebas SET ROLE mastererp_app verifican current_user y lectura por tenant, denegación de escrituras, pertenencia/contexto ausentes, override, módulo y actores/organizaciones inactivos. Las pruebas estructurales usan el rol de migración para insertar fixtures y comprobar FK, límites, precisión, reversos, condiciones selladas, vínculos de idempotencia y coherencia monetaria. No son evidencia de permisos de escritura para el backend.

El informe [administration-local-validation.json](administration-local-validation.json) contiene el resultado real de la última ejecución. También comprueba sobreaplicación concurrente, versión obsoleta concurrente, ausencia de efectos parciales y reaplicación sin restablecer concesiones retiradas. No se realizaron pruebas HTTP ni verificaciones RDS.

## Decisiones y límites

Pendientes funcionales: fiscalidad/numeración legal, redondeo comercial y conversión, aprobaciones, crédito y sobrepagos, integración de devoluciones con stock, permisos de comandos de escritura, ACL de empresa, propiedad definitiva del maestro de Clientes, retención de idempotencia y reglas de liquidación de anticipos. No se precargan tasas ni porcentajes.

Bloqueo conservador por empresa serializa escrituras: protege agregados, pero requiere pruebas de carga y afinamiento antes de alto volumen. Los validadores diferidos recorren datos de la empresa; no se afirma rendimiento de producción. Escribir requiere futuros comandos controlados con autorización y comprobación de contenido de idempotencia. No debe concederse DML general para eludir esa dependencia.

Recuperación local: descartar únicamente los archivos candidatos tras revisión; no hay cambios remotos que revertir. Una futura migración DEV necesitará snapshot y plan específico. No se ofrece DROP de tablas como recuperación porque podría destruir datos una vez utilizadas.

## Promoción DEV autorizada

El propietario autorizó publicar y validar en AWS DEV us-west-1. Se conserva la descripción anterior como evidencia de la fase local. Antes del push se confirmó dev remoto igual a 2631c7a, equivalencia de 001–008 y del handler desplegado tras normalizar saltos de línea, y snapshot available. RDS no contiene ledger individual de migraciones: la evidencia es paquete/commit, catálogo y ejecución, no registros inventados.

Se amplía únicamente el manifiesto del migrador oficial a 009–013 y el empaquetado de suites aisladas. Los workflows permanecen intactos: changes → deploy-migrator → apply; deploy espera actualización y valida CodeSha256, y apply comprueba FunctionError y status/tests. Modelo y reaplicación se confirman antes de las pruebas; un rollback de pruebas no revierte el esquema.

La acción explícita validate_administration usa UUIDs únicos, rol sintético propio y rollback integral; no concede permisos a roles existentes. El modo concurrency confirma únicamente fixtures mutables propias, prueba dos escritores y elimina esos UUIDs en finally, sin desactivar integridad. La carrera de sobreaplicación sobre el mismo saldo conserva evidencia local; queda pendiente en RDS porque los hechos monetarios inmutables exigirían un procedimiento de fixtures persistentes y recuperación adicional. No se declara aprobada remotamente.

Se registra HTTP antes/después sin cambiar estados QA ni crear sesiones. La línea base ya presenta 403 de administradores en Uonify (tres comprobaciones); no se corrige ampliando permisos como parte de la migración. Las escrituras completas de Onboarding no se ejercitan con este runner de solo lectura.

Recuperación: snapshot registrado en administration-dev-validation.json y ZIP anterior conservado en el directorio temporal local mastererp-administration-before.zip. Detener ante fallo y conservar fase/archivo/SQLSTATE/committed_passes; no reintentar automáticamente. Correcciones mediante migración posterior; restaurar un snapshot requeriría decisión explícita sobre una instancia nueva y su endpoint. Restaurar código no revierte SQL.
