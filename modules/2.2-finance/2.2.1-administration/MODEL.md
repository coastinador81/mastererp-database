# Modelo candidato de AdministraciÃ³n

Estado: diseÃ±o y SQL locales para revisiÃ³n; no aplicado en RDS, no publicado, no capacidades de negocio implementadas. Algedis queda fuera del alcance por instrucciÃ³n del propietario; no se buscan documentos ni se afirma cumplimiento de ellos.

## Inventario y decisiones tÃ©cnicas previas al SQL

El esquema 001â€“008 contiene 17 tablas de plataforma/organizaciÃ³n/auditorÃ­a. No contiene clientes, proveedores, productos, monedas, facturas, cartera o tesorerÃ­a. Las carpetas de maestros de CatÃ¡logo son reservas documentales. Se reutilizan organizacion.companies/branches, plataforma.users/user_tenants, permisos/capacidad, auditoria.events e idempotency_keys. No se modifica una migraciÃ³n aplicada ni el manifiesto del migrador ni los workflows.

Se propone una Ãºnica referencia canÃ³nica mÃ­nima de terceros (roles cliente/proveedor), productos y monedas en catalogo: NO tablas separadas de clientes/proveedores en AdministraciÃ³n. Los nombres/cÃ³digos son identidad del maestro, no copia de compaÃ±Ã­as internas. El responsable definitivo del maestro de Clientes y su integraciÃ³n con CatÃ¡logo quedan para revisiÃ³n funcional; el candidato no habilita escrituras de aplicaciÃ³n sobre esos maestros.

Un documento y sus detalles representan cotizaciones, ventas, facturas de ambos sentidos, solicitudes/Ã³rdenes, devoluciones, notas de crÃ©dito/dÃ©bito y justificantes de fondos. No hay una segunda tabla de facturas por cada Ã¡rea. Una partida de cartera referencia un documento facturado/dÃ©bito; no copia su importe. Los vencimientos distribuyen ese importe; aplicaciones vinculan cobros/pagos o notas de crÃ©dito. Las vistas calculan saldos, no columnas de saldo editables.

Solo movimientos_tesoreria representa dinero interno. Operaciones agrupa cobros/pagos/transferencias y sus justificantes, sin duplicar el importe. Los extractos son observaciones externas y conciliaciÃ³n es correspondencia, nunca otro movimiento de caja. Una transferencia tiene dos piernas en cuentas distintas de la misma empresa. Reversos son filas nuevas, nunca ediciÃ³n de hechos monetarios.

Gastos clasifica un documento existente (factura de proveedor o justificante de gasto), sin crear otra factura/deuda. Fondos menores referencia una cuenta de caja existente. ReposiciÃ³n/anticipo vinculan justificante y movimiento; rendiciÃ³n consume gastos identificados mediante detalles, sin contabilizaciÃ³n automÃ¡tica. Reservas y liberaciones no son pagos: polÃ­tica configurable con tope opcional, sin regla de porcentaje o insuficiencia de caja inventada.

## Matriz requisito â†’ tablas â†’ relaciones â†’ propietario

