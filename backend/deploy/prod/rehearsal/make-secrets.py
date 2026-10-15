"""LOCAL REHEARSAL ONLY: generate a secret document with the same shape as the one Terraform
writes to Secrets Manager (deploy/aws/terraform/secrets.tf). Fresh random values on every run;
printed to stdout, stored only inside the rehearsal host container. Never a development value.

    python3 make-secrets.py staging > secrets.json
"""

import json
import secrets
import string
import sys

env = sys.argv[1] if len(sys.argv) > 1 else "staging"
alphabet = string.ascii_letters + string.digits  # same character set as random_password(special=false)


def rand(n: int) -> str:
    return "".join(secrets.choice(alphabet) for _ in range(n))


doc = {k: rand(40) for k in ("db_postgres_password", "db_owner_password", "db_app_password", "mqtt_svc_ingest_password", "mqtt_svc_health_password")}
doc |= {k: rand(64) for k in ("jwt_signing_key", "otp_hmac_key")}
doc["test_otp_code"] = f"{secrets.randbelow(1_000_000):06d}" if env == "staging" else None
doc["mqtt_test_devices"] = {d: rand(40) for d in ("sim-0001", "sim-0002")} if env == "staging" else {}
print(json.dumps(doc))
