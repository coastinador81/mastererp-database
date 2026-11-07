# Numeración de aplicaciones y transición de rutas

Estado: reorganización fuente autorizada para publicar en dev. No aplica SQL ni traslada recursos AWS. La sustitución explícita del hostname de Agentes se gestiona aparte sobre su hosting existente. Platform es la fuente de esta guía y del JSON de correspondencias; sincronizar copias idénticas en los tres repositorios.

## Aplicaciones y rutas funcionales

| Carpeta | Aplicación | Dominio DEV objetivo | Responsabilidad general |
| --- | --- | --- | --- |
| `0-uonify` | Uonify | `dev.uonify.com` | Entrada, cuenta, espacios, chat y lanzador. |
| `1.0-platform-base` | Plataforma Base | `Sin subdominio de aplicación` | Identidad, onboarding, permisos, auditoría, notificaciones y administración de seguridad. |
| `2.1-inventory` | Inventario | `inventario-dev.uonify.com` | Existencias, reservas, movimientos, nodos y preparación compartida. |
| `2.2-finance` | Finanzas | `finanzas-dev.uonify.com` | Administración, Contabilidad, BI, MasterPay y Recursos humanos. |
| `2.3-ecommerce` | Ecommerce | `ecom-dev.uonify.com` | Pedidos, tiendas, website, catálogo comercial, contenido y marketplaces. |
| `2.4-marketing` | Marketing | `marketing-dev.uonify.com` | Meta y HubSpot; otras capacidades pendientes. |
| `2.5-services` | Servicios | `servicios-dev.uonify.com` | Mantenimiento, fabricación, proyectos y RFID, con alcance pendiente. |
| `2.6-agent-center` | Centro de Agentes | `agentes-dev.uonify.com` | Creación y gobierno de agentes, documentación, flujos, tareas, auditoría y aprobaciones. |
| `2.7-crm` | CRM | `crm-dev.uonify.com` | MasterCRM; capacidades y contratos por definir. |
| `2.8-productivity` | Productividad | `productividad-dev.uonify.com` | Opsphere, Google Workspace y Microsoft 365. |
| `2.9-pos` | Punto de venta | `pos-dev.uonify.com` | Venta presencial y cajas; consume nodos, terceros e inventario compartidos. |
| `2.10-transport` | Transporte | `transporte-dev.uonify.com` | Repartidores, transportistas, Chipipro, MRW y rutas de reparto. |
| `2.11-studio` | Estudio | `estudio-dev.uonify.com` | Vídeo, imágenes y generación de texto; reservas documentales. |

La tienda pública pertenece a `2.3-ecommerce/2.3.2-stores/storefront/` en Platform frontend y conserva `tienda-dev.uonify.com`; no es otra aplicación del lanzador. El frontend administrativo existente de Andrea se conserva en la raíz `frontend/modules/2.3-ecommerce/`. Preparación pertenece a Inventario y puede presentarse en Ecommerce/POS sin duplicar datos; las rutas de reparto pertenecen a Transporte.

## Correspondencias de carpetas

Estas rutas son relativas a `frontend/modules/` y `backend/modules/` en Platform, y a `modules/` en Database e Infrastructure. Se aplica la coincidencia en las cuatro capas.

