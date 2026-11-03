-- Technical integrity only: no posting, fiscal calculation, approvals or business API.
CREATE OR REPLACE FUNCTION administracion.proteger_fila() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,administracion,plataforma,organizacion,pg_temp AS $$
DECLARE r jsonb; v_tenant uuid; v_empresa uuid; v_actor uuid; v_fields text[]; v_condition uuid;
BEGIN
 r:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 v_tenant:=(r->>'tenant_id')::uuid; v_empresa:=(r->>'empresa_id')::uuid;
 -- All integrity aggregates serialize per company, including inserts on distinct child rows.
 PERFORM 1 FROM organizacion.companies c JOIN plataforma.tenants t ON t.id=c.tenant_id
 WHERE c.id=v_empresa AND c.tenant_id=v_tenant AND c.status='active' AND t.status='active' AND t.deleted_at IS NULL FOR UPDATE OF c;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid active company scope' USING ERRCODE='23503'; END IF;
 v_actor:=plataforma.current_app_user_id();
 IF v_tenant IS DISTINCT FROM plataforma.current_app_tenant_id() OR v_actor IS NULL
 OR NOT EXISTS(SELECT 1 FROM plataforma.user_tenants ut JOIN plataforma.users u ON u.id=ut.user_id
 WHERE ut.tenant_id=v_tenant AND ut.user_id=v_actor AND ut.status='active' AND u.status='active')
 OR NULLIF(current_setting('app.correlation_id',true),'') IS NULL THEN
  RAISE EXCEPTION 'Active actor and transaction correlation required' USING ERRCODE='42501'; END IF;
 IF (r->>'sucursal_id') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM organizacion.branches b
 WHERE b.id=(r->>'sucursal_id')::uuid AND b.tenant_id=v_tenant AND b.company_id=v_empresa AND b.status='active') THEN
 RAISE EXCEPTION 'Invalid active branch scope' USING ERRCODE='23503'; END IF;
 IF TG_TABLE_NAME IN ('condiciones_comerciales','descuentos_pronto_pago') THEN
  v_condition:=CASE WHEN TG_TABLE_NAME='condiciones_comerciales' THEN (r->>'id')::uuid ELSE (r->>'condicion_id')::uuid END;
  IF EXISTS(SELECT 1 FROM administracion.documentos WHERE condicion_id=v_condition AND cerrado) THEN
   RAISE EXCEPTION 'Agreed condition edition is immutable; create a new edition' USING ERRCODE='23514'; END IF;
 END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.version<>1 OR NEW.creado_en<>transaction_timestamp() THEN RAISE EXCEPTION 'Server creation metadata required' USING ERRCODE='23514'; END IF;
  IF NEW.creado_por IS DISTINCT FROM v_actor THEN RAISE EXCEPTION 'Actor mismatch' USING ERRCODE='42501'; END IF;
 ELSE
  IF TG_TABLE_NAME IN ('operaciones_tesoreria','movimientos_tesoreria','transferencias','extractos_bancarios','lineas_extracto','partidas_conciliacion','aplicaciones_cartera','reservas_fondos')
  THEN RAISE EXCEPTION 'Append-only fact; use a linked reversal' USING ERRCODE='23514'; END IF;
  IF TG_TABLE_NAME='documentos' AND (to_jsonb(OLD)->>'cerrado')::boolean THEN
   RAISE EXCEPTION 'Sealed document is immutable' USING ERRCODE='23514'; END IF;
  IF TG_TABLE_NAME='detalles_documento' AND EXISTS(SELECT 1 FROM administracion.documentos WHERE id=(to_jsonb(OLD)->>'documento_id')::uuid AND cerrado) THEN
   RAISE EXCEPTION 'Sealed document details are immutable' USING ERRCODE='23514'; END IF;
  IF TG_OP='UPDATE' THEN
   v_fields:=CASE TG_TABLE_NAME
    WHEN 'detalles_documento' THEN ARRAY['documento_id']
    WHEN 'descuentos_pronto_pago' THEN ARRAY['condicion_id']
    WHEN 'perfiles_tercero' THEN ARRAY['tercero_id','rol']
    WHEN 'detalle_destinos' THEN ARRAY['detalle_id','destino_id']
    WHEN 'partidas_cartera' THEN ARRAY['documento_id','lado']
    WHEN 'vencimientos' THEN ARRAY['partida_id','posicion']
    WHEN 'gastos' THEN ARRAY['documento_id']
    WHEN 'fondos_caja_chica' THEN ARRAY['cuenta_id']
    WHEN 'anticipos' THEN ARRAY['documento_id','movimiento_id']
    WHEN 'reposiciones' THEN ARRAY['documento_id','movimiento_id','fondo_id']
    WHEN 'rendiciones' THEN ARRAY['documento_id','anticipo_id']
    WHEN 'rendicion_gastos' THEN ARRAY['rendicion_id','gasto_id','detalle_id']
    ELSE ARRAY[]::text[] END;
   IF EXISTS(SELECT 1 FROM unnest(v_fields) k WHERE to_jsonb(NEW)->k IS DISTINCT FROM to_jsonb(OLD)->k) THEN
    RAISE EXCEPTION 'Source identity cannot be reassigned' USING ERRCODE='23514'; END IF;
   IF (NEW.tenant_id,NEW.empresa_id,NEW.id,NEW.creado_por,NEW.creado_en) IS DISTINCT FROM
      (OLD.tenant_id,OLD.empresa_id,OLD.id,OLD.creado_por,OLD.creado_en) THEN
    RAISE EXCEPTION 'Record ownership/identity is immutable' USING ERRCODE='23514'; END IF;
   IF NEW.version<>OLD.version+1 THEN RAISE EXCEPTION 'Stale record version' USING ERRCODE='40001'; END IF;
  END IF;
 END IF;
 IF TG_OP='INSERT' AND TG_TABLE_NAME='detalles_documento' AND EXISTS(SELECT 1 FROM administracion.documentos WHERE id=(r->>'documento_id')::uuid AND cerrado) THEN
  RAISE EXCEPTION 'Sealed document details are immutable' USING ERRCODE='23514'; END IF;
 IF TG_OP='INSERT' AND TG_TABLE_NAME='reservas_fondos' AND r->>'origen_id' IS NULL
 AND NOT EXISTS(SELECT 1 FROM administracion.politicas_reserva WHERE id=(r->>'politica_id')::uuid AND habilitada) THEN
  RAISE EXCEPTION 'Reservation policy disabled' USING ERRCODE='23514'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;

