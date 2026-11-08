-- Link only exact duplicate access replies from the same Live session.
-- Preserve the original rows and every other spoken answer.
UPDATE uony_live_turns v SET reply_to_turn_id=h.turn_id
FROM uony_live_handoffs h
JOIN uony_requests r ON r.user_id=h.user_id AND r.request_id=h.request_id
JOIN uony_live_turns source ON source.user_id=h.user_id
    AND source.thread_id=h.thread_id AND source.session_id=h.session_id
    AND source.turn_id=h.turn_id AND source.role='user'
WHERE v.user_id=h.user_id AND v.thread_id=h.thread_id
  AND v.session_id=h.session_id AND v.role='assistant'
  AND v.reply_to_turn_id IS NULL AND h.intent='use_drive_materials'
  AND r.status='success'
  AND r.reply='Ya puedo consultar tu Drive. ¿Qué quieres que busque o analice?'
  AND v.text=r.reply
  AND v.created_at BETWEEN source.created_at - interval '30 seconds'
                       AND source.created_at + interval '30 seconds'
  AND NOT EXISTS (
      SELECT 1 FROM uony_live_turns other_turn
      WHERE other_turn.user_id=v.user_id AND other_turn.thread_id=v.thread_id
        AND other_turn.session_id=v.session_id AND other_turn.role='user'
        AND other_turn.turn_id<>h.turn_id
        AND other_turn.created_at BETWEEN LEAST(source.created_at,v.created_at)
                                      AND GREATEST(source.created_at,v.created_at)
  );
