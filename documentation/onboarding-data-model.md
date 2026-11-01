# Onboarding and tenant data model

El registro crea un usuario. Ese usuario puede iniciar el alta de un tenant, seleccionar módulos del catálogo global y seguir un flujo condicional de onboarding. Cada selección se registra por tenant y se activa de manera independiente.

Una empresa legal y sus sucursales son opcionales: se crean únicamente para tenants que activen módulos que la requieren, como ERP Finance. Los módulos futuros se agregan en `plataforma.modules`; no requieren cambios en la tabla de tenants.

El aislamiento se mantiene con `tenant_id` en relaciones operativas. `auditoria.events` registra acciones operativas y metadatos, nunca el contenido de chat.

Uonify es temporal: PostgreSQL no conserva historial de conversaciones, mensajes, prompts, respuestas, audio ni contexto. El acceso a Uonify se resuelve durante la sesión mediante sus contratos de plataforma.

Durante DEV, GitHub Actions usa credenciales AWS guardadas como secretos del repositorio para invocar la Lambda `mastererp-dev-database-migrator` en California (`us-west-1`). La Lambda se conecta de forma privada y lee las credenciales del secreto administrado por RDS; GitHub Actions no recibe la contraseña PostgreSQL ni se conecta directamente a la base.

Este repositorio mantiene RDS, el migrador, sus workflows y los SQL. `mastererp-infrastructure` mantiene las definiciones de API Gateway compartidos y las tres Lambdas funcionales de onboarding; `mastererp-platform` mantiene su código.
