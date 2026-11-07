# Instrucciones para IA

## Lectura obligatoria del contrato frontend

Antes de modificar frontends, navegación, autenticación, contexto de tenant/empresa o hosting, es obligatorio leer y respetar [docs/FRONTEND_ARCHITECTURE.md](docs/FRONTEND_ARCHITECTURE.md). Su fuente oficial es Platform/dev; las copias de Infrastructure y Database deben permanecer idénticas. Aplicar la experiencia objetivo de aplicaciones por subdominio, con Uonify como entrada y lanzador; distinguir decisiones objetivo de hosting y SSO realmente desplegados. No imponer una tecnología de integración ni rutas internas sin el diseño correspondiente; menús, URLs y contexto frontend no conceden permisos. La API valida cada operación.

Antes de modificar archivos, leer PROJECT.md, README.md, CONTRIBUTING.md, docs/DEVELOPMENT_STANDARD.md, docs/FOLDER_STANDARD.md y el README del módulo afectado. Estas instrucciones no sustituyen las indicaciones explícitas del propietario ni las políticas del entorno.

## Responsabilidad de este repositorio

RDS, migrador, SQL, seeds, pruebas y workflows de base de datos pertenecen aquí. No introducir Lambdas funcionales ni API Gateway.

## Comportamiento obligatorio

Secuencia de trabajo: leer contexto y README afectado/padres; identificar dominio y capas; buscar código y recursos existentes; conservar contratos/cambios; definir una sola propiedad por recurso y documentar conexiones explícitas; implementar solo la tarea priorizada; actualizar documentación y ejecutar validaciones proporcionales informando omitidas. Usar docs/HOW_TO_BUILD_A_MODULE.md. Resolver decisiones técnicas rutinarias sin confirmaciones adicionales dentro del alcance autorizado.

- Mantener nombres, numeración y rutas funcionales equivalentes en las cuatro capas. 0 Uonify; 1.0 Plataforma Base; 2.1 Inventario; 2.2 Finanzas (incluye 2.2.5 Recursos humanos); 2.3 Ecommerce; 2.4 Marketing; 2.5 Servicios; 2.6 Centro de Agentes; 2.7 CRM; 2.8 Productividad; 2.9 POS; 2.10 Transporte (incluye 2.10.5 Rutas); 2.11 Estudio. Seguridad reside en 1.2.6, dentro de Gestión de Plataforma Base. Marketing: 2.4; CRM: 2.7; Google Workspace: 2.8.2; Microsoft 365: 2.8.3. No existe Despacho. Consultar docs/MODULE_RENUMBERING.md y el registro vigente; no inferir IDs técnicos desde esta numeración.
- Cada nuevo módulo, submódulo o pantalla necesita README de responsabilidad, estado, dependencias y propietario. Infrastructure añade resources.yml. Sin implementación, no generar código vacío.
- Infrastructure: declarar todas las Lambdas y recursos exclusivos en el resources.yml raíz del módulo, submódulo o pantalla propietario; no crear YAML por Lambda. Backend conserva lambdas/<nombre>/ para código; esa carpeta técnica no se replica entre capas. Las plantillas heredadas por Lambda requieren transición explícita, nunca traslado automático. Ver docs/FOLDER_STANDARD.md.
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

## Alcance y decisiones

## Definición progresiva y responsabilidades

Los módulos comienzan con objetivos generales y límites de responsabilidad. No es obligatorio especificar todos los módulos, requisitos o contratos por adelantado: el detalle de cada tarea se define cuando se prioriza.

El Product Owner ampliará progresivamente los objetivos, prioridades, reglas de negocio y criterios de aceptación. Cada desarrollador elaborará la solución técnica y actualizará la documentación del módulo conforme avance, conservando los objetivos generales y límites acordados.

Las IA pueden resolver decisiones técnicas dentro de los estándares y contratos vigentes. Las decisiones funcionales no definidas se marcan como pendientes y se acuerdan con el Product Owner antes de implementar el comportamiento afectado; el trabajo independiente puede continuar. No inventar requisitos ni expandir artificialmente los README para simular una especificación completa.

No instalar herramientas, publicar ni desplegar por una tarea documental. Respetar contratos y alcance; no inventar recursos o pruebas aprobadas. Preguntar solo cuando la ambigüedad cambie contratos, propiedad o arquitectura; continuar comprobaciones independientes. Verificar implementación real y comunicar validaciones omitidas.
