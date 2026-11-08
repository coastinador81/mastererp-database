ALTER TABLE uony_requests ADD COLUMN requested_model text NOT NULL DEFAULT 'auto';
ALTER TABLE uony_requests ADD COLUMN effort text NOT NULL DEFAULT 'medium';
ALTER TABLE uony_requests ADD COLUMN selection_reason text NOT NULL DEFAULT 'Modelo inicial';
CREATE TABLE uony_preferences (
 user_id uuid PRIMARY KEY REFERENCES users(id),
 model text NOT NULL,
 effort text NOT NULL,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE uony_model_checks (
 user_id uuid NOT NULL REFERENCES users(id),
 project_id text NOT NULL,
 google_subject text NOT NULL,
 model text NOT NULL,
 effort text NOT NULL,
 checked_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,project_id,google_subject,model,effort)
);
