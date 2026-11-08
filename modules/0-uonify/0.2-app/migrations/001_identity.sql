CREATE TABLE users (
    id uuid PRIMARY KEY,
    google_subject text NOT NULL UNIQUE,
    email text NOT NULL,
    display_name text NOT NULL DEFAULT '',
    onboarding_step text NOT NULL DEFAULT 'identity',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE sessions (
    token_hash text PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sessions_user ON sessions(user_id);
CREATE TABLE oauth_attempts (
    state_hash text PRIMARY KEY,
    browser_hash text NOT NULL,
    nonce text NOT NULL,
    verifier_encrypted text NOT NULL,
    expires_at timestamptz NOT NULL
);
CREATE TABLE request_limits (
    bucket text PRIMARY KEY,
    hits integer NOT NULL,
    expires_at timestamptz NOT NULL
);
