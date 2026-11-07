# Validación local previa a la publicación de la renumeración

Fecha: 2026-11-07. Alcance: reorganización fuente autorizada en dev de los tres repositorios, sin commit, push, SQL remoto ni despliegue.

## Comprobaciones aprobadas

- Correspondencia exacta de 109 carpetas numeradas y 7 carpetas de pantalla entre frontend, backend, Database e Infrastructure (116 rutas funcionales por capa).
- `py scripts/validate_structure.py` y `git diff --check` en los tres repositorios.
- SHA-256 idéntico entre repositorios para PROJECT.md, FRONTEND_ARCHITECTURE.md, MODULE_RENUMBERING.md, MODULE_RENUMBERING_MAP.json, MODULE_REGISTRY.md y HOW_TO_BUILD_A_MODULE.md.
- Enlaces relativos Markdown: sin referencias rotas en la revisión local. Enlaces versionados históricos conservan sus commits originales.
- Integridad frente al respaldo previo: los 1.423 archivos originales están presentes en su ruta destino; no se perdió código ni trabajo local. Todos los SQL conservan sus bytes; ninguna migración, seed o prueba SQL fue modificada. La lógica Python de los módulos conserva sus bytes; solo los empaquetadores usan localización independiente de profundidad para los archivos compartidos.
- Las 122 plantillas anteriores de Infrastructure se compararon semánticamente con el respaldo: sin diferencias de recursos, propiedades, parámetros ni outputs. Las reservas nuevas son YAML vacíos y quedan excluidas del despliegue.
- Manifiestos Platform/Infrastructure: 12 capacidades existentes resuelven sus directorios nuevos; los identificadores de stacks y funciones permanecen iguales.
- Sintaxis: 13 workflows YAML y 33 bloques Bash comprobados con `bash -n`. AST de 274 archivos Python sin ejecutar handlers ni pruebas backend.
- Build estándar de Finanzas y Uonify aprobado. Ecommerce compiló usando React/Vite ya disponibles en Finanzas, sin instalación, con las opciones de build equivalentes y aliases locales de dependencias.
- 16 pruebas Node de navegación Finanzas/Ecommerce y autenticación frontend aprobadas.
- Navegador local: once tarjetas de aplicación acordadas, ausencia de aplicaciones retiradas, límites del panel móvil y Escape aprobados, bloqueando todas las peticiones externas. El servidor local de Finanzas fue reiniciado en http://127.0.0.1:5180/.

## Límites y fallos previos comprobados

- El `npm run build` directo de Ecommerce está bloqueado porque su carpeta no tiene Vite instalado. No se instalaron dependencias; la compilación alternativa anterior no equivale a ejecutar su pipeline remoto.
- No se ejecutó el build Expo de Storefront; faltan sus dependencias locales. Sus fuentes e imports se conservaron y se revisaron estáticamente. El build de CI sigue pendiente de una futura publicación autorizada.
- El validador legado `validate_phase5.py` de Platform falla por la comprobación textual `mastererpAuth` de Productos. Se ejecutó el mismo validador sobre una copia del respaldo anterior y produjo el mismo fallo: `runtime auth contract missing: 2.1-catalog/2.1.1-products` (ruta histórica).
- El equivalente de Infrastructure falla por el reconocimiento de la ruta pública `PublicCatalogRouteV2`; se reprodujo el mismo fallo sobre el respaldo anterior: `route authorization mismatch: 2.4-digital-sales/2.4.2-ecommerce/PublicCatalogRouteV2` (ruta histórica). No se modificó la autorización para hacer pasar el validador.
- No se realizaron pruebas funcionales backend, SQL/RLS, empaquetado binario Linux, HTTP real, DNS, Cognito ni recursos AWS. Los controles estructurales no acreditan esas capacidades.

## Publicación y recuperación pendientes

Los cambios siguen locales, junto con modificaciones previas del equipo conservadas. No utilizar `git add .` ni publicar indiscriminadamente. Revisar los cambios propios y el mapa antes de un commit coordinado. Los filtros de workflows actualizados siguen los archivos movidos y pueden publicar frontend al hacer push; Database no cambió schema/seeds/tests/migrador y sus movimientos documentales no corresponden a los paths actuales de aplicación SQL.

Para recuperación local existe un respaldo de archivos, diffs y mapa archivo origen → destino fuera de los repositorios; no contiene una nueva credencial ni se publica. Recuperar solo archivos concretos y conciliar cualquier trabajo posterior. No usar reset/clean global ni restaurar RDS para deshacer una reorganización fuente. La propiedad efectiva de los stacks permanece vigente conforme a los manifiestos existentes.
