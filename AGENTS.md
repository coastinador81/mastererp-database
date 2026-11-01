# Instrucciones para IA

Antes de modificar archivos, leer README.md, CONTRIBUTING.md y docs/FOLDER_STANDARD.md. Estas instrucciones no sustituyen las indicaciones explícitas del propietario ni las políticas del entorno.

## Responsabilidad de este repositorio

RDS, migrador, SQL, seeds, pruebas y workflows de base de datos pertenecen aquí. No introducir Lambdas funcionales ni API Gateway.

## Comportamiento obligatorio

- Mantener nombres, numeración y rutas funcionales equivalentes en las cuatro capas. Uonify es 0-uonify; Marketing 2.8.2, MasterCRM 2.8.3, Google 2.8.4, Microsoft 2.8.5. Transporte incluye Chipipro y MRW; no crear Despacho.
- Cada nuevo módulo, submódulo o pantalla necesita README de responsabilidad, estado, dependencias y propietario. Infrastructure añade resources.yml. Sin implementación, no generar código vacío.
- No duplicar recursos: los compartidos pertenecen al padre común. Referenciar explícitamente parámetros y salidas; las carpetas no crean relaciones de stacks automáticamente.
- Un YAML vacío es una reserva y se excluye del despliegue. No vaciar plantillas que ya contienen recursos. No recrear las cinco Lambdas eliminadas sin una petición explícita del propietario.
- Respetar cambios existentes y no publicar secretos. No ejecutar SQL, despliegues, eliminaciones ni cambios de DNS como consecuencia implícita de una reorganización.
- Antes de editar, revisar rama y estado de Git. Trabajar en dev; si hay otra rama o cambios superpuestos, advertir y resolver sin sobrescribir trabajo ajeno.
- Ejecutar python scripts/validate_structure.py y las pruebas pertinentes antes de proponer integración. No afirmar que una validación pasó si no se ejecutó.

## Advertencia y recomendación

Si una petición contradice el estándar, detener solo la operación afectada y comunicar:

> Advertencia: [regla y archivo afectados]. Consecuencia: [impacto concreto]. Recomendación: [alternativa compatible].

Continuar las comprobaciones independientes. No inventar permisos, implementaciones o correspondencias. Si falta otro repositorio, informar de qué correspondencia queda pendiente. Una excepción explícita del propietario se documenta con su alcance; la IA no la concede por sí misma ni cambia el estándar silenciosamente.

## Alcance del control

El validador comprueba estructura local básica; no certifica seguridad, equivalencia con AWS, propiedad entre stacks ni sincronización de repositorios separados. Su resultado es orientativo: mostrar advertencias y recomendar correcciones. No configurar este workflow como obligatorio ni añadir protección de rama para imponer este estándar. La decisión de integración corresponde al desarrollador y al propietario.
