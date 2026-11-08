# Estándar UX/UI de MasterERP

Fuente oficial: Platform/dev, `docs/UX_UI_STANDARD.md`. Database e Infrastructure conservan copias idénticas de este documento y su imagen de referencia. Los README de módulo resumen este contrato y enlazan la fuente; no mantienen paletas alternativas.

## Alcance y estado

El patrón acordado es la interfaz administrativa de Finanzas/Proveedores: menú blanco, fondo gris azulado muy claro, acentos azules, tipografía Inter regular, superficies limpias e iconos de línea. Es la referencia para desarrollar y revisar las interfaces administrativas de los módulos de MasterERP.

La implementación de referencia está en Finanzas; documentar este estándar no significa que los demás módulos ya lo apliquen. Se adopta al crear o modificar sus interfaces, conservando objetivos, datos, contratos y cambios del equipo. Esta entrega es documental y no rediseña aplicaciones existentes.

Uonify/chat, POS y storefront pueden necesitar composiciones diferentes según su responsabilidad. Reutilizan la identidad y los componentes compatibles; el menú administrativo y la tabla no se imponen a toda experiencia. Una necesidad de layout se documenta en el módulo; una decisión funcional pendiente se acuerda con el Product Owner. No se cambia la arquitectura ni la integración por una preferencia estética.

Leer también [arquitectura frontend](FRONTEND_ARCHITECTURE.md), [desarrollo](DEVELOPMENT_STANDARD.md) y [carpetas](FOLDER_STANDARD.md).

## Referencia visual

[Abrir imagen de referencia](assets/ux-ui/supplier-reference.png).

La imagen «Refined Supplier Dashboard Typography» define la composición y el acabado. Los valores siguientes concretan el contrato visual. Tumandaito, los nombres DEMO y las ocho filas de la imagen son ejemplos: no se codifican como datos, contadores, permisos o selección de empresa del producto.

## Tipografía y colores

| Elemento | Regla común |
| --- | --- |
| Fuente | Inter, preferiblemente alojada en el proyecto, con fallback `sans-serif`. Conservar su licencia y evitar peticiones externas de fuentes cuando se reutilice la versión local. |
| Texto general | `#4B5563`, peso 400; base de 14 px. |
| Texto secundario | `#667085`; no suavizar mediante opacidad del contenedor. |
| Título principal | `#374151`, peso 500, aproximadamente 28–34 px en escritorio según la jerarquía; 26–28 px en móvil. |
| Celdas de tabla | 14 px, peso 400 y `#667085`, incluidos códigos, nombres, enlaces y cantidades. Sin negrita ni subrayado permanente para destacar la primera columna. |
| Encabezados de tabla | 14 px, peso 400, fondo `#F4F7FB`, texto `#667085`. |
| Fondo general | `#F6F8FC`. |
| Superficies y menú | Blanco `#FFFFFF`. |
| Bordes y separadores | Finos, `#E8EDF3`; controles con borde `#D8E2F0` cuando corresponda. |
| Acción principal | Azul `#096BDC`, texto blanco; hover `#0758B3`. |
| Acento y selección | Azul claro `#93C5FD` y superficie `#EFF6FF`. |
| Hover de fila | `#F1F6FD`, discreto. |
| Fila con foco | `#EFF6FF`, con foco visible en el control activo. |
| Contorno de teclado | `#3B82F6`, 2 px y separación visible. |

Mantener al menos 4,5:1 para texto normal y 3:1 para indicadores de foco. Verificar los colores de texto sobre blanco, encabezados, hover y selección. La referencia actual da aproximadamente 4,97:1 sobre blanco, 4,63:1 en encabezados, 4,58:1 en hover y 4,57:1 en foco; no bajar el contraste mediante un azul más oscuro detrás de `#667085`.

Los estados de éxito, advertencia y error también llevan texto o icono comprensible, además del color. Conservar los estados semánticos del producto; no inventar una aprobación, conexión o resultado exitoso por el diseño de un badge.

## Tokens, componentes y propiedad

