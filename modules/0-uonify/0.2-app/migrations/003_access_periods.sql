-- Solo el backend podrá registrar periodos tras verificar la prueba o el pago.
CREATE TABLE access_periods (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind text NOT NULL CHECK (kind IN ('trial', 'paid')),
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL CHECK (ends_at > starts_at),
    revoked_at timestamptz,
    source_reference text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX access_periods_user ON access_periods(user_id, ends_at);