| Requisito | Tablas existentes / nuevas | Relaciones principales | Propietario funcional |
| --- | --- | --- | --- |
| Tenant/empresa/sucursal/actor | Existentes tenants, companies, branches, users, user_tenants | FK compuestas de tenant/empresa/sucursal; pertenencia del responsable | Plataforma Base / OrganizaciÃ³n |
| Clientes/proveedores | Nuevas catalogo.terceros, roles_tercero; administracion.perfiles_tercero | Un tercero con ambos roles; perfil por empresa â†’ condiciones | CatÃ¡logo compartido; perfil en 2.2.1.1.1 y 2.2.1.2.1; ubicaciÃ³n final de Clientes pendiente |
| Productos y monedas | Nuevas catalogo.productos, monedas | Detalles â†’ producto del tenant; documentos/cuentas â†’ cÃ³digo monetario | CatÃ¡logo; monedas referencia compartida |
| Condiciones/pronto pago | condiciones_comerciales, descuentos_pronto_pago | Perfil/documento â†’ condiciÃ³n; descuentos explÃ­citos sin valores precargados | GestiÃ³n comercial / Compras |
| Cotizaciones/ventas/facturas/solicitudes/Ã³rdenes | documentos, detalles_documento, relaciones_documento | Una cabecera tipada, detalles, orÃ­genes y referencias compuestas | 2.2.1.1 GestiÃ³n comercial / 2.2.1.2 Compras |
| Devoluciones y notas crÃ©dito/dÃ©bito | Misma cabecera/detalles y documento_origen_id | Origen de factura compatible; devoluciones con detalle origen | AdministraciÃ³n; efectos de stock solo Inventario |
| Destinos de compras | destinos_compra, detalle_destinos | Sucursal de empresa, reparto de cantidad de solicitud/orden | 2.2.1.2 Compras; almacÃ©n/inventario externo pendiente de contrato |
| Cuentas por cobrar/pagar y vencimientos | partidas_cartera, vencimientos, aplicaciones_cartera | Una partida por factura/dÃ©bito; crÃ©dito o dinero aplicado a vencimientos | 2.2.1.3 Cartera |
| Caja/banco/cobros/pagos/movimientos | cuentas_tesoreria, operaciones_tesoreria, movimientos_tesoreria | Cuenta/moneda, operaciÃ³n y contraparte; saldos derivados | 2.2.1.4 TesorerÃ­a |
| Transferencias | transferencias | OperaciÃ³n + movimiento salida/entrada, cuentas distintas | 2.2.1.4.5 Transferencias |
| Extractos/conciliaciÃ³n | extractos_bancarios, lineas_extracto, conciliaciones, partidas_conciliacion | Cuenta/moneda, lÃ­neas y movimientos con correspondencias limitadas | 2.2.1.4.6 ConciliaciÃ³n |
| Soportes | soportes | Documento o extracto; referencia opaca y SHA-256, sin binario/credenciales | AdministraciÃ³n; almacenamiento externo |
| CategorÃ­as/gastos | categorias_gasto, gastos | Gasto â†’ documento existente + categorÃ­a | 2.2.1.5.1 Gastos operativos |
| Caja chica/reposiciones | fondos_caja_chica, reposiciones | Fondo â†’ cuenta caja; reposiciÃ³n â†’ documento/movimiento | 2.2.1.5.2 Caja chica |
| Anticipos/rendiciones | anticipos, rendiciones, rendicion_gastos | Anticipo â†’ documento/salida/responsable; rendiciÃ³n â†’ gastos trazables | 2.2.1.5.3 Anticipos/rendiciones |
| Reservas configurables | politicas_reserva, reservas_fondos | PolÃ­tica/cuenta/documento, reserva y liberaciones trazables | Compras + TesorerÃ­a en padre AdministraciÃ³n |
| AuditorÃ­a/idempotencia | Existentes auditoria.events / plataforma.idempotency_keys | Actor, tenant, empresa, correlaciÃ³n; clave â†’ recurso/operaciÃ³n/huella | Plataforma compartida |

## Integridad y seguridad

UUID con UNIQUE tenant/empresa/id y FK del mismo alcance; ninguna asociaciÃ³n solo por UUID sin comprobar empresa/tenant. Importes NUMERIC exactos, escala interna mÃ¡xima 6, sin redondeo implÃ­cito: se rechaza precisiÃ³n adicional. Cantidades/precios son exactos y sus productos deben ser representables; polÃ­tica fiscal/redondeo comercial futura, no asumida. Tipo de cambio explÃ­cito (moneda origen â†’ base), fecha y fuente; misma moneda exige 1. Conversiones base se conservan exactas. No se precargan monedas, impuestos, tasas ni porcentajes.

Cabecera/detalles, vencimientos, aplicaciones, devoluciones y conciliaciones se comprueban al final de la transacciÃ³n mediante triggers de integridad diferidos. Bloqueo por empresa serializa escrituras del candidato y evita sumas concurrentes inconsistentes; es conservador y deberÃ¡ afinarse por documento/cuenta antes de cargas elevadas. Versionado explÃ­cito de filas mutables exige version_anterior+1; hechos monetarios, aplicaciones y reversos son append-only. Cerrar un documento significa sellarlo tÃ©cnicamente, no aprobaciÃ³n fiscal ni contabilizaciÃ³n.