- Centralizar colores, tipografía, espacios, radios y sombras en variables reutilizables. Escala de espaciado: 4, 8, 12, 16, 20, 24 y 32 px; reutilizarla para alineaciones y separaciones.
- Radios orientativos: 8 px en controles, 12–16 px en tarjetas. Bordes discretos y sombras mínimas; superficies sin opacidad global.
- Contenido centrado con máximo aproximado de 1480 px y columnas que permitan encoger el área principal. Menú de referencia de unos 256 px y encabezado de unos 80 px en escritorio; son dimensiones del shell, no alturas rígidas para todo contenido.
- Reutilizar encabezados, breadcrumbs, botones, iconos, campos, tablas, paginación y estados existentes. Buscar antes de crear otro componente o una dependencia de iconos.
- La implementación actual usa variables `--finance-*` y alcance `.finance-app`. No importar esa hoja esperando que aplique automáticamente a otra aplicación ni añadir esa clase a Uonify para forzar su apariencia.
- Al necesitar una base compartida para otro módulo, extraer o adaptar los componentes en su propietario técnico común de Platform, conservando estos valores y revisando consumidores. No duplicar una paleta o una fuente por módulo. La existencia de esta guía no acredita una biblioteca visual compartida ya implementada.

Referencias de código existentes, verificadas en Platform:

