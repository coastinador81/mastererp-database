# Espacio conversacional

Responsabilidad general: Composición de la interfaz conversacional de Uonify; los datos de sus operaciones pertenecen a los módulos propietarios.

Capa Database: correspondencia documental con la pantalla existente en Platform frontend/backend e Infrastructure. No se crea una pantalla nueva, un esquema, tabla, seed ni migración. Recursos de datos compartidos continúan en su propietario actual.

Estado: sin implementación de datos propia; cualquier necesidad futura queda pendiente de definición e implementación. Esta reserva no acredita funcionalidad backend ni acceso a datos. Propietario funcional: Uonify; responsable nominal pendiente. Mantener identidad estable, aislamiento por tenant y el estándar común cuando se priorice una operación real.

Esta correspondencia faltaba antes de la revisión de la base compartida; se añade solo el README para mantener las cuatro capas alineadas.
