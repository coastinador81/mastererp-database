INSERT INTO plataforma.modules (
    code, name, description, category, module_type, requires_company, requires_country, requires_subscription, status
) VALUES
    ('uonify.core', 'Uonify Core', 'Asistencia temporal y orquestación.', 'ai', 'core', false, false, false, 'active'),
    ('video.creation', 'Video Creation', 'Creación de video por tenant.', 'ai', 'addon', false, false, true, 'active'),
    ('digital_sales.product_content', 'Product Content', 'Contenido de productos para canales digitales.', 'digital_sales', 'module', false, false, true, 'active'),
    ('digital_sales.marketplaces', 'Marketplaces', 'Gobierno funcional de marketplaces.', 'digital_sales', 'module', false, false, true, 'active'),
    ('digital_sales.ecommerce', 'E-commerce', 'Storefront multi-tenant configurable.', 'digital_sales', 'module', true, false, true, 'active'),
    ('erp.catalog', 'ERP Catalog', 'Catálogo de productos.', 'erp', 'module', true, false, true, 'active'),
    ('erp.inventory', 'ERP Inventory', 'Inventario empresarial.', 'erp', 'module', true, false, true, 'active'),
    ('erp.finance', 'ERP Finance', 'Operación financiera.', 'erp', 'module', true, true, true, 'active'),
    ('erp.operations', 'ERP Operations', 'Pedidos y operación.', 'erp', 'module', true, false, true, 'active'),
    ('erp.transport', 'ERP Transport', 'Repartidores, preparación y rutas.', 'erp', 'module', true, false, true, 'active'),
    ('agent_center', 'Agent Center', 'Configuración de agentes.', 'ai', 'agent', false, false, true, 'active'),
    ('integration.amazon', 'Amazon Integration', 'Conector técnico Amazon.', 'integration', 'integration', false, false, true, 'active'),
    ('integration.mercadolibre', 'Mercado Libre Integration', 'Conector técnico Mercado Libre.', 'integration', 'integration', false, false, true, 'active')
ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    category = EXCLUDED.category,
    module_type = EXCLUDED.module_type,
    requires_company = EXCLUDED.requires_company,
    requires_country = EXCLUDED.requires_country,
    requires_subscription = EXCLUDED.requires_subscription,
    status = EXCLUDED.status,
    updated_at = now();
