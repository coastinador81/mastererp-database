-- Keep the conversation visible after a product is deleted, but never send
-- its earlier facts back to the model after its explicit link is removed.
ALTER TABLE uony_threads ADD COLUMN product_history_cutoff_at timestamptz;
