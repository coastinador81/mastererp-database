-- Preserve reviewed customer receipts in Cobros and complete the owner orchestration grant.
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='tenant.owner'
 AND p.code IN ('administration.sales.write','administration.read','operations.orders.read')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION administracion.pagos_pendientes_leer(p_empresa uuid,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.receipts.validate',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Payment review denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY created_at DESC,id DESC),'[]') INTO result FROM (
  SELECT p.id,p.creado_en created_at,jsonb_build_object('order_id',p.id,'number',p.numero,'version',p.version,
   'created_at',p.creado_en,'currency',p.moneda,'total',p.total,'customer',p.cliente_snapshot,
   'payment',p.pago_snapshot,'branch_id',p.sucursal_id,'review',CASE WHEN r.id IS NULL THEN NULL ELSE
   jsonb_build_object('id',r.id,'decision',r.estado,'reason',r.motivo,'evidence',r.evidencia,
    'reviewed_by',r.creado_por,'reviewed_at',r.creado_en) END) item
  FROM operaciones.pedidos p
  LEFT JOIN administracion.revisiones_pago r ON r.tenant_id=p.tenant_id
   AND r.empresa_id=p.empresa_id AND r.pedido_id=p.id
  WHERE p.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_empresa
  AND p.pago_snapshot->>'method' IN ('mobile','transfer','mobile_payment','bank_transfer')
  AND (p.pago_snapshot->>'status'='PENDING_VERIFICATION' OR r.id IS NOT NULL)
  ORDER BY p.creado_en DESC,p.id DESC LIMIT p_limit
 ) receipts;
 RETURN result;
END $$;

REVOKE ALL ON FUNCTION administracion.pagos_pendientes_leer(uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.pagos_pendientes_leer(uuid,integer) TO mastererp_app;
