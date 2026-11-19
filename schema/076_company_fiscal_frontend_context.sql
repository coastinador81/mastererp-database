-- Expose only the non-sensitive company identity needed by administrative documents.
CREATE OR REPLACE FUNCTION plataforma.current_frontend_context()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,plataforma,organizacion,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM plataforma.list_current_user_spaces()
               WHERE tenant_id=plataforma.current_app_tenant_id()) THEN
  RAISE EXCEPTION 'Context denied' USING ERRCODE='42501';
 END IF;
 SELECT jsonb_build_object(
  'tenant_id',plataforma.current_app_tenant_id(),
  'modules',COALESCE((SELECT jsonb_agg(m.code ORDER BY m.code)
   FROM plataforma.tenant_modules tm JOIN plataforma.modules m ON m.id=tm.module_id
   WHERE tm.tenant_id=plataforma.current_app_tenant_id() AND tm.status='active'
    AND m.status='active' AND (tm.expires_at IS NULL OR tm.expires_at>now())),'[]'::jsonb),
  'permissions',COALESCE((SELECT jsonb_agg(p.code ORDER BY p.code) FROM plataforma.permissions p
   WHERE plataforma.has_current_tenant_permission(p.code)),'[]'::jsonb),
  'companies',COALESCE((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'id',c.id,
    'name',COALESCE(NULLIF(c.trade_name,''),c.legal_name),
    'legal_name',c.legal_name,
    'trade_name',c.trade_name,
    'tax_identifier',c.tax_identifier,
    'address',COALESCE(c.settings#>>'{fiscal,address}',c.settings->>'fiscal_address',c.settings->>'direccion_fiscal',c.settings->>'address',c.settings->>'direccion'),
    'phone',COALESCE(c.settings#>>'{fiscal,phone}',c.settings->>'phone',c.settings->>'telefono'),
    'email',COALESCE(c.settings#>>'{fiscal,email}',c.settings->>'email',c.settings->>'correo'),
    'logo_url',COALESCE(c.settings#>>'{branding,logoUrl}',c.settings#>>'{branding,logo_url}',c.settings->>'logoUrl',c.settings->>'logo_url'),
    'primary_color',COALESCE(c.settings#>>'{branding,primaryColor}',c.settings#>>'{branding,primary_color}',c.settings->>'primaryColor',c.settings->>'primary_color')
   )) ORDER BY c.legal_name,c.id)
   FROM organizacion.companies c WHERE c.tenant_id=plataforma.current_app_tenant_id() AND c.status='active'
    AND (plataforma.has_current_tenant_capability('erp.finance','administration.parties.read',c.id) OR plataforma.has_current_tenant_capability('erp.finance','administration.purchases.read',c.id) OR plataforma.has_current_tenant_capability('erp.finance','administration.read',c.id))),'[]'::jsonb)
 ) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION plataforma.current_frontend_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.current_frontend_context() TO mastererp_app;
