-- A customer goal survives a change of conversation before any product exists.
-- It is context only: rows here do not authorize reading, creation or publishing.
CREATE TABLE uony_assignments (
    user_id uuid NOT NULL REFERENCES users(id),
    id uuid NOT NULL,
    google_subject text NOT NULL,
    origin_request_id uuid NOT NULL,
    origin_thread_id text NOT NULL,
    label text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 80),
    objective text NOT NULL CHECK (char_length(objective) BETWEEN 1 AND 500),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','waiting_authorization','in_progress','completed','failed')),
    next_step text NOT NULL DEFAULT 'clarify_source'
        CHECK (next_step IN ('clarify_source','select_product','select_folder',
            'await_authorization','check_work','review_result','none')),
    product_id uuid,
    intake_id uuid,
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,origin_request_id),
    UNIQUE (user_id,id,google_subject),
    -- Historical provenance: keep the source ID even if that conversation is purged.
    -- The API verifies the source thread on creation; an FK would erase the goal's
    -- independence from a conversation that the customer later deletes.
    FOREIGN KEY (user_id,product_id) REFERENCES products(user_id,id),
    FOREIGN KEY (user_id,intake_id) REFERENCES uony_product_intakes(user_id,id)
);
CREATE INDEX uony_assignments_recent
    ON uony_assignments(user_id,google_subject,updated_at DESC,id DESC);

-- Focusing a goal never changes a product binding or enqueues a job.
CREATE TABLE uony_assignment_focus (
    user_id uuid NOT NULL,
    thread_id text NOT NULL,
    google_subject text NOT NULL,
    assignment_id uuid NOT NULL,
    previous_assignment_id uuid,
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,thread_id),
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,assignment_id,google_subject)
        REFERENCES uony_assignments(user_id,id,google_subject),
    FOREIGN KEY (user_id,previous_assignment_id,google_subject)
        REFERENCES uony_assignments(user_id,id,google_subject),
    CHECK (previous_assignment_id IS NULL OR previous_assignment_id <> assignment_id)
);

-- A lost HTTP response can be reconciled with the same request ID without
-- repeating a focus change or overwriting a later choice from another tab.
CREATE TABLE uony_assignment_focus_requests (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    thread_id text NOT NULL,
    google_subject text NOT NULL,
    assignment_id uuid NOT NULL,
    expected_version integer NOT NULL CHECK (expected_version >= 0),
    applied_version integer NOT NULL CHECK (applied_version > 0),
    previous_assignment_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,request_id),
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,assignment_id,google_subject)
        REFERENCES uony_assignments(user_id,id,google_subject),
    FOREIGN KEY (user_id,previous_assignment_id,google_subject)
        REFERENCES uony_assignments(user_id,id,google_subject)
);