CREATE OR REPLACE FUNCTION administracion.auditar_fila() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plataforma,auditoria,pg_temp AS $$
DECLARE r jsonb;
BEGIN
 r:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES((r->>'tenant_id')::uuid,plataforma.current_app_user_id(),'2.2.1-administration',TG_TABLE_NAME,(r->>'id')::uuid,
 lower(TG_OP),NULLIF(current_setting('app.correlation_id',true),'')::uuid,
 jsonb_build_object('empresa_id',r->>'empresa_id','resultado','succeeded'));
 RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION administracion.validar_empresa(p_tenant uuid,p_empresa uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,administracion,catalogo,organizacion,plataforma,pg_temp AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM administracion.documentos d JOIN organizacion.companies e ON e.id=d.empresa_id
 WHERE d.tenant_id=p_tenant AND d.empresa_id=p_empresa AND (d.moneda_base<>e.base_currency_code
 OR d.total<>COALESCE((SELECT sum(l.total) FROM administracion.detalles_documento l WHERE l.documento_id=d.id),0)
 OR (d.cerrado AND NOT EXISTS(SELECT 1 FROM administracion.detalles_documento l WHERE l.documento_id=d.id))
 OR d.total<>round(d.total,(SELECT decimales FROM catalogo.monedas WHERE codigo=d.moneda)))) THEN RAISE EXCEPTION 'Document scope, currency precision or detail total mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.detalles_documento l JOIN administracion.documentos d ON d.id=l.documento_id
 WHERE l.tenant_id=p_tenant AND l.empresa_id=p_empresa AND (l.sucursal_id IS DISTINCT FROM d.sucursal_id
 OR (d.clase IN ('devolucion_cliente','devolucion_proveedor') AND l.detalle_origen_id IS NULL)
 OR l.total<>round(l.total,(SELECT decimales FROM catalogo.monedas WHERE codigo=d.moneda)))) THEN RAISE EXCEPTION 'Detail branch, return origin or monetary precision mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.documentos d JOIN administracion.documentos o ON o.id=d.documento_origen_id
 WHERE d.tenant_id=p_tenant AND d.empresa_id=p_empresa AND d.clase IN ('devolucion_cliente','devolucion_proveedor','credito_cliente','credito_proveedor','debito_cliente','debito_proveedor')
 AND (NOT o.cerrado OR o.clase<>CASE WHEN d.clase LIKE '%cliente' THEN 'factura_cliente' ELSE 'factura_proveedor' END
 OR d.tercero_id IS DISTINCT FROM o.tercero_id OR d.moneda<>o.moneda)) THEN RAISE EXCEPTION 'Adjustment requires compatible sealed invoice' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.detalles_documento l JOIN administracion.documentos d ON d.id=l.documento_id
 JOIN administracion.detalles_documento o ON o.id=l.detalle_origen_id JOIN administracion.documentos od ON od.id=o.documento_id
 WHERE l.tenant_id=p_tenant AND l.empresa_id=p_empresa AND
 (l.producto_id IS DISTINCT FROM o.producto_id OR (d.tercero_id IS NOT NULL AND od.tercero_id IS NOT NULL AND d.tercero_id<>od.tercero_id)
 OR (d.clase IN ('devolucion_cliente','devolucion_proveedor','credito_cliente','credito_proveedor','debito_cliente','debito_proveedor') AND o.documento_id<>d.documento_origen_id))) THEN RAISE EXCEPTION 'Detail origin is incompatible' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.detalles_documento o WHERE o.tenant_id=p_tenant AND o.empresa_id=p_empresa
 AND o.cantidad<(SELECT COALESCE(sum(l.cantidad),0) FROM administracion.detalles_documento l JOIN administracion.documentos d ON d.id=l.documento_id
 WHERE l.detalle_origen_id=o.id AND d.cerrado AND d.clase IN ('devolucion_cliente','devolucion_proveedor'))) THEN RAISE EXCEPTION 'Returns exceed original quantity' USING ERRCODE='23514'; END IF;
 IF EXISTS(WITH RECURSIVE edges AS (
 SELECT documento_origen_id a,id b FROM administracion.documentos WHERE tenant_id=p_tenant AND empresa_id=p_empresa AND documento_origen_id IS NOT NULL
 UNION SELECT origen_id,destino_id FROM administracion.relaciones_documento WHERE tenant_id=p_tenant AND empresa_id=p_empresa),
 paths AS (SELECT a,b,ARRAY[a,b] path,a=b cycle FROM edges UNION ALL
 SELECT p.a,e.b,p.path||e.b,e.b=ANY(p.path) FROM paths p JOIN edges e ON e.a=p.b WHERE NOT p.cycle)
 SELECT 1 FROM paths WHERE cycle) THEN RAISE EXCEPTION 'Cyclic document origin graph' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.detalles_documento l JOIN administracion.documentos d ON d.id=l.documento_id
 WHERE l.tenant_id=p_tenant AND l.empresa_id=p_empresa AND EXISTS(SELECT 1 FROM administracion.detalle_destinos x WHERE x.detalle_id=l.id)
 AND (d.clase NOT IN ('solicitud_compra','orden_compra') OR l.cantidad<(SELECT sum(x.cantidad) FROM administracion.detalle_destinos x WHERE x.detalle_id=l.id))) THEN RAISE EXCEPTION 'Purchase destination allocation invalid' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.movimientos_tesoreria m JOIN organizacion.companies e ON e.id=m.empresa_id JOIN administracion.operaciones_tesoreria o ON o.id=m.operacion_id
 WHERE m.tenant_id=p_tenant AND m.empresa_id=p_empresa AND (m.moneda_base<>e.base_currency_code
 OR m.importe<>round(m.importe,(SELECT decimales FROM catalogo.monedas WHERE codigo=m.moneda))
 OR (o.tipo='cobro' AND m.sentido<>'entrada') OR (o.tipo='pago' AND m.sentido<>'salida'))) THEN RAISE EXCEPTION 'Cash movement currency or direction invalid' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.movimientos_tesoreria m JOIN administracion.movimientos_tesoreria o ON o.id=m.reverso_de_id
 JOIN administracion.operaciones_tesoreria op ON op.id=m.operacion_id JOIN administracion.operaciones_tesoreria oo ON oo.id=o.operacion_id
 WHERE m.tenant_id=p_tenant AND m.empresa_id=p_empresa AND (o.reverso_de_id IS NOT NULL OR m.cuenta_id<>o.cuenta_id OR m.importe<>o.importe
 OR m.sentido=o.sentido OR m.moneda<>o.moneda OR m.moneda_base<>o.moneda_base OR m.tipo_cambio<>o.tipo_cambio OR op.tipo<>'reverso'
 OR op.tercero_id IS DISTINCT FROM oo.tercero_id)) THEN RAISE EXCEPTION 'Cash reversal must fully invert its original fact' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.operaciones_tesoreria o WHERE o.tenant_id=p_tenant AND o.empresa_id=p_empresa
 AND (NOT EXISTS(SELECT 1 FROM administracion.movimientos_tesoreria m WHERE m.operacion_id=o.id)
 OR (o.tipo='transferencia' AND NOT EXISTS(SELECT 1 FROM administracion.transferencias t WHERE t.operacion_id=o.id)))) THEN RAISE EXCEPTION 'Cash operation requires movements and transfer pairing' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.transferencias t JOIN administracion.movimientos_tesoreria s ON s.id=t.salida_id
 JOIN administracion.movimientos_tesoreria e ON e.id=t.entrada_id JOIN administracion.operaciones_tesoreria o ON o.id=t.operacion_id
 WHERE t.tenant_id=p_tenant AND t.empresa_id=p_empresa AND (o.tipo<>'transferencia' OR s.operacion_id<>o.id OR e.operacion_id<>o.id
 OR s.sentido<>'salida' OR e.sentido<>'entrada' OR s.cuenta_id=e.cuenta_id OR s.reverso_de_id IS NOT NULL OR e.reverso_de_id IS NOT NULL
 OR (SELECT count(*) FROM administracion.movimientos_tesoreria m WHERE m.operacion_id=o.id)<>2
 OR e.importe<>s.importe*t.cambio_entre_cuentas OR (e.moneda=s.moneda AND t.cambio_entre_cuentas<>1)
 OR t.diferencia_base<>e.importe_base-s.importe_base)) THEN RAISE EXCEPTION 'Transfer legs or explicit exchange mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.transferencias t
 LEFT JOIN administracion.movimientos_tesoreria rs ON rs.reverso_de_id=t.salida_id
 LEFT JOIN administracion.movimientos_tesoreria re ON re.reverso_de_id=t.entrada_id
 WHERE t.tenant_id=p_tenant AND t.empresa_id=p_empresa AND
 ((rs.id IS NULL)<>(re.id IS NULL) OR rs.operacion_id IS DISTINCT FROM re.operacion_id)) THEN
 RAISE EXCEPTION 'Both transfer legs must reverse atomically in one operation' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.extractos_bancarios e JOIN administracion.cuentas_tesoreria c ON c.id=e.cuenta_id
 WHERE e.tenant_id=p_tenant AND e.empresa_id=p_empresa AND (c.tipo<>'banco'
 OR e.saldo_final-e.saldo_inicial<>COALESCE((SELECT sum(l.importe) FROM administracion.lineas_extracto l WHERE l.extracto_id=e.id),0))) THEN RAISE EXCEPTION 'Bank statement balance does not match its lines' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.partidas_conciliacion p JOIN administracion.conciliaciones c ON c.id=p.conciliacion_id
 JOIN administracion.lineas_extracto l ON l.id=p.linea_id JOIN administracion.movimientos_tesoreria m ON m.id=p.movimiento_id
 WHERE p.tenant_id=p_tenant AND p.empresa_id=p_empresa AND (c.cuenta_id<>l.cuenta_id OR l.cuenta_id<>m.cuenta_id
 OR (l.importe>0)<>(m.sentido='entrada') OR p.importe<>round(p.importe,(SELECT decimales FROM catalogo.monedas WHERE codigo=l.moneda)))) THEN RAISE EXCEPTION 'Reconciliation account or direction mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.partidas_conciliacion p JOIN administracion.partidas_conciliacion o ON o.id=p.reverso_de_id
 WHERE p.tenant_id=p_tenant AND p.empresa_id=p_empresa AND (o.reverso_de_id IS NOT NULL OR p.linea_id<>o.linea_id OR p.movimiento_id<>o.movimiento_id OR p.importe<>o.importe OR p.conciliacion_id<>o.conciliacion_id)) THEN RAISE EXCEPTION 'Reconciliation reversal mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.lineas_extracto t WHERE t.tenant_id=p_tenant AND t.empresa_id=p_empresa
 AND abs(t.importe)<(SELECT COALESCE(sum(CASE WHEN p.reverso_de_id IS NULL THEN p.importe ELSE -p.importe END),0) FROM administracion.partidas_conciliacion p WHERE p.linea_id=t.id)) THEN RAISE EXCEPTION 'Reconciliation exceeds source amount' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.movimientos_tesoreria t WHERE t.tenant_id=p_tenant AND t.empresa_id=p_empresa
 AND t.importe<(SELECT COALESCE(sum(CASE WHEN p.reverso_de_id IS NULL THEN p.importe ELSE -p.importe END),0) FROM administracion.partidas_conciliacion p WHERE p.movimiento_id=t.id)) THEN RAISE EXCEPTION 'Reconciliation exceeds source amount' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.partidas_cartera p JOIN administracion.documentos d ON d.id=p.documento_id
 WHERE p.tenant_id=p_tenant AND p.empresa_id=p_empresa AND (NOT d.cerrado
 OR d.clase NOT IN ('factura_cliente','factura_proveedor','debito_cliente','debito_proveedor')
 OR p.lado<>CASE WHEN d.clase LIKE '%cliente' THEN 'cobrar' ELSE 'pagar' END
 OR d.total<>COALESCE((SELECT sum(v.importe) FROM administracion.vencimientos v WHERE v.partida_id=p.id),0)
 OR NOT EXISTS(SELECT 1 FROM administracion.vencimientos v WHERE v.partida_id=p.id))) THEN RAISE EXCEPTION 'Receivable/payable requires sealed source and full schedule' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.vencimientos v WHERE v.tenant_id=p_tenant AND v.empresa_id=p_empresa
 AND v.importe<(SELECT COALESCE(sum(CASE WHEN a.reverso_de_id IS NULL THEN a.importe_destino ELSE -a.importe_destino END),0)
 FROM administracion.aplicaciones_cartera a WHERE a.vencimiento_id=v.id)) THEN RAISE EXCEPTION 'Applications exceed scheduled amount' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.aplicaciones_cartera a JOIN administracion.vencimientos v ON v.id=a.vencimiento_id
 JOIN administracion.partidas_cartera p ON p.id=v.partida_id JOIN administracion.documentos d ON d.id=p.documento_id
 LEFT JOIN administracion.movimientos_tesoreria m ON m.id=a.movimiento_id LEFT JOIN administracion.operaciones_tesoreria o ON o.id=m.operacion_id
 LEFT JOIN administracion.documentos c ON c.id=a.credito_id
 WHERE a.tenant_id=p_tenant AND a.empresa_id=p_empresa AND
 ((m.id IS NOT NULL AND (m.reverso_de_id IS NOT NULL OR o.tercero_id IS DISTINCT FROM d.tercero_id OR m.sentido<>CASE WHEN p.lado='cobrar' THEN 'entrada' ELSE 'salida' END))
 OR (c.id IS NOT NULL AND (NOT c.cerrado OR c.clase<>CASE WHEN p.lado='cobrar' THEN 'credito_cliente' ELSE 'credito_proveedor' END OR c.tercero_id IS DISTINCT FROM d.tercero_id))
 OR (COALESCE(m.moneda,c.moneda)=d.moneda AND a.tipo_cambio<>1)
 OR a.importe_origen<>round(a.importe_origen,(SELECT decimales FROM catalogo.monedas WHERE codigo=COALESCE(m.moneda,c.moneda)))
 OR a.importe_destino<>round(a.importe_destino,(SELECT decimales FROM catalogo.monedas WHERE codigo=d.moneda)))) THEN RAISE EXCEPTION 'Application party, direction, source or currency mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.aplicaciones_cartera a JOIN administracion.aplicaciones_cartera o ON o.id=a.reverso_de_id
 WHERE a.tenant_id=p_tenant AND a.empresa_id=p_empresa AND (o.reverso_de_id IS NOT NULL OR a.vencimiento_id<>o.vencimiento_id
 OR a.movimiento_id IS DISTINCT FROM o.movimiento_id OR a.credito_id IS DISTINCT FROM o.credito_id OR a.importe_origen<>o.importe_origen
 OR a.importe_destino<>o.importe_destino OR a.tipo_cambio<>o.tipo_cambio)) THEN RAISE EXCEPTION 'Application reversal mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.movimientos_tesoreria t WHERE t.tenant_id=p_tenant AND t.empresa_id=p_empresa AND
 t.importe<(SELECT COALESCE(sum(CASE WHEN a.reverso_de_id IS NULL THEN a.importe_origen ELSE -a.importe_origen END),0)
 FROM administracion.aplicaciones_cartera a WHERE a.movimiento_id=t.id)) THEN RAISE EXCEPTION 'Applications exceed payment or credit source' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.documentos t WHERE t.tenant_id=p_tenant AND t.empresa_id=p_empresa AND
 t.total<(SELECT COALESCE(sum(CASE WHEN a.reverso_de_id IS NULL THEN a.importe_origen ELSE -a.importe_origen END),0)
 FROM administracion.aplicaciones_cartera a WHERE a.credito_id=t.id)) THEN RAISE EXCEPTION 'Applications exceed payment or credit source' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.movimientos_tesoreria m WHERE m.tenant_id=p_tenant AND m.empresa_id=p_empresa
 AND EXISTS(SELECT 1 FROM administracion.movimientos_tesoreria r WHERE r.reverso_de_id=m.id)
 AND 0<>(SELECT COALESCE(sum(CASE WHEN a.reverso_de_id IS NULL THEN a.importe_origen ELSE -a.importe_origen END),0)
 FROM administracion.aplicaciones_cartera a WHERE a.movimiento_id=m.id)) THEN RAISE EXCEPTION 'Reverse applications before reversing money' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.gastos g JOIN administracion.documentos d ON d.id=g.documento_id
 WHERE g.tenant_id=p_tenant AND g.empresa_id=p_empresa AND (NOT d.cerrado OR d.clase NOT IN ('gasto','factura_proveedor'))) THEN RAISE EXCEPTION 'Expense classifies a sealed invoice or expense support only' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.fondos_caja_chica f JOIN administracion.cuentas_tesoreria c ON c.id=f.cuenta_id
 WHERE f.tenant_id=p_tenant AND f.empresa_id=p_empresa AND c.tipo<>'caja') THEN RAISE EXCEPTION 'Petty cash fund requires cash account' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.reposiciones r JOIN administracion.fondos_caja_chica f ON f.id=r.fondo_id
 JOIN administracion.movimientos_tesoreria m ON m.id=r.movimiento_id JOIN administracion.documentos d ON d.id=r.documento_id
 WHERE r.tenant_id=p_tenant AND r.empresa_id=p_empresa AND (NOT d.cerrado OR d.clase<>'reposicion' OR m.cuenta_id<>f.cuenta_id
 OR m.sentido<>'entrada' OR m.moneda<>d.moneda OR m.importe<>d.total OR m.reverso_de_id IS NOT NULL)) THEN RAISE EXCEPTION 'Replenishment document and incoming fund movement mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.anticipos a JOIN administracion.documentos d ON d.id=a.documento_id
 JOIN administracion.movimientos_tesoreria m ON m.id=a.movimiento_id WHERE a.tenant_id=p_tenant AND a.empresa_id=p_empresa
 AND (NOT d.cerrado OR d.clase<>'anticipo' OR m.sentido<>'salida' OR m.moneda<>d.moneda OR m.importe<>d.total OR m.reverso_de_id IS NOT NULL)) THEN RAISE EXCEPTION 'Advance requires its sealed support and outgoing movement' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.rendiciones r JOIN administracion.documentos d ON d.id=r.documento_id
 JOIN administracion.anticipos a ON a.id=r.anticipo_id JOIN administracion.documentos ad ON ad.id=a.documento_id
 WHERE r.tenant_id=p_tenant AND r.empresa_id=p_empresa AND (NOT d.cerrado OR d.clase<>'rendicion' OR d.moneda<>ad.moneda
 OR d.total<>COALESCE((SELECT sum(l.total) FROM administracion.rendicion_gastos x JOIN administracion.detalles_documento l ON l.id=x.detalle_id WHERE x.rendicion_id=r.id),0))) THEN RAISE EXCEPTION 'Expense report support, currency or allocation mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.rendicion_gastos x JOIN administracion.rendiciones r ON r.id=x.rendicion_id
 JOIN administracion.detalles_documento l ON l.id=x.detalle_id JOIN administracion.gastos g ON g.id=x.gasto_id
 JOIN administracion.documentos gd ON gd.id=g.documento_id JOIN administracion.documentos rd ON rd.id=r.documento_id
 WHERE x.tenant_id=p_tenant AND x.empresa_id=p_empresa AND (l.documento_id<>r.documento_id OR gd.moneda<>rd.moneda)) THEN RAISE EXCEPTION 'Expense report line belongs to another document/currency' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.gastos g JOIN administracion.documentos d ON d.id=g.documento_id WHERE g.tenant_id=p_tenant AND g.empresa_id=p_empresa
 AND d.total<(SELECT COALESCE(sum(l.total),0) FROM administracion.rendicion_gastos x JOIN administracion.detalles_documento l ON l.id=x.detalle_id WHERE x.gasto_id=g.id)) THEN RAISE EXCEPTION 'Expense claimed more than once' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.reservas_fondos r JOIN administracion.politicas_reserva p ON p.id=r.politica_id
 JOIN administracion.documentos d ON d.id=r.documento_id WHERE r.tenant_id=p_tenant AND r.empresa_id=p_empresa
 AND (d.clase NOT IN ('solicitud_compra','orden_compra') OR d.moneda<>(SELECT moneda FROM administracion.cuentas_tesoreria WHERE id=p.cuenta_id))) THEN RAISE EXCEPTION 'Reservation policy or purchase currency invalid' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.reservas_fondos r JOIN administracion.reservas_fondos o ON o.id=r.origen_id
 WHERE r.tenant_id=p_tenant AND r.empresa_id=p_empresa AND (o.origen_id IS NOT NULL OR r.politica_id<>o.politica_id OR r.documento_id<>o.documento_id)) THEN RAISE EXCEPTION 'Reservation release origin mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.reservas_fondos o WHERE o.tenant_id=p_tenant AND o.empresa_id=p_empresa AND o.origen_id IS NULL
 AND o.importe<(SELECT COALESCE(sum(r.importe),0) FROM administracion.reservas_fondos r WHERE r.origen_id=o.id)) THEN RAISE EXCEPTION 'Released reservation exceeds original' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.politicas_reserva p WHERE p.tenant_id=p_tenant AND p.empresa_id=p_empresa AND p.tope IS NOT NULL
 AND p.tope<(SELECT COALESCE(sum(CASE WHEN r.origen_id IS NULL THEN r.importe ELSE -r.importe END),0) FROM administracion.reservas_fondos r WHERE r.politica_id=p.id)) THEN RAISE EXCEPTION 'Configured reservation cap exceeded' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.documentos d JOIN plataforma.idempotency_keys k ON k.idempotency_key=d.idempotency_key
 WHERE d.tenant_id=p_tenant AND d.empresa_id=p_empresa AND (k.actor_user_id<>d.creado_por OR k.request_tenant_id IS DISTINCT FROM d.tenant_id
 OR k.operation<>'administracion.documento.'||d.clase||'.crear' OR k.resource_id IS DISTINCT FROM d.id OR k.request_fingerprint IS NULL OR k.request_fingerprint !~ '^[0-9a-f]{64}$' OR d.creado_en<k.created_at OR d.creado_en>=k.expires_at)) THEN RAISE EXCEPTION 'Shared idempotency actor, tenant, operation, resource or fingerprint mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.operaciones_tesoreria d JOIN plataforma.idempotency_keys k ON k.idempotency_key=d.idempotency_key
 WHERE d.tenant_id=p_tenant AND d.empresa_id=p_empresa AND (k.actor_user_id<>d.creado_por OR k.request_tenant_id IS DISTINCT FROM d.tenant_id
 OR k.operation<>'administracion.tesoreria.crear' OR k.resource_id IS DISTINCT FROM d.id OR k.request_fingerprint IS NULL OR k.request_fingerprint !~ '^[0-9a-f]{64}$' OR d.creado_en<k.created_at OR d.creado_en>=k.expires_at)) THEN RAISE EXCEPTION 'Shared idempotency actor, tenant, operation, resource or fingerprint mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.vencimientos v JOIN administracion.partidas_cartera p ON p.id=v.partida_id
 JOIN administracion.documentos d ON d.id=p.documento_id WHERE v.tenant_id=p_tenant AND v.empresa_id=p_empresa
 AND v.importe<>round(v.importe,(SELECT decimales FROM catalogo.monedas WHERE codigo=d.moneda))) THEN
 RAISE EXCEPTION 'Schedule amount is not representable in its currency' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.aplicaciones_cartera d JOIN plataforma.idempotency_keys k ON k.idempotency_key=d.idempotency_key
 WHERE d.tenant_id=p_tenant AND d.empresa_id=p_empresa AND (k.actor_user_id<>d.creado_por OR k.request_tenant_id IS DISTINCT FROM d.tenant_id
 OR k.operation<>CASE WHEN d.reverso_de_id IS NULL THEN 'administracion.cartera.aplicar' ELSE 'administracion.cartera.reversar' END OR k.resource_id IS DISTINCT FROM d.id OR k.request_fingerprint IS NULL
 OR k.request_fingerprint !~ '^[0-9a-f]{64}$' OR d.creado_en<k.created_at OR d.creado_en>=k.expires_at)) THEN
 RAISE EXCEPTION 'Shared allocation idempotency binding mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.partidas_conciliacion d JOIN plataforma.idempotency_keys k ON k.idempotency_key=d.idempotency_key
 WHERE d.tenant_id=p_tenant AND d.empresa_id=p_empresa AND (k.actor_user_id<>d.creado_por OR k.request_tenant_id IS DISTINCT FROM d.tenant_id
 OR k.operation<>CASE WHEN d.reverso_de_id IS NULL THEN 'administracion.conciliar' ELSE 'administracion.desconciliar' END OR k.resource_id IS DISTINCT FROM d.id OR k.request_fingerprint IS NULL
 OR k.request_fingerprint !~ '^[0-9a-f]{64}$' OR d.creado_en<k.created_at OR d.creado_en>=k.expires_at)) THEN
 RAISE EXCEPTION 'Shared allocation idempotency binding mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.reservas_fondos d JOIN plataforma.idempotency_keys k ON k.idempotency_key=d.idempotency_key
 WHERE d.tenant_id=p_tenant AND d.empresa_id=p_empresa AND (k.actor_user_id<>d.creado_por OR k.request_tenant_id IS DISTINCT FROM d.tenant_id
 OR k.operation<>CASE WHEN d.origen_id IS NULL THEN 'administracion.reservar' ELSE 'administracion.liberar_reserva' END OR k.resource_id IS DISTINCT FROM d.id OR k.request_fingerprint IS NULL
 OR k.request_fingerprint !~ '^[0-9a-f]{64}$' OR d.creado_en<k.created_at OR d.creado_en>=k.expires_at)) THEN
 RAISE EXCEPTION 'Shared allocation idempotency binding mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.rendicion_gastos d JOIN plataforma.idempotency_keys k ON k.idempotency_key=d.idempotency_key
 WHERE d.tenant_id=p_tenant AND d.empresa_id=p_empresa AND (k.actor_user_id<>d.creado_por OR k.request_tenant_id IS DISTINCT FROM d.tenant_id
 OR k.operation<>'administracion.rendicion.asignar_gasto' OR k.resource_id IS DISTINCT FROM d.id OR k.request_fingerprint IS NULL
 OR k.request_fingerprint !~ '^[0-9a-f]{64}$' OR d.creado_en<k.created_at OR d.creado_en>=k.expires_at)) THEN
 RAISE EXCEPTION 'Shared allocation idempotency binding mismatch' USING ERRCODE='23514'; END IF;
