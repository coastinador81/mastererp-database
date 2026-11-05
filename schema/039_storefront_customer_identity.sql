-- Explicit Storefront customer claims. Email is profile data, never a linkage key.
CREATE TABLE IF NOT EXISTS ventas_digitales.cliente_identidades (
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 empresa_id uuid NOT NULL,
 cliente_id uuid NOT NULL,
 user_id uuid NOT NULL REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(tenant_id,empresa_id,cliente_id),
 UNIQUE(tenant_id,empresa_id,user_id),
 FOREIGN KEY(tenant_id,cliente_id) REFERENCES catalogo.terceros(tenant_id,id)
);

CREATE TABLE IF NOT EXISTS ventas_digitales.cliente_invitaciones (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 empresa_id uuid NOT NULL,
 tienda_id uuid NOT NULL,
 cliente_id uuid NOT NULL,
 token_sha256 char(64) NOT NULL UNIQUE CHECK(token_sha256~'^[0-9a-f]{64}$'),
 estado text NOT NULL DEFAULT 'PENDING' CHECK(estado IN('PENDING','CLAIMED','REVOKED','EXPIRED')),
 expira_en timestamptz NOT NULL,
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),
 reclamado_por uuid REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 reclamado_en timestamptz,
 FOREIGN KEY(tenant_id,empresa_id,tienda_id)
  REFERENCES ventas_digitales.tiendas(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,cliente_id) REFERENCES catalogo.terceros(tenant_id,id)
);
CREATE INDEX IF NOT EXISTS cliente_invitaciones_scope_idx
 ON ventas_digitales.cliente_invitaciones(tenant_id,empresa_id,cliente_id,estado);

ALTER TABLE ventas_digitales.cliente_identidades ENABLE ROW LEVEL SECURITY;
ALTER TABLE ventas_digitales.cliente_invitaciones ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ventas_digitales.cliente_identidades,
 ventas_digitales.cliente_invitaciones FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_invitacion_crear(
 p_empresa uuid,p_tienda uuid,p_cliente uuid,p_token_sha256 text,p_expira_en timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,plataforma,administracion,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id();actor uuid:=plataforma.current_app_user_id();
 invitation uuid:=gen_random_uuid();correlation uuid;
BEGIN
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF p_token_sha256 !~ '^[0-9a-f]{64}$' OR p_expira_en<=transaction_timestamp()
 OR p_expira_en>transaction_timestamp()+interval '7 days' OR correlation IS NULL THEN
  RAISE EXCEPTION 'Invalid invitation' USING ERRCODE='22023';END IF;
 IF plataforma.has_current_tenant_capability('digital_sales.ecommerce','digital_sales.ecommerce.write',p_empresa) IS NOT TRUE
 OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.storefront.invitation.create' THEN
  RAISE EXCEPTION 'Invitation denied' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM ventas_digitales.tiendas WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_tienda AND estado='ACTIVE')
 OR NOT EXISTS(SELECT 1 FROM administracion.perfiles_tercero WHERE tenant_id=tenant AND empresa_id=p_empresa AND tercero_id=p_cliente AND rol='cliente') THEN
  RAISE EXCEPTION 'Invitation scope not found' USING ERRCODE='P0002';END IF;
 INSERT INTO ventas_digitales.cliente_invitaciones(id,tenant_id,empresa_id,tienda_id,cliente_id,token_sha256,expira_en,creado_por)
 VALUES(invitation,tenant,p_empresa,p_tienda,p_cliente,p_token_sha256,p_expira_en,actor);
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.4.2-ecommerce','cliente_invitacion',invitation,'digital_sales.storefront.invitation.create',correlation,
  jsonb_build_object('empresa_id',p_empresa,'tienda_id',p_tienda,'cliente_id',p_cliente));
 RETURN jsonb_build_object('invitation_id',invitation,'expires_at',p_expira_en);
END $$;

