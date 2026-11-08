CREATE TABLE amazon_connections (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    seller_id text NOT NULL UNIQUE,
    marketplace_id text NOT NULL DEFAULT 'A1RKKUPIHCS9HS',
    refresh_encrypted text NOT NULL,
    connected_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE amazon_oauth_attempts (
    id text PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_hash text NOT NULL,
    launch_hash text UNIQUE,
    bootstrap_hash text UNIQUE,
    state_encrypted text NOT NULL,
    browser_hash text,
    payload_encrypted text,
    expected_seller text,
    status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','confirming','ready','authorizing','exchanging','success','error')),
    error_code text,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX amazon_attempts_user ON amazon_oauth_attempts(user_id);
CREATE TABLE amazon_oauth_intents (
    id text PRIMARY KEY,
    browser_hash text NOT NULL,
    payload_encrypted text NOT NULL,
    seller_id text NOT NULL,
    expires_at timestamptz NOT NULL
);
