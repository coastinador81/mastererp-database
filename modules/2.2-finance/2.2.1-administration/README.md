# Administración

Objetivo específico: Organizar la administración financiera; alcance contable y fiscal por definir.

Responsabilidad: Administración, dentro de Finanzas.
Estado: pendiente de implementación en esta capa. Sin código vacío.


## Contrato y estado de esta capa

Código: 2.2.1. Nombre/ruta: `2.2.1-administration`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Finanzas; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: la reserva documental no acredita implementación; conservar cualquier código/plantilla existente y revisar evidencia específica antes de marcar implementado.

Validaciones: estructura local mediante scripts/validate_structure.py. Pendientes: contratos específicos, responsable nominal y pruebas funcionales antes de habilitar esta capacidad.



## Áreas de Administración

Estructura documental; todas las áreas y sus submódulos están pendientes de implementación. Se mantienen las rutas existentes de Finanzas y Administración. Contabilidad, BI y MasterPay conservan sus carpetas y responsabilidades.

- [2.2.1.1 Gestión comercial](2.2.1.1-gestion-comercial/README.md)
- [2.2.1.2 Gestión de compras](2.2.1.2-gestion-compras/README.md)
- [2.2.1.3 Cartera y obligaciones](2.2.1.3-cartera-obligaciones/README.md)
- [2.2.1.4 Tesorería](2.2.1.4-tesoreria/README.md)
- [2.2.1.5 Gastos y fondos menores](2.2.1.5-gastos-fondos-menores/README.md)

Clientes y Proveedores consumen maestros existentes sin duplicarlos. Proveedores referencia Catálogo; la ubicación y el contrato del maestro de Clientes quedan pendientes de identificación antes de implementar. No se definen aquí reglas contables, fiscales ni contratos nuevos.

## Jerarquía de infraestructura

Se conserva la ruta y responsabilidad funcional. La composición Finanzas → Administración y las reservas de Contabilidad/BI se documentan en [docs/FINANCE_HIERARCHY.md](../../../docs/FINANCE_HIERARCHY.md). En Infrastructure, cada recurso permanece en el YAML raíz de su carpeta propietaria; una carpeta no obliga a crear un stack. El resultado AWS se informa por separado en el mapa y evidencia de Infrastructure.
