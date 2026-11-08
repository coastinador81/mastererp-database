-- 138 (ítem 4 build ronda 1; RESOLUCIÓN del Consultor 2026-10-27): confirmación de gasto POR GENERACIÓN
-- del MUNDO 090 (grafo). Análoga a la confirmación §125/084 (otra tabla) pero keyed por (user_id, job_id, request_sha256) y
-- con FK al grafo 090, NO a creative_generation_quotes (084). La confirmación es el acto del CLIENTE (ruta
-- confirmar_* del cliente, NO herramienta del modelo) que abre el gate de gasto 090 (gate_decider) para
-- ESE requestSha256 exacto; el modelo no tiene ruta de gasto → no puede fabricarla. `source` FIJO a
-- 'client_explicit' (coincide con _CLIENT_SOURCE del gate; una confirmación de modelo/worker no existe).
-- Contenido inmutable; used_at write-once (single-use OPCIONAL: la idempotencia del gasto ya la da el
-- envelope 090/single-POST, no se EXIGE un solo uso). Reusa account_write_allowed() (039). Aditiva,
-- forward-only, hueco 138 sobre la 137.
CREATE TABLE creative_execution_confirmations (
    user_id uuid NOT NULL,
    job_id uuid NOT NULL,
    request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    source text NOT NULL CHECK (source = 'client_explicit'),
    confirmed_at timestamptz NOT NULL DEFAULT now(),
    used_at timestamptz,
    PRIMARY KEY (user_id, job_id, request_sha256),
    FOREIGN KEY (user_id, job_id)
        REFERENCES creative_execution_jobs(user_id, id) ON DELETE CASCADE
);

-- Contenido inmutable; used_at write-once (NULL -> valor una sola vez). El acto del cliente no muta
-- bajo una confirmación ya emitida ni se puede "des-usar" (igual que la 133).
CREATE FUNCTION creative_execution_confirmation_write_once() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id <> OLD.user_id OR NEW.job_id <> OLD.job_id
        OR NEW.request_sha256 <> OLD.request_sha256 OR NEW.source <> OLD.source
        OR NEW.confirmed_at <> OLD.confirmed_at THEN
        RAISE EXCEPTION 'creative execution confirmation content is immutable';
    END IF;
    IF OLD.used_at IS NOT NULL AND NEW.used_at IS DISTINCT FROM OLD.used_at THEN
        RAISE EXCEPTION 'creative execution confirmation used_at is write-once';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_execution_confirmation_write_once
    BEFORE UPDATE ON creative_execution_confirmations
    FOR EACH ROW EXECUTE FUNCTION creative_execution_confirmation_write_once();

CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON creative_execution_confirmations
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
