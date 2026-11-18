-- Orders created by the authorized Operations command are a trusted sales
-- origin too. Keep the origin decision server-side; never accept it from a
-- browser field or from payment evidence.
DO $migration$
DECLARE
 definition text;
 old_guard text := $$AND pedido_id=p_pedido AND motivo='STOREFRONT_CHECKOUT' AND estado_nuevo='PENDING'$$;
 new_guard text := $$AND pedido_id=p_pedido AND motivo IN ('STOREFRONT_CHECKOUT','ORDER_CREATED') AND estado_nuevo='PENDING'$$;
BEGIN
 SELECT pg_get_functiondef(
  'administracion.venta_desde_pedido(uuid,uuid,bigint,character varying,date,numeric,date,text)'::regprocedure
 ) INTO definition;
 IF position(new_guard IN definition)>0 THEN
  RETURN;
 END IF;
 IF position(old_guard IN definition)=0 THEN
  RAISE EXCEPTION 'Reviewed sales origin guard not found' USING ERRCODE='55000';
 END IF;
 EXECUTE replace(definition,old_guard,new_guard);
END
$migration$;
