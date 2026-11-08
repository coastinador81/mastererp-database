# Plantilla breve de README funcional

Ejemplo para copiar al priorizar trabajo; no inventar datos para rellenar secciones.

## Nombre y código funcional

Nombre/código o ruta de pantalla.

## Objetivo

Objetivo general; detalle de la tarea priorizada.

## Responsabilidad y exclusiones

Qué posee y qué pertenece a otro dominio.

## Propietario

Dominio funcional; responsable nominal asignado o pendiente de definir.

## Correspondencia entre capas

Rutas frontend, backend, database e infrastructure. No aplica con motivo si corresponde.

## Dependencias y contratos

Entradas, resultados, permisos y errores de la tarea; pendientes explícitos.

## Recursos

Propios y compartidos consumidos: origen, parámetros/salidas y conexión. No aplica con explicación.

## Estado y evidencia

Reserva, parcial, implementado o validado; archivo/prueba/ejecución que lo acredita.

## Validaciones y pendientes

Comandos ejecutados, resultados y límites. Pendiente de definir con motivo cuando proceda.


## Plantilla propietaria de infraestructura

Indicar el resources.yml raíz de esta carpeta funcional en Infrastructure; listar las Lambdas y recursos exclusivos que declara. Para recursos compartidos, indicar el YAML del padre común y las referencias consumidas. Código Backend en lambdas/<nombre>/; no crear YAML por Lambda. Si existe una plantilla heredada por función, identificarla y documentar la transición pendiente sin duplicarla ni moverla implícitamente.

<!-- ux-ui-standard:start -->
## UX/UI cuando exista interfaz

Enlazar el [estándar común UX/UI](../UX_UI_STANDARD.md) con la ruta relativa correcta desde el README nuevo. Resumir Inter regular, tabla 14 px/peso 400/#667085, menú blanco, fondo #F6F8FC, acentos azules, foco visible e iconos de línea. Reutilizar componentes y tokens; conservar contexto y permisos. Documentar layout aplicable, comportamientos reales, pruebas visuales y variantes justificadas. Una capa sin UI enlaza su contraparte frontend; no crea estilos o pantallas para llenar esta sección. Mantener los objetivos generales y el estado real sin inventar requisitos.
<!-- ux-ui-standard:end -->
