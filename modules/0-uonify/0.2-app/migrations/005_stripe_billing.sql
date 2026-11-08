CREATE TABLE billing_checkouts (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    offer_version text NOT NULL REFERENCES subscription_offers(version),
    interval text NOT NULL CHECK (interval IN ('monthly','annual')),
    stripe_session text UNIQUE,
    stripe_subscription text UNIQUE,
    status text NOT NULL DEFAULT 'creating' CHECK (status IN ('creating','open','complete','expired')),
    trial_days integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX billing_one_open_checkout ON billing_checkouts(user_id) WHERE status IN ('creating','open');
CREATE TABLE billing_subscriptions (
    stripe_id text PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    checkout_id uuid UNIQUE NOT NULL REFERENCES billing_checkouts(id),
    customer_id text NOT NULL,
    status text NOT NULL,
    cancel_at_period_end boolean NOT NULL DEFAULT false,
    trial_start timestamptz,
    trial_end timestamptz,
    period_end timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE billing_events (id text PRIMARY KEY, processed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE billing_reminders (
    subscription_id text PRIMARY KEY REFERENCES billing_subscriptions(stripe_id),
    due_at timestamptz NOT NULL,
    delivered_at timestamptz,
    canceled_at timestamptz
);
