# MasterERP — contexto común

## Contrato de arquitectura frontend

MasterERP conserva datos, reglas, procesos y autorización. `app-dev.uonify.com` es la entrada general DEV: la experiencia objetivo es un dashboard con chat y menú de módulos habilitados para el tenant y autorizados para el usuario. Sus pantallas se presentan dentro de Uonify, con navegación, identidad y contexto comunes; conversar no es obligatorio. Finanzas agrupa Administración, Contabilidad, BI y capacidades asociadas y conserva build/pipeline/despliegue propios. Su hosting `finanzas-dev.uonify.com` existe como acceso independiente de desarrollo y pruebas, no como navegación objetivo del usuario final; no se exige un subdominio financiero en producción ni una entrada `/finanzas`. El primer recorrido de Clientes/Proveedores ya está integrado y probado en DEV; las demás capacidades siguen pendientes. Cognito autentica; MasterERP autoriza cada operación por API. Ver [contrato oficial y estado desplegado](docs/FRONTEND_ARCHITECTURE.md). La fuente oficial está en Platform/dev y sus copias en Infrastructure y Database deben ser idénticas; solo se trabaja en DEV.

## Visión objetivo

MasterERP busca centralizar operaciones empresariales para usuarios individuales, empresas y grupos que contratan módulos según sus necesidades. Uonify (0-uonify) es el front general con dashboard, menú y chat para consultar y operar el sistema; MasterERP conserva el núcleo de negocio y autorización. Cada módulo ejecuta sus operaciones y aplica sus reglas; el chat no sustituye su autorización ni es propietario de todos sus datos. Esta es la visión objetivo, no una afirmación de que todos los módulos estén implementados.

## Identidad y aislamiento

Un usuario puede pertenecer a varios tenants. El tenant es la unidad de aislamiento y habilitación de módulos; una empresa es una entidad organizativa dentro del tenant, no su sinónimo. La pertenencia activa, el rol, los permisos y el contexto de tenant delimitan las operaciones. El catálogo backend no implica disponibilidad de pantallas frontend.

El backend autentica y valida el actor antes de establecer contexto transaccional PostgreSQL. RLS complementa la autorización; no autentica por sí solo los valores de contexto. Auditar operaciones con actor, tenant y correlación sin prompts, respuestas ni credenciales. Usar idempotencia para operaciones repetibles, sin cruzar usuarios u operaciones.

## Arquitectura y repositorios

Flujo objetivo: usuario → App Shell/Uonify → API o herramienta MCP → módulo propietario → datos y auditoría. Los contratos de cada módulo deben fijar entradas, permisos, errores y resultados. Los conectores técnicos viven en integraciones; Digital Sales gobierna sus capacidades comerciales.

| Repositorio | Responsabilidad |
| --- | --- |
| mastererp-platform | frontend/app-shell, frontend/modules, backend/modules y código compartido |
| mastererp-infrastructure | Recursos funcionales AWS, Lambdas y API Gateway compartidos |
| mastererp-database | RDS, red asociada a datos, migrador, schemas, seeds y pruebas SQL |

Las cuatro capas replican rutas funcionales; directorios técnicos internos no requieren duplicación. Un recurso se declara una sola vez y los compartidos pertenecen al padre común. Los YAML vacíos son reservas excluidas de despliegue.

## Dominios funcionales

0 Uonify; 1.0 Plataforma Base (1.1 onboarding, 1.2 gestión, 1.3 shell); 2.1 Catálogo; 2.2 Finanzas; 2.3 Operaciones; 2.4 Digital Sales; 2.5 Servicios; 2.6 Centro de Agentes; 2.7 Recursos Humanos; 2.8 Productividad; 2.9 POS; 2.10 Transporte; 2.11 Seguridad. Marketing es 2.8.2, MasterCRM 2.8.3, Google Workspace 2.8.4 y Microsoft 365 2.8.5. Transporte incluye Chipipro y MRW; no existe Despacho. Registro detallado en [MODULE_REGISTRY](docs/MODULE_REGISTRY.md).

## Estado comprobado y pendientes

Frontend: el hosting independiente de Finanzas DEV está publicado como página inicial pública; el dashboard y las pantallas de Clientes/Proveedores están integrados y probados en Uonify DEV. La página inicial fue sustituida por el primer recorrido autorizado de Clientes/Proveedores; ver el contrato frontend enlazado arriba.