CREATE OR REPLACE FUNCTION ventas_digitales.cliente_identidad_reclamar(
 p_issuer text,p_subject text,p_email text,p_display_name text,p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,plataforma,auditoria,pg_temp AS $$
DECLARE invitation ventas_digitales.cliente_invitaciones%ROWTYPE;actor uuid;existing uuid;correlation uuid;
 digest text:=encode(public.digest(convert_to(p_token,'UTF8'),'sha256'),'hex');
BEGIN
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF p_issuer !~ '^https://' OR length(p_subject) NOT BETWEEN 1 AND 255
 OR p_email IS NULL OR length(p_email)>254 OR length(p_display_name)>200
 OR length(p_token)<32 OR correlation IS NULL
 OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.storefront.identity.claim' THEN
  RAISE EXCEPTION 'Invalid identity claim' USING ERRCODE='22023';END IF;
 SELECT * INTO invitation FROM ventas_digitales.cliente_invitaciones
 WHERE token_sha256=digest FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invitation not found' USING ERRCODE='P0002';END IF;
 IF invitation.estado='CLAIMED' THEN
  SELECT e.user_id INTO existing FROM plataforma.external_identities e
  JOIN ventas_digitales.cliente_identidades l ON l.user_id=e.user_id
  WHERE e.issuer=p_issuer AND e.subject=p_subject AND l.tenant_id=invitation.tenant_id
   AND l.empresa_id=invitation.empresa_id AND l.cliente_id=invitation.cliente_id;
  IF existing=invitation.reclamado_por THEN
   RETURN jsonb_build_object('tenant_id',invitation.tenant_id,'company_id',invitation.empresa_id,
    'store_id',invitation.tienda_id,'customer_id',invitation.cliente_id,'replayed',true);END IF;
  RAISE EXCEPTION 'Invitation already claimed' USING ERRCODE='23505';
 END IF;
 IF invitation.estado<>'PENDING' OR invitation.expira_en<=transaction_timestamp() THEN
  RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE='42501';END IF;
 SELECT user_id INTO actor FROM plataforma.external_identities WHERE issuer=p_issuer AND subject=p_subject AND status='active';
 IF actor IS NULL THEN
  actor:=gen_random_uuid();
  INSERT INTO plataforma.users(id,email,display_name,status) VALUES(actor,p_email,COALESCE(NULLIF(btrim(p_display_name),''),p_email),'active');
  INSERT INTO plataforma.external_identities(issuer,subject,user_id,status) VALUES(p_issuer,p_subject,actor,'active');
 END IF;
 IF EXISTS(SELECT 1 FROM ventas_digitales.cliente_identidades
  WHERE tenant_id=invitation.tenant_id AND empresa_id=invitation.empresa_id
  AND (cliente_id=invitation.cliente_id OR user_id=actor)) THEN
  RAISE EXCEPTION 'Customer identity conflict' USING ERRCODE='23505';END IF;
 INSERT INTO ventas_digitales.cliente_identidades(tenant_id,empresa_id,cliente_id,user_id)
 VALUES(invitation.tenant_id,invitation.empresa_id,invitation.cliente_id,actor);
 UPDATE ventas_digitales.cliente_invitaciones SET estado='CLAIMED',reclamado_por=actor,reclamado_en=transaction_timestamp()
 WHERE id=invitation.id;
 PERFORM set_config('app.current_user_id',actor::text,true);PERFORM set_config('app.current_tenant_id',invitation.tenant_id::text,true);
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(invitation.tenant_id,actor,'2.4.2-ecommerce','cliente',invitation.cliente_id,
  'digital_sales.storefront.identity.claim',correlation,jsonb_build_object('empresa_id',invitation.empresa_id,'tienda_id',invitation.tienda_id));
 RETURN jsonb_build_object('tenant_id',invitation.tenant_id,'company_id',invitation.empresa_id,
  'store_id',invitation.tienda_id,'customer_id',invitation.cliente_id,'replayed',false);
END $$;

REVOKE ALL ON FUNCTION ventas_digitales.cliente_invitacion_crear(uuid,uuid,uuid,text,timestamptz),
 ventas_digitales.cliente_identidad_reclamar(text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.cliente_invitacion_crear(uuid,uuid,uuid,text,timestamptz),
 ventas_digitales.cliente_identidad_reclamar(text,text,text,text,text) TO mastererp_app;
