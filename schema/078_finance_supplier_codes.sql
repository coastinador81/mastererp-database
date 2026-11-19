-- The proposal is read-only. The create command serializes assignment with
-- the existing tenant-wide party lock and delegates persistence to party_write_v2.
CREATE OR REPLACE FUNCTION administracion.proponer_codigo_proveedor(p_company uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,catalogo,plataforma,pg_temp AS $$
DECLARE
 tenant uuid:=plataforma.current_app_tenant_id();
 siguiente text;
BEGIN
 IF tenant IS NULL OR p_company IS NULL
 OR plataforma.has_current_tenant_capability('erp.finance','administration.parties.write',p_company) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.finance','administration.parties.read',p_company) IS NOT TRUE THEN
  RAISE EXCEPTION 'Party access denied' USING ERRCODE='42501';
 END IF;
 SELECT (COALESCE(max(substring(codigo from 6)::numeric),0)+1)::text INTO siguiente
 FROM (
  SELECT codigo FROM catalogo.terceros WHERE tenant_id=tenant AND codigo ~ '^PROV-[0-9]+$'
  UNION ALL
  SELECT codigo FROM catalogo.proveedores_catalogo WHERE tenant_id=tenant AND codigo ~ '^PROV-[0-9]+$'
 ) AS codigos;
 RETURN 'PROV-'||lpad(siguiente,greatest(4,length(siguiente)),'0');
END $$;

CREATE OR REPLACE FUNCTION administracion.crear_proveedor_codigo_automatico(
 p_company uuid,p_name text,p_key text,p_details jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,plataforma,pg_temp AS $$
DECLARE
 actor uuid:=plataforma.current_app_user_id();
 tenant uuid:=plataforma.current_app_tenant_id();
 operation constant text:='administration.proveedor.create';
 comando_key text;
 cache_key text;
 codigo text;
BEGIN
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 128 OR p_key !~ '^[A-Za-z0-9._:-]+$' THEN
  RAISE EXCEPTION 'Idempotency key required' USING ERRCODE='22023';
 END IF;
 -- Keep automatic and explicit-code requests in separate key namespaces.
 comando_key:='auto-proveedor:'||encode(sha256(convert_to(p_key,'UTF8')),'hex');
 cache_key:=encode(sha256(convert_to(jsonb_build_array(actor,tenant,operation,comando_key)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(cache_key,0));
 SELECT response_payload->>'codigo' INTO codigo
 FROM plataforma.idempotency_keys WHERE idempotency_key=cache_key;
 IF NOT FOUND THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(tenant::text||':party-master',0));
  codigo:=administracion.proponer_codigo_proveedor(p_company);
 END IF;
 RETURN administracion.party_write_v2(p_company,'proveedor','create',NULL,codigo,p_name,NULL,comando_key,p_details);
END $$;

REVOKE ALL ON FUNCTION administracion.proponer_codigo_proveedor(uuid),
 administracion.crear_proveedor_codigo_automatico(uuid,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.proponer_codigo_proveedor(uuid),
 administracion.crear_proveedor_codigo_automatico(uuid,text,text,jsonb) TO mastererp_app;
