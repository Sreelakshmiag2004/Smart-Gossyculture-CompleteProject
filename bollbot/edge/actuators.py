"""Pi side of the Pi <-> ESP32 link over MQTT (spec Sections 9, 10, 11).

The ESP32 is the safety AUTHORITY: it refuses or aborts any spray when the
E-stop, dead-man or person guard says no. This bridge adds fast feedback,
converts a dose in millilitres into pump time using the calibrated flow,
and logs every spray (completed, aborted or refused) to the outbox.

  python -m bollbot.edge.actuators status            # live ESP32 status
  python -m bollbot.edge.actuators calibrate         # 5 s spray into a measuring jug
  python -m bollbot.edge.actuators spray --ml 27     # one test spray (WATER only)
  python -m bollbot.edge.actuators home              # arm to home pose
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import uuid
from datetime import datetime
from typing import Callable, Optional, Protocol

from .detectors import now_ist
from .store import Outbox


class Transport(Protocol):
    def publish(self, topic: str, payload: str) -> None: ...
    def subscribe(self, topic: str, handler: Callable[[str, str], None]) -> None: ...


class SprayRefused(RuntimeError):
    pass


class ServoError(RuntimeError):
    pass


class ActuatorBridge:
    def __init__(self, transport: Transport, cart_id: str, cfg: dict, outbox: Optional[Outbox] = None,
                 farm: str = "", clock: Callable[[], datetime] = now_ist,
                 mono: Callable[[], float] = time.monotonic):
        self.t, self.cart_id, self.outbox, self.farm = transport, cart_id, outbox, farm
        self.flow = float(cfg["flow_ml_per_s"])
        if self.flow <= 0:
            raise ValueError("flow_ml_per_s must be > 0 (calibrate the pump)")
        self.min_ms, self.max_ms = int(cfg["spray_min_ms"]), int(cfg["spray_max_ms"])
        self.max_age = float(cfg.get("status_max_age_s", 3))
        self.clock, self.mono = clock, mono
        self.prefix = f"cart/{cart_id}"
        self.status: dict = {}
        self.status_at: Optional[float] = None
        self.online = False
        self._lock = threading.Lock()
        self._sprays: dict[str, dict] = {}        # id -> request info
        self._servo: dict[str, dict] = {}         # id -> {"ack": Event, "done": Event, ...}
        self.spray_log: list[dict] = []           # also kept in memory (CLI, tests)
        for suffix, fn in (("/status", self._on_status), ("/esp/online", self._on_online),
                           ("/event/spray_ack", self._on_spray_ack), ("/event/spray", self._on_spray),
                           ("/event/servo_ack", self._on_servo_ack),
                           ("/event/servo_done", self._on_servo_done),
                           ("/event/effector_ack", self._on_effector_ack)):
            transport.subscribe(self.prefix + suffix, fn)

    # --------------------------------------------------------------- status
    def ready_to_spray(self) -> tuple[bool, str]:
        """Pi-side pre-check for fast feedback. The ESP32 still decides."""
        if not self.online:
            return False, "esp32 offline"
        if self.status_at is None or self.mono() - self.status_at > self.max_age:
            return False, "esp32 status stale"
        block = self.status.get("block", "unknown")
        return (True, "ok") if block == "none" else (False, block)

    def ms_for_ml(self, ml: float) -> int:
        """Pump time for a dose. Refuses doses outside the pump limits rather
        than silently changing the dose."""
        if ml <= 0:
            raise SprayRefused("dose must be > 0 ml")
        ms = round(ml / self.flow * 1000)
        if not self.min_ms <= ms <= self.max_ms:
            raise SprayRefused(f"{ml} ml needs {ms} ms; allowed {self.min_ms}-{self.max_ms} ms "
                               f"at {self.flow} ml/s")
        return ms

    # ---------------------------------------------------------------- spray
    def spray_ml(self, ml: float, segment: str = "", purpose: str = "test") -> str:
        """Spray a dose (ml at label dilution). Returns the command id."""
        return self.spray_ms(self.ms_for_ml(ml), segment, purpose, ml)

    def spray_ms(self, ms: int, segment: str = "", purpose: str = "test",
                 ml: Optional[float] = None) -> str:
        """Run the pump for ms milliseconds (calibration uses this directly)."""
        if not self.min_ms <= ms <= self.max_ms:
            raise SprayRefused(f"{ms} ms outside {self.min_ms}-{self.max_ms} ms")
        ok, why = self.ready_to_spray()
        if not ok:
            self._log({"id": f"refused-{uuid.uuid4().hex[:8]}", "ml_requested": ml,
                       "ms_requested": ms, "ms_on": 0, "completed": False,
                       "result": "refused_by_pi", "reason": why, "segment": segment,
                       "purpose": purpose})
            raise SprayRefused(why)
        sid = f"s-{uuid.uuid4().hex[:12]}"
        with self._lock:
            self._sprays[sid] = {"ml_requested": ml, "ms_requested": ms, "segment": segment,
                                 "purpose": purpose, "sent": self.clock().isoformat()}
        self.t.publish(f"{self.prefix}/cmd/spray", json.dumps({"id": sid, "ms": ms}))
        return sid

    def _on_spray_ack(self, topic: str, payload: str) -> None:
        msg = _parse(payload)
        if not msg or msg.get("result") == "ok":
            return
        with self._lock:
            req = self._sprays.pop(msg.get("id", ""), None)
        if req is not None:
            self._log({**req, "id": msg["id"], "ms_on": 0, "completed": False,
                       "result": msg.get("result"), "reason": msg.get("reason")})

    def _on_spray(self, topic: str, payload: str) -> None:
        msg = _parse(payload)
        if not msg:
            return
        with self._lock:
            req = self._sprays.pop(msg.get("id", ""), None) or {}
        ms_on = int(msg.get("ms_on", 0))
        self._log({**req, "id": msg.get("id"), "ms_requested": msg.get("ms_requested"),
                   "ms_on": ms_on, "ml_delivered": round(ms_on / 1000 * self.flow, 1),
                   "completed": bool(msg.get("completed")),
                   "result": "completed" if msg.get("completed") else "aborted",
                   "reason": msg.get("reason")})

    def _log(self, rec: dict) -> None:
        rec = {"cart_id": self.cart_id, "farm": self.farm, "ts": self.clock().isoformat(),
               "flow_ml_per_s": self.flow, **rec}
        self.spray_log.append(rec)
        if self.outbox is not None:
            self.outbox.put("spray_event", rec["id"], rec)

    # ---------------------------------------------------------------- servo
    def move(self, angles: Optional[list[float]] = None, speed_dps: float = 30.0,
             home: bool = False, timeout_s: float = 15.0) -> str:
        """Move the arm and WAIT until the target is reached. Raises ServoError
        if the ESP32 rejects the move or it does not finish in time."""
        mid = f"m-{uuid.uuid4().hex[:12]}"
        entry = {"ack": threading.Event(), "done": threading.Event(), "ack_msg": None}
        with self._lock:
            self._servo[mid] = entry
        cmd = {"id": mid, "speed_dps": speed_dps}
        if home:
            cmd["home"] = True
        else:
            cmd["angles"] = [float(a) for a in angles or []]
        try:
            self.t.publish(f"{self.prefix}/cmd/servo", json.dumps(cmd))
            if not entry["ack"].wait(min(timeout_s, 3.0)):
                raise ServoError("no reply from ESP32")
            ack = entry["ack_msg"] or {}
            if not ack.get("accepted"):
                raise ServoError(f"move rejected: {ack.get('error') or 'unknown'}")
            if not entry["done"].wait(timeout_s):
                raise ServoError("move did not finish in time (E-stop or link loss?)")
            return mid
        finally:
            with self._lock:
                self._servo.pop(mid, None)

    def effector(self, on: bool, ms: int = 0, timeout_s: float = 3.0) -> None:
        """Switch the picking head (blower + rollers). ON is always time-limited
        by the firmware. Raises ServoError if the ESP32 refuses or does not answer."""
        eid = f"e-{uuid.uuid4().hex[:12]}"
        entry = {"ack": threading.Event(), "ack_msg": None}
        with self._lock:
            self._servo[eid] = entry
        try:
            self.t.publish(f"{self.prefix}/cmd/effector", json.dumps({"id": eid, "on": on, "ms": int(ms)}))
            if not entry["ack"].wait(timeout_s):
                raise ServoError("no reply from ESP32 (effector)")
            ack = entry["ack_msg"] or {}
            if ack.get("result") != "ok":
                raise ServoError(f"effector refused: {ack.get('result')} ({ack.get('reason')})")
        finally:
            with self._lock:
                self._servo.pop(eid, None)

    def _on_effector_ack(self, topic: str, payload: str) -> None:
        msg = _parse(payload)
        with self._lock:
            e = self._servo.get((msg or {}).get("id", ""))
        if e:
            e["ack_msg"] = msg
            e["ack"].set()

    def _on_servo_ack(self, topic: str, payload: str) -> None:
        msg = _parse(payload)
        with self._lock:
            e = self._servo.get((msg or {}).get("id", ""))
        if e:
            e["ack_msg"] = msg
            e["ack"].set()

    def _on_servo_done(self, topic: str, payload: str) -> None:
        msg = _parse(payload)
        with self._lock:
            e = self._servo.get((msg or {}).get("id", ""))
        if e:
            e["done"].set()

    # --------------------------------------------------------------- status
    def _on_status(self, topic: str, payload: str) -> None:
        msg = _parse(payload)
        if msg is not None:
            self.status, self.status_at = msg, self.mono()

    def _on_online(self, topic: str, payload: str) -> None:
        self.online = payload.strip() == "1"


def _parse(payload: str) -> Optional[dict]:
    try:
        v = json.loads(payload)
        return v if isinstance(v, dict) else None
    except (json.JSONDecodeError, TypeError):
        return None


class PahoTransport:
    """MQTT via paho-mqtt 2.x (pip install paho-mqtt). Resubscribes after reconnects."""

    def __init__(self, host: str, port: int, username: str = "", password: str = "",
                 client_id: str = ""):
        import paho.mqtt.client as mqtt
        self._c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                              client_id=client_id or f"bollbot-pi-{uuid.uuid4().hex[:6]}")
        if username:
            self._c.username_pw_set(username, password)
        self._handlers: dict[str, Callable[[str, str], None]] = {}
        self._c.on_message = lambda c, u, m: self._dispatch(m.topic, m.payload.decode("utf-8", "replace"))
        self._c.on_connect = lambda c, u, f, rc, p: [c.subscribe(t, qos=1) for t in self._handlers]
        self._c.reconnect_delay_set(1, 30)
        self._c.connect(host, port, keepalive=30)
        self._c.loop_start()

    def publish(self, topic: str, payload: str) -> None:
        self._c.publish(topic, payload, qos=1)

    def subscribe(self, topic: str, handler: Callable[[str, str], None]) -> None:
        self._handlers[topic] = handler
        self._c.subscribe(topic, qos=1)

    def _dispatch(self, topic: str, payload: str) -> None:
        h = self._handlers.get(topic)
        if h:
            h(topic, payload)

    def close(self) -> None:
        self._c.loop_stop()
        self._c.disconnect()


def connect_from_config(cfg: dict, outbox: Optional[Outbox] = None) -> ActuatorBridge:
    from .cart import resolve
    a = cfg["actuators"]
    pw_file = resolve(a.get("mqtt_password_file", ""))
    password = pw_file.read_text(encoding="utf-8").strip() if a.get("mqtt_password_file") and pw_file.exists() else ""
    t = PahoTransport(a["mqtt_host"], int(a["mqtt_port"]), a.get("mqtt_user", ""), password)
    return ActuatorBridge(t, cfg["cart_id"], a, outbox, cfg.get("farm", ""))


def main(argv: list[str] | None = None) -> int:
    from .cart import load_cart_config
    ap = argparse.ArgumentParser(description="Pi <-> ESP32 actuator tools (use WATER for tests)")
    ap.add_argument("--config")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("calibrate")
    sp = sub.add_parser("spray")
    sp.add_argument("--ml", type=float, required=True)
    sub.add_parser("home")
    a = ap.parse_args(argv)
    try:
        bridge = connect_from_config(load_cart_config(a.config))
    except ImportError:
        print("pip install paho-mqtt", file=sys.stderr)
        return 2
    time.sleep(2.5)                                 # wait for retained online flag + a status
    if a.cmd == "status":
        print(json.dumps({"online": bridge.online, **bridge.status}, indent=2))
        return 0
    if a.cmd == "home":
        bridge.move(home=True, speed_dps=20)
        print("arm at home")
        return 0
    ok, why = bridge.ready_to_spray()
    if not ok:
        print(f"not ready: {why} (hold the dead-man button, release the E-stop, clear 2 m)",
              file=sys.stderr)
        return 1
    if a.cmd == "calibrate":
        ms = bridge.max_ms
        print(f"spraying for {ms / 1000:.1f} s into a measuring jug - keep holding the dead-man")
        sid = bridge.spray_ms(ms, purpose="calibration")
    else:
        ms = bridge.ms_for_ml(a.ml)
        sid = bridge.spray_ml(a.ml, purpose="manual_test")
    deadline = time.monotonic() + ms / 1000 + 5
    while time.monotonic() < deadline and not any(r.get("id") == sid for r in bridge.spray_log):
        time.sleep(0.1)
    rec = next((r for r in bridge.spray_log if r.get("id") == sid), None)
    print(json.dumps(rec, indent=2) if rec else "no result from ESP32")
    if a.cmd == "calibrate" and rec and rec.get("completed"):
        print(f"measure the water (ml), then set flow_ml_per_s = ml / {ms / 1000:.1f} in cart.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
