-- Planificación privada y sin generación. Una petición de conversación crea
-- como máximo una revisión; las ejecuciones futuras tendrán otro recibo.
CREATE TABLE uony_creative_plans (
    user_id uuid NOT NULL REFERENCES users(id),
    id uuid NOT NULL,
    google_subject text NOT NULL,
    project_id text NOT NULL,
    thread_id text NOT NULL,
    origin_request_id uuid NOT NULL,
    product_id uuid,
    product_revision integer,
    skill_version text NOT NULL,
    recipe text NOT NULL,
    plan jsonb NOT NULL,
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','stale')),
    spend_limit_usd numeric(10,2) NOT NULL DEFAULT 0 CHECK (spend_limit_usd >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,origin_request_id),
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,product_id) REFERENCES products(user_id,id),
    CHECK ((product_id IS NULL) = (product_revision IS NULL))
);
CREATE INDEX uony_creative_plans_thread_recent ON uony_creative_plans
    (user_id,google_subject,thread_id,created_at DESC);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_creative_plans
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
