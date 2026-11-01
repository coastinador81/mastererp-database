# Estándar común de desarrollo

## Código y contratos

## Definición progresiva y responsabilidades

Los módulos comienzan con objetivos generales y límites de responsabilidad. No es obligatorio especificar todos los módulos, requisitos o contratos por adelantado: el detalle de cada tarea se define cuando se prioriza.

El Product Owner ampliará progresivamente los objetivos, prioridades, reglas de negocio y criterios de aceptación. Cada desarrollador elaborará la solución técnica y actualizará la documentación del módulo conforme avance, conservando los objetivos generales y límites acordados.

Las IA pueden resolver decisiones técnicas dentro de los estándares y contratos vigentes. Las decisiones funcionales no definidas se marcan como pendientes y se acuerdan con el Product Owner antes de implementar el comportamiento afectado; el trabajo independiente puede continuar. No inventar requisitos ni expandir artificialmente los README para simular una especificación completa.

Conservar el lenguaje/framework real. Python: snake_case para funciones y módulos, tipos en interfaces públicas, errores tipados/sanitizados y transacciones explícitas. TypeScript cuando se implemente frontend: tipos estrictos, PascalCase para componentes y camelCase para variables. SQL: nombres existentes snake_case, cambios repetibles y no destructivos; no renombrar firmas sin transición documentada.

Validar entradas, tamaños y formatos antes de operar; parametrizar SQL. Distinguir rechazo de autorización, validación, conflicto y fallo interno. Nunca convertir un error de un servicio real en éxito simulado. Definir contratos entre frontend, backend y datos antes de integrar; no descargar código remoto desde URLs del catálogo.

## Seguridad y operaciones

Configuración por entorno; secretos únicamente en mecanismos existentes del servidor. Ningún secreto RDS en frontend. Autenticar antes de establecer actor/tenant; validar pertenencia y usar permisos mínimos. No usar administrador para peticiones ordinarias ni desactivar RLS para resolver bloqueos. Limpiar contexto y cachés al cambiar tenant. Datos de auditoría mínimos, correlación sin contenido sensible. Idempotencia debe vincular actor y operación y no reutilizar respuestas de otros usuarios.

## Pruebas y cambios

Ejecutar el validador existente de estructura y las pruebas proporcionales. Probar autorización con rol efectivo, no solo como administrador. Distinguir SQL de integración backend completa. Documentar omitidas y límites del entorno. La fase de tests con ROLLBACK no revierte esquemas confirmados. En documentación no instalar herramientas ni ejecutar SQL/despliegues.

Trabajar en dev según instrucciones vigentes, revisar estado/diff y conservar trabajo ajeno. Commits descriptivos y de alcance único; push solo autorizado, sin force salvo autorización específica. Revisar workflows que se disparan al publicar. Validación orientativa, sin imponer protección de rama. Entregar evidencias, riesgos, archivos, pruebas y pendientes. Mantener compatibilidad y preferir migraciones hacia delante; no borrar datos para resolver pruebas.
