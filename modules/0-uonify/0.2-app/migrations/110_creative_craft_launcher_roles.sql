-- Inactive least-privilege identities and desired deployment policy for the
-- disconnected Craft launcher.  This migration does not grant LOGIN, enable
-- a worker, register startup hooks or activate provider execution.

-- Roles are cluster-global even when tests or tenants migrate independent
-- schemas.  Serialize this DDL across those schema-local transactions.
SELECT pg_advisory_xact_lock(
    hashtextextended('uonify-craft-launcher-roles-v1',0));

-- A pre-existing identity is reusable only when it has no membership edge in
-- either direction.  Silently revoking a subset would make a contaminated
-- cluster look least-privileged while an unknown inheritance path survives.
-- This check intentionally runs before every ALTER/REVOKE/GRANT below.
DO $$
DECLARE contaminated text;
DECLARE owned text;
DECLARE privileged text;
BEGIN
    SELECT string_agg(DISTINCT role_name,',' ORDER BY role_name)
      INTO contaminated
      FROM (
        SELECT role.rolname AS role_name
          FROM pg_roles role
          JOIN pg_auth_members membership
            ON membership.roleid=role.oid OR membership.member=role.oid
         WHERE role.rolname IN (
             'uonify_craft_launcher_preparer',
             'uonify_craft_launcher_ack_worker',
             'uonify_craft_escrow_worker')
      ) contaminated_roles;
    IF contaminated IS NOT NULL THEN
        RAISE EXCEPTION
            'pre-existing Craft role membership is contaminated: %',
            contaminated USING ERRCODE='55000';
    END IF;
    SELECT string_agg(role.rolname,',' ORDER BY role.rolname)
      INTO owned
      FROM pg_roles role
     WHERE role.rolname IN (
             'uonify_craft_launcher_preparer',
             'uonify_craft_launcher_ack_worker',
             'uonify_craft_escrow_worker')
       AND (
         -- Shared owner dependencies include objects in other schemas and
         -- databases, plus ownership of a database itself.
         EXISTS (SELECT 1 FROM pg_shdepend dependency
                  WHERE dependency.refclassid='pg_authid'::regclass
                    AND dependency.refobjid=role.oid
                    AND dependency.deptype='o')
         OR
         EXISTS (SELECT 1 FROM pg_namespace namespace
                  WHERE namespace.nspname=current_schema()
                    AND namespace.nspowner=role.oid)
         OR EXISTS (
            SELECT 1 FROM pg_class relation
            JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
            WHERE namespace.nspname=current_schema()
              AND relation.relowner=role.oid)
         OR EXISTS (
            SELECT 1 FROM pg_proc routine
            JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
            WHERE namespace.nspname=current_schema()
              AND routine.proowner=role.oid)
       );
    IF owned IS NOT NULL THEN
        RAISE EXCEPTION
            'pre-existing Craft role ownership is contaminated: %', owned
            USING ERRCODE='55000';
    END IF;
    SELECT string_agg(role.rolname,',' ORDER BY role.rolname)
      INTO privileged
      FROM pg_roles role
     WHERE role.rolname IN (
             'uonify_craft_launcher_preparer',
             'uonify_craft_launcher_ack_worker',
             'uonify_craft_escrow_worker')
       AND EXISTS (
         -- ACL dependencies are cluster-visible here, including grants and
         -- ALTER DEFAULT PRIVILEGES recorded in another schema or database.
         SELECT 1 FROM pg_shdepend dependency
          WHERE dependency.refclassid='pg_authid'::regclass
            AND dependency.refobjid=role.oid
            AND dependency.deptype='a');
    IF privileged IS NOT NULL THEN
        RAISE EXCEPTION
            'pre-existing Craft role ACL is contaminated: %', privileged
            USING ERRCODE='55000';
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                   WHERE rolname='uonify_craft_launcher_preparer') THEN
        CREATE ROLE uonify_craft_launcher_preparer NOLOGIN NOINHERIT
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                   WHERE rolname='uonify_craft_launcher_ack_worker') THEN
        CREATE ROLE uonify_craft_launcher_ack_worker NOLOGIN NOINHERIT
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                   WHERE rolname='uonify_craft_escrow_worker') THEN
        CREATE ROLE uonify_craft_escrow_worker NOLOGIN NOINHERIT
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
END $$;

ALTER ROLE uonify_craft_launcher_preparer NOLOGIN NOINHERIT
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE uonify_craft_launcher_ack_worker NOLOGIN NOINHERIT
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE uonify_craft_escrow_worker NOLOGIN NOINHERIT
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

