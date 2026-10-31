# Onboarding and tenant data model

El registro crea un usuario. Ese usuario puede iniciar el alta de un tenant, seleccionar módulos del catálogo global y seguir un flujo condicional de onboarding. Cada selección se registra por tenant y se activa de manera independiente.

Una empresa legal y sus sucursales son opcionales: se crean únicamente para tenants que activen módulos que la requieren, como ERP Finance. Los módulos futuros se agregan en `plataforma.modules`; no requieren cambios en la tabla de tenants.

El aislamiento se mantiene con `tenant_id` en relaciones operativas. `auditoria.events` registra acciones operativas y metadatos, nunca el contenido de chat.

Uonify es temporal: PostgreSQL no conserva historial de conversaciones, mensajes, prompts, respuestas, audio ni contexto. El acceso a Uonify se resuelve durante la sesión mediante sus contratos de plataforma.

Durante DEV, el runner self-hosted lee su conexión local desde `$HOME/.mastererp/.env`. Más adelante la conexión migrará de `.env` a AWS Secrets Manager.
