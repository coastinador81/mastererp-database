-- Server-created semantic decision for a written pilot request.
ALTER TABLE uony_conversation_jobs ADD COLUMN semantic_decision jsonb;
ALTER TABLE uony_conversation_jobs ADD CONSTRAINT conversation_semantic_decision_object
    CHECK (semantic_decision IS NULL OR jsonb_typeof(semantic_decision)='object');
