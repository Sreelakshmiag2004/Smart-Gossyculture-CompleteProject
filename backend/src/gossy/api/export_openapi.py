"""Write the OpenAPI document: ``python -m gossy.api.export_openapi > docs/openapi.json``.

tests/unit/test_openapi.py fails if docs/openapi.json differs from the code, so the committed
contract cannot drift from the implementation.
"""

from __future__ import annotations

import json
import sys

from gossy.api.app import create_app
from gossy.config import ApiSettings, CommonSettings


def build() -> dict:
    app = create_app(common=CommonSettings(environment="test", log_json=True), api=ApiSettings(docs_enabled=True), readiness_checks=[])
    return app.openapi()


def render() -> str:
    return json.dumps(build(), indent=2, sort_keys=True) + "\n"


if __name__ == "__main__":
    sys.stdout.write(render())
