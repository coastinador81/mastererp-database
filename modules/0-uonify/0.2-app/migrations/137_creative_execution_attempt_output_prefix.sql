-- 137 (ítem 4, RESOLUCIÓN del Consultor 2026-10-27): el prefijo §6 de salida de clips-only vive en el
-- MUNDO 090 (grafo de ejecución), NO en reserve_once/084. Persiste UNA sola vez el output_prefix durable
-- del intento del GRAFO en creative_execution_attempts (la tabla que direcciona fence/claim.attempt_id),
-- inmutable y con la forma canónica provider/{operationUuid} IDÉNTICA a la 129 (mismo constructor
-- google_provider_output_uri; ambos mundos comparten la forma). Así el reader reconstruye el prefijo
-- desde la MISMA fila del intento (fence.attempt_id==row.id, authority.operation_id==operationId) y la
-- aserción derived==persisted pasa. El CHECK acota SOLO esta columna (NULL o un prefijo provider/); no
-- vigila el subárbol {attempt}/ pelado. Idempotente; CHECK NOT VALID + VALIDATE después para no bloquear
-- la tabla ni a sus escritores. Forward-only (reversión = dejar la columna NULL). Hueco 137, sobre la 136.
ALTER TABLE creative_execution_attempts ADD COLUMN IF NOT EXISTS output_prefix text;

ALTER TABLE creative_execution_attempts
    DROP CONSTRAINT IF EXISTS creative_execution_attempts_output_prefix_form;
ALTER TABLE creative_execution_attempts
    ADD CONSTRAINT creative_execution_attempts_output_prefix_form
    CHECK (output_prefix IS NULL OR output_prefix ~
        '^gs://[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]/creative/staging/google/[0-9a-f-]{36}/[0-9a-f-]{36}/provider/[0-9a-f-]{36}/$')
    NOT VALID;
ALTER TABLE creative_execution_attempts
    VALIDATE CONSTRAINT creative_execution_attempts_output_prefix_form;

-- Inmutabilidad: una vez escrito (no NULL), output_prefix no puede cambiar (igual que la 129).
CREATE OR REPLACE FUNCTION creative_execution_attempt_output_prefix_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.output_prefix IS NOT NULL
            AND NEW.output_prefix IS DISTINCT FROM OLD.output_prefix THEN
        RAISE EXCEPTION
            'creative execution attempt output_prefix is immutable once set';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS creative_execution_attempt_output_prefix_immutable
    ON creative_execution_attempts;
CREATE TRIGGER creative_execution_attempt_output_prefix_immutable
    BEFORE UPDATE ON creative_execution_attempts
    FOR EACH ROW EXECUTE FUNCTION creative_execution_attempt_output_prefix_immutable();
