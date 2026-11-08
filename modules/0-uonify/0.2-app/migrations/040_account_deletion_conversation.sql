-- Presentación de la eliminación propia; nunca una orden de borrado del modelo.
CREATE OR REPLACE FUNCTION uony_connection_actions_valid(actions jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(actions) <> 'array' THEN false ELSE
        jsonb_array_length(actions) <= 5
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(actions) AS entry
            WHERE entry NOT IN ('{"provider":"amazon","action":"manage"}'::jsonb,
                '{"provider":"cloud","action":"manage"}'::jsonb,
                '{"provider":"drive","action":"manage"}'::jsonb,
                '{"provider":"blender","action":"manage"}'::jsonb,
                '{"provider":"account","action":"manage"}'::jsonb))
        AND jsonb_array_length(actions) = (SELECT count(DISTINCT entry) FROM jsonb_array_elements(actions) AS entry)
    END;
$$;
