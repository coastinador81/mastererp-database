-- Positive/negative idempotency of the exact new functions, really as application role.
BEGIN;
INSERT INTO plataforma.users(id,email,display_name) VALUES
 ('91000000-0000-0000-0000-000000000001','foundation-idempotency-a@example.invalid','Foundation idempotency A'),
 ('91000000-0000-0000-0000-000000000002','foundation-idempotency-b@example.invalid','Foundation idempotency B');
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_user_id','91000000-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','',true),set_config('app.current_operation','tenant.create',true),
 set_config('app.correlation_id','95000000-0000-0000-0000-000000000001',true);
DO $$ DECLARE a uuid; again uuid; company uuid; company_again uuid; b uuid;
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 a:=plataforma.create_tenant_with_owner('foundation-idempotency-a','foundation-idempotency-a','Foundation A','individual',
 '91000000-0000-0000-0000-000000000001','foundation-idempotent-tenant-a');
 again:=plataforma.create_tenant_with_owner('foundation-idempotency-a','foundation-idempotency-a','Foundation A','individual',
 '91000000-0000-0000-0000-000000000001','foundation-idempotent-tenant-a');
 IF a IS DISTINCT FROM again THEN RAISE EXCEPTION 'Tenant replay duplicated effect'; END IF;
 BEGIN
  PERFORM plataforma.create_tenant_with_owner('foundation-idempotency-a','foundation-idempotency-a','Changed content','individual',
   '91000000-0000-0000-0000-000000000001','foundation-idempotent-tenant-a');
  RAISE EXCEPTION 'Tenant content mismatch accepted';
 EXCEPTION WHEN unique_violation THEN NULL; END;
 PERFORM set_config('app.current_tenant_id',a::text,true);
 PERFORM set_config('app.current_operation','company.create',true);
 company:=organizacion.register_company_once('foundation-idempotent-company-a','Foundation company','US','USD','UTC',NULL);
 company_again:=organizacion.register_company_once('foundation-idempotent-company-a','Foundation company','US','USD','UTC',NULL);
 IF company IS DISTINCT FROM company_again OR (SELECT count(*) FROM organizacion.companies WHERE tenant_id=a)<>1
 THEN RAISE EXCEPTION 'Company replay duplicated effect'; END IF;
 BEGIN
  PERFORM organizacion.register_company_once('foundation-idempotent-company-a','Changed company','US','USD','UTC',NULL);
  RAISE EXCEPTION 'Company content mismatch accepted';
 EXCEPTION WHEN unique_violation THEN NULL; END;
 IF (SELECT count(*) FROM auditoria.events WHERE tenant_id=a AND action='company.created')<>1
 OR EXISTS(SELECT 1 FROM auditoria.events WHERE tenant_id=a AND correlation_id IS NULL)
 THEN RAISE EXCEPTION 'Company audit duplicated or uncorrelated'; END IF;
 IF (SELECT request_tenant_id FROM plataforma.idempotency_keys WHERE idempotency_key='foundation-idempotent-company-a') IS DISTINCT FROM a
 THEN RAISE EXCEPTION 'Company key not tenant-bound'; END IF;
 PERFORM set_config('app.current_tenant_id','',true);
 PERFORM set_config('app.current_user_id','91000000-0000-0000-0000-000000000002',true);
 b:=plataforma.create_tenant_with_owner('foundation-idempotency-b','foundation-idempotency-b','Foundation B','individual',
 '91000000-0000-0000-0000-000000000002','foundation-idempotent-tenant-b');
 PERFORM set_config('app.current_tenant_id',b::text,true);
 BEGIN
  PERFORM organizacion.register_company_once('foundation-idempotent-company-a','Foundation company','US','USD','UTC',NULL);
  RAISE EXCEPTION 'Foreign actor replay accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF EXISTS(SELECT 1 FROM plataforma.idempotency_keys WHERE idempotency_key='foundation-idempotent-company-a')
 THEN RAISE EXCEPTION 'Foreign key data exposed'; END IF;
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Effective role changed'; END IF;
END $$;
ROLLBACK;
