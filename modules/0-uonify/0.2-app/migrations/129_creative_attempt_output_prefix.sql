-- 129 (§6 release creativo; «Consultor google» 2026-10-22, APROBADO CON CONDICIONES):
-- persistir UNA sola vez el prefijo de salida DURABLE de Veo en el intento, inmutable y
-- con forma canónica provider/{operationUuid}. El CHECK acota SOLO esta columna (el
-- prefijo de salida de Veo); NO vigila el subárbol {attempt}/ pelado, así que no rechaza
-- los segmentos hermanos craft/ (uploader), outputs/ (staging_v2) ni manifest/: esos
-- nombres viven en otras columnas/tablas, nunca en output_prefix (que es siempre NULL o
-- un prefijo provider/). Idempotente; el CHECK se añade NOT VALID y se valida después
-- para no bloquear la tabla ni a sus escritores. Forward-only (la reversión = flags en
-- False); queda en el hueco 129, por debajo de la 130 ya aplicada (el despliegue aplica
-- en orden de nombre).
ALTER TABLE creative_generation_attempts ADD COLUMN IF NOT EXISTS output_prefix text;

ALTER TABLE creative_generation_attempts
    DROP CONSTRAINT IF EXISTS creative_generation_attempts_output_prefix_form;
ALTER TABLE creative_generation_attempts
    ADD CONSTRAINT creative_generation_attempts_output_prefix_form
    CHECK (output_prefix IS NULL OR output_prefix ~
        '^gs://[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]/creative/staging/google/[0-9a-f-]{36}/[0-9a-f-]{36}/provider/[0-9a-f-]{36}/$')
    NOT VALID;
ALTER TABLE creative_generation_attempts
    VALIDATE CONSTRAINT creative_generation_attempts_output_prefix_form;

-- Inmutabilidad: una vez escrito (no NULL), output_prefix no puede cambiar.
CREATE OR REPLACE FUNCTION creative_attempt_output_prefix_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.output_prefix IS NOT NULL
            AND NEW.output_prefix IS DISTINCT FROM OLD.output_prefix THEN
        RAISE EXCEPTION
            'creative generation attempt output_prefix is immutable once set';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS creative_attempt_output_prefix_immutable
    ON creative_generation_attempts;
CREATE TRIGGER creative_attempt_output_prefix_immutable
    BEFORE UPDATE ON creative_generation_attempts
    FOR EACH ROW EXECUTE FUNCTION creative_attempt_output_prefix_immutable();