END $$;
CREATE OR REPLACE FUNCTION administracion.integridad_diferida() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' THEN PERFORM administracion.validar_empresa(OLD.tenant_id,OLD.empresa_id);
 ELSE PERFORM administracion.validar_empresa(NEW.tenant_id,NEW.empresa_id); END IF;
 RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION administracion.proteger_moneda_base() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,pg_temp AS $$
BEGIN
 IF NEW.base_currency_code IS DISTINCT FROM OLD.base_currency_code AND
 (EXISTS(SELECT 1 FROM administracion.documentos WHERE empresa_id=OLD.id) OR
  EXISTS(SELECT 1 FROM administracion.movimientos_tesoreria WHERE empresa_id=OLD.id)) THEN
 RAISE EXCEPTION 'Base currency with financial history requires an explicit transition' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS administracion_moneda_base ON organizacion.companies;
CREATE TRIGGER administracion_moneda_base BEFORE UPDATE OF base_currency_code ON organizacion.companies
FOR EACH ROW EXECUTE FUNCTION administracion.proteger_moneda_base();
REVOKE ALL ON SCHEMA catalogo,administracion FROM PUBLIC;
GRANT USAGE ON SCHEMA catalogo,administracion TO mastererp_app;
INSERT INTO plataforma.permissions(code,description) VALUES
 ('administration.read','Read administration within enabled finance and authorized company context'),
 ('catalog.master.read','Read shared canonical references within active tenant context') ON CONFLICT(code) DO NOTHING;
