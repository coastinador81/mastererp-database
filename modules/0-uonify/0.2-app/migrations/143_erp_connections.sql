-- Conexión de Uony con ERP · Finanzas (D-UONY-ERP-AGENTES-20261110), igual que Drive: el usuario
-- autoriza en una ventana contra el Cognito del ERP y el servidor guarda solo el refresh cifrado
-- con la misma encryption-key de Drive (Consultor C4). Nunca access tokens, nombres ni importes.

-- Intentos y ventanas: el mismo diseño que drive_oauth_attempts y drive_popup_flows (006, 007, 008
-- y 013), con la clave ajena a users que 008 añade aparte.
CREATE TABLE IF NOT EXISTS erp_oauth_attempts (
    state_hash text PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    session_hash text NOT NULL,
    browser_hash text NOT NULL,
    nonce text NOT NULL,
    verifier_encrypted text NOT NULL,
    expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS erp_popup_flows (
    id text PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    session_hash text NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','success','error')),
    expires_at timestamptz NOT NULL,
    error_code text
);

-- Una conexión por usuario. El sub de Cognito se fija en la primera conexión: otra cuenta deja
-- 'account_mismatch' y hay que desconectar para cambiarla. 'not_linked': la cuenta existe en el
-- ERP, pero su identidad no está dada de alta. Espacio y empresa son solo ids elegidos por el
-- usuario y comprobados contra el ERP; no conceden permisos (el ERP decide cada lectura).
CREATE TABLE IF NOT EXISTS erp_connections (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    issuer text NOT NULL,
    cognito_sub text NOT NULL,
    email text NOT NULL,
    refresh_encrypted text NOT NULL,
    scope text NOT NULL,
    status text NOT NULL DEFAULT 'connected'
        CHECK(status IN ('connected','reauthorize','not_linked','account_mismatch')),
    tenant_id uuid,
    company_id uuid,
    connected_at timestamptz NOT NULL DEFAULT now(),
    refreshed_at timestamptz,
    CHECK(company_id IS NULL OR tenant_id IS NOT NULL)
);

-- Referencias opacas que ve el modelo en lugar de los UUID del ERP, con caducidad (como
-- uony_drive_scopes, 123). Atadas al espacio y la empresa en los que se emitieron.
CREATE TABLE IF NOT EXISTS uony_erp_refs (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ref text NOT NULL CHECK(length(ref) BETWEEN 1 AND 128),
    kind text NOT NULL CHECK(length(kind) BETWEEN 1 AND 32),
    record_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    expires_at timestamptz NOT NULL,
    PRIMARY KEY(user_id, ref)
);
CREATE INDEX IF NOT EXISTS uony_erp_refs_expiry ON uony_erp_refs(expires_at);

-- Definición vigente (040) más la tarjeta del ERP. El tope sube de 5 a 6 con el proveedor nuevo,
-- como en 040: cada proveedor aparece una sola vez.
CREATE OR REPLACE FUNCTION uony_connection_actions_valid(actions jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(actions) <> 'array' THEN false ELSE
        jsonb_array_length(actions) <= 6
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(actions) AS entry
            WHERE entry NOT IN ('{"provider":"amazon","action":"manage"}'::jsonb,
                '{"provider":"cloud","action":"manage"}'::jsonb,
                '{"provider":"drive","action":"manage"}'::jsonb,
                '{"provider":"blender","action":"manage"}'::jsonb,
                '{"provider":"account","action":"manage"}'::jsonb,
                '{"provider":"erp","action":"manage"}'::jsonb))
        AND jsonb_array_length(actions) = (SELECT count(DISTINCT entry) FROM jsonb_array_elements(actions) AS entry)
    END;
$$;
