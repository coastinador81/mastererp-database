# Continuación del cierre DEV — entrega adicional

Esta entrega es posterior a 61756d9 / 0e4920e / 232ef24. **La base completa sigue abierta.** No se ejecutó apply_model ni se repitieron migraciones/pruebas SQL del modelo. Sí se ejecutaron consultas y mutaciones de fixtures QA estrictamente acotados para validar HTTP.

## Cambios nuevos publicados

- Database 302a7f9: el workflow clasifica las rutas cambiadas. Push de código auxiliar/workflow: despliega migrador y omite apply. Cambios en schema/, seeds/ o tests/ y workflow_dispatch explícito conservan aplicación precedida por despliegue, needs, concurrencia, FunctionError y succeeded/passed. Cinco pruebas locales y dos comparaciones con commits reales aprobadas; YAML/Bash validados.
- Database 48893f4: ciclo de pertenencia temporal QA en la Lambda oficial, sin nuevo migrador, permisos IAM, tablas ni migraciones. Solo acepta el run sintético reservado, cuentas example.invalid y tenant B del mismo run. Su UUID se deriva de run+nonce (UUIDv5); no admite un ID arbitrario que permita modificar/borrar otras pertenencias. Preparación rechaza una pertenencia ya existente. Permiso B se permite/deniega sobre esa fila temporal; limpieza en finally. Cuatro tests de guards y propagación de fallos del migrador aprobados localmente.
- Platform: scripts/validate_dual_tenant_dev.py y docs/dual-tenant-continuation.json contienen la prueba real y su resultado. Nonce y estado de recuperación se guardan fuera de Git, sin credenciales. Solo access tokens reales Cognito, sin doubles.
- Infrastructure: foundation-continuation-routing.json identifica IDs físicos y destinos ausentes de cada ruta; foundation-continuation-runtime.json registra configuración del aprovisionador y comparación de catálogo de datos. No se desplegaron cambios de stacks.

## Resultado de cada pendiente anterior

| Pendiente | Resultado en esta entrega | Evidencia / siguiente requisito |
| --- | --- | --- |
| Un usuario en dos tenants por HTTP | **CERRADO para el contrato cubierto** | 20 comprobaciones nuevas aprobadas, 17 con HTTP. Mismo actor: A=200/B=403, ocho lecturas concurrentes, B=200 tras retirar deny, B=403 tras revocarlo; A conserva 200. Espacios incluyen ambos y vuelven al estado inicial tras limpieza. |
| Seis rutas heredadas | **NO RESUELTO** | API qx8nmypdhi, propietario mastererp-dev-onboarding, mismos seis IDs y cuatro destinos Lambda ausentes. GET catálogo/config/módulos devuelven 500 sin token. POST/PATCH/PUT no se invocaron. No se presentan como autenticación aprobada. Se requiere reparación de integración compatible con el Body SAM y las ocho rutas de Administración que no pertenecen a ese Body; no reimportar una definición parcial ni recrear funciones. |
| Aprovisionador interno | **NO RESUELTO** | State Active no acredita función operativa. Lectura actual: sin VPC, sin secreto de aplicación y sin configuración Cognito. No se invocó. Requiere adaptar código/configuración y comando autorizado/atómico con idempotencia, manteniendo mastererp_app; no conectar credenciales administrativas para hacerlo pasar. |
| Idempotencia y concurrencia HTTP de creación tenant/empresa | **PENDIENTE, NO EJECUTADO** | POST de tenant apunta a función retirada; no hay recorrido HTTP de empresa reparado. La concurrencia SQL y los seis tests SQL de la entrega anterior siguen siendo evidencia histórica, no pruebas nuevas ni equivalencia HTTP. |
| Cruces empresa/sucursal por HTTP | **PENDIENTE, NO EJECUTADO** | No hay operación HTTP validada para ese recorrido. Los checks SQL previos no se reejecutaron ni se presentan como HTTP. No se añadieron pantallas, endpoints ficticios o health para simularlo. |
| Autorregistro | **DESACTIVADO, SIN CAMBIO** | Alcance aprobado: usuario interno activo crea su propio tenant. Sigue pendiente reparar/probar su ruta real. No se activa por una nota ni se cambia propietario mediante email/grupos. |
| Aislamiento, overrides y contexto del mismo actor | **AMPLIADO Y APROBADO** | Deny en B no bloquea A; allow y nueva revocación de B se reflejan por API. Ocho lecturas concurrentes alternando tenants no filtraron el permiso de A a B. |
| Regresión Uonify/Cognito | **APROBADO EN EL RECORRIDO NUEVO** | Login Code+PKCE real, espacios y status not_configured con módulo activo. No OAuth Google/Gemini, navegador completo ni otras rutas no probadas. Core QA y overrides originales restaurados; pertenencia temporal eliminada. |
| Repetición de migraciones | **EVITADA Y VERIFICADA** | Dos ejecuciones nuevas: changes=success, deploy-migrator=success, apply=skipped. Solo código; manifiesto SQL sin cambios. |

## Versión y ejecuciones exactas

Modelo SQL aplicado: **3c24386ae4308d1545b4c63845f2169aa273b189**, sin reaplicación en esta continuación. Migrador con instrumentación nueva: **48893f4d45b787a14befa63033a967e2807bd00b**, CodeSha256 **j1rgImg8ve4FgJHLvsjEeq1kB70ORsqYMVUS7BgSJzI=**, Active/Successful.

- [Clasificación y despliegue sin apply, 41529465109](https://github.com/eticayservicios/mastererp-database/actions/runs/41529465109).
- [Actualización QA sin apply, 41530211106](https://github.com/eticayservicios/mastererp-database/actions/runs/41530211106).

Los hashes/configuración de seis funciones SQL y el FK de sucursales comparados por inspección de solo lectura permanecen iguales al informe anterior. La comparación excluye anotaciones locales como matches_reviewed_source; no interpreta una diferencia de formato del reporte como drift SQL. No hay un nuevo registro retrospectivo de migración.

## Límites y recuperación

No se modificaron SQL, datos de clientes, Cognito, frontend, Finanzas, red ni propiedad de stacks. El único dato temporal nuevo fue la segunda pertenencia QA; se eliminó. Se restauraron los campos funcionales de QA, conservando las marcas updated_at de la actividad de prueba. Las pruebas HTTP no utilizan credenciales administrativas: las acciones administrativas del migrador se limitan a preparar/retirar fixtures; el acceso HTTP sigue pasando por el rol de aplicación real.

Ante fallo no se reintenta automáticamente. El runner conserva run/nonce/baselines en un archivo temporal de recuperación; permite limpiar exclusivamente la fila derivada de ese nonce y restaurar QA mediante la acción acotada. No restaurar snapshot ni ejecutar apply_model para recuperar estas pruebas. Sigue vigente el respaldo y procedimiento anterior para cambios de esquema, que aquí no se ejecutaron.

Guía: [FOUNDATION_INTEGRATION.md](FOUNDATION_INTEGRATION.md). Corte previo: [FOUNDATION_CLOSURE_DEV.md](FOUNDATION_CLOSURE_DEV.md). El cierre total todavía exige resolver las rutas y comandos funcionales indicados; esta entrega adicional no los declara implementados.
