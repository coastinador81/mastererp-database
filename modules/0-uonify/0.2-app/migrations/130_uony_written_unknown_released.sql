-- Lote 6, point 5 («Consultor google», 21-10-2026): a written ADK turn commits its
-- effects only in finish(), together with its terminal state, so a written ADK order
-- left unknown before this lote had none. Release the identical resend such orders
-- still block (acknowledged_at), as the owner's two releases of 21-10 did by hand.
-- Their status, history and usage stay as they are. Voice handoffs, the classic engine
-- and restored copies (restore_reconciliation_required) keep their protection.
-- Idempotent: an acknowledged order is never touched again.
UPDATE uony_conversation_jobs j SET acknowledged_at=now()
WHERE j.status='unknown' AND j.acknowledged_at IS NULL AND j.engine='adk'
  AND j.error_code='consumption_unknown'
  AND NOT EXISTS (SELECT 1 FROM uony_live_handoffs h
    WHERE h.user_id=j.user_id AND h.request_id=j.request_id);
