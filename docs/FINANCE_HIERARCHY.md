# Jerarquía de Finanzas y composición de infraestructura

Jerarquía oficial conservada en las cuatro capas: 2.2-finance → 2.2.1-administration, 2.2.2-accounting, 2.2.3-bi y 2.2.4-masterpay. Administración conserva sus cinco áreas y 19 submódulos. No renumerar ni crear pantallas ficticias.

Infrastructure usa modules/2.2-finance/resources.yml como plantilla padre de Finanzas. La plantilla raíz de Administración compone las ocho plantillas de capacidades que ya declaran recursos; la composición se ensambla antes de validarse/desplegarse. El hijo AWS es el stack existente mastererp-dev-administration, adoptado por importación y verificado en DEV; su StackId y sus 48 recursos se conservaron. No existe un stack por cada YAML ni una segunda declaración de las funciones.

Contabilidad y BI conservan README y resources.yml vacíos en Infrastructure: reservas documentales excluidas del despliegue hasta tener recursos. MasterPay y las demás carpetas se conservan. Las capacidades y pantallas mantienen sus recursos exclusivos en su resources.yml raíz; frontend y Database mantienen correspondencia documental, Backend contiene código en lambdas/<nombre>/.

Parámetros Environment (dev/qa/prod), referencias de API y artefactos preparados sin crear QA/PROD. El procedimiento ejecutable limita la cuenta 277352717693 y región us-west-1 a DEV. No habilitar otro entorno cambiando solo un valor: requiere recursos compartidos y artefactos propios revisados. No dar por compartida una API DEV con QA/PROD.

API Gateway, Identidad y Database conservan sus propietarios reales. Finanzas consume identificadores explícitos mediante parámetros; el padre publica outputs de su hijo y API. Cognito/Database no se duplican ni se conceden permisos anticipados a handlers que no los utilizan. La excepción pública de los ocho health permanece técnica y no autoriza operaciones de negocio.

Los recursos existentes no se trasladan por mover YAML. Consultar en mastererp-infrastructure/docs los archivos FINANCE_RESOURCE_MAP_DEV.md y FINANCE_HIERARCHY_DEV.md para mapa, compatibilidad, lotes, resultado y recuperación. Los documentos anteriores de DevOps se conservan; diferencias entre inventarios deben distinguir fecha y región.

El código de negocio, SQL y despliegues de Database están fuera de esta reorganización. Las cinco funciones eliminadas y rutas obsoletas no se restauran ni eliminan implícitamente. Una nueva capacidad exige definir autenticación, autorización por tenant y contrato antes de habilitar operaciones de negocio.