-- No role grants: permission assignments remain explicit, never resurrected on reapply.
ALTER TABLE administracion.condiciones_comerciales ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.condiciones_comerciales FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.condiciones_comerciales TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.condiciones_comerciales;
CREATE POLICY lectura_autorizada ON administracion.condiciones_comerciales FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.condiciones_comerciales;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.condiciones_comerciales FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.condiciones_comerciales;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.condiciones_comerciales FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.condiciones_comerciales;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.condiciones_comerciales
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.descuentos_pronto_pago ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.descuentos_pronto_pago FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.descuentos_pronto_pago TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.descuentos_pronto_pago;
CREATE POLICY lectura_autorizada ON administracion.descuentos_pronto_pago FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.descuentos_pronto_pago;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.descuentos_pronto_pago FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.descuentos_pronto_pago;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.descuentos_pronto_pago FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.descuentos_pronto_pago;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.descuentos_pronto_pago
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.perfiles_tercero ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.perfiles_tercero FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.perfiles_tercero TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.perfiles_tercero;
CREATE POLICY lectura_autorizada ON administracion.perfiles_tercero FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.perfiles_tercero;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.perfiles_tercero FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.perfiles_tercero;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.perfiles_tercero FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.perfiles_tercero;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.perfiles_tercero
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.documentos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.documentos FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.documentos TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.documentos;
CREATE POLICY lectura_autorizada ON administracion.documentos FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.documentos;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.documentos FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.documentos;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.documentos FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.documentos;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.documentos
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.detalles_documento ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.detalles_documento FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.detalles_documento TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.detalles_documento;
CREATE POLICY lectura_autorizada ON administracion.detalles_documento FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.detalles_documento;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.detalles_documento FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.detalles_documento;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.detalles_documento FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.detalles_documento;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.detalles_documento
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.relaciones_documento ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.relaciones_documento FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.relaciones_documento TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.relaciones_documento;
CREATE POLICY lectura_autorizada ON administracion.relaciones_documento FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.relaciones_documento;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.relaciones_documento FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.relaciones_documento;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.relaciones_documento FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.relaciones_documento;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.relaciones_documento
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.destinos_compra ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.destinos_compra FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.destinos_compra TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.destinos_compra;
CREATE POLICY lectura_autorizada ON administracion.destinos_compra FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.destinos_compra;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.destinos_compra FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.destinos_compra;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.destinos_compra FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.destinos_compra;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.destinos_compra
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.detalle_destinos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.detalle_destinos FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.detalle_destinos TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.detalle_destinos;
CREATE POLICY lectura_autorizada ON administracion.detalle_destinos FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.detalle_destinos;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.detalle_destinos FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.detalle_destinos;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.detalle_destinos FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.detalle_destinos;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.detalle_destinos
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.cuentas_tesoreria ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.cuentas_tesoreria FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.cuentas_tesoreria TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.cuentas_tesoreria;
CREATE POLICY lectura_autorizada ON administracion.cuentas_tesoreria FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.cuentas_tesoreria;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.cuentas_tesoreria FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.cuentas_tesoreria;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.cuentas_tesoreria FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.cuentas_tesoreria;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.cuentas_tesoreria
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.operaciones_tesoreria ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.operaciones_tesoreria FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.operaciones_tesoreria TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.operaciones_tesoreria;
CREATE POLICY lectura_autorizada ON administracion.operaciones_tesoreria FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.operaciones_tesoreria;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.operaciones_tesoreria FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.operaciones_tesoreria;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.operaciones_tesoreria FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.operaciones_tesoreria;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.operaciones_tesoreria
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.movimientos_tesoreria ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.movimientos_tesoreria FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.movimientos_tesoreria TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.movimientos_tesoreria;
CREATE POLICY lectura_autorizada ON administracion.movimientos_tesoreria FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.movimientos_tesoreria;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.movimientos_tesoreria FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.movimientos_tesoreria;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.movimientos_tesoreria FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.movimientos_tesoreria;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.movimientos_tesoreria
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.transferencias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.transferencias FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.transferencias TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.transferencias;
CREATE POLICY lectura_autorizada ON administracion.transferencias FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.transferencias;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.transferencias FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.transferencias;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.transferencias FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.transferencias;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.transferencias
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.extractos_bancarios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.extractos_bancarios FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.extractos_bancarios TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.extractos_bancarios;
CREATE POLICY lectura_autorizada ON administracion.extractos_bancarios FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.extractos_bancarios;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.extractos_bancarios FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.extractos_bancarios;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.extractos_bancarios FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.extractos_bancarios;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.extractos_bancarios
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.lineas_extracto ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.lineas_extracto FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.lineas_extracto TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.lineas_extracto;
CREATE POLICY lectura_autorizada ON administracion.lineas_extracto FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.lineas_extracto;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.lineas_extracto FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.lineas_extracto;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.lineas_extracto FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.lineas_extracto;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.lineas_extracto
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.conciliaciones ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.conciliaciones FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.conciliaciones TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.conciliaciones;
CREATE POLICY lectura_autorizada ON administracion.conciliaciones FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.conciliaciones;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.conciliaciones FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.conciliaciones;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.conciliaciones FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.conciliaciones;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.conciliaciones
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.partidas_conciliacion ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.partidas_conciliacion FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.partidas_conciliacion TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.partidas_conciliacion;
CREATE POLICY lectura_autorizada ON administracion.partidas_conciliacion FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.partidas_conciliacion;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.partidas_conciliacion FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.partidas_conciliacion;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.partidas_conciliacion FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.partidas_conciliacion;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.partidas_conciliacion
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.partidas_cartera ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.partidas_cartera FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.partidas_cartera TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.partidas_cartera;
CREATE POLICY lectura_autorizada ON administracion.partidas_cartera FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.partidas_cartera;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.partidas_cartera FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.partidas_cartera;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.partidas_cartera FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.partidas_cartera;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.partidas_cartera
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.vencimientos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.vencimientos FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.vencimientos TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.vencimientos;
CREATE POLICY lectura_autorizada ON administracion.vencimientos FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.vencimientos;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.vencimientos FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.vencimientos;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.vencimientos FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.vencimientos;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.vencimientos
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.aplicaciones_cartera ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.aplicaciones_cartera FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.aplicaciones_cartera TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.aplicaciones_cartera;
CREATE POLICY lectura_autorizada ON administracion.aplicaciones_cartera FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.aplicaciones_cartera;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.aplicaciones_cartera FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.aplicaciones_cartera;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.aplicaciones_cartera FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.aplicaciones_cartera;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.aplicaciones_cartera
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.categorias_gasto ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.categorias_gasto FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.categorias_gasto TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.categorias_gasto;
CREATE POLICY lectura_autorizada ON administracion.categorias_gasto FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.categorias_gasto;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.categorias_gasto FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.categorias_gasto;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.categorias_gasto FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.categorias_gasto;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.categorias_gasto
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.gastos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.gastos FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.gastos TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.gastos;
CREATE POLICY lectura_autorizada ON administracion.gastos FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.gastos;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.gastos FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.gastos;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.gastos FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.gastos;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.gastos
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.fondos_caja_chica ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.fondos_caja_chica FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.fondos_caja_chica TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.fondos_caja_chica;
CREATE POLICY lectura_autorizada ON administracion.fondos_caja_chica FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.fondos_caja_chica;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.fondos_caja_chica FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.fondos_caja_chica;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.fondos_caja_chica FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.fondos_caja_chica;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.fondos_caja_chica
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.reposiciones ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.reposiciones FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.reposiciones TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.reposiciones;
CREATE POLICY lectura_autorizada ON administracion.reposiciones FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.reposiciones;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.reposiciones FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.reposiciones;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.reposiciones FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.reposiciones;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.reposiciones
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.anticipos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.anticipos FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.anticipos TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.anticipos;
CREATE POLICY lectura_autorizada ON administracion.anticipos FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.anticipos;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.anticipos FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.anticipos;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.anticipos FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.anticipos;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.anticipos
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.rendiciones ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.rendiciones FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.rendiciones TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.rendiciones;
CREATE POLICY lectura_autorizada ON administracion.rendiciones FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.rendiciones;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.rendiciones FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.rendiciones;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.rendiciones FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.rendiciones;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.rendiciones
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.rendicion_gastos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.rendicion_gastos FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.rendicion_gastos TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.rendicion_gastos;
CREATE POLICY lectura_autorizada ON administracion.rendicion_gastos FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.rendicion_gastos;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.rendicion_gastos FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.rendicion_gastos;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.rendicion_gastos FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.rendicion_gastos;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.rendicion_gastos
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.politicas_reserva ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.politicas_reserva FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.politicas_reserva TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.politicas_reserva;
CREATE POLICY lectura_autorizada ON administracion.politicas_reserva FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.politicas_reserva;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.politicas_reserva FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.politicas_reserva;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.politicas_reserva FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.politicas_reserva;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.politicas_reserva
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.reservas_fondos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.reservas_fondos FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.reservas_fondos TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.reservas_fondos;
CREATE POLICY lectura_autorizada ON administracion.reservas_fondos FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.reservas_fondos;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.reservas_fondos FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.reservas_fondos;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.reservas_fondos FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.reservas_fondos;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.reservas_fondos
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE administracion.soportes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.soportes FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.soportes TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.soportes;
CREATE POLICY lectura_autorizada ON administracion.soportes FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id,sucursal_id));
DROP TRIGGER IF EXISTS proteger ON administracion.soportes;
CREATE TRIGGER proteger BEFORE INSERT OR UPDATE OR DELETE ON administracion.soportes FOR EACH ROW EXECUTE FUNCTION administracion.proteger_fila();
DROP TRIGGER IF EXISTS auditar ON administracion.soportes;
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON administracion.soportes FOR EACH ROW EXECUTE FUNCTION administracion.auditar_fila();
DROP TRIGGER IF EXISTS integridad ON administracion.soportes;
CREATE CONSTRAINT TRIGGER integridad AFTER INSERT OR UPDATE OR DELETE ON administracion.soportes
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.integridad_diferida();
ALTER TABLE catalogo.terceros ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON catalogo.terceros FROM PUBLIC,mastererp_app;
GRANT SELECT ON catalogo.terceros TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON catalogo.terceros;
CREATE POLICY lectura_autorizada ON catalogo.terceros FOR SELECT TO mastererp_app USING (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_permission('catalog.master.read'));
ALTER TABLE catalogo.roles_tercero ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON catalogo.roles_tercero FROM PUBLIC,mastererp_app;
GRANT SELECT ON catalogo.roles_tercero TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON catalogo.roles_tercero;
CREATE POLICY lectura_autorizada ON catalogo.roles_tercero FOR SELECT TO mastererp_app USING (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_permission('catalog.master.read'));
ALTER TABLE catalogo.productos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON catalogo.productos FROM PUBLIC,mastererp_app;
GRANT SELECT ON catalogo.productos TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON catalogo.productos;
CREATE POLICY lectura_autorizada ON catalogo.productos FOR SELECT TO mastererp_app USING (tenant_id=plataforma.current_app_tenant_id() AND plataforma.has_current_tenant_permission('catalog.master.read'));
ALTER TABLE catalogo.monedas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON catalogo.monedas FROM PUBLIC,mastererp_app;
GRANT SELECT ON catalogo.monedas TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON catalogo.monedas;
CREATE POLICY lectura_autorizada ON catalogo.monedas FOR SELECT TO mastererp_app USING (EXISTS(SELECT 1 FROM plataforma.users u WHERE u.id=plataforma.current_app_user_id() AND u.status='active'));
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA administracion FROM PUBLIC,mastererp_app;
CREATE OR REPLACE VIEW administracion.saldos_cuentas WITH(security_invoker=true) AS
 SELECT c.tenant_id,c.empresa_id,c.id cuenta_id,c.moneda,COALESCE(sum(CASE WHEN m.sentido='entrada' THEN m.importe ELSE -m.importe END),0) saldo
 FROM administracion.cuentas_tesoreria c LEFT JOIN administracion.movimientos_tesoreria m ON m.cuenta_id=c.id GROUP BY c.tenant_id,c.empresa_id,c.id,c.moneda;
