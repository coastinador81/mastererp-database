# Modelo candidato de Administración

Estado: diseño y SQL locales para revisión; no aplicado en RDS, no publicado, no capacidades de negocio implementadas. Algedis queda fuera del alcance por instrucción del propietario; no se buscan documentos ni se afirma cumplimiento de ellos.

## Inventario y decisiones técnicas previas al SQL

El esquema 001–008 contiene 17 tablas de plataforma/organización/auditoría. No contiene clientes, proveedores, productos, monedas, facturas, cartera o tesorería. Las carpetas de maestros de Catálogo son reservas documentales. Se reutilizan organizacion.companies/branches, plataforma.users/user_tenants, permisos/capacidad, auditoria.events e idempotency_keys. No se modifica una migración aplicada ni el manifiesto del migrador ni los workflows.

Se propone una única referencia canónica mínima de terceros (roles cliente/proveedor), productos y monedas en catalogo: NO tablas separadas de clientes/proveedores en Administración. Los nombres/códigos son identidad del maestro, no copia de compañías internas. El responsable definitivo del maestro de Clientes y su integración con Catálogo quedan para revisión funcional; el candidato no habilita escrituras de aplicación sobre esos maestros.

Un documento y sus detalles representan cotizaciones, ventas, facturas de ambos sentidos, solicitudes/órdenes, devoluciones, notas de crédito/débito y justificantes de fondos. No hay una segunda tabla de facturas por cada área. Una partida de cartera referencia un documento facturado/débito; no copia su importe. Los vencimientos distribuyen ese importe; aplicaciones vinculan cobros/pagos o notas de crédito. Las vistas calculan saldos, no columnas de saldo editables.

Solo movimientos_tesoreria representa dinero interno. Operaciones agrupa cobros/pagos/transferencias y sus justificantes, sin duplicar el importe. Los extractos son observaciones externas y conciliación es correspondencia, nunca otro movimiento de caja. Una transferencia tiene dos piernas en cuentas distintas de la misma empresa. Reversos son filas nuevas, nunca edición de hechos monetarios.

Gastos clasifica un documento existente (factura de proveedor o justificante de gasto), sin crear otra factura/deuda. Fondos menores referencia una cuenta de caja existente. Reposición/anticipo vinculan justificante y movimiento; rendición consume gastos identificados mediante detalles, sin contabilización automática. Reservas y liberaciones no son pagos: política configurable con tope opcional, sin regla de porcentaje o insuficiencia de caja inventada.

## Matriz requisito → tablas → relaciones → propietario

| Requisito | Tablas existentes / nuevas | Relaciones principales | Propietario funcional |
| --- | --- | --- | --- |
| Tenant/empresa/sucursal/actor | Existentes tenants, companies, branches, users, user_tenants | FK compuestas de tenant/empresa/sucursal; pertenencia del responsable | Plataforma Base / Organización |
| Clientes/proveedores | Nuevas catalogo.terceros, roles_tercero; administracion.perfiles_tercero | Un tercero con ambos roles; perfil por empresa → condiciones | Catálogo compartido; perfil en 2.2.1.1.1 y 2.2.1.2.1; ubicación final de Clientes pendiente |
| Productos y monedas | Nuevas catalogo.productos, monedas | Detalles → producto del tenant; documentos/cuentas → código monetario | Catálogo; monedas referencia compartida |
| Condiciones/pronto pago | condiciones_comerciales, descuentos_pronto_pago | Perfil/documento → condición; descuentos explícitos sin valores precargados | Gestión comercial / Compras |
| Cotizaciones/ventas/facturas/solicitudes/órdenes | documentos, detalles_documento, relaciones_documento | Una cabecera tipada, detalles, orígenes y referencias compuestas | 2.2.1.1 Gestión comercial / 2.2.1.2 Compras |
| Devoluciones y notas crédito/débito | Misma cabecera/detalles y documento_origen_id | Origen de factura compatible; devoluciones con detalle origen | Administración; efectos de stock solo Inventario |
| Destinos de compras | destinos_compra, detalle_destinos | Sucursal de empresa, reparto de cantidad de solicitud/orden | 2.2.1.2 Compras; almacén/inventario externo pendiente de contrato |
| Cuentas por cobrar/pagar y vencimientos | partidas_cartera, vencimientos, aplicaciones_cartera | Una partida por factura/débito; crédito o dinero aplicado a vencimientos | 2.2.1.3 Cartera |
| Caja/banco/cobros/pagos/movimientos | cuentas_tesoreria, operaciones_tesoreria, movimientos_tesoreria | Cuenta/moneda, operación y contraparte; saldos derivados | 2.2.1.4 Tesorería |
| Transferencias | transferencias | Operación + movimiento salida/entrada, cuentas distintas | 2.2.1.4.5 Transferencias |
| Extractos/conciliación | extractos_bancarios, lineas_extracto, conciliaciones, partidas_conciliacion | Cuenta/moneda, líneas y movimientos con correspondencias limitadas | 2.2.1.4.6 Conciliación |
| Soportes | soportes | Documento o extracto; referencia opaca y SHA-256, sin binario/credenciales | Administración; almacenamiento externo |
| Categorías/gastos | categorias_gasto, gastos | Gasto → documento existente + categoría | 2.2.1.5.1 Gastos operativos |
| Caja chica/reposiciones | fondos_caja_chica, reposiciones | Fondo → cuenta caja; reposición → documento/movimiento | 2.2.1.5.2 Caja chica |
| Anticipos/rendiciones | anticipos, rendiciones, rendicion_gastos | Anticipo → documento/salida/responsable; rendición → gastos trazables | 2.2.1.5.3 Anticipos/rendiciones |
| Reservas configurables | politicas_reserva, reservas_fondos | Política/cuenta/documento, reserva y liberaciones trazables | Compras + Tesorería en padre Administración |
| Auditoría/idempotencia | Existentes auditoria.events / plataforma.idempotency_keys | Actor, tenant, empresa, correlación; clave → recurso/operación/huella | Plataforma compartida |

