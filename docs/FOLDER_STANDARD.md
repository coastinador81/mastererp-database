# Estándar de carpetas funcionales

## Pantallas y recursos compartidos

Convención mínima: screens/<slug-kebab-case>/; una subpantalla usa screens/<pantalla>/screens/<subpantalla>/. Sus rutas funcionales corresponden en las cuatro capas, sin convertirlas en módulos numerados. No mover rutas técnicas existentes para simular correspondencia. Cada carpeta de pantalla/subpantalla tiene README y, solo en Infrastructure, resources.yml.

Un recurso se declara una sola vez en el padre común más cercano. modules/ aloja recursos de alcance general; los API existentes en api-gateways.yml no se duplican. Los consumidores documentan origen y parámetros/salidas incluso al consumir distintos niveles. Las carpetas no conectan stacks automáticamente ni exigen un stack por carpeta. Una pantalla o YAML no implica Lambda/API/stack. YAML sin recursos permanece vacío, excluido del despliegue. Ver [guía con ejemplo ilustrativo](HOW_TO_BUILD_A_MODULE.md) y [plantilla README](templates/MODULE_README_TEMPLATE.md).

Cada módulo, submódulo y pantalla tiene README.md. Las cuatro capas mantienen nombres y rutas funcionales coincidentes. Nuevos submódulos se añaden correlativamente sin renumerar los existentes.

Infrastructure declara recursos propios en resources.yml. Un YAML vacío reserva ubicación: NO es una plantilla desplegable y debe excluirse del empaquetado y despliegue. Los recursos compartidos se definen una sola vez en el padre común. api-gateways.yml en modules es la definición compartida existente; no duplicarla en resources.yml.

Backend implementa la Lambda en lambdas/<nombre>/handler.py; frontend implementa pantallas en screens/<nombre>/; database mantiene SQL. Usar los mismos nombres para la correspondencia. Sin implementación, solo README; no crear código vacío ni inventar pantallas.

Las plantillas separadas de onboarding siguen pendientes de equivalencia con AWS y migración de propiedad. No desplegarlas automáticamente ni recrear las funciones eliminadas. Directorios técnicos internos de Python no se replican entre capas. El desarrollador debe replicar nuevas carpetas funcionales y documentar dependencias en las cuatro capas.


## Propiedad de recursos y carpetas de Lambdas

Regla vigente: en Infrastructure, cada módulo, submódulo, pantalla o subpantalla declara sus recursos exclusivos en `resources.yml` ubicado directamente en la raíz de esa carpeta funcional. Ese único archivo puede declarar cero, una o varias Lambdas, sus roles, Log Groups y demás recursos propios. No se crea un YAML, una carpeta de infraestructura ni un stack por cada Lambda.

`lambdas/<nombre>/` es una carpeta técnica de código en Platform Backend, con su handler y documentación; no obliga a replicar esa carpeta en Infrastructure, frontend o Database. La correspondencia entre capas se mantiene en la carpeta funcional propietaria. Frontend y Database no añaden YAML de infraestructura por esta regla; se conservan las plantillas técnicas de datos existentes en Database.

Los recursos compartidos se declaran una sola vez en el `resources.yml` del padre funcional común más cercano. Los API Gateway compartidos conservan `modules/api-gateways.yml` y su stack propietario vigente durante la transición. Los consumidores reciben referencias explícitas mediante parámetros/salidas documentados. No duplicar declaraciones en padre e hijo. Un YAML vacío es una reserva excluida del despliegue; no implica crear una Lambda.

Las plantillas preexistentes bajo `lambdas/<nombre>/resources.yml` son excepciones heredadas pendientes de revisión y transición, no ejemplos para nuevas funciones. No moverlas, copiarlas, vaciarlas ni desplegarlas por aplicar esta regla documental: primero identificar el stack propietario, preservar sus recursos y preparar una transición explícita autorizada. Documentar su ubicación real hasta completar esa transición.
