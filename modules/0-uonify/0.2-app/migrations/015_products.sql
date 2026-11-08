CREATE TABLE products (
    user_id uuid NOT NULL REFERENCES users(id),
    id uuid NOT NULL,
    sku text NOT NULL,
    data jsonb NOT NULL,
    revision integer NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    PRIMARY KEY(user_id,id)
);
CREATE UNIQUE INDEX products_active_sku ON products(user_id,lower(sku)) WHERE deleted_at IS NULL;
CREATE TABLE product_revisions (
    user_id uuid NOT NULL,
    product_id uuid NOT NULL,
    revision integer NOT NULL,
    data jsonb NOT NULL,
    source text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,product_id,revision),
    FOREIGN KEY(user_id,product_id) REFERENCES products(user_id,id)
);
ALTER TABLE uony_requests ADD COLUMN product_context jsonb;
ALTER TABLE uony_requests ADD COLUMN product_changes jsonb NOT NULL DEFAULT '[]';