## Integridad y seguridad

UUID con UNIQUE tenant/empresa/id y FK del mismo alcance; ninguna asociación solo por UUID sin comprobar empresa/tenant. Importes NUMERIC exactos, escala interna máxima 6, sin redondeo implícito: se rechaza precisión adicional. Cantidades/precios son exactos y sus productos deben ser representables; política fiscal/redondeo comercial futura, no asumida. Tipo de cambio explícito (moneda origen → base), fecha y fuente; misma moneda exige 1. Conversiones base se conservan exactas. No se precargan monedas, impuestos, tasas ni porcentajes.

Cabecera/detalles, vencimientos, aplicaciones, devoluciones y conciliaciones se comprueban al final de la transacción mediante triggers de integridad diferidos. Bloqueo por empresa serializa escrituras del candidato y evita sumas concurrentes inconsistentes; es conservador y deberá afinarse por documento/cuenta antes de cargas elevadas. Versionado explícito de filas mutables exige version_anterior+1; hechos monetarios, aplicaciones y reversos son append-only. Cerrar un documento significa sellarlo técnicamente, no aprobación fiscal ni contabilización.

mastererp_app tiene lectura con RLS, módulo erp.finance y permiso administration.read; sin concesiones automáticas a roles. Maestros requieren catalog.master.read y pertenencia activa. No tiene DML directo. Los comandos de escritura, sus permisos y contratos se implementarán cuando se prioricen: no se crean funciones ficticias para permitir CRUD. Las funciones nuevas son exclusivamente de integridad/auditoría. Auditoría reutiliza events con IDs/operación/correlación y sin nombres, importes, soportes ni payloads. La clave compartida, si se vincula, debe corresponder al actor/tenant/operación/recurso y tener huella; no se duplica su almacén ni se afirma idempotencia HTTP implementada.

## Fuera de Administración y decisiones pendientes

Inventario posee existencias, recepción/despacho, coste y ubicación de almacenes. Administración conserva únicamente cantidades/documentos/destino solicitado; no ajusta stock. Contabilidad posee asientos, plan de cuentas, periodos, impuestos/retenciones y diferencias de cambio contabilizadas: no se generan asientos ni reglas fiscales. BI consume vistas/saldos, no es dueño de facturas ni dinero.

Pendientes: fiscalidad por país; numeración legal; precisión/redondeo por moneda y descuento; autorizaciones/aprobaciones; devolución comercial y efectos de stock; ACL por empresa; reglas de crédito, sobrepago/anticipos, reutilización de claves expiradas; contratos de maestros definitivos; política de reserva/presupuesto y liberación; importación y firma de soportes bancarios. Se definen al priorizar el comportamiento, no con porcentajes o datos ficticios.

## Orden y validación local

009 referencias compartidas; 010 documentos/compras; 011 tesorería; 012 cartera/gastos; 013 integridad/RLS/vistas. Son candidatos locales, fuera del manifiesto desplegable actual. El runner explícito en scripts/validate_administration_disposable.py aplica 001–013 en un contenedor PostgreSQL 17.9 sin red, puertos ni volúmenes de datos compartidos; prueba restricciones, permisos reales SET ROLE, precisión y concurrencia. No usar el runner genérico antiguo para desplegar este candidato. No push: schema/** dispararía el workflow de aplicación aunque el paquete actual no incluya estos archivos.

## Precisiones del candidato

Las condiciones tienen ediciones explícitas: una condición utilizada por un documento sellado y sus descuentos no se modifican; se registra otra edición. Las monedas declaran decimales y los importes nativos deben ser representables; la conversión a base conserva el producto exacto. No se aplica redondeo fiscal automático.

La clave de idempotencia compartida se puede vincular a documentos, operaciones, aplicaciones/reversos, conciliación/reversos, reservas/liberaciones y asignación de gastos a rendiciones. La integridad exige actor/tenant/operación/recurso, huella hexadecimal de 64 caracteres y vigencia al crear el recurso. Los futuros comandos deben calcular la huella canónica del contenido y exigir/reproducir la clave; esta validación de vínculos no implementa por sí sola el replay HTTP. La retención o limpieza de claves vinculadas requiere un contrato: la FK evita borrar evidencia todavía referenciada.

Las doce vistas security_invoker exponen documentos tipados y saldos sin almacenar saldos editables. Las escrituras de pruebas de integridad/concurrencia utilizan el rol de migración exclusivamente en PostgreSQL desechable; las pruebas de autorización cambian realmente a mastererp_app y comprueban current_user. Ningún permiso de escritura de aplicación se deduce de esas pruebas.
