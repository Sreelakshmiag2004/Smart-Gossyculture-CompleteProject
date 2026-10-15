"""Public edge of a deployed stack (Phase 3): TLS for REST, WebSocket and MQTT, and what is NOT
exposed. Runs only against the production stack (rehearsal or a real host) - set
GOSSY_TEST_EDGE_API_HOST, GOSSY_TEST_EDGE_MQTT_HOST and GOSSY_TEST_EDGE_CA_FILE."""

import asyncio
import json
import os
import socket
import ssl

import aiomqtt
import httpx
import pytest
from websockets.asyncio.client import connect as ws_connect_raw
from websockets.exceptions import InvalidStatus

from tests.integration.conftest import FARMER_A, bearer, login, password

API_HOST = os.environ.get("GOSSY_TEST_EDGE_API_HOST")
MQTT_HOST = os.environ.get("GOSSY_TEST_EDGE_MQTT_HOST")
CA_FILE = os.environ.get("GOSSY_TEST_EDGE_CA_FILE")
pytestmark = [pytest.mark.integration, pytest.mark.skipif(not API_HOST, reason="edge tests need a deployed stack (GOSSY_TEST_EDGE_API_HOST)")]


def ctx(minimum=ssl.TLSVersion.TLSv1_2, maximum=None) -> ssl.SSLContext:
    c = ssl.create_default_context(cafile=CA_FILE)
    if maximum:
        c.set_ciphers("DEFAULT:@SECLEVEL=0")  # let the CLIENT offer old versions: the server must refuse
        c.maximum_version = maximum
    c.minimum_version = minimum
    return c


@pytest.fixture
async def edge():
    async with httpx.AsyncClient(base_url=f"https://{API_HOST}", verify=ctx(), timeout=10) as client:
        yield client


async def test_https_health_and_security_headers(edge):
    r = await edge.get("/healthz")
    assert r.status_code == 200 and r.json() == {"status": "ok"}
    assert r.headers["strict-transport-security"].startswith("max-age=")
    assert "server" not in r.headers
    assert r.http_version in ("HTTP/1.1", "HTTP/2")


@pytest.mark.parametrize("path", ["/readyz", "/metrics", "/docs", "/openapi.json", "/", "/admin"])
async def test_internal_endpoints_are_not_exposed(edge, path):
    assert (await edge.get(path)).status_code == 404


async def test_api_through_tls_requires_authentication(edge):
    r = await edge.get("/api/v1/me")
    assert r.status_code == 401 and r.json()["error"]["code"] == "unauthenticated"


async def test_login_and_data_through_tls(edge):
    tokens = await login(edge, FARMER_A)
    r = await edge.get("/api/v1/me", headers=bearer(tokens))
    assert r.status_code == 200 and r.json()["phone"] == FARMER_A


async def test_wss_through_tls(edge):
    tokens = await login(edge, FARMER_A)
    async with ws_connect_raw(f"wss://{API_HOST}/api/v1/ws", ssl=ctx(), additional_headers=bearer(tokens), open_timeout=10) as ws:
        hello = json.loads(await asyncio.wait_for(ws.recv(), 10))
    assert hello["type"] == "hello"
    with pytest.raises(InvalidStatus) as exc:
        async with ws_connect_raw(f"wss://{API_HOST}/api/v1/ws", ssl=ctx(), open_timeout=10):
            pass
    assert exc.value.response.status_code == 403


def handshake(host: str, port: int, server_name: str, context: ssl.SSLContext) -> dict:
    with socket.create_connection((host, port), timeout=10) as raw, context.wrap_socket(raw, server_hostname=server_name) as tls:
        return {"version": tls.version(), "cert": tls.getpeercert()}


@pytest.mark.parametrize("port_host", ["api", "mqtt"])
def test_tls12_minimum_and_hostname_verification(port_host):
    host, port = (API_HOST, 443) if port_host == "api" else (MQTT_HOST, 8883)
    assert handshake(host, port, host, ctx())["version"] in ("TLSv1.2", "TLSv1.3")
    with pytest.raises(ssl.SSLError):  # TLS 1.1 and below refused
        handshake(host, port, host, ctx(minimum=ssl.TLSVersion.TLSv1, maximum=ssl.TLSVersion.TLSv1_1))
    # Another name: Mosquitto presents its certificate (verification fails); Caddy has no
    # certificate for it and aborts the handshake. Both are refusals (SSLError).
    with pytest.raises(ssl.SSLError):
        handshake(host, port, "wrong-name.invalid", ctx())
    with pytest.raises(ssl.SSLCertVerificationError):  # not trusted without the right CA
        s = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=10) as raw, s.wrap_socket(raw, server_hostname=host):
            pass


def test_broker_serves_the_certificate_for_the_mqtt_host():
    cert = handshake(MQTT_HOST, 8883, MQTT_HOST, ctx())["cert"]
    names = {v for k, v in cert["subjectAltName"] if k == "DNS"}
    assert MQTT_HOST in names
    assert "NOT FOR PRODUCTION" not in json.dumps(cert)  # never the development CA


async def test_mqtt_tls_device_connection_with_hostname_verification():
    async with aiomqtt.Client(MQTT_HOST, 8883, username="sim-0002", password=password("sim-0002"), identifier="itest-edge",
                              protocol=aiomqtt.ProtocolVersion.V5, tls_context=ctx(), timeout=10):
        pass
    with pytest.raises(aiomqtt.MqttError):
        async with aiomqtt.Client(MQTT_HOST, 8883, username="sim-0002", password="wrong-password", identifier="itest-edge-bad",
                                  protocol=aiomqtt.ProtocolVersion.V5, tls_context=ctx(), timeout=10):
            pass


@pytest.mark.parametrize("port", [80, 1883, 9001])
def test_no_plaintext_or_websocket_broker_listener(port):
    for host in (API_HOST, MQTT_HOST):
        with pytest.raises(OSError):
            socket.create_connection((host, port), timeout=3).close()
