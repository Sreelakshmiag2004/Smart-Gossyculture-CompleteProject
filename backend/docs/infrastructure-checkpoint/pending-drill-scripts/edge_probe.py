"""Outside-in probe of the deployed stack: TLS, exposure, unauthorized access. Runs on a separate
machine; reaches the host only through its two published ports."""
import asyncio, json, os, socket, ssl, sys, warnings
import aiomqtt, httpx
from websockets.asyncio.client import connect as ws_connect
from websockets.exceptions import InvalidStatus
warnings.simplefilter("ignore")
API, MQTT, CA = "api.rehearsal.invalid", "mqtt.rehearsal.invalid", "/s/rehearsal-root.crt"
DEV, DEV_PW = "sim-0002", os.environ["DEV_PW"]
fails = 0
def check(name, ok, detail=""):
    global fails
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))
def ctx(ca=CA, lo=ssl.TLSVersion.TLSv1_2, hi=None):
    c = ssl.create_default_context(cafile=ca)
    if hi: c.set_ciphers("DEFAULT:@SECLEVEL=0"); c.maximum_version = hi
    c.minimum_version = lo
    return c
def hs(host, port, name, c):
    with socket.create_connection((host, port), timeout=8) as raw, c.wrap_socket(raw, server_hostname=name) as t:
        return t.version(), t.cipher()[0], t.getpeercert()
def refused(fn, *exc):
    try: fn(); return False, "accepted"
    except exc as e: return True, type(e).__name__
print("== TLS")
for host, port in ((API, 443), (MQTT, 8883)):
    v, cipher, cert = hs(host, port, host, ctx())
    sans = [x[1] for x in cert["subjectAltName"]]
    check(f"{host}:{port} handshake verified (chain + hostname)", v in ("TLSv1.2", "TLSv1.3"), f"{v} {cipher}; SAN={sans}; issuer={dict(x[0] for x in cert['issuer']).get('commonName')}; notAfter={cert['notAfter']}")
    check(f"{host}:{port} TLS 1.0/1.1 refused", *refused(lambda: hs(host, port, host, ctx(lo=ssl.TLSVersion.TLSv1, hi=ssl.TLSVersion.TLSv1_1)), ssl.SSLError, OSError))
    check(f"{host}:{port} wrong server name refused", *refused(lambda: hs(host, port, "wrong-name.invalid", ctx()), ssl.SSLError))
    check(f"{host}:{port} not trusted by the public trust store (rehearsal CA only)", *refused(lambda: hs(host, port, host, ssl.create_default_context()), ssl.SSLCertVerificationError))
    check(f"{host}:{port} certificate is not a development certificate", "NOT FOR PRODUCTION" not in json.dumps(cert) and "DEVELOPMENT" not in json.dumps(cert))
def plain(port):
    with socket.create_connection((API, port), timeout=5) as s:
        s.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n"); return s.recv(200)
