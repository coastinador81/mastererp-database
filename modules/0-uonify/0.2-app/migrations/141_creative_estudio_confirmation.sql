-- Estudio ADK · Gate de gasto a PRUEBA DE MODELO (cond. 1 del veredicto ADK). Token de confirmación
-- de UN SOLO USO que ata el OK de gasto a un acto REAL del cliente: `cotizar_estudio` lo emite y lo
-- entrega SOLO a la UI del cliente (nunca al modelo); `confirmar_creacion` (ruta del cliente, NO
-- herramienta del modelo) exige el token + la cotización sellada vigente antes de aprobar el §6. El
-- modelo no tiene el token ni una herramienta de gasto → no puede disparar el gasto. Aditiva,
-- forward-only; no toca §6/§E/129/gate. Reutiliza account_write_allowed() (039).

CREATE TABLE creative_estudio_confirmations (
    user_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    token text NOT NULL CHECK (token ~ '^[A-Za-z0-9_-]{32,64}$'),
    quote_sha256 text NOT NULL CHECK (quote_sha256 ~ '^[0-9a-f]{64}$'),
    max_total_usd numeric(12,2) NOT NULL CHECK (max_total_usd > 0),
    thread_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    used_at timestamptz,
    PRIMARY KEY (user_id, quote_id),
    UNIQUE (user_id, token),
    FOREIGN KEY (user_id, quote_id)
        REFERENCES creative_generation_quotes(user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, thread_id) REFERENCES uony_threads(user_id, id)
);

-- El contenido es inmutable; used_at es write-once (NULL -> valor una sola vez). Así el token no muta
-- bajo una confirmación ya emitida ni se puede "des-usar".
CREATE FUNCTION creative_estudio_confirmation_write_once() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id <> OLD.user_id OR NEW.quote_id <> OLD.quote_id OR NEW.token <> OLD.token
        OR NEW.quote_sha256 <> OLD.quote_sha256 OR NEW.max_total_usd <> OLD.max_total_usd
        OR NEW.thread_id <> OLD.thread_id OR NEW.created_at <> OLD.created_at THEN
        RAISE EXCEPTION 'creative estudio confirmation content is immutable';
    END IF;
    IF OLD.used_at IS NOT NULL AND NEW.used_at IS DISTINCT FROM OLD.used_at THEN
        RAISE EXCEPTION 'creative estudio confirmation used_at is write-once';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_estudio_confirmation_write_once
    BEFORE UPDATE ON creative_estudio_confirmations
    FOR EACH ROW EXECUTE FUNCTION creative_estudio_confirmation_write_once();

CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON creative_estudio_confirmations
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
