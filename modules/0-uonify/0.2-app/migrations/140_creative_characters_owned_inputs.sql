-- 132 (§B del Estudio — ELEMENTOS reutilizables + registro de PROPIEDAD de entradas).
-- Dueño 22-10: la sección «Personajes» pasa a «Elementos»: una sola sección con CUATRO tipos
-- (personaje, producto/objeto, lugar, estilo); solo el personaje lleva voz (opcional); persona real →
-- consentimiento. «Consultor google» 2026-10-22 (VEREDICTO-ELEMENTOS-REUTILIZABLES-ESTUDIO): la
-- persistencia es craft/infra, FUERA de su veto Google; el USO en generación (refs de imagen 1-14 =
-- vía fiable; lugar/estilo por primer fotograma; asset Veo 1-3 / Omni 1-13 contract_only, no
-- prometidos) es §G/§H de SC. Los TOPES por modelo viven en los contratos de petición, NO aquí.
-- Forward-only; reversión = dejar de escribir estas tablas (inerte hasta cablear el Estudio). Queda
-- por encima de la 130 ya aplicada y de la 131 (§E de SC); el despliegue aplica en orden de nombre y
-- tolera huecos. Sin GRANTs en la propia migración (como 089_creative_asset_registry): app-runtime.
--
-- Tres tablas, user-scoped y ligadas a uony_projects:
--   * creative_owned_inputs: PRUEBA DE PROPIEDAD de una entrada aportada por el cliente (foto/clip
--     subido, de Drive o de la ficha; o imagen/fotograma generado), por su SHA256 de CONTENIDO. Es el
--     registro por el que creative_generation_ledger._request podrá aceptar entradas (hoy las rechaza:
--     creative_assets_unverified). El input_hash de una petición = sha256 de cada ítem de input_manifest
--     (creative_request_fingerprint.fingerprint), así que, si el cliente es su dueño, existe una fila
--     'allowed' con ese (user_id, sha256). La ELEVACIÓN del gate en _request es del §6/§H de SC (cambio
--     de invariante, con su veredicto); esta migración solo CREA el store. Contenido inmutable salvo
--     revocación. NO cambia respecto a la versión anterior de la 132 (el §H de SC depende de ella).
--   * creative_elements: elemento de la biblioteca del cliente, con TIPO (personaje/producto/lugar/
--     estilo), nombre, y —solo para personaje— voz prebuilt opcional + persona real + consentimiento.
--   * creative_element_references: imágenes de referencia ORDENADAS del elemento → entradas owned.

CREATE TABLE creative_owned_inputs (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id uuid NOT NULL,
    uonify_project_id uuid,
    sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    kind text NOT NULL CHECK (kind IN ('image','video','audio')),
    mime_type text NOT NULL CHECK (char_length(mime_type) BETWEEN 3 AND 128),
    byte_size bigint NOT NULL CHECK (byte_size > 0),
    origin text NOT NULL CHECK (origin IN ('drive','upload','product_photo','generated')),
    storage_bucket text NOT NULL CHECK (char_length(storage_bucket) BETWEEN 3 AND 222),
    storage_name text NOT NULL CHECK (char_length(storage_name) BETWEEN 1 AND 1024),
    storage_generation bigint NOT NULL CHECK (storage_generation > 0),
    authorization_state text NOT NULL DEFAULT 'allowed'
        CHECK (authorization_state IN ('allowed','revoked')),
    revoked_at timestamptz,
    state_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,sha256),
    UNIQUE (storage_bucket,storage_name,storage_generation),
    FOREIGN KEY (user_id,uonify_project_id)
        REFERENCES uony_projects(user_id,id) ON DELETE CASCADE,
    CHECK ((authorization_state='allowed' AND revoked_at IS NULL AND state_reason IS NULL)
        OR (authorization_state='revoked' AND revoked_at IS NOT NULL
            AND state_reason IS NOT NULL))
);

-- Verificación de propiedad de _request: (user_id, sha256) con estado 'allowed'.
CREATE INDEX creative_owned_inputs_allowed
    ON creative_owned_inputs(user_id,sha256)
    WHERE authorization_state='allowed';

-- El contenido de una entrada (huella, tipo, tamaño y ubicación) es INMUTABLE una vez
-- registrado; solo puede pasar de 'allowed' a 'revoked' (con motivo y fecha), nunca al revés.
CREATE FUNCTION creative_owned_input_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id
            OR NEW.id IS DISTINCT FROM OLD.id
            OR NEW.uonify_project_id IS DISTINCT FROM OLD.uonify_project_id
            OR NEW.sha256 IS DISTINCT FROM OLD.sha256
            OR NEW.kind IS DISTINCT FROM OLD.kind
            OR NEW.mime_type IS DISTINCT FROM OLD.mime_type
            OR NEW.byte_size IS DISTINCT FROM OLD.byte_size
            OR NEW.origin IS DISTINCT FROM OLD.origin
            OR NEW.storage_bucket IS DISTINCT FROM OLD.storage_bucket
            OR NEW.storage_name IS DISTINCT FROM OLD.storage_name
            OR NEW.storage_generation IS DISTINCT FROM OLD.storage_generation
            OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'creative owned input content is immutable; only revocation may change it';
    END IF;
    IF OLD.authorization_state = 'revoked' AND NEW.authorization_state <> 'revoked' THEN
        RAISE EXCEPTION 'a revoked owned input cannot be reinstated';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_owned_input_immutable
    BEFORE UPDATE ON creative_owned_inputs
    FOR EACH ROW EXECUTE FUNCTION creative_owned_input_immutable();

-- Elemento reutilizable. type: 'character' (personaje), 'product' (producto u objeto),
-- 'place' (lugar/escenario), 'style' (estilo). Voz/persona-real/consentimiento SOLO en 'character'.
CREATE TABLE creative_elements (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id uuid NOT NULL,
    uonify_project_id uuid,
    type text NOT NULL CHECK (type IN ('character','product','place','style')),
    name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
    voice_prebuilt_id text
        CHECK (voice_prebuilt_id IS NULL OR voice_prebuilt_id ~ '^[A-Za-z0-9._-]{1,64}$'),
    is_real_person boolean NOT NULL DEFAULT false,
    consent_input_id uuid,
    lineage jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(lineage) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    FOREIGN KEY (user_id,uonify_project_id)
        REFERENCES uony_projects(user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,consent_input_id)
        REFERENCES creative_owned_inputs(user_id,id) ON DELETE RESTRICT,
    -- Voz, persona-real y consentimiento SOLO aplican al tipo 'character'.
    CHECK (type = 'character'
           OR (voice_prebuilt_id IS NULL AND is_real_person = false
               AND consent_input_id IS NULL)),
    -- Gate de consentimiento: un personaje de persona REAL exige consentimiento registrado.
    CHECK (NOT is_real_person OR consent_input_id IS NOT NULL)
);

CREATE TABLE creative_element_references (
    user_id uuid NOT NULL,
    element_id uuid NOT NULL,
    position smallint NOT NULL CHECK (position >= 0),
    input_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,element_id,position),
    UNIQUE (user_id,element_id,input_id),
    FOREIGN KEY (user_id,element_id)
        REFERENCES creative_elements(user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,input_id)
        REFERENCES creative_owned_inputs(user_id,id) ON DELETE RESTRICT
);

CREATE INDEX creative_element_references_input
    ON creative_element_references(user_id,input_id);
