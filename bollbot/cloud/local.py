"""Run the cloud rules locally on a cart's outbox, without Firebase.

Useful for demos, the viva, and checking a field day's data on a laptop:

  python -m bollbot.cloud.local --outbox bollbot/data/outbox.sqlite --farm F01 \
      [--lat 11.23 --lon 78.88] [--extra extra.json] [--now 2027-01-18T11:00:00+05:30]

--extra: a JSON file with trap counts, observations and confirmations, e.g.
  {"traps": [{"farm":"F01","trap":"PBW-1","date":"2027-01-17","moths":9}],
   "observations": [{"farm":"F01","date":"2027-01-17","observation":"jassid_per_leaf","count":60,"units":25}],
   "confirmations": [{"farm":"F01","row":3,"segment":1,"class":"mealybug_colony","date":"2027-01-17"}]}
With --lat/--lon the live Open-Meteo forecast is used (needs internet).
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

from bollbot.core.config import load_etl, load_thresholds
from bollbot.core.rules import IST
from bollbot.edge.store import Outbox
from .service import InMemoryRepo, recompute_farm
from .weather import fetch


def load_repo(outbox_path: str, farm: str, extra: dict, lat=None, lon=None) -> InMemoryRepo:
    repo = InMemoryRepo()
    repo.add("farms", farm, {"name": farm, "lat": lat, "lon": lon})
    ob = Outbox(outbox_path)
    try:
        rows = ob._db.execute("SELECT kind, doc_id, payload FROM outbox WHERE kind='scan'").fetchall()
    finally:
        ob.close()
    for _, doc_id, payload in rows:
        repo.add("scans", doc_id, json.loads(payload))
    for coll in ("traps", "observations", "confirmations"):
        for i, d in enumerate(extra.get(coll, [])):
            repo.add(coll, f"{coll}-{i}", d)
    return repo


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Run the cloud rules on a local outbox")
    ap.add_argument("--outbox", required=True)
    ap.add_argument("--farm", required=True)
    ap.add_argument("--lat", type=float)
    ap.add_argument("--lon", type=float)
    ap.add_argument("--extra", help="JSON with traps / observations / confirmations")
    ap.add_argument("--now", help="ISO time with offset (default: now, IST)")
    a = ap.parse_args(argv)
    if not Path(a.outbox).exists():
        print(f"no outbox at {a.outbox}", file=sys.stderr)
        return 1
    extra = json.loads(Path(a.extra).read_text(encoding="utf-8")) if a.extra else {}
    now = datetime.fromisoformat(a.now) if a.now else datetime.now(IST)
    repo = load_repo(a.outbox, a.farm, extra, a.lat, a.lon)
    sent = []
    rep = recompute_farm(repo, a.farm, now, load_thresholds(), load_etl(), notifier=sent.extend,
                         fetch=fetch if a.lat is not None and a.lon is not None else None)
    st = repo.docs["farm_status"][a.farm]
    print(f"farm {a.farm} at {now.isoformat()}: {len(rep.segments)} segments")
    for s in st["segments"]:
        print(f"  {s['segment']}  R={s['readiness']}  {s['status']:9s} open={s['open_bolls']}")
    if st["window"]:
        print(f"picking window: {st['window']['status']} {st['window']['failed'] or ''}")
    for adv in repo.docs.get("advisories", {}).values():
        if adv.get("active"):
            print(f"[{adv['type']}] {adv['text_en']}\n   {adv['text_ta']}")
    print(f"{len(sent)} push messages would be sent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
