# Smart Gossyculture / BollBot

AI cotton harvesting and pest detection robot. Final-year B.E. CSE project, Sri Sairam Engineering College.
Team: Divyashree K M, Sree Lakshmi A G, Swetha Sankara Kumar. Guide: Dr. C. R. Rene Robin.

| Folder | What it is | How to test |
|---|---|---|
| `lib/`, `test/` (top level) | Flutter app for farmers and operators | `flutter test` |
| `backend/` | FastAPI backend: REST/WebSocket API, MQTT ingestion, PostgreSQL/TimescaleDB | see `backend/README.md` |
| `bollbot/` | Cart and robot software: detection, counting, farm rules, robotic arm, ESP32 firmware, ML pipeline | `python -m unittest discover -s bollbot/tests -t .` (from this folder) |

Every push runs all suites on GitHub Actions (`.github/workflows/ci.yml`).
