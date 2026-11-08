CREATE TABLE onboarding_profiles (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE consent_acceptances (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    document_id text NOT NULL,
    version text NOT NULL,
    accepted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, document_id, version)
);