- [Tokens y estilos de Finanzas](https://github.com/eticayservicios/mastererp-platform/blob/dev/frontend/modules/2.2-finance/src/finance.css).
- [Iconos de línea](https://github.com/eticayservicios/mastererp-platform/blob/dev/frontend/modules/2.2-finance/src/FinanceIcon.jsx) y [navegación](https://github.com/eticayservicios/mastererp-platform/blob/dev/frontend/modules/2.2-finance/src/FinanceNavigation.jsx).
- [Listado y buscador de Proveedores](https://github.com/eticayservicios/mastererp-platform/blob/dev/frontend/modules/2.2-finance/2.2.1-administration/screens/parties/SupplierDirectory.jsx) y [fila accesible](https://github.com/eticayservicios/mastererp-platform/blob/dev/frontend/modules/2.2-finance/2.2.1-administration/screens/parties/SupplierRow.jsx).
- [Fuente local y procedencia](https://github.com/eticayservicios/mastererp-platform/blob/dev/frontend/modules/2.2-finance/src/assets/fonts/README.md).

## Composición de una pantalla administrativa

1. Conservar el shell, identidad y contexto comunes; no duplicar un menú o encabezado dentro de una pantalla integrada.
2. Mostrar breadcrumb basado en la navegación existente. No crear enlaces a rutas que no existan solo porque en la referencia un texto aparece azul.
3. Presentar título, descripción breve cuando ayude y acción principal con nombre explícito, como «Crear proveedor». El icono acompaña al texto.
4. Agrupar listado y herramientas necesarias en una superficie blanca. Añadir búsqueda, filtros, métricas o acciones solo cuando estén dentro del alcance y funcionen con los contratos reales.
5. Colocar conteo y paginación de forma consistente: resumen a la izquierda y controles a la derecha en escritorio; disposición flexible en móvil.
6. Mostrar carga, vacío, error, acceso denegado y conflicto con mensajes claros. Un fallo de servicio no se convierte en lista vacía ni en éxito simulado.

Los objetivos y reglas particulares del módulo siguen en su README y contratos. Este patrón no obliga a que cada módulo tenga una tabla, un buscador o una Lambda por pantalla.

## Tablas y navegación a fichas

- En listados con ficha, la fila puede abrir el registro mediante la navegación vigente. El nombre conserva un enlace HTML real con `href`, foco por teclado, Enter, clic modificado, menú contextual y apertura en otra pestaña.
- Conservar semántica de tabla y una secuencia de foco útil. No convertir la fila en otro botón o enlace que duplique el acceso por teclado al nombre.
- Respetar selección de texto y controles internos: enlaces, botones, etiquetas, casillas, campos y contenido editable. No interceptar gestos del navegador ni provocar dos navegaciones por un único clic.
- Mostrar hover y foco suaves. El enlace puede subrayarse al interactuar, pero no permanece subrayado como estilo normal de tabla.
- Evitar una columna redundante «Acción / Ver detalle» cuando el nombre y la fila ya ofrecen ese acceso. Conservar otras acciones reales necesarias, sin ocultarlas para copiar una captura.
- Derivar columnas y datos del contrato del módulo. Las cinco columnas de Proveedores no sustituyen las columnas legítimas de otro dominio; quitar una columna visual no elimina campos del modelo.
- Calcular contadores con los datos disponibles: «Mostrando N en esta página» si no se conoce el total. No fijar el número de filas de la referencia.

## Búsqueda y paginación reales

El buscador tiene etiqueta accesible, icono decorativo y placeholder que indique qué campos busca. Debe mantener su estado de carga, resultados sin coincidencias, limpieza, errores y navegación por teclado.

Antes de implementarlo, verificar los parámetros y campos reales de la API. No enviar un `search` o `q` que el backend no admite, ni presentar un filtro sobre la página actual como búsqueda completa del directorio.

Para grandes volúmenes, preferir búsqueda y paginación en servidor con un contrato explícito en el módulo propietario. La primera implementación de Proveedores recorre páginas autorizadas de la API existente y filtra en memoria; es una solución frontend de alcance limitado, no el patrón obligatorio de acceso a datos para todos los módulos. Su índice vive solo en la vista y el contexto actual.

Vincular solicitudes y cachés a identidad, tenant y empresa autorizados. Al cambiar contexto, cancelar o descartar respuestas anteriores y limpiar resultados. No guardar un índice global ni materializarlo en almacenamiento persistente como atajo. Si falla una página, indicar el fallo; no anunciar una búsqueda parcial como completa.

## Iconografía y responsive

- Usar SVG de línea fina, normalmente 18–20 px, trazo aproximado de 1,5 px, extremos y uniones redondeados. Iconos decorativos con `aria-hidden`; botones de solo icono con nombre accesible.
- Mantener la alineación entre iconos, etiquetas, badges y chevrons. Los iconos no sustituyen textos necesarios ni introducen operaciones ficticias.
- En móvil, conservar márgenes laterales de unos 16 px, controles cómodos y un menú lateral que se abre y cierra mediante la navegación existente.
- Las tablas anchas pueden desplazarse horizontalmente dentro de su contenedor. No provocar desbordamiento horizontal de toda la página ni reducir el texto para hacer caber todas las columnas.
- Asegurar foco visible y uso con teclado, tanto en formularios como en menús, búsqueda, enlaces y paginación.

## Datos, permisos y alcance

Cognito autentica y las APIs de MasterERP autorizan. Menús, URLs, colores, badges o el contexto enviado desde el navegador no conceden acceso. Conservar los contratos de tenant/empresa, permisos, módulos habilitados, idempotencia y versiones que correspondan.

No copiar datos de ejemplo al runtime, fijar el tenant Tumandaito, simular funciones por aparecer en la imagen ni inventar reglas fiscales, estados o requisitos funcionales. Las fixtures se limitan a pruebas; nunca son un fallback del servicio desplegable.

## Trabajo del desarrollador y su IA

1. Leer AGENTS, este estándar, el contrato frontend y el README del módulo antes de modificar una interfaz.
2. Revisar la implementación real y sus dependencias. Reutilizar componentes y tokens compatibles, conservando el trabajo existente.
3. Mantener este acabado y documentar en el README las variantes justificadas, el comportamiento real, las pruebas y los pendientes. El Product Owner define las decisiones funcionales no acordadas; la IA resuelve decisiones técnicas dentro de los estándares.
4. Si hay una desviación, advertir con archivo, consecuencia y recomendación concreta. Corregir la parte autorizada y continuar el trabajo independiente; no inventar un flujo de aprobación para decisiones rutinarias.
5. Comprobar build, validadores y `git diff --check`, más interacción de filas, selección de texto, controles, teclado, nueva pestaña, búsqueda, paginación y cambios de contexto cuando apliquen.
6. Revisar capturas de escritorio y móvil, incluyendo hover y foco; medir los contrastes relevantes. Las pruebas locales con fixtures no acreditan integración en DEV.
7. Publicar o desplegar únicamente dentro de la autorización del propietario y revisar qué workflows activa un push.

El estándar guía la implementación y revisión. No añade protección de ramas, workflows obligatorios ni una migración automática de interfaces existentes.

## Mantenimiento

Editar primero esta guía en Platform/dev y sincronizar el documento y la imagen completos en Database e Infrastructure, después de revisar sus cambios locales. Comparar SHA-256 y enlaces. Los README de módulos mantienen un resumen y referencia; las modificaciones de contrato se hacen aquí, no en múltiples versiones de la paleta.

Las nuevas carpetas funcionales deben incluir la referencia UX/UI en su README usando la plantilla vigente. Las instrucciones de `frontend/AGENTS.md` se heredan en Platform; no es necesario copiar un AGENTS con reglas divergentes en cada módulo.