| Origen anterior | Destino actual |
| --- | --- |
| `2.1-catalog/2.1.1-products` | `2.3-ecommerce/2.3.4-catalog/2.3.4.1-products` |
| `2.1-catalog/2.1.2-categories` | `2.3-ecommerce/2.3.4-catalog/2.3.4.2-categories` |
| `2.1-catalog/2.1.3-attributes` | `2.3-ecommerce/2.3.4-catalog/2.3.4.3-attributes` |
| `2.1-catalog/2.1.4-brands` | `2.3-ecommerce/2.3.4-catalog/2.3.4.4-brands` |
| `2.1-catalog/2.1.5-suppliers` | `2.3-ecommerce/2.3.4-catalog/2.3.4.5-suppliers` |
| `2.1-catalog/2.1.6-inventory` | `2.1-inventory/2.1.1-inventory` |
| `2.1-catalog` | `2.3-ecommerce/2.3.4-catalog` |
| `2.3-operations/2.3.1-orders` | `2.3-ecommerce/2.3.1-orders` |
| `2.3-operations/2.3.2-preparation` | `2.1-inventory/2.1.3-preparation` |
| `2.3-operations/2.3.3-routes` | `2.10-transport/2.10.5-routes` |
| `2.3-operations/2.3.4-nodes` | `2.1-inventory/2.1.2-nodes` |
| `2.3-operations` | `2.3-ecommerce` |
| `2.4-digital-sales/2.4.1-website` | `2.3-ecommerce/2.3.3-website` |
| `2.4-digital-sales/2.4.2-ecommerce` | `2.3-ecommerce/2.3.2-stores` |
| `2.4-digital-sales/2.4.3-product-content` | `2.3-ecommerce/2.3.5-product-content` |
| `2.4-digital-sales/2.4.4-marketplaces` | `2.3-ecommerce/2.3.6-marketplaces` |
| `2.4-digital-sales` | `2.3-ecommerce` |
| `2.7-hr/2.7.1-employees` | `2.2-finance/2.2.5-hr/2.2.5.1-employees` |
| `2.7-hr/2.7.2-payroll` | `2.2-finance/2.2.5-hr/2.2.5.2-payroll` |
| `2.7-hr/2.7.3-absences` | `2.2-finance/2.2.5-hr/2.2.5.3-absences` |
| `2.7-hr` | `2.2-finance/2.2.5-hr` |
| `2.8-productivity/2.8.2-marketing/2.8.2.1-meta` | `2.4-marketing/2.4.1-meta` |
| `2.8-productivity/2.8.2-marketing/2.8.2.2-hubspot` | `2.4-marketing/2.4.2-hubspot` |
| `2.8-productivity/2.8.2-marketing` | `2.4-marketing` |
| `2.8-productivity/2.8.3-mastercrm` | `2.7-crm` |
| `2.8-productivity/2.8.4-google-workspace` | `2.8-productivity/2.8.2-google-workspace` |
| `2.8-productivity/2.8.5-microsoft-365` | `2.8-productivity/2.8.3-microsoft-365` |
| `2.11-security/2.11.1-users` | `1.0-platform-base/1.2-platform-management/1.2.6-security/1.2.6.1-users` |
| `2.11-security/2.11.2-groups` | `1.0-platform-base/1.2-platform-management/1.2.6-security/1.2.6.2-groups` |
| `2.11-security/2.11.3-roles` | `1.0-platform-base/1.2-platform-management/1.2.6-security/1.2.6.3-roles` |
| `2.11-security` | `1.0-platform-base/1.2-platform-management/1.2.6-security` |
| `2.8-productivity/2.8.4-google-workspace/2.8.4.1-gmail` | `2.8-productivity/2.8.2-google-workspace/2.8.2.1-gmail` |
| `2.8-productivity/2.8.4-google-workspace/2.8.4.2-meet` | `2.8-productivity/2.8.2-google-workspace/2.8.2.2-meet` |
| `2.8-productivity/2.8.4-google-workspace/2.8.4.3-drive` | `2.8-productivity/2.8.2-google-workspace/2.8.2.3-drive` |
| `2.8-productivity/2.8.5-microsoft-365/2.8.5.1-outlook` | `2.8-productivity/2.8.3-microsoft-365/2.8.3.1-outlook` |
| `2.8-productivity/2.8.5-microsoft-365/2.8.5.2-teams` | `2.8-productivity/2.8.3-microsoft-365/2.8.3.2-teams` |
| `2.8-productivity/2.8.5-microsoft-365/2.8.5.3-onedrive` | `2.8-productivity/2.8.3-microsoft-365/2.8.3.3-onedrive` |
| `2.8-productivity/2.8.5-microsoft-365/2.8.5.4-sharepoint` | `2.8-productivity/2.8.3-microsoft-365/2.8.3.4-sharepoint` |
| `2.8-productivity/2.8.5-microsoft-365/2.8.5.5-planner` | `2.8-productivity/2.8.3-microsoft-365/2.8.3.5-planner` |
| `2.8-productivity/2.8.5-microsoft-365/2.8.5.6-power-automate` | `2.8-productivity/2.8.3-microsoft-365/2.8.3.6-power-automate` |

