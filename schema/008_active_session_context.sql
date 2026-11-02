-- Forward-only fix after 007: pre-tenant onboarding also requires an active actor.
DROP POLICY IF EXISTS foundation_session_actor ON plataforma.onboarding_sessions;
CREATE POLICY foundation_session_actor ON plataforma.onboarding_sessions AS RESTRICTIVE
 FOR ALL TO mastererp_app USING
 (EXISTS(SELECT 1 FROM plataforma.users u WHERE u.id=plataforma.current_app_user_id() AND u.status='active'))
 WITH CHECK
 (EXISTS(SELECT 1 FROM plataforma.users u WHERE u.id=plataforma.current_app_user_id() AND u.status='active'));

DROP POLICY IF EXISTS foundation_idempotency_context ON plataforma.idempotency_keys;
CREATE POLICY foundation_idempotency_context ON plataforma.idempotency_keys AS RESTRICTIVE
 FOR SELECT TO mastererp_app USING
 (EXISTS(SELECT 1 FROM plataforma.users u WHERE u.id=plataforma.current_app_user_id() AND u.status='active')
 AND ((request_tenant_id IS NULL AND plataforma.current_app_tenant_id() IS NULL)
      OR plataforma.user_has_tenant_access(request_tenant_id)));
