CREATE TABLE subscription_offers (
    version text PRIMARY KEY,
    currency text NOT NULL CHECK (currency = 'EUR'),
    monthly_cents integer NOT NULL CHECK (monthly_cents > 0),
    annual_cents integer NOT NULL CHECK (annual_cents > 0),
    trial_days integer NOT NULL CHECK (trial_days > 0),
    reminder_days integer NOT NULL CHECK (reminder_days > 0 AND reminder_days < trial_days),
    effective_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO subscription_offers (version,currency,monthly_cents,annual_cents,trial_days,reminder_days)
VALUES ('launch-2026-10-09','EUR',990,11880,14,3);
CREATE TABLE subscription_selections (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    offer_version text NOT NULL REFERENCES subscription_offers(version),
    interval text NOT NULL CHECK (interval IN ('monthly','annual')),
    updated_at timestamptz NOT NULL DEFAULT now()
);
