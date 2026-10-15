"""Consistency check for the monitoring chain, usable without an AWS account.

    services' /metrics  ->  CloudWatch agent (Prometheus scrape -> EMF)  ->  CloudWatch alarms

CloudWatch itself cannot be exercised locally, so this checks that the three definitions agree:
every application alarm in terraform/monitoring.tf must reference a series that (1) a service
really exports and (2) the agent configuration publishes with the dimensions the alarm uses.
An alarm on a metric that is never published would stay silent forever.

    curl -s 127.0.0.1:8001/metrics > ingest.txt ; curl -s 127.0.0.1:8000/metrics > api.txt
    python deploy/aws/check-monitoring.py ingest.txt api.txt

It does NOT prove that alarms fire in AWS (delivery, evaluation, SNS): that needs a deployed
environment. Standard library only.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MONITORING_TF = HERE / "terraform" / "monitoring.tf"
AGENT_JSON = HERE.parent / "prod" / "cloudwatch" / "amazon-cloudwatch-agent.json"
SCRAPE_LABELS = {"Environment", "job"}  # added by the scrape configuration (prometheus.yaml)
JOB_OF_FILE = {"ingest": "gossy-ingest", "api": "gossy-api"}


def exported_series(paths: list[str]) -> dict[str, dict[str, set[str]]]:
    """metric name -> job -> label names, from Prometheus text files named <job>*.txt."""
    series: dict[str, dict[str, set[str]]] = {}
    for path in paths:
        job = next((j for key, j in JOB_OF_FILE.items() if key in Path(path).name), None)
        if job is None:
            sys.exit(f"cannot tell the scrape job from the file name: {path}")
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            m = re.match(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{([^}]*)\})?\s", line)
            if not m:
                continue
            labels = set(re.findall(r'([a-zA-Z_][a-zA-Z0-9_]*)="', m.group(2) or ""))
            series.setdefault(m.group(1), {}).setdefault(job, set()).update(labels)
    return series


def app_alarms() -> list[tuple[str, str, set[str]]]:
    """(resource, metric, dimension names) for every Gossy/App alarm in monitoring.tf."""
    text = MONITORING_TF.read_text(encoding="utf-8")
    alarms = []
    for block in re.finditer(r'resource "aws_cloudwatch_metric_alarm" "(\w+)" \{(.*?)\n\}', text, re.S):
        name, body = block.groups()
        if 'namespace           = "Gossy/App"' not in body:
            continue
        metric = re.search(r'metric_name\s*=\s*"([^"]+)"', body).group(1)
        dims = re.search(r"dimensions\s*=\s*(.+)", body).group(1)
        names = {"Environment"} | set(re.findall(r"(\w+)\s*=", dims)) - {"Environment"}
        alarms.append((name, metric, names))
    return alarms


def main() -> int:
    series = exported_series(sys.argv[1:])
    declarations = json.loads(AGENT_JSON.read_text(encoding="utf-8"))["logs"]["metrics_collected"]["prometheus"]["emf_processor"]["metric_declaration"]
    alarms = app_alarms()
    failed = 0
    for name, metric, dims in alarms:
        jobs = series.get(metric)
        published = any(
            re.search(d["label_matcher"], job)
            and any(re.search(sel, metric) for sel in d["metric_selectors"])
            and any(set(dimset) == dims and set(dimset) <= labels | SCRAPE_LABELS for dimset in d["dimensions"])
            for d in declarations
            for job, labels in (jobs or {}).items()
        )
        ok = jobs is not None and published
        failed += not ok
        why = "ok" if ok else ("not exported by any service" if jobs is None else "not published by the agent with these dimensions")
        print(f"{'PASS' if ok else 'FAIL'}  alarm {name}: {metric} {sorted(dims)} - {why}")
    selected = {m for m in series for d in declarations if any(re.search(s, m) for s in d["metric_selectors"])}
    print(f"{len(alarms)} application alarms checked, {failed} failed; {len(selected)} of {len(series)} exported series are published to CloudWatch")
    return 1 if failed or not alarms else 0


if __name__ == "__main__":
    sys.exit(main())
