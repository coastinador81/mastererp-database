-- 142 (rama (c) preview Drive, decisión del dueño 2026-10-27): registro de ENTREGA del clip clips-only al
-- Drive del cliente. El clip adoptado (089, tras el paso storage_adopt del MUNDO 090) se COPIA al Drive del
-- cliente (drive.file app-owned) y el preview es NATIVO en su Drive. Esta tabla da (a) IDEMPOTENCIA: el fileId
-- de Drive se RESERVA y persiste ANTES de subir, de modo que un reintento REUSE el mismo id
-- (google_drive_provider.upload es 409-idempotente) y NO duplique en el Drive del cliente; (b) el PUNTERO de
-- preview (delivered_file_id = el fileId del cliente en SU Drive, card-safe: nunca gs://, bucket, generación ni
-- project-id — D-PROTECCIÓN). Una fila por (user_id, job_id) (clips-only = 1 clip por job). Contenido inmutable;
-- delivered_file_id/sha256/delivered_at write-once (reserved -> delivered una sola vez, sin revertir). Reusa
-- account_write_allowed() (039). Aditiva, forward-only.
-- ORDEN/combined6: nº 142 = DESPUÉS del set creativo (131–135 → renumerado 137–141) y de admin (131–136); evita
-- la colisión de número con admin_platform 136. FKea SOLO a creative_execution_jobs (mig 088, base, siempre
-- presente) + account_write_allowed (039) → NO depende del rango renumerado 137–141 (sin riesgo de FK-target).
CREATE TABLE creative_clip_drive_deliveries (
    user_id uuid NOT NULL,
    job_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    reserved_file_id text NOT NULL CHECK (reserved_file_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    delivered_file_id text CHECK (delivered_file_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    sha256 text CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    status text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved', 'delivered')),
    reserved_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz,
    PRIMARY KEY (user_id, job_id),
    FOREIGN KEY (user_id, job_id)
        REFERENCES creative_execution_jobs(user_id, id) ON DELETE CASCADE,
    -- Coherencia de estado: delivered <=> hay fileId entregado <=> hay sha256 <=> hay delivered_at.
    CHECK ((status = 'delivered') = (delivered_file_id IS NOT NULL)),
    CHECK ((delivered_file_id IS NULL) = (sha256 IS NULL)),
    CHECK ((delivered_file_id IS NULL) = (delivered_at IS NULL))
);

-- Contenido inmutable; la transición reserved -> delivered es write-once (NULL -> valor una sola vez) y no
-- revierte. El id reservado no cambia (la idempotencia depende de reusar SIEMPRE el mismo id).
CREATE FUNCTION creative_clip_drive_delivery_write_once() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id <> OLD.user_id OR NEW.job_id <> OLD.job_id
        OR NEW.asset_id <> OLD.asset_id OR NEW.reserved_file_id <> OLD.reserved_file_id
        OR NEW.reserved_at <> OLD.reserved_at THEN
        RAISE EXCEPTION 'creative clip drive delivery content is immutable';
    END IF;
    IF OLD.delivered_file_id IS NOT NULL
        AND (NEW.delivered_file_id IS DISTINCT FROM OLD.delivered_file_id
             OR NEW.sha256 IS DISTINCT FROM OLD.sha256
             OR NEW.delivered_at IS DISTINCT FROM OLD.delivered_at
             OR NEW.status IS DISTINCT FROM OLD.status) THEN
        RAISE EXCEPTION 'creative clip drive delivery is write-once once delivered';
    END IF;
    IF OLD.status = 'delivered' AND NEW.status <> 'delivered' THEN
        RAISE EXCEPTION 'creative clip drive delivery cannot revert from delivered';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_clip_drive_delivery_write_once
    BEFORE UPDATE ON creative_clip_drive_deliveries
    FOR EACH ROW EXECUTE FUNCTION creative_clip_drive_delivery_write_once();

CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON creative_clip_drive_deliveries
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
