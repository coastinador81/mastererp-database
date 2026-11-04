"""Read-only, PII-free DEV snapshot for the authorized Phase 6 reconciliation."""

from uuid import UUID

from dev_validation import _dev_guard


SOURCE_SHA256 = "6a6d9c5030bd7c63070a91876b9114b0d8d36553cddf8c15bc103589084a212d"


def _objects(rows, fields):
    return [dict(zip(fields, row)) for row in rows]


def inspect_phase6(connection, event, context):
    """Return only reconciliation keys, states and numeric balances for Tumandaito."""
    _dev_guard(context)
    if event.get("name") != "Tumandaito" or event.get("source_sha256") != SOURCE_SHA256:
        raise ValueError("Exact Phase 6 inspection contract required")
    connection.run("BEGIN READ ONLY")
    try:
        scope = connection.run("""SELECT t.id,c.id FROM plataforma.tenants t
          JOIN organizacion.companies c ON c.tenant_id=t.id
          WHERE t.code='tumandaito' AND t.status='active'
          AND c.legal_name='Tumandaito' AND c.status='active'""")
        if len(scope) != 1:
            raise ValueError("Unique active Tumandaito scope required")
        tenant, company = map(str, scope[0])
        UUID(tenant); UUID(company)
        categories = _objects(connection.run("""SELECT slug,estado FROM catalogo.categorias
          WHERE tenant_id=:tenant ORDER BY slug""", tenant=tenant), ("source_id", "status"))
        products = _objects(connection.run("""SELECT referencia_externa,estado FROM catalogo.productos
          WHERE tenant_id=:tenant AND referencia_externa IS NOT NULL ORDER BY referencia_externa""",
          tenant=tenant), ("source_id", "status"))
        customers = _objects(connection.run("""SELECT t.codigo FROM catalogo.terceros t
          JOIN administracion.perfiles_tercero p ON (p.tenant_id,p.tercero_id)=(t.tenant_id,t.id)
          WHERE t.tenant_id=:tenant AND p.empresa_id=:company AND p.rol='cliente' ORDER BY t.codigo""",
          tenant=tenant, company=company), ("source_id",))
        nodes = _objects(connection.run("""SELECT id::text,estado FROM operaciones.nodos
          WHERE tenant_id=:tenant AND empresa_id=:company ORDER BY id""", tenant=tenant, company=company),
          ("target_id", "status"))
        inventories = _objects(connection.run("""SELECT i.nodo_id::text,p.referencia_externa,
          i.existencia::text,i.reservado::text FROM catalogo.inventarios i
          JOIN catalogo.productos p ON (p.tenant_id,p.id)=(i.tenant_id,i.producto_id)
          WHERE i.tenant_id=:tenant AND i.empresa_id=:company
          ORDER BY i.nodo_id,p.referencia_externa""", tenant=tenant, company=company),
          ("node_id", "product_source_id", "stock", "reserved"))
        drivers = _objects(connection.run("""SELECT d.referencia_externa,d.estado,d.disponibilidad,
          count(n.nodo_id)::integer FROM transporte.repartidores d
          LEFT JOIN transporte.repartidor_nodos n ON n.tenant_id=d.tenant_id
          AND n.repartidor_id=d.id AND n.empresa_id=:company AND n.activo
          WHERE d.tenant_id=:tenant GROUP BY d.id ORDER BY d.referencia_externa""",
          tenant=tenant, company=company), ("source_id", "status", "availability", "node_count"))
        orders = _objects(connection.run("""SELECT p.referencia_externa,p.estado,p.moneda::text,
          p.subtotal::text,p.tarifa_entrega::text,p.total::text,count(l.id)::integer
          FROM operaciones.pedidos p LEFT JOIN operaciones.pedido_lineas l
          ON (l.tenant_id,l.empresa_id,l.pedido_id)=(p.tenant_id,p.empresa_id,p.id)
          WHERE p.tenant_id=:tenant AND p.empresa_id=:company GROUP BY p.id
          ORDER BY p.referencia_externa""", tenant=tenant, company=company),
          ("source_id", "status", "currency", "subtotal", "delivery_fee", "total", "line_count"))
        routes = _objects(connection.run("""SELECT r.estado,r.nodo_id::text,
          COALESCE(d.referencia_externa,''),count(s.pedido_id)::integer FROM operaciones.rutas r
          LEFT JOIN transporte.repartidores d ON (d.tenant_id,d.id)=(r.tenant_id,r.repartidor_id)
          LEFT JOIN operaciones.ruta_paradas s ON
          (s.tenant_id,s.empresa_id,s.ruta_id)=(r.tenant_id,r.empresa_id,r.id)
          WHERE r.tenant_id=:tenant AND r.empresa_id=:company GROUP BY r.id,d.referencia_externa
          ORDER BY r.estado,r.nodo_id,COALESCE(d.referencia_externa,'')""", tenant=tenant, company=company),
          ("status", "node_id", "driver_source_id", "stop_count"))
        stores = _objects(connection.run("""SELECT dominio,estado,nodo_id::text
          FROM ventas_digitales.tiendas WHERE tenant_id=:tenant AND empresa_id=:company
          ORDER BY dominio""", tenant=tenant, company=company),
          ("domain", "status", "node_id"))
        snapshot = {"categories": categories, "products": products, "customers": customers,
                    "nodes": nodes, "inventories": inventories, "drivers": drivers,
                    "orders": orders, "routes": routes, "stores": stores}
        return {"status": "succeeded", "read_only": True, "source_sha256": SOURCE_SHA256,
                "counts": {name: len(rows) for name, rows in snapshot.items()}, "snapshot": snapshot}
    finally:
        connection.run("ROLLBACK")

