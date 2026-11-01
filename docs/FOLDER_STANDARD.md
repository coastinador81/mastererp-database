# Estándar de carpetas funcionales

Cada módulo, submódulo y pantalla tiene README.md. Las cuatro capas mantienen nombres y rutas funcionales coincidentes. Nuevos submódulos se añaden correlativamente sin renumerar los existentes.

Infrastructure declara recursos propios en resources.yml. Un YAML vacío reserva ubicación: NO es una plantilla desplegable y debe excluirse del empaquetado y despliegue. Los recursos compartidos se definen una sola vez en el padre común. api-gateways.yml en modules es la definición compartida existente; no duplicarla en resources.yml.

Backend implementa la Lambda en lambdas/<nombre>/handler.py; frontend implementa pantallas en screens/<nombre>/; database mantiene SQL. Usar los mismos nombres para la correspondencia. Sin implementación, solo README; no crear código vacío ni inventar pantallas.

Las plantillas separadas de onboarding siguen pendientes de equivalencia con AWS y migración de propiedad. No desplegarlas automáticamente ni recrear las funciones eliminadas. Directorios técnicos internos de Python no se replican entre capas. El desarrollador debe replicar nuevas carpetas funcionales y documentar dependencias en las cuatro capas.
