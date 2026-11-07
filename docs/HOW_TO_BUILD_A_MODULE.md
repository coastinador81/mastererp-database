# Cómo desarrollar un módulo

Leer [contexto](../PROJECT.md), [carpetas](FOLDER_STANDARD.md) y [estándar](DEVELOPMENT_STANDARD.md).
Aplicar además el [patrón verificable](IMPLEMENTATION_PATTERN.md), incluida la
regla de máximo 500 líneas de código fuente por archivo.

1. Identificar módulo, submódulo o pantalla y su dominio propietario.
2. Leer su README y los padres pertinentes.
3. Para la tarea priorizada, acordar alcance, reglas y aceptación con Product Owner.
4. Buscar código, datos y recursos existentes antes de duplicarlos.
5. Definir entradas, resultados, errores, permisos y contratos necesarios antes de integrar.
6. Identificar cambios en frontend, backend, datos e infraestructura.
7. Implementar en rutas funcionales equivalentes, sin replicar directorios técnicos internos.
8. Documentar recursos compartidos, su plantilla de origen y parámetros/salidas que conectan consumidores.
9. Ejecutar python scripts/validate_structure.py y pruebas proporcionales; informar omitidas.
10. Actualizar README con evidencia y pendientes y entregar diff. Publicar solo con autorización; revisar disparadores de workflows.

No especificar todo el producto de antemano. El Product Owner amplía prioridades y comportamiento; desarrollador e IA resuelven decisiones técnicas dentro del estándar. Un comportamiento funcional desconocido queda pendiente antes de implementarse.

## Ejemplo ilustrativo; no son carpetas ni recursos implementados

| Elemento ilustrativo | Platform frontend | Platform backend | Database | Infrastructure |
| --- | --- | --- | --- | --- |
| Módulo | `frontend/modules/2.3-ecommerce/2.3.4-catalog/` | `backend/modules/2.3-ecommerce/2.3.4-catalog/` | `modules/2.3-ecommerce/2.3.4-catalog/` | `modules/2.3-ecommerce/2.3.4-catalog/` |
| Submódulo | `frontend/modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/` | `backend/modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/` | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/` | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/` |
| Pantalla listado | `frontend/modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/list/` | `backend/modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/list/` | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/list/` | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/list/` |
| Pantalla detalle | `frontend/modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/` | `backend/modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/` | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/` | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/` |
| Subpantalla historial | `frontend/modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/screens/history/` | `backend/modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/screens/history/` | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/screens/history/` | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/screens/history/` |

| Alcance ilustrativo | Declaración en Infrastructure |
| --- | --- |
| General compartido | Raíz funcional `modules/`; API ya declaradas en `modules/api-gateways.yml`, sin duplicarlas |
| Común del módulo | `modules/2.3-ecommerce/2.3.4-catalog/resources.yml` |
| Común del submódulo | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/resources.yml` |
| Pantalla sin recursos propios | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/list/resources.yml` vacío y excluido del despliegue |
| Subpantalla con recurso exclusivo | `modules/2.3-ecommerce/2.3.4-catalog/2.3.4.1-products/screens/detail/screens/history/resources.yml`, cuando se implemente |

Todo el ejemplo es ilustrativo: no acredita carpetas o recursos implementados ni es una plantilla desplegable. Cada carpeta funcional tiene README; solo Infrastructure añade resources.yml. Los consumidores reciben referencias explícitas mediante parámetros/salidas documentados. Cada recurso se declara una sola vez y, si es compartido, en el padre común más cercano. Se pueden consumir recursos de distintos niveles. Las carpetas no conectan stacks automáticamente; un stack puede abarcar varias carpetas. Una pantalla no exige Lambda, API ni stack.

## Datos y ejecución reales

Database modules/ es correspondencia funcional documental: no se ejecuta automáticamente. El despliegue copia schema/*.sql, seeds/*.sql y tests/*.sql al paquete. El handler migrations/lambda/handler.py define SCHEMA_FILES, SEED_FILES y TEST_FILES y el orden efectivo. Una tarea SQL debe añadir el archivo en el directorio apropiado, actualizar el manifiesto del handler si debe ejecutarse y aportar pruebas. Evitar colisiones de nombres porque el empaquetado aplana las rutas. Revisar schemas ya existentes y documentación de permisos. Push a dev en rutas observadas por los workflows puede desplegar y aplicar SQL; una tarea documental no autoriza ese push.

## Infrastructure actual

Las definiciones reorganizadas no son todavía un despliegue consolidado equivalente a AWS. Falta preparar el empaquetado del código backend de Platform, publicar artefactos autorizados y conectar referencias entre plantillas/stacks conservando API, rutas, autorización y permisos. Ver RESOURCE_OWNERSHIP.md cuando exista en este repo; no dar por migrada la propiedad del Admin API. No crear un stack por carpeta por defecto.


## Propiedad de recursos y carpetas de Lambdas

Regla vigente: en Infrastructure, cada módulo, submódulo, pantalla o subpantalla declara sus recursos exclusivos en `resources.yml` ubicado directamente en la raíz de esa carpeta funcional. Ese único archivo puede declarar cero, una o varias Lambdas, sus roles, Log Groups y demás recursos propios. No se crea un YAML, una carpeta de infraestructura ni un stack por cada Lambda.

`lambdas/<nombre>/` es una carpeta técnica de código en Platform Backend, con su handler y documentación; no obliga a replicar esa carpeta en Infrastructure, frontend o Database. La correspondencia entre capas se mantiene en la carpeta funcional propietaria. Frontend y Database no añaden YAML de infraestructura por esta regla; se conservan las plantillas técnicas de datos existentes en Database.

Los recursos compartidos se declaran una sola vez en el `resources.yml` del padre funcional común más cercano. Los API Gateway compartidos conservan `modules/api-gateways.yml` y su stack propietario vigente durante la transición. Los consumidores reciben referencias explícitas mediante parámetros/salidas documentados. No duplicar declaraciones en padre e hijo. Un YAML vacío es una reserva excluida del despliegue; no implica crear una Lambda.

Las plantillas preexistentes bajo `lambdas/<nombre>/resources.yml` son excepciones heredadas pendientes de revisión y transición, no ejemplos para nuevas funciones. No moverlas, copiarlas, vaciarlas ni desplegarlas por aplicar esta regla documental: primero identificar el stack propietario, preservar sus recursos y preparar una transición explícita autorizada. Documentar su ubicación real hasta completar esa transición.


## Ejemplo ilustrativo: varias Lambdas de un mismo submódulo

En Infrastructure, la ubicación propietaria es `modules/2.2-finance/2.2.1-administration/2.2.1.1-gestion-comercial/2.2.1.1.1-clientes/resources.yml`. Allí se declaran las Lambdas exclusivas de Clientes y sus recursos; no se crea `lambdas/<nombre>/resources.yml`.

En Platform, el código correspondiente se ubica en `backend/modules/2.2-finance/2.2.1-administration/2.2.1.1-gestion-comercial/2.2.1.1.1-clientes/lambdas/mastererp-dev-adm-clientes/handler.py`. Si Clientes necesita otra función, su código recibe otra carpeta dentro de `lambdas/`, pero ambas funciones se declaran en el mismo `resources.yml` raíz de Clientes en Infrastructure.

Las pantallas siguen la misma regla: cada `screens/<pantalla>/resources.yml` declara solo sus recursos exclusivos; los compartidos con otra pantalla pertenecen al padre común. Este ejemplo no acredita código, recursos ni despliegues implementados.
