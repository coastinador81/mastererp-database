-- Estudio §E: nivel LOTE sobre el §6 por intento. Un OK cubre N piezas (1-4), sellando el conjunto
-- EXACTO de cotizaciones por hash (lote_sha256 sobre los N quote_sha256), con la SUMA de los máximos
-- EXACTOS por pieza, de UN SOLO USO. No toca §6 (084), ni la 129, ni el gate: cada pieza conserva su
-- quote/approval/reserve_once del §6; el lote solo VINCULA el conjunto y añade el OK único. Aditiva,
-- forward-only. Reutiliza creative_generation_immutable() (084) y account_write_allowed() (039).

CREATE TABLE creative_generation_lotes (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    thread_id text NOT NULL,
    issue_request_id uuid NOT NULL,
    lote_sha256 text NOT NULL CHECK (lote_sha256 ~ '^[0-9a-f]{64}$'),
    max_total_usd numeric(12,2) NOT NULL CHECK (max_total_usd > 0),
    piece_count integer NOT NULL CHECK (piece_count BETWEEN 1 AND 4),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, issue_request_id),
    UNIQUE (user_id, id),
    -- El sello NO es único a propósito: el mismo conjunto puede pedirse en lotes distintos
    -- (dos generaciones legítimas pagadas por separado). La integridad del conjunto se exige
    -- al aprobar (approve compara el sello reconocido con el del lote), no por unicidad global.
    FOREIGN KEY (user_id, thread_id) REFERENCES uony_threads(user_id, id)
);

-- Las piezas del lote: una fila por pieza, con su cotización §6. approval_id se fija al aprobar el
-- lote (NULL -> valor, una sola vez por el OK único del lote).
CREATE TABLE creative_generation_lote_pieces (
    user_id uuid NOT NULL,
    lote_id uuid NOT NULL,
    ordinal integer NOT NULL CHECK (ordinal >= 1),
    quote_id uuid NOT NULL,
    approval_request_id uuid NOT NULL,
    approval_id uuid,
    PRIMARY KEY (user_id, lote_id, ordinal),
    UNIQUE (user_id, lote_id, quote_id),
    UNIQUE (user_id, approval_request_id),
    FOREIGN KEY (user_id, lote_id) REFERENCES creative_generation_lotes(user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, quote_id) REFERENCES creative_generation_quotes(user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, approval_id) REFERENCES creative_generation_approvals(user_id, id)
);

-- Aprobación del lote: UN SOLO USO por lote (UNIQUE user_id,lote_id). El importe reconocido es la
-- suma de los máximos exactos; cada pieza no puede facturar por encima de su propio máximo (§6).
CREATE TABLE creative_generation_lote_approvals (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    lote_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    lote_sha256 text NOT NULL CHECK (lote_sha256 ~ '^[0-9a-f]{64}$'),
    max_total_usd numeric(12,2) NOT NULL CHECK (max_total_usd > 0),
    approved_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, lote_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, lote_id) REFERENCES creative_generation_lotes(user_id, id) ON DELETE CASCADE
);

CREATE INDEX creative_generation_lotes_thread
    ON creative_generation_lotes(user_id, thread_id, created_at DESC);

-- lotes y lote_approvals son recibos inmutables (como quotes/approvals del §6). lote_pieces muta
-- solo para fijar approval_id una vez: trigger que impide cambiar un approval_id ya escrito.
CREATE TRIGGER creative_generation_lote_immutable
    BEFORE UPDATE ON creative_generation_lotes
    FOR EACH ROW EXECUTE FUNCTION creative_generation_immutable();
CREATE TRIGGER creative_generation_lote_approval_immutable
    BEFORE UPDATE ON creative_generation_lote_approvals
    FOR EACH ROW EXECUTE FUNCTION creative_generation_immutable();

CREATE FUNCTION creative_lote_piece_approval_write_once() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.approval_id IS NOT NULL AND NEW.approval_id IS DISTINCT FROM OLD.approval_id THEN
        RAISE EXCEPTION 'creative lote piece approval is write-once';
    END IF;
    IF NEW.quote_id <> OLD.quote_id OR NEW.ordinal <> OLD.ordinal
        OR NEW.lote_id <> OLD.lote_id OR NEW.approval_request_id <> OLD.approval_request_id THEN
        RAISE EXCEPTION 'creative lote piece is immutable except approval_id';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_generation_lote_piece_write_once
    BEFORE UPDATE ON creative_generation_lote_pieces
    FOR EACH ROW EXECUTE FUNCTION creative_lote_piece_approval_write_once();

CREATE TRIGGER account_write_allowed BEFORE INSERT ON creative_generation_lotes
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON creative_generation_lote_pieces
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT ON creative_generation_lote_approvals
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
