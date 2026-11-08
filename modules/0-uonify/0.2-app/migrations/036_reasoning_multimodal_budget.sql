-- Bounded allowance for proposing and independently checking multimodal evidence.
-- Calls and actual usage remain recorded; this is a reservation ceiling, not a charge.
ALTER TABLE product_reasoning_jobs ALTER COLUMN max_tokens SET DEFAULT 400000;
