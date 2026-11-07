# eCommerce

Objetivo específico: Gestionar venta online; catálogo y finanzas conservan sus datos propietarios.

Responsabilidad: eCommerce, dentro de Ecommerce.
Estado: esquema y funciones implementados en `schema/027_digital_sales_ecommerce.sql`.


## Contrato y estado de esta capa

Código: 2.3.2. Nombre/ruta: `2.3.2-stores`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Ecommerce; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: configuración autorizada y catálogo público por tenant/dominio aprobados en PostgreSQL desechable. Aplicación DEV pendiente.

Validaciones: estructura local mediante scripts/validate_structure.py. Pendientes: contratos específicos, responsable nominal y pruebas funcionales antes de habilitar esta capacidad.
