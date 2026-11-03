CREATE FUNCTION pg_temp.assert_true(value boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF value IS DISTINCT FROM true THEN RAISE EXCEPTION '%',message; END IF; END $$;
CREATE FUNCTION pg_temp.reject_sql(statement text,expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual text;
BEGIN
 BEGIN EXECUTE statement; SET CONSTRAINTS ALL IMMEDIATE;
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS actual=RETURNED_SQLSTATE; END;
 IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'Expected SQLSTATE %, got %',expected,COALESCE(actual,'success'); END IF;
 SET CONSTRAINTS ALL DEFERRED;
END $$;
