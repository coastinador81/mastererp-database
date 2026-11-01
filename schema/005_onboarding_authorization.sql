-- Final least-privilege overlay. Repeated after 004 on every model application.
REVOKE ALL ON ALL TABLES IN SCHEMA plataforma, organizacion, auditoria FROM mastererp_app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA plataforma, organizacion, auditoria FROM mastererp_app;
GRANT SELECT ON plataforma.users, plataforma.roles, plataforma.modules,
 plataforma.onboarding_flows, plataforma.onboarding_flow_steps TO mastererp_app;
GRANT SELECT ON plataforma.tenants, plataforma.user_tenants, plataforma.tenant_modules,
 plataforma.onboarding_sessions, plataforma.onboarding_step_responses,
 organizacion.companies, organizacion.branches, auditoria.events,
 plataforma.idempotency_keys TO mastererp_app;
GRANT UPDATE (name, default_country_code, default_locale, default_timezone, settings, status)
 ON plataforma.tenants TO mastererp_app;
GRANT INSERT, UPDATE ON plataforma.tenant_modules, plataforma.onboarding_sessions,
 plataforma.onboarding_step_responses, organizacion.companies, organizacion.branches TO mastererp_app;
GRANT INSERT ON auditoria.events TO mastererp_app;

CREATE OR REPLACE FUNCTION plataforma.user_has_tenant_access(p_tenant_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp AS $$
 SELECT p_tenant_id = plataforma.current_app_tenant_id() AND EXISTS (
 SELECT 1 FROM plataforma.user_tenants ut JOIN plataforma.users u ON u.id=ut.user_id
 WHERE ut.tenant_id=p_tenant_id AND ut.user_id=plataforma.current_app_user_id()
 AND ut.status='active' AND u.status='active');
$$;
CREATE OR REPLACE FUNCTION plataforma.user_owns_current_tenant(p_tenant_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp AS $$
 SELECT plataforma.user_has_tenant_access(p_tenant_id) AND EXISTS (
 SELECT 1 FROM plataforma.user_tenants ut JOIN plataforma.roles r ON r.id=ut.role_id
 WHERE ut.tenant_id=p_tenant_id AND ut.user_id=plataforma.current_app_user_id()
 AND ut.status='active' AND r.code='tenant.owner');
$$;
REVOKE ALL ON FUNCTION plataforma.user_has_tenant_access(uuid),
 plataforma.user_owns_current_tenant(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.user_has_tenant_access(uuid),
 plataforma.user_owns_current_tenant(uuid) TO mastererp_app;

DROP POLICY IF EXISTS tenants_owner_update ON plataforma.tenants;
CREATE POLICY tenants_owner_update ON plataforma.tenants FOR UPDATE TO mastererp_app
 USING (plataforma.user_owns_current_tenant(id))
 WITH CHECK (plataforma.user_owns_current_tenant(id));
DROP POLICY IF EXISTS user_tenants_member_select ON plataforma.user_tenants;
CREATE POLICY user_tenants_member_select ON plataforma.user_tenants FOR SELECT TO mastererp_app
 USING (plataforma.user_has_tenant_access(tenant_id));

ALTER TABLE plataforma.users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS users_self_select ON plataforma.users;
CREATE POLICY users_self_select ON plataforma.users FOR SELECT TO mastererp_app
 USING (id=plataforma.current_app_user_id() AND status='active');

ALTER TABLE plataforma.idempotency_keys ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS idempotency_actor_select ON plataforma.idempotency_keys;
CREATE POLICY idempotency_actor_select ON plataforma.idempotency_keys FOR SELECT TO mastererp_app
 USING (actor_user_id=plataforma.current_app_user_id()
 AND operation=NULLIF(current_setting('app.current_operation',true),''));

DROP POLICY IF EXISTS onboarding_sessions_member_all ON plataforma.onboarding_sessions;
CREATE POLICY onboarding_sessions_member_all ON plataforma.onboarding_sessions FOR ALL TO mastererp_app
 USING (initiated_by_user_id=plataforma.current_app_user_id()
 AND ((tenant_id IS NULL AND plataforma.current_app_tenant_id() IS NULL)
 OR plataforma.user_owns_current_tenant(tenant_id)))
 WITH CHECK (initiated_by_user_id=plataforma.current_app_user_id()
 AND ((tenant_id IS NULL AND plataforma.current_app_tenant_id() IS NULL)
 OR plataforma.user_owns_current_tenant(tenant_id)));
DROP POLICY IF EXISTS onboarding_step_responses_member_all ON plataforma.onboarding_step_responses;
CREATE POLICY onboarding_step_responses_member_all ON plataforma.onboarding_step_responses FOR ALL TO mastererp_app
 USING (EXISTS (SELECT 1 FROM plataforma.onboarding_sessions s WHERE s.id=session_id))
 WITH CHECK (EXISTS (SELECT 1 FROM plataforma.onboarding_sessions s WHERE s.id=session_id));

DROP POLICY IF EXISTS tenant_modules_member_all ON plataforma.tenant_modules;
CREATE POLICY tenant_modules_member_all ON plataforma.tenant_modules FOR ALL TO mastererp_app
 USING (plataforma.user_owns_current_tenant(tenant_id))
 WITH CHECK (plataforma.user_owns_current_tenant(tenant_id));

DROP POLICY IF EXISTS companies_member_all ON organizacion.companies;
CREATE POLICY companies_member_all ON organizacion.companies FOR ALL TO mastererp_app
 USING (plataforma.user_owns_current_tenant(tenant_id))
 WITH CHECK (plataforma.user_owns_current_tenant(tenant_id));

DROP POLICY IF EXISTS branches_member_all ON organizacion.branches;
CREATE POLICY branches_member_all ON organizacion.branches FOR ALL TO mastererp_app
 USING (plataforma.user_owns_current_tenant(tenant_id))
 WITH CHECK (plataforma.user_owns_current_tenant(tenant_id));

DROP POLICY IF EXISTS events_member_select ON auditoria.events;
DROP POLICY IF EXISTS events_member_insert ON auditoria.events;
CREATE POLICY events_member_select ON auditoria.events FOR SELECT TO mastererp_app
 USING (plataforma.user_has_tenant_access(tenant_id));
CREATE POLICY events_member_insert ON auditoria.events FOR INSERT TO mastererp_app
 WITH CHECK (actor_user_id=plataforma.current_app_user_id()
 AND plataforma.user_owns_current_tenant(tenant_id));