CREATE OR REPLACE VIEW administracion.saldos_vencimientos WITH(security_invoker=true) AS
 SELECT v.tenant_id,v.empresa_id,v.id vencimiento_id,v.fecha,v.importe,
 COALESCE(sum(CASE WHEN a.reverso_de_id IS NULL THEN a.importe_destino ELSE -a.importe_destino END),0) aplicado,
 v.importe-COALESCE(sum(CASE WHEN a.reverso_de_id IS NULL THEN a.importe_destino ELSE -a.importe_destino END),0) pendiente
 FROM administracion.vencimientos v LEFT JOIN administracion.aplicaciones_cartera a ON a.vencimiento_id=v.id GROUP BY v.tenant_id,v.empresa_id,v.id,v.fecha,v.importe;
CREATE OR REPLACE VIEW administracion.reservas_pendientes WITH(security_invoker=true) AS
 SELECT p.tenant_id,p.empresa_id,p.id politica_id,p.cuenta_id,p.tope,
 COALESCE(sum(CASE WHEN r.origen_id IS NULL THEN r.importe ELSE -r.importe END),0) reservado
 FROM administracion.politicas_reserva p LEFT JOIN administracion.reservas_fondos r ON r.politica_id=p.id GROUP BY p.tenant_id,p.empresa_id,p.id,p.cuenta_id,p.tope;