r = plain(443)
check("plaintext HTTP on 443 is not served", b"200" not in r, r[:60].decode(errors="replace").strip().replace("\r\n", " | "))
async def main():
    print("== HTTP exposure / unauthorized access")
    async with httpx.AsyncClient(base_url=f"https://{API}", verify=ctx(), timeout=10) as c:
        r = await c.get("/healthz"); check("GET /healthz", r.status_code == 200, f"{r.status_code} {r.text} hsts={r.headers.get('strict-transport-security')} server-header={'server' in r.headers}")
        for p in ("/readyz", "/metrics", "/docs", "/openapi.json", "/redoc", "/", "/admin", "/api/v2/me", "/.env"):
            r = await c.get(p); check(f"GET {p} not exposed", r.status_code == 404, str(r.status_code))
        r = await c.get("/api/v1/me"); check("API without token", r.status_code == 401, f"{r.status_code} {r.json()['error']['code']}")
        r = await c.get("/api/v1/me", headers={"authorization": "Bearer not-a-token"}); check("API with forged token", r.status_code == 401, str(r.status_code))
        r = await c.get("/api/v1/devices"); check("device list without token", r.status_code == 401, str(r.status_code))
        r = await c.post("/api/v1/auth/otp/verify", json={"phone": "+99900000001", "code": "000000"}); check("OTP verify with wrong code / no request", r.status_code in (400, 401, 403, 422, 429), str(r.status_code))
        # Uniform 202 by design (no enumeration). A number that is not allow-listed gets NO challenge:
        # even the correct staging test code cannot sign it in, and nothing is sent (no SMS provider).
        r = await c.post("/api/v1/auth/otp/request", json={"phone": "+99900000777"}); check("OTP request for a non-allow-listed number: uniform answer", r.status_code == 202, str(r.status_code))
        r = await c.post("/api/v1/auth/otp/verify", json={"phone": "+99900000777", "code": os.environ["TEST_OTP"]}); check("non-allow-listed number cannot sign in even with the test code", r.status_code == 401, str(r.status_code))
    try:
        async with ws_connect(f"wss://{API}/api/v1/ws", ssl=ctx(), open_timeout=10): check("WSS without token", False, "accepted")
    except InvalidStatus as e: check("WSS without token", e.response.status_code == 403, str(e.response.status_code))
    print("== MQTT unauthorized access")
    async def connect(user, pw, cid):
        async with aiomqtt.Client(MQTT, 8883, username=user, password=pw, identifier=cid, protocol=aiomqtt.ProtocolVersion.V5, tls_context=ctx(), timeout=8): return True
    for name, user, pw in (("anonymous", None, None), ("wrong password", DEV, "wrong-password"), ("unknown user", "sim-9999", "x" * 40), ("service account with device password", "svc-ingest", DEV_PW)):
        try: await connect(user, pw, "probe-" + name.split()[0]); check(f"MQTT connect: {name} refused", False, "accepted")
        except aiomqtt.MqttError as e: check(f"MQTT connect: {name} refused", True, str(e)[:60])
    try:
        raw = socket.create_connection((MQTT, 8883), timeout=5); raw.sendall(b"\x10\x10\x00\x04MQTT\x05\x02\x00\x3c\x00\x00\x03abc"); raw.settimeout(5); d = raw.recv(10); raw.close()
        check("MQTT without TLS on 8883 refused", d[:1] != b"\x20", repr(d))
    except OSError as e: check("MQTT without TLS on 8883 refused", True, type(e).__name__)
    async with aiomqtt.Client(MQTT, 8883, username=DEV, password=DEV_PW, identifier="probe-device", protocol=aiomqtt.ProtocolVersion.V5, tls_context=ctx(), timeout=8) as c:
        check("MQTT connect: valid staging test device over TLS", True)
        pass
    # ACL denial is reported in the MQTT 5 PUBACK reason code (135 = Not authorized); read it with paho.
    import paho.mqtt.client as paho
    pc = paho.Client(paho.CallbackAPIVersion.VERSION2, client_id="probe-device-pub", protocol=paho.MQTTv5)
    pc.username_pw_set(DEV, DEV_PW); pc.tls_set_context(ctx()); codes = {}
    pc.on_publish = lambda cl, ud, mid, rc, props: codes.__setitem__(mid, rc)
    pc.connect(MQTT, 8883, 30); pc.loop_start()
    for topic in ("bollbot/v1/sim-0001/telemetry", "bollbot/v1/sim-0002/command", "bollbot/v1/sim-0002/config", "gossy/health", "$SYS/broker/x"):
        info = pc.publish(topic, b"{}", qos=1); info.wait_for_publish(8)
        rc = codes.get(info.mid)
        check(f"device publish to {topic} denied", rc is not None and rc.value == 135, f"PUBACK reason {getattr(rc, 'value', None)} {rc}")
    pc.loop_stop(); pc.disconnect()
    async with aiomqtt.Client(MQTT, 8883, username=DEV, password=DEV_PW, identifier="probe-device", protocol=aiomqtt.ProtocolVersion.V5, tls_context=ctx(), timeout=8) as c:
        await c.subscribe("bollbot/v1/#", qos=1); await c.subscribe("$SYS/#", qos=0); await c.subscribe("#", qos=0)
        got = []
        async def listen():
            async for m in c.messages: got.append(str(m.topic))
        t = asyncio.create_task(listen())
        async with aiomqtt.Client(MQTT, 8883, username="sim-0001", password=os.environ["DEV1_PW"], identifier="probe-device-1", protocol=aiomqtt.ProtocolVersion.V5, tls_context=ctx(), timeout=8) as other:
            await other.publish("bollbot/v1/sim-0001/telemetry", b'{"probe":true}', qos=1)
        await asyncio.sleep(4); t.cancel()
        check("device receives nothing (other devices' data, $SYS, wildcard)", got == [], f"received={got}")
asyncio.run(main())
print(f"edge probe: {fails} failed")
sys.exit(1 if fails else 0)
