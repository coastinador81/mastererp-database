# Pruebas negativas HTTP DEV acotadas

El helper dev_validation preexistente se amplía con qa_foundation_state exclusivamente para fixtures qa-identity-<12 hex>, emails example.invalid y sus tenants del mismo run. No admite SQL, nombres de permisos ni identificadores arbitrarios. Solo la Lambda migradora oficial, invocada con IAM, permite esta acción; no existe ruta HTTP para ella.

Procedimiento: inspeccionar cada baseline con case=inspect antes de cambiar estados; guardar fuera de Git; ejecutar baseline y los casos user_inactive, tenant_inactive, membership_inactive, permission_denied y module_disabled; comprobar HTTP; restaurar siempre el baseline original mediante case=restore en finally, incluso si falla HTTP. actor_label solo admite admin_a/admin_b. Las mutaciones se confirman únicamente sobre estos fixtures sintéticos y se revierten explícitamente; NO se presentan como pruebas SQL con ROLLBACK.

El test SQL del migrador sigue usando fixtures y ROLLBACK, separado del esquema confirmado. La concurrencia SQL del informe local no se presenta como concurrencia DEV. No se altera SQL 006 ni 007 para añadir esta instrumentación.

La habilitación temporal de uonify.core de QA permite probar el guard real; no autoriza activar módulos de clientes ni implica OAuth/Gemini. Restaurar módulo ausente deja la operación correctamente denegada hasta su habilitación autorizada.

Las pruebas HTTP de sesión crean una fila nueva con qa_validation=run y qa_probe=UUID aleatorio, sin tenant. cleanup_session solo elimina exactamente esa fila, con id, iniciador QA, tenant NULL y ambos marcadores coincidentes. No permite borrar sesiones previas ni acepta SQL. Ejecutar limpieza en finally; registrar un fallo de limpieza sin ocultarlo.

La restauración compara los campos funcionales guardados (estados, overrides y asignación de módulo). Los updated_at automáticos de los fixtures QA reflejan la actividad de prueba; no se reescriben timestamps históricos para ocultarla. No se modifican datos de clientes.
