CREATE OR REPLACE FUNCTION organizacion.company_fiscal_profile_read(p_empresa uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,organizacion,plataforma,pg_temp AS $$
DECLARE company organizacion.companies%ROWTYPE;
BEGIN
 IF plataforma.has_current_tenant_capability('digital_sales.ecommerce','digital_sales.ecommerce.read',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Company fiscal profile access denied' USING ERRCODE='42501';
 END IF;
 SELECT * INTO company FROM organizacion.companies
 WHERE id=p_empresa AND tenant_id=plataforma.current_app_tenant_id() AND status='active';
 IF NOT FOUND THEN RAISE EXCEPTION 'Company not found' USING ERRCODE='P0002'; END IF;
 RETURN jsonb_strip_nulls(jsonb_build_object(
  'legal_name',company.legal_name,'trade_name',company.trade_name,'tax_identifier',company.tax_identifier,
  'address',COALESCE(company.settings#>>'{fiscal,address}',company.settings->>'fiscal_address'),
  'phone',COALESCE(company.settings#>>'{fiscal,phone}',company.settings->>'phone'),
  'email',COALESCE(company.settings#>>'{fiscal,email}',company.settings->>'email'),
  'logo_url',COALESCE(company.settings#>>'{branding,logoUrl}',company.settings->>'logo_url'),
  'primary_color',COALESCE(company.settings#>>'{branding,primaryColor}',company.settings->>'primary_color')));
END $$;

CREATE OR REPLACE FUNCTION organizacion.company_fiscal_profile_update(p_empresa uuid,p_profile jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,organizacion,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id();actor uuid:=plataforma.current_app_user_id();corr uuid;key text;
BEGIN
 IF plataforma.has_current_tenant_capability('digital_sales.ecommerce','digital_sales.ecommerce.write',p_empresa) IS NOT TRUE
 OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.ecommerce.configure' THEN
  RAISE EXCEPTION 'Company fiscal profile update denied' USING ERRCODE='42501';
 END IF;
 IF jsonb_typeof(p_profile)<>'object' THEN RAISE EXCEPTION 'Invalid fiscal profile' USING ERRCODE='22023'; END IF;
 FOR key IN SELECT jsonb_object_keys(p_profile) LOOP
  IF key NOT IN('legal_name','trade_name','tax_identifier','address','phone','email','logo_url','primary_color') THEN
   RAISE EXCEPTION 'Unsupported fiscal profile field' USING ERRCODE='22023'; END IF;
 END LOOP;
 UPDATE organizacion.companies SET
  legal_name=btrim(p_profile->>'legal_name'),trade_name=NULLIF(btrim(p_profile->>'trade_name'),''),
  tax_identifier=NULLIF(upper(btrim(p_profile->>'tax_identifier')),''),
  settings=COALESCE(settings,'{}')||jsonb_build_object(
   'fiscal',COALESCE(settings->'fiscal','{}')||jsonb_build_object('address',COALESCE(p_profile->>'address',''),'phone',COALESCE(p_profile->>'phone',''),'email',COALESCE(p_profile->>'email','')),
   'branding',COALESCE(settings->'branding','{}')||jsonb_build_object('logoUrl',COALESCE(p_profile->>'logo_url',''),'primaryColor',COALESCE(p_profile->>'primary_color',''))),
  updated_at=transaction_timestamp()
 WHERE id=p_empresa AND tenant_id=tenant AND status='active';
 IF NOT FOUND THEN RAISE EXCEPTION 'Company not found' USING ERRCODE='P0002'; END IF;
 corr:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.4.2-ecommerce','company',p_empresa,'digital_sales.company.fiscal_profile.update',corr,'{}');
 RETURN organizacion.company_fiscal_profile_read(p_empresa);
END $$;

REVOKE ALL ON FUNCTION organizacion.company_fiscal_profile_read(uuid),organizacion.company_fiscal_profile_update(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION organizacion.company_fiscal_profile_read(uuid),organizacion.company_fiscal_profile_update(uuid,jsonb) TO mastererp_app;
