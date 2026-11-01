# Cómo desarrollar un módulo

Leer [contexto](../PROJECT.md), [carpetas](FOLDER_STANDARD.md) y [estándar](DEVELOPMENT_STANDARD.md).

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

| Nivel | Ruta relativa equivalente en las cuatro capas | Recursos ilustrativos |
| --- | --- | --- |
| General | raíz modules/ | API compartida existente: modules/api-gateways.yml, sin duplicarla |
| Módulo | 2.1-catalog/ | Un recurso común del catálogo, solo si se necesita |
| Submódulo | 2.1-catalog/2.1.1-products/ | Dependencia propia compartida por sus pantallas, si procede |
| Pantalla sin recursos | …/screens/list/ | resources.yml vacío; consume API general y recurso de catálogo |
| Subpantalla exclusiva | …/screens/detail/screens/history/ | Un recurso exclusivo ilustrativo, pendiente de diseño |

Prefijos: Platform frontend/modules/ y backend/modules/; Database modules/; Infrastructure modules/. Cada carpeta funcional tiene README; solo Infrastructure añade resources.yml. Los recursos del ejemplo no son plantillas ni una autorización para crear AWS. Cada consumidor documenta referencias que recibe del padre u otro nivel; carpeta y stack son conceptos distintos. Un stack puede incluir varias carpetas. Una pantalla no exige Lambda, API ni stack.

## Datos y ejecución reales

Database modules/ es correspondencia funcional documental: no se ejecuta automáticamente. El despliegue copia schema/*.sql, seeds/*.sql y tests/*.sql al paquete. El handler migrations/lambda/handler.py define SCHEMA_FILES, SEED_FILES y TEST_FILES y el orden efectivo. Una tarea SQL debe añadir el archivo en el directorio apropiado, actualizar el manifiesto del handler si debe ejecutarse y aportar pruebas. Evitar colisiones de nombres porque el empaquetado aplana las rutas. Revisar schemas ya existentes y documentación de permisos. Push a dev en rutas observadas por los workflows puede desplegar y aplicar SQL; una tarea documental no autoriza ese push.

## Infrastructure actual

Las definiciones reorganizadas no son todavía un despliegue consolidado equivalente a AWS. Falta preparar el empaquetado del código backend de Platform, publicar artefactos autorizados y conectar referencias entre plantillas/stacks conservando API, rutas, autorización y permisos. Ver RESOURCE_OWNERSHIP.md cuando exista en este repo; no dar por migrada la propiedad del Admin API. No crear un stack por carpeta por defecto.
