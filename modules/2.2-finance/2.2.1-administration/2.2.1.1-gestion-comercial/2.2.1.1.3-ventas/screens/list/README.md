# Listado de Ventas

Responsabilidad: Consultar ventas con búsqueda servidor y paginación por empresa.

Propietario: Finanzas → Administración → Gestión comercial → Ventas.
Estado: candidato local, pendiente de validación/publicación de esta entrega.

Contrato: GET /v1/administration/ventas; JWT, tenant y empresa autorizados, erp.finance habilitado y administration.read. La API y SQL vuelven a comprobar acceso. Sin creación manual, facturación ni cobros. Reutiliza administracion.documentos, ventas_origen y detalles_documento; no hay tabla ni Lambda por pantalla.

UX/UI: Inter, menú blanco, fondo gris azulado, acentos azules, celdas/encabezados 14 px y peso 400, foco visible y filas con enlace accesible. No mostrar cifras simuladas ni inventar estados financieros. La implementación de pantalla es única y reutilizable por Finanzas/Uonify.

Correspondencia: misma ruta funcional screens/list en las cuatro capas. Backend reutiliza la Lambda del módulo; Database refiere schema/048_sales_read_model.sql. Infrastructure mantiene recursos comunes en el resources.yml raíz de Ventas; esta pantalla no posee recursos exclusivos, por lo que su YAML vacío queda fuera del despliegue.