GRANT SELECT ON administracion.saldos_cuentas,administracion.saldos_vencimientos,administracion.reservas_pendientes TO mastererp_app;
CREATE INDEX IF NOT EXISTS detalles_documento_documento_id_lookup_idx ON administracion.detalles_documento(documento_id);
CREATE INDEX IF NOT EXISTS detalles_documento_detalle_origen_id_lookup_idx ON administracion.detalles_documento(detalle_origen_id);
CREATE INDEX IF NOT EXISTS detalle_destinos_detalle_id_lookup_idx ON administracion.detalle_destinos(detalle_id);
CREATE INDEX IF NOT EXISTS movimientos_tesoreria_operacion_id_lookup_idx ON administracion.movimientos_tesoreria(operacion_id);
CREATE INDEX IF NOT EXISTS movimientos_tesoreria_cuenta_id_lookup_idx ON administracion.movimientos_tesoreria(cuenta_id);
CREATE INDEX IF NOT EXISTS lineas_extracto_extracto_id_lookup_idx ON administracion.lineas_extracto(extracto_id);
CREATE INDEX IF NOT EXISTS vencimientos_partida_id_lookup_idx ON administracion.vencimientos(partida_id);
CREATE INDEX IF NOT EXISTS aplicaciones_cartera_vencimiento_id_lookup_idx ON administracion.aplicaciones_cartera(vencimiento_id);
CREATE INDEX IF NOT EXISTS aplicaciones_cartera_movimiento_id_lookup_idx ON administracion.aplicaciones_cartera(movimiento_id);
CREATE INDEX IF NOT EXISTS aplicaciones_cartera_credito_id_lookup_idx ON administracion.aplicaciones_cartera(credito_id);
CREATE INDEX IF NOT EXISTS partidas_conciliacion_linea_id_lookup_idx ON administracion.partidas_conciliacion(linea_id);
CREATE INDEX IF NOT EXISTS partidas_conciliacion_movimiento_id_lookup_idx ON administracion.partidas_conciliacion(movimiento_id);
CREATE INDEX IF NOT EXISTS reservas_fondos_politica_id_lookup_idx ON administracion.reservas_fondos(politica_id);
CREATE INDEX IF NOT EXISTS reservas_fondos_origen_id_lookup_idx ON administracion.reservas_fondos(origen_id);
CREATE INDEX IF NOT EXISTS rendicion_gastos_gasto_id_lookup_idx ON administracion.rendicion_gastos(gasto_id);
CREATE OR REPLACE VIEW administracion.saldos_partidas WITH(security_invoker=true) AS
 SELECT p.tenant_id,p.empresa_id,p.id partida_id,p.documento_id,p.lado,d.moneda,d.total,
 COALESCE(sum(v.pendiente),0) pendiente FROM administracion.partidas_cartera p
 JOIN administracion.documentos d ON d.id=p.documento_id
 LEFT JOIN administracion.saldos_vencimientos v ON v.vencimiento_id IN
 (SELECT id FROM administracion.vencimientos WHERE partida_id=p.id)
 GROUP BY p.tenant_id,p.empresa_id,p.id,p.documento_id,p.lado,d.moneda,d.total;
