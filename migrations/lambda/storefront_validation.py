"""Guarded DEV Storefront operational configuration migration."""

import json
import os
import re
from uuid import UUID


def configure_payments(connection, event, context):
    if (os.environ.get("ENVIRONMENT") != "dev" or os.environ.get("DB_NAME") != "mastererp"
            or not getattr(context, "invoked_function_arn", "").endswith(":function:mastererp-dev-database-migrator")):
        raise ValueError("Storefront payment DEV guard rejected")
    tenant = str(UUID(str(event.get("tenant_id", ""))))
    domain = str(event.get("domain", "")).lower()
    details = event.get("payment_details")
    if domain != "tienda-dev.tumandaito.com" or not isinstance(details, dict) or set(details) != {"mobilePayment", "bankTransfer"}:
        raise ValueError("Exact Storefront payment migration contract required")
    mobile = details.get("mobilePayment")
    transfer = details.get("bankTransfer")
    if (not isinstance(mobile, dict) or transfer is not None
            or not re.fullmatch(r"[VEJG]-?\d{6,12}", str(mobile.get("document", "")), re.I)
            or not re.fullmatch(r"0\d{10}", str(mobile.get("phone", "")))
            or not re.fullmatch(r"\d{4}", str(mobile.get("bankCode", "")))
            or not isinstance(mobile.get("bankName"), str)):
        raise ValueError("Invalid tenant payment recipient")
    connection.run("BEGIN")
    try:
        rows = connection.run("""UPDATE ventas_digitales.tiendas
          SET configuracion=jsonb_set(configuracion,'{paymentDetails}',CAST(:details AS jsonb),true),
              version=version+1,actualizado_en=transaction_timestamp()
          WHERE tenant_id=CAST(:tenant AS uuid) AND dominio=:domain AND estado='ACTIVE'
          RETURNING id,creado_por""", details=json.dumps(details), tenant=tenant, domain=domain)
        if len(rows) != 1:
            raise ValueError("Single active DEV store required")
        store, actor = rows[0]
        connection.run("""INSERT INTO auditoria.events
          (tenant_id,actor_user_id,module_code,entity_type,entity_id,action,metadata)
          VALUES(CAST(:tenant AS uuid),:actor,'2.4.2-ecommerce','tienda',:store,
          'dev.storefront.payment_configuration',jsonb_build_object('domain',:domain,'source','legacy-customer-app'))""",
          tenant=tenant, actor=actor, store=store, domain=domain)
        connection.run("COMMIT")
        return {"status": "succeeded", "tenant_id": tenant, "domain": domain,
                "store_id": str(store), "methods": ["cash", "mobile"]}
    except Exception:
        connection.run("ROLLBACK")
        raise
