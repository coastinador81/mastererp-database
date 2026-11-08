CREATE TABLE drive_oauth_attempts (LIKE cloud_oauth_attempts INCLUDING ALL);
ALTER TABLE drive_oauth_attempts ADD FOREIGN KEY (user_id) REFERENCES users(id);
CREATE TABLE drive_popup_flows (LIKE cloud_popup_flows INCLUDING ALL);
ALTER TABLE drive_popup_flows ADD FOREIGN KEY (user_id) REFERENCES users(id);
CREATE TABLE google_drive_connections (
    user_id uuid PRIMARY KEY REFERENCES users(id),
    google_subject text NOT NULL,
    email text NOT NULL,
    refresh_encrypted text NOT NULL,
    scope text NOT NULL,
    status text NOT NULL DEFAULT 'connected' CHECK(status IN ('connected','reauthorize')),
    folder_id text,
    connected_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE drive_materials (
    user_id uuid NOT NULL REFERENCES users(id),
    google_subject text NOT NULL,
    file_id text NOT NULL,
    metadata jsonb NOT NULL,
    selected_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,google_subject,file_id)
);
CREATE TABLE drive_uploads (
    user_id uuid NOT NULL REFERENCES users(id),
    google_subject text NOT NULL,
    request_id uuid NOT NULL,
    file_id text NOT NULL,
    fingerprint text NOT NULL,
    PRIMARY KEY(user_id,google_subject,request_id)
);