CREATE TABLE creative_craft_launcher_deployment_policies (
    policy_id text NOT NULL
        CHECK (policy_id ~ '^[a-z][a-z0-9._-]{1,127}$'),
    policy_version integer NOT NULL CHECK (policy_version > 0),
    launcher_protocol_version integer NOT NULL
        CHECK (launcher_protocol_version = 1),
    launcher_version text NOT NULL
        CHECK (launcher_version ~ '^[a-z][a-z0-9._-]{1,127}$'),
    launcher_artifact_manifest jsonb NOT NULL
        CHECK (jsonb_typeof(launcher_artifact_manifest)='object'),
    launcher_artifact_sha256 text NOT NULL
        CHECK (launcher_artifact_sha256 ~ '^[0-9a-f]{64}$'),
    platform text NOT NULL CHECK (platform = 'linux/arm64'),
    launcher_uid integer NOT NULL CHECK (launcher_uid > 0),
    worker_uid integer NOT NULL CHECK (worker_uid > 0),
    private_gid integer NOT NULL CHECK (private_gid > 0),
    control_socket_path text NOT NULL
        CHECK (left(control_socket_path,1)='/'
               AND length(control_socket_path) BETWEEN 2 AND 4096
               AND control_socket_path !~ '[[:cntrl:]]'),
    control_socket_mode integer NOT NULL CHECK (control_socket_mode = 432),
    control_directory_mode integer NOT NULL
        CHECK (control_directory_mode = 456),
    oci_socket_path text NOT NULL
        CHECK (left(oci_socket_path,1)='/'
               AND length(oci_socket_path) BETWEEN 2 AND 4096
               AND oci_socket_path !~ '[[:cntrl:]]'),
    seccomp_profile text NOT NULL
        CHECK (seccomp_profile ~ '^[a-z][a-z0-9._-]{1,127}$'),
    seccomp_profile_version text NOT NULL
        CHECK (seccomp_profile_version ~ '^[a-z0-9][a-z0-9._-]{0,127}$'),
    desired_active boolean NOT NULL DEFAULT false CHECK (NOT desired_active),
    policy_sha256 text NOT NULL
        CHECK (policy_sha256 ~ '^[0-9a-f]{64}$'),
    registered_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (policy_id,policy_version),
    UNIQUE (policy_sha256),
    CHECK (launcher_uid <> worker_uid),
    CHECK (launcher_uid <> private_gid),
    CHECK (worker_uid <> private_gid),
    CHECK (control_socket_path <> oci_socket_path)
);

CREATE FUNCTION creative_craft_launcher_deployment_policy_guard()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
    RAISE EXCEPTION 'creative craft launcher deployment policy is append-only';
END; $$;

CREATE TRIGGER creative_craft_launcher_deployment_policy_guard
    BEFORE UPDATE OR DELETE ON creative_craft_launcher_deployment_policies
    FOR EACH ROW EXECUTE FUNCTION
        creative_craft_launcher_deployment_policy_guard();

-- Both digests use canonical UTF-8 JSON (sorted keys, compact separators).
-- The artifact manifest pins the five launcher modules audited by ART-02;
-- the policy digest pins every desired field except itself and registered_at.
-- The policy is intentionally inactive.
INSERT INTO creative_craft_launcher_deployment_policies
    (policy_id,policy_version,launcher_protocol_version,launcher_version,
     launcher_artifact_manifest,launcher_artifact_sha256,platform,launcher_uid,
     worker_uid,private_gid,control_socket_path,control_socket_mode,
     control_directory_mode,oci_socket_path,seccomp_profile,
     seccomp_profile_version,desired_active,policy_sha256)
VALUES
    ('craft-launcher-linux-arm64-v1',1,1,'craft-launcher-v2',
     '{"schemaVersion":1,"files":[
       {"path":"backend/app/creative_craft_launcher_contract.py",
        "sha256":"cbdf5cb92e314f30475def885da3b251a6a45232fdeba4903358bcb1bc410f76"},
       {"path":"backend/app/creative_craft_launcher_authority.py",
        "sha256":"f427deed956e345d5482e281eda28872dfc21da75377707b03ee2f0144c5870f"},
       {"path":"backend/app/creative_craft_launcher.py",
        "sha256":"02d4707556993016cedbad013c8adf7b3566e35cae43d9d999c9b3e02e07e2a0"},
       {"path":"backend/app/creative_craft_docker_launcher.py",
        "sha256":"cd630ff29bf13d7d897a188b237fab159550845785c48cff654b9272903ccdb8"},
       {"path":"backend/app/creative_craft_launcher_socket.py",
        "sha256":"46045d817a81a776fb3f2384d029e75fea19f1c24b641be5ca850e7c18a1d778"}
      ]}'::jsonb,
     '41f44605b41004b979b22964eb77f1f7b09b6d8e535d8a5fb12aa4cf8e435c22',
     'linux/arm64',10021,10022,11020,
     '/run/uonify/craft-launcher/launcher.sock',432,456,
     '/var/run/docker.sock','builtin','docker-29.7.2-default',false,
     '3b70950fe3410e369dfbf6efb252f78c4806d1f17364dcc70a87cdc310b90151');

DO $$ DECLARE schema_name text := current_schema(); BEGIN
    -- Normalize any direct privileges left by an abandoned local experiment.
    -- The identities stay deliberately non-executable until a later migration
    -- introduces narrowly-scoped transition functions and activates policy.
    EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I FROM
        uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,
        uonify_craft_escrow_worker',schema_name);
    EXECUTE format('REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I FROM
        uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,
        uonify_craft_escrow_worker',schema_name);
    EXECUTE format('REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA %I FROM
        uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,
        uonify_craft_escrow_worker',schema_name);
    EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA %I FROM
        uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,
        uonify_craft_escrow_worker',schema_name);
END $$;

-- Remove historical or default broad authority before adding the exact
-- preparation, terminal-ACK and escrow projections below.
REVOKE ALL ON creative_craft_launcher_reservations,
    creative_craft_launcher_ack_outbox,
    creative_craft_launcher_deployment_policies
    FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,
         uonify_creative_evaluator,uonify_creative_reviewer,
         uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,
         uonify_craft_escrow_worker;

REVOKE ALL ON FUNCTION creative_craft_launcher_deployment_policy_guard()
    FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,
         uonify_creative_evaluator,uonify_creative_reviewer,
         uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,
         uonify_craft_escrow_worker;