mastererp_app tiene lectura con RLS, mÃ³dulo erp.finance y permiso administration.read; sin concesiones automÃ¡ticas a roles. Maestros requieren catalog.master.read y pertenencia activa. No tiene DML directo. Los comandos de escritura, sus permisos y contratos se implementarÃ¡n cuando se prioricen: no se crean funciones ficticias para permitir CRUD. Las funciones nuevas son exclusivamente de integridad/auditorÃ­a. AuditorÃ­a reutiliza events con IDs/operaciÃ³n/correlaciÃ³n y sin nombres, importes, soportes ni payloads. La clave compartida, si se vincula, debe corresponder al actor/tenant/operaciÃ³n/recurso y tener huella; no se duplica su almacÃ©n ni se afirma idempotencia HTTP implementada.

## Fuera de AdministraciÃ³n y decisiones pendientes

Inventario posee existencias, recepciÃ³n/despacho, coste y ubicaciÃ³n de almacenes. AdministraciÃ³n conserva Ãºnicamente cantidades/documentos/destino solicitado; no ajusta stock. Contabilidad posee asientos, plan de cuentas, periodos, impuestos/retenciones y diferencias de cambio contabilizadas: no se generan asientos ni reglas fiscales. BI consume vistas/saldos, no es dueÃ±o de facturas ni dinero.

Pendientes: fiscalidad por paÃ­s; numeraciÃ³n legal; precisiÃ³n/redondeo por moneda y descuento; autorizaciones/aprobaciones; devoluciÃ³n comercial y efectos de stock; ACL por empresa; reglas de crÃ©dito, sobrepago/anticipos, reutilizaciÃ³n de claves expiradas; contratos de maestros definitivos; polÃ­tica de reserva/presupuesto y liberaciÃ³n; importaciÃ³n y firma de soportes bancarios. Se definen al priorizar el comportamiento, no con porcentajes o datos ficticios.

## Orden y validaciÃ³n local

009 referencias compartidas; 010 documentos/compras; 011 tesorerÃ­a; 012 cartera/gastos; 013 integridad/RLS/vistas. Son candidatos locales, fuera del manifiesto desplegable actual. El runner explÃ­cito en scripts/validate_administration_disposable.py aplica 001â€“013 en un contenedor PostgreSQL 17.9 sin red, puertos ni volÃºmenes de datos compartidos; prueba restricciones, permisos reales SET ROLE, precisiÃ³n y concurrencia. No usar el runner genÃ©rico antiguo para desplegar este candidato. No push: schema/** dispararÃ­a el workflow de aplicaciÃ³n aunque el paquete actual no incluya estos archivos.

## Precisiones del candidato

Las condiciones tienen ediciones explÃ­citas: una condiciÃ³n utilizada por un documento sellado y sus descuentos no se modifican; se registra otra ediciÃ³n. Las monedas declaran decimales y los importes nativos deben ser representables; la conversiÃ³n a base conserva el producto exacto. No se aplica redondeo fiscal automÃ¡tico.

La clave de idempotencia compartida se puede vincular a documentos, operaciones, aplicaciones/reversos, conciliaciÃ³n/reversos, reservas/liberaciones y asignaciÃ³n de gastos a rendiciones. La integridad exige actor/tenant/operaciÃ³n/recurso, huella hexadecimal de 64 caracteres y vigencia al crear el recurso. Los futuros comandos deben calcular la huella canÃ³nica del contenido y exigir/reproducir la clave; esta validaciÃ³n de vÃ­nculos no implementa por sÃ­ sola el replay HTTP. La retenciÃ³n o limpieza de claves vinculadas requiere un contrato: la FK evita borrar evidencia todavÃ­a referenciada.

Las doce vistas security_invoker exponen documentos tipados y saldos sin almacenar saldos editables. Las escrituras de pruebas de integridad/concurrencia utilizan el rol de migraciÃ³n exclusivamente en PostgreSQL desechable; las pruebas de autorizaciÃ³n cambian realmente a mastererp_app y comprueban current_user. NingÃºn permiso de escritura de aplicaciÃ³n se deduce de esas pruebas.