Según la ejecución reportada del commit 454fec7 de database, la autorización SQL de onboarding se aplicó y reaplicó en RDS DEV us-west-1, con pruebas efectivas como mastererp_app: propietario, miembro, ajeno, contexto, sesiones, idempotencia y primitivas de aprovisionamiento SQL. Esto no prueba el backend completo. Evidencia: https://github.com/eticayservicios/mastererp-database/actions/runs/41310430235.

Platform contiene implementación Python de onboarding y seguridad compartida; el primer recorrido de Clientes/Proveedores ya se integra en Uonify y en el acceso independiente de Finanzas; las demás capacidades siguen pendientes. La existencia de carpetas no acredita funcionalidad. Infrastructure conserva definiciones en transición: aún hay que preservar integraciones, autorización y propiedad del Admin API al consolidar stacks. La Lambda migradora oficial pertenece a database; código histórico adicional no implica una segunda función autorizada. No inferir estado AWS actual sin consulta explícita.


## Definición progresiva y responsabilidades

Los módulos comienzan con objetivos generales y límites de responsabilidad. No es obligatorio especificar todos los módulos, requisitos o contratos por adelantado: el detalle de cada tarea se define cuando se prioriza.

El Product Owner ampliará progresivamente los objetivos, prioridades, reglas de negocio y criterios de aceptación. Cada desarrollador elaborará la solución técnica y actualizará la documentación del módulo conforme avance, conservando los objetivos generales y límites acordados.

Las IA pueden resolver decisiones técnicas dentro de los estándares y contratos vigentes. Las decisiones funcionales no definidas se marcan como pendientes y se acuerdan con el Product Owner antes de implementar el comportamiento afectado; el trabajo independiente puede continuar. No inventar requisitos ni expandir artificialmente los README para simular una especificación completa.

## Mapa y sincronización documental

Leer [README](README.md), [AGENTS](AGENTS.md), [CONTRIBUTING](CONTRIBUTING.md), [estándar de desarrollo](docs/DEVELOPMENT_STANDARD.md), [carpetas](docs/FOLDER_STANDARD.md) y registro. Consultar arquitectura, propiedad e integraciones donde el mapa de cada README los enlace.

Fuente oficial del contenido común: mastererp-platform/PROJECT.md en dev. Cambiar primero esa copia, copiar el archivo completo sin modificaciones a los otros dos repositorios y comparar SHA-256 antes de proponer revisión. Si solo se dispone de uno, registrar propuesta/copia pendiente y no afirmar sincronización. Revisar estados con evidencia y actualizar los tres en la misma entrega; no publicar ni desplegar implícitamente.

## Propiedad de recursos y carpetas de Lambdas

Regla vigente: en Infrastructure, cada módulo, submódulo, pantalla o subpantalla declara sus recursos exclusivos en `resources.yml` ubicado directamente en la raíz de esa carpeta funcional. Ese único archivo puede declarar cero, una o varias Lambdas, sus roles, Log Groups y demás recursos propios. No se crea un YAML, una carpeta de infraestructura ni un stack por cada Lambda.

`lambdas/<nombre>/` es una carpeta técnica de código en Platform Backend, con su handler y documentación; no obliga a replicar esa carpeta en Infrastructure, frontend o Database. La correspondencia entre capas se mantiene en la carpeta funcional propietaria. Frontend y Database no añaden YAML de infraestructura por esta regla; se conservan las plantillas técnicas de datos existentes en Database.

Los recursos compartidos se declaran una sola vez en el `resources.yml` del padre funcional común más cercano. Los API Gateway compartidos conservan `modules/api-gateways.yml` y su stack propietario vigente durante la transición. Los consumidores reciben referencias explícitas mediante parámetros/salidas documentados. No duplicar declaraciones en padre e hijo. Un YAML vacío es una reserva excluida del despliegue; no implica crear una Lambda.

Las plantillas preexistentes bajo `lambdas/<nombre>/resources.yml` son excepciones heredadas pendientes de revisión y transición, no ejemplos para nuevas funciones. No moverlas, copiarlas, vaciarlas ni desplegarlas por aplicar esta regla documental: primero identificar el stack propietario, preservar sus recursos y preparar una transición explícita autorizada. Documentar su ubicación real hasta completar esa transición.