CREATE OR REPLACE VIEW administracion.cuentas_por_cobrar WITH(security_invoker=true) AS SELECT * FROM administracion.saldos_partidas WHERE lado='cobrar';
CREATE OR REPLACE VIEW administracion.cuentas_por_pagar WITH(security_invoker=true) AS SELECT * FROM administracion.saldos_partidas WHERE lado='pagar';
GRANT SELECT ON administracion.saldos_partidas,administracion.cuentas_por_cobrar,administracion.cuentas_por_pagar TO mastererp_app;
CREATE OR REPLACE VIEW administracion.cotizaciones WITH(security_invoker=true) AS SELECT * FROM administracion.documentos WHERE clase='cotizacion';
GRANT SELECT ON administracion.cotizaciones TO mastererp_app;
CREATE OR REPLACE VIEW administracion.ventas WITH(security_invoker=true) AS SELECT * FROM administracion.documentos WHERE clase='venta';
GRANT SELECT ON administracion.ventas TO mastererp_app;
CREATE OR REPLACE VIEW administracion.facturas_cliente WITH(security_invoker=true) AS SELECT * FROM administracion.documentos WHERE clase='factura_cliente';
GRANT SELECT ON administracion.facturas_cliente TO mastererp_app;
CREATE OR REPLACE VIEW administracion.solicitudes_compra WITH(security_invoker=true) AS SELECT * FROM administracion.documentos WHERE clase='solicitud_compra';
GRANT SELECT ON administracion.solicitudes_compra TO mastererp_app;
CREATE OR REPLACE VIEW administracion.ordenes_compra WITH(security_invoker=true) AS SELECT * FROM administracion.documentos WHERE clase='orden_compra';
GRANT SELECT ON administracion.ordenes_compra TO mastererp_app;
CREATE OR REPLACE VIEW administracion.facturas_proveedor WITH(security_invoker=true) AS SELECT * FROM administracion.documentos WHERE clase='factura_proveedor';
GRANT SELECT ON administracion.facturas_proveedor TO mastererp_app;
