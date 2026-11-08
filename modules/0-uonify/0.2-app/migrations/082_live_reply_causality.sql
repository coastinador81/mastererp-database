-- Keep a Live reply attached to the exact customer turn that prompted it.
-- A durable handoff supersedes the model's provisional reply to that turn.
ALTER TABLE uony_live_turns
 ADD COLUMN reply_to_turn_id uuid,
 ADD CONSTRAINT uony_live_reply_only_assistant
 CHECK (role='assistant' OR reply_to_turn_id IS NULL);
