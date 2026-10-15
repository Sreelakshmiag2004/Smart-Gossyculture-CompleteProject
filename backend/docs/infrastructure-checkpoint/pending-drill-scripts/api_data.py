"""What the application serves to signed-in test farmers (run in the rehearsal tests container)."""
import asyncio, hashlib, json, os
import httpx
from tests.integration.conftest import FARMER_A, FARMER_B, FARMER_C, bearer, login

def n(body):
    if isinstance(body, list): return len(body)
    for k in ("items", "data", "results"):
        if isinstance(body, dict) and isinstance(body.get(k), list): return len(body[k])
    return "?"

async def main():
    out = []
    async with httpx.AsyncClient(base_url=os.environ.get("GOSSY_TEST_API_URL", "http://api:8000"), timeout=15) as c:
        for phone in (FARMER_A, FARMER_B, FARMER_C):
            t = await login(c, phone)
            parts = []
            for path in ("/api/v1/farms", "/api/v1/devices", "/api/v1/alerts", "/api/v1/detections"):
                r = await c.get(path, headers=bearer(t))
                parts.append(f"{path.rsplit('/', 1)[1]}={r.status_code}/{n(r.json())}/{hashlib.sha256(r.content).hexdigest()[:10]}")
            out.append(f"{phone}: " + " ".join(parts))
    print("\n".join(out))
asyncio.run(main())
