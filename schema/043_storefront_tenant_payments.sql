-- Remove the superseded cash-only checkout signature after 040 creates the JSON payment contract.
DROP FUNCTION IF EXISTS ventas_digitales.checkout_crear(text,text,text,jsonb,jsonb,text,text,varchar);