Las subcarpetas y pantallas existentes viajan con su propietario. Finanzas/Administración conserva íntegra su numeración. El archivo anterior raíz de Digital Sales se conserva como `2.3-ecommerce/DIGITAL_SALES_HISTORY.md`; su YAML vacío como `digital-sales-resources.reserved.yml`, histórico y excluido de despliegue. No se vació ni eliminó ninguna plantilla con recursos. Seguridad funcional se conserva en `1.2.6-security`; identidad y evaluación técnica de permisos siguen en sus módulos existentes, sin otro sistema de autorización.

## Contratos técnicos que NO cambian por renumerar

Los códigos funcionales numerados son rutas fuente, no identificadores desplegados. Se conservan schemas SQL (`catalogo`, `operaciones`, etc.), permisos (`catalog.*`, `operations.*`, etc.), códigos de módulos registrados, firmas SQL, endpoints HTTP y nombres físicos de Lambdas. No editar migraciones aplicadas ni seeds para aparentar que el cambio ya está en RDS.

Los dominios anteriores siguen siendo los propietarios efectivos de sus stacks y recursos. Por ejemplo, los manifiestos de empaquetado apuntan ahora a nuevas carpetas, pero `mastererp-dev-catalog`, `mastererp-dev-operations` y `mastererp-dev-digital-sales` conservan sus identidades. No desplegar el árbol nuevo creando stacks de Inventario, Ecommerce o Transporte para recursos que ya tienen propietario.

## Publicación futura: revisión obligatoria

Los paths de workflows y empaquetado se actualizan para que encuentren el código; su alcance operativo y credenciales no se amplían. Un push de esta reorganización puede disparar workflows de frontend y validación, y el workflow de Database observado por cambios del migrador. El mero traslado no aplica SQL y no autoriza ejecutar despliegues. Antes de publicar, revisar `git diff --name-only`, los filtros de cada workflow, la clasificación SQL y los manifiestos efectivos; publicar solo tras decisión explícita.

Una evolución posterior puede reorganizar navegación y ownership AWS, pero requiere su propio inventario, plan y change sets. No cambiar DNS, callbacks Cognito, CORS o URLs desplegadas para resolver referencias locales. `dev.uonify.com` es la entrada objetivo; la sustitución de `app-dev.uonify.com` y la federación Google/SSO entre dominios siguen pendientes de configuración y validación.

## Conservación y recuperación local

Se guardó antes de mover una copia de los archivos versionados y no ignorados, los diffs locales y el mapa archivo origen → destino fuera de los repositorios. No se sobrescribió trabajo ajeno; los README y código existentes se trasladaron con sus modificaciones locales. No restaurar el repositorio completo con reset/clean: recuperar solo un archivo concreto desde el respaldo si fuera necesario y conciliar cambios posteriores.

Las reservas de Estudio y sus submódulos contienen únicamente README y, en Infrastructure, YAML vacíos. No prueban implementación. Los objetivos se amplían progresivamente por el Product Owner; no inventar requisitos ni sustituir controles de autorización por el menú.

## Resultado de validación

Ver [comprobaciones ejecutadas, fallos previos y límites](MODULE_RENUMBERING_VALIDATION.md).
