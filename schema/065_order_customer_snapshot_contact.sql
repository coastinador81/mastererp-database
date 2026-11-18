-- Preserve the contact data visible at order creation time for every new order.
CREATE OR REPLACE FUNCTION operaciones.pedido_cliente_snapshot_completar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,operaciones,catalogo,ventas_digitales,plataforma,pg_temp AS $$
DECLARE
 customer_name text;
 customer_email text;
 customer_phone text;
BEGIN
 SELECT t.nombre,u.email::text,p.telefono
 INTO customer_name,customer_email,customer_phone
 FROM catalogo.terceros t
 LEFT JOIN ventas_digitales.cliente_identidades i
   ON (i.tenant_id,i.empresa_id,i.cliente_id)=(NEW.tenant_id,NEW.empresa_id,t.id)
 LEFT JOIN plataforma.users u ON u.id=i.user_id
 LEFT JOIN ventas_digitales.cliente_perfiles p
   ON (p.tenant_id,p.empresa_id,p.cliente_id)=(NEW.tenant_id,NEW.empresa_id,t.id)
 WHERE (t.tenant_id,t.id)=(NEW.tenant_id,NEW.cliente_id)
 LIMIT 1;

 NEW.cliente_snapshot:=jsonb_strip_nulls(
   jsonb_build_object('customer_id',NEW.cliente_id,'name',customer_name,
     'email',customer_email,'phone',customer_phone)
   || COALESCE(NEW.cliente_snapshot,'{}'::jsonb));
 RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION operaciones.pedido_cliente_snapshot_completar() FROM PUBLIC;

DROP TRIGGER IF EXISTS pedido_cliente_snapshot_completar_trigger ON operaciones.pedidos;
CREATE TRIGGER pedido_cliente_snapshot_completar_trigger
BEFORE INSERT ON operaciones.pedidos
FOR EACH ROW EXECUTE FUNCTION operaciones.pedido_cliente_snapshot_completar();
