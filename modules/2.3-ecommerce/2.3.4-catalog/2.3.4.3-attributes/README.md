# Atributos

Objetivo específico: Definir atributos y valores que describen productos.

Responsabilidad: Atributos, dentro de Catálogo.
Estado: candidato SQL implementado, no aplicado en DEV.


## Contrato y estado de esta capa

Código: 2.3.4.3. Nombre/ruta: `2.3.4.3-attributes`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Ecommerce / Catálogo compartido; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: `022_catalog_attributes.sql` define atributos tipados, opciones y relación segura con categorías, con funciones autorizadas e idempotentes.

Validaciones: estructura local mediante scripts/validate_structure.py. Pendientes: contratos específicos, responsable nominal y pruebas funcionales antes de habilitar esta capacidad.
