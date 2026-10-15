"""Prometheus text exposition (format 0.0.4) for ``GET /metrics``, without extra dependencies.

Each service sets ``app.state.metrics_source`` to a callable returning ``Metric`` objects. In
production the CloudWatch agent scrapes the endpoint over the internal network (Phase 3); the
reverse proxy does NOT publish it (see deploy/prod/caddy/Caddyfile).
"""

from __future__ import annotations

import inspect
import re
from dataclasses import dataclass, field

from fastapi import APIRouter, Request
from fastapi.responses import PlainTextResponse

router = APIRouter(tags=["health"])
_NAME = re.compile(r"^[a-zA-Z_:][a-zA-Z0-9_:]*$")
CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"


@dataclass(frozen=True)
class Metric:
    name: str
    kind: str  # counter | gauge
    help: str
    samples: list[tuple[dict[str, str], float]] = field(default_factory=list)

    @classmethod
    def single(cls, name: str, kind: str, help: str, value: float) -> Metric:
        return cls(name, kind, help, [({}, value)])


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def render(metrics: list[Metric]) -> str:
    lines: list[str] = []
    for m in metrics:
        if not _NAME.match(m.name) or m.kind not in ("counter", "gauge"):
            raise ValueError(f"invalid metric {m.name!r}/{m.kind!r}")
        lines.append(f"# HELP {m.name} {m.help}")
        lines.append(f"# TYPE {m.name} {m.kind}")
        for labels, value in m.samples:
            label_text = ",".join(f'{k}="{_escape(v)}"' for k, v in sorted(labels.items()))
            lines.append(f"{m.name}{{{label_text}}} {float(value):g}" if label_text else f"{m.name} {float(value):g}")
    return "\n".join(lines) + "\n"


async def database_up(engine) -> Metric:
    """Live dependency probe at scrape time (bounded by the readiness-check timeout)."""
    from gossy.health.checks import _guarded, database_check

    result = await _guarded(database_check(engine))
    return Metric.single("gossy_database_up", "gauge", "1 if SELECT 1 succeeded at scrape time", 1.0 if result.ok else 0.0)


@router.get("/metrics", include_in_schema=False)
async def metrics(request: Request) -> PlainTextResponse:
    source = getattr(request.app.state, "metrics_source", None)
    result = source() if source else []
    if inspect.isawaitable(result):
        result = await result
    return PlainTextResponse(render(result), media_type=CONTENT_TYPE)
