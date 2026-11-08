CREATE TABLE drive_onboarding_preferences (
    user_id uuid PRIMARY KEY REFERENCES users(id),
    deferred_at timestamptz NOT NULL DEFAULT now()
);
