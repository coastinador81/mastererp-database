ALTER TABLE billing_checkouts ADD COLUMN ui_mode text NOT NULL DEFAULT 'hosted'
    CHECK (ui_mode IN ('hosted','embedded'));
ALTER TABLE billing_checkouts ADD COLUMN renewal_accepted_at timestamptz;
