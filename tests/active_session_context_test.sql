-- Identifiable fixtures exist only inside this rollback transaction.
BEGIN;
INSERT INTO plataforma.users(id,email,display_name) VALUES
 ('81000000-0000-0000-0000-000000000001','foundation-session-active@example.invalid','Foundation session active'),
 ('81000000-0000-0000-0000-000000000002','foundation-session-other@example.invalid','Foundation session other');
INSERT INTO plataforma.onboarding_sessions(initiated_by_user_id) VALUES
 ('81000000-0000-0000-0000-000000000001'),('81000000-0000-0000-0000-000000000002');
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,response_body) VALUES
 ('foundation-active-session-a','81000000-0000-0000-0000-000000000001','tenant.create','{}'),
 ('foundation-active-session-b','81000000-0000-0000-0000-000000000002','tenant.create','{}');
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_user_id','81000000-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','',true),set_config('app.current_operation','tenant.create',true);
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 IF (SELECT count(*) FROM plataforma.onboarding_sessions)<>1 THEN RAISE EXCEPTION 'Active session isolation failed'; END IF;
 IF (SELECT count(*) FROM plataforma.idempotency_keys)<>1 THEN RAISE EXCEPTION 'Active idempotency isolation failed'; END IF;
END $$;
RESET ROLE;
UPDATE plataforma.users SET status='inactive' WHERE id='81000000-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 IF EXISTS(SELECT 1 FROM plataforma.onboarding_sessions) OR EXISTS(SELECT 1 FROM plataforma.idempotency_keys)
 THEN RAISE EXCEPTION 'Inactive actor read pre-tenant data'; END IF;
 BEGIN
  INSERT INTO plataforma.onboarding_sessions(initiated_by_user_id) VALUES('81000000-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'Inactive actor created session';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('app.current_user_id','',true);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM plataforma.onboarding_sessions) OR EXISTS(SELECT 1 FROM plataforma.idempotency_keys)
 THEN RAISE EXCEPTION 'Absent actor read data'; END IF;
END $$;
ROLLBACK;
