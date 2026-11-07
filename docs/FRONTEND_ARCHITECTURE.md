# Contrato general de arquitectura frontend — MasterERP + Uonify

Estado: arquitectura objetivo aprobada y numeración local reorganizada. No acredita nuevos dominios, SSO federado ni migración de hosting. Fuente oficial: Platform/dev; las copias en Database e Infrastructure deben ser idénticas.

## 1. Entrada y aplicaciones independientes

MasterERP conserva los datos, reglas, procesos y autorización. Uonify es la entrada general objetivo DEV en `dev.uonify.com`: cuenta, espacios, chat y lanzador. No se exige conversar para abrir una aplicación. Cada aplicación principal abre su subdominio, con componentes, build, pipeline, despliegue y rollback propios. Administración no es otra aplicación: vive dentro de Finanzas, junto con Contabilidad, BI, MasterPay y Recursos humanos.

Esta decisión sustituye la experiencia objetivo anterior de mostrar todas las pantallas dentro del App Shell de Uonify. La composición de código existente puede conservarse durante la transición; no implica que deba borrarse ni publicarse otro hosting automáticamente. El contrato anterior se conserva como referencia histórica en [FRONTEND_ARCHITECTURE_BEFORE_RENUMBERING.md](history/FRONTEND_ARCHITECTURE_BEFORE_RENUMBERING.md).

Las aplicaciones, dominios propuestos y rutas están en [MODULE_RENUMBERING.md](MODULE_RENUMBERING.md) y [MODULE_REGISTRY.md](MODULE_REGISTRY.md). Ecommerce administrativo usa `ecom-dev.uonify.com`; su tienda pública independiente usa `tienda-dev.uonify.com` y pertenece al mismo dominio funcional. La biblioteca de catálogo es única y consumida por Inventario, POS, Compras y Ecommerce.

## 2. Cuenta común y acceso a servicios

La experiencia objetivo es una cuenta común para entrar a los servicios y un lanzador que presente las aplicaciones. Cada módulo define progresivamente funcionalidades, espacios, habilitación y límites. Mostrar una aplicación o permitir visitar su entrada no concede acceso a operaciones ni datos privados. Una reserva documental no es un servicio funcional: identificar pendientes sin enlaces ficticios.

Cognito autentica, con federación Google y otros proveedores solo cuando estén configurados y validados. La identidad interna se resuelve exclusivamente mediante issuer + sub, sin asociación automática por email. No usar grupos Cognito ni platform.admin como bypass de tenants. MasterERP PostgreSQL autoriza cada operación y prevalecen las denegaciones explícitas.

## 3. Sesión, espacios y contexto

Un usuario puede pertenecer a varios tenants y cada tenant tener varias empresas. Cada API valida usuario, tenant y pertenencia activos, empresa compatible, permisos y módulos habilitados conforme al contrato vigente. El hostname, la marca, el menú y los IDs enviados por frontend no conceden permisos ni determinan por sí solos el tenant.

La sesión entre subdominios no se comparte automáticamente. Cada frontend debe obtener y validar su sesión mediante el contrato Cognito acordado, con Authorization Code + PKCE donde corresponda. No enviar access tokens, ID tokens ni refresh tokens en URLs o enlaces de navegación; no usar cookies amplias entre subdominios como atajo sin un diseño específico revisado. La recuperación del tenant/empresa activos, expiración, pestañas simultáneas y cierre de sesión entre aplicaciones requieren pruebas explícitas. Cerrar sesión local o global sigue siendo una decisión pendiente.

Al cambiar usuario, tenant o empresa, cancelar solicitudes anteriores y limpiar datos/cachés de contexto; el destino revalida pertenencia y selección. Menús ocultos o visibles no sustituyen la autorización backend.

## 4. Responsabilidades compartidas

Terceros, productos, empresas, monedas, identidad y servicios de IA se reutilizan mediante sus contratos existentes. El número de carpeta no cambia el identificador del permiso, schema o servicio. Estudio crea vídeo, imágenes y texto; Marketing y Ecommerce pueden consumir esos recursos. Centro de Agentes construye y gobierna agentes; Uonify puede invocarlos sin otorgar permisos adicionales.

Inventario mantiene existencias, nodos y preparación entre canales. Ecommerce presenta los pedidos de su canal y puede invocar preparación; POS reutiliza nodos e inventario. Transporte administra repartidores y rutas. Recursos humanos pertenece a Finanzas, conservando sus permisos específicos y sin acceso automático por tener un permiso financiero general.

## 5. Cuatro capas y propiedad

Frontend y backend de Platform, Database e Infrastructure mantienen la misma numeración y rutas funcionales. [FOLDER_STANDARD.md](FOLDER_STANDARD.md) exige README por carpeta funcional y resources.yml en Infrastructure. Una carpeta, pantalla o YAML no obliga a crear Lambda, tabla o stack. Recursos compartidos se declaran una sola vez en el padre común; los consumidores reciben referencias explícitas.

Mover archivos no cambia el stack propietario ni los recursos físicos. Se conservan APIs, autorizadores, Cognito, RDS, secretos, Lambdas y endpoints existentes. La transición de ownership requiere un plan separado. Solo DEV; no se crean QA/PROD ni se inventan dominios de producción.

## 6. Estado y pendientes

Los repositorios contienen hosting y aplicaciones anteriores en distintos grados de implementación. `app-dev.uonify.com` sigue apareciendo en contratos técnicos vigentes; `dev.uonify.com` es la entrada objetivo y su sustitución no se ejecuta por esta reorganización. Las pruebas históricas acreditan únicamente sus versiones y alcance originales. La renumeración local no valida de nuevo DNS, certificados, login, permisos SQL ni funcionamiento en AWS.

Pendientes: configurar/validar SSO y federación Google, actualizar de forma coordinada callbacks/CORS/dominios, definir continuidad y logout, cerrar entradas de servicios y límites por aplicación, y preparar cualquier migración de propiedad AWS. No afirmar una implementación completa por tener README, build o endpoints health aprobados.

## 7. Fuente oficial y mantenimiento

Editar primero en mastererp-platform/dev, conservar cambios ajenos y copiar el contenido completo a docs/FRONTEND_ARCHITECTURE.md en los otros repositorios. Comparar SHA-256. PROJECT.md se mantiene con la misma fuente oficial y sincronización. Consultar AGENTS, el estándar UX/UI y el mapa de numeración antes de implementar cambios. El Product Owner define progresivamente reglas y criterios; el desarrollador concreta la solución técnica dentro de esos contratos.
