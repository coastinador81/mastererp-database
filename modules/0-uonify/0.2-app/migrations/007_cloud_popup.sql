CREATE TABLE cloud_popup_flows (
    id text PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    session_hash text NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','success','error')),
    expires_at timestamptz NOT NULL
);
