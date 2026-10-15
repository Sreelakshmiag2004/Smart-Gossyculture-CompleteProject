"""Summarise container log lines read from stdin: how many are JSON, which fields, top events."""
import collections
import json
import sys

name = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "shape"
total = parsed = 0
keys: set[str] = set()
events: collections.Counter = collections.Counter()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    total += 1
    try:
        doc = json.loads(line)
    except ValueError:
        continue
    if not isinstance(doc, dict):
        continue
    parsed += 1
    keys |= set(doc)
    events[(doc.get("level"), doc.get("event") or doc.get("message") or doc.get("msg"))] += 1
if mode == "shape":
    print(f"  {name}: {parsed}/{total} lines are JSON" + (f"; fields: {sorted(keys)[:10]}" if parsed else " (plain text)"))
else:
    for (level, event), n in sorted(events.items(), key=lambda item: -item[1])[:16]:
        print(f"  {n:>6}  {level}  {event}")
