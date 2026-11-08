CREATE TABLE cloud_oauth_attempts (
    state_hash text PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    session_hash text NOT NULL,
    browser_hash text NOT NULL,
    nonce text NOT NULL,
    verifier_encrypted text NOT NULL,
    expires_at timestamptz NOT NULL
);
CREATE TABLE google_cloud_connections (
    user_id uuid PRIMARY KEY REFERENCES users(id),
    google_subject text NOT NULL,
    email text NOT NULL,
    refresh_encrypted text NOT NULL,
    scope text NOT NULL,
    status text NOT NULL DEFAULT 'connected' CHECK(status IN ('connected','reauthorize')),
    project_id text,
    project_name text,
    project_check jsonb,
    checked_at timestamptz,
    connected_at timestamptz NOT NULL DEFAULT now()
);
