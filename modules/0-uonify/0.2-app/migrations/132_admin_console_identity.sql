-- Consola de administración interna (H1): identidad del equipo, acceso correo+código+2FA,
-- sesión de panel separada de la del cliente y auditoría. Superficie PRIVILEGIADA y aislada:
-- ningún dato de estas tablas se expone al cliente. Aditiva: no toca ninguna tabla existente.

CREATE TABLE IF NOT EXISTS admin_users (
    id uuid PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name text NOT NULL,
    role text NOT NULL CHECK (role IN ('superadmin','operaciones','soporte','finanzas','lectura')),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended')),
    -- Secreto TOTP cifrado en reposo con Fernet (misma clave de servidor que el resto). NULL hasta enrolar.
    totp_secret_encrypted text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES admin_users(id)
);

-- Códigos de recuperación de un solo uso (alternativa al TOTP), hasheados (sha256), nunca en claro.
CREATE TABLE IF NOT EXISTS admin_recovery_codes (
    id uuid PRIMARY KEY,
    admin_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    code_hash text NOT NULL,
    used_at timestamptz
);
CREATE INDEX IF NOT EXISTS admin_recovery_codes_admin ON admin_recovery_codes(admin_id);

-- Reto de correo: código de 6 dígitos (hash), ligado al navegador, un solo uso, con caducidad y reenvío con espera.
CREATE TABLE IF NOT EXISTS admin_email_challenges (
    id uuid PRIMARY KEY,
    admin_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    code_hash text NOT NULL,
    browser_hash text NOT NULL,
    attempts int NOT NULL DEFAULT 0,
    expires_at timestamptz NOT NULL,
    resend_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_email_challenges_expiry ON admin_email_challenges(expires_at);

-- Segundo factor tras validar el correo: ventana corta para presentar TOTP o código de recuperación.
CREATE TABLE IF NOT EXISTS admin_mfa_challenges (
    id uuid PRIMARY KEY,
    admin_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    browser_hash text NOT NULL,
    attempts int NOT NULL DEFAULT 0,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_mfa_challenges_expiry ON admin_mfa_challenges(expires_at);

-- Sesión del panel: token opaco hasheado (sha256), caducidad corta, separada de sessions del cliente.
CREATE TABLE IF NOT EXISTS admin_sessions (
    token_hash text PRIMARY KEY,
    admin_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_sessions_admin ON admin_sessions(admin_id);

-- Registro de auditoría: toda acción del equipo (quién/qué/cuándo/sobre qué/resultado). Sin contenido sensible.
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id uuid PRIMARY KEY,
    at timestamptz NOT NULL DEFAULT now(),
    actor_admin_id uuid REFERENCES admin_users(id),
    actor_email text NOT NULL,
    action text NOT NULL,
    target_type text,
    target_id text,
    target_label text,
    reason text,
    detail text,
    result text NOT NULL DEFAULT 'ok'
);
CREATE INDEX IF NOT EXISTS admin_audit_at ON admin_audit_log(at DESC);
