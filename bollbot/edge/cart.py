"""The cart program: scan rows, count bolls per segment, queue results for upload.

  python -m bollbot.edge.cart --farm F01                       # live camera
  python -m bollbot.edge.cart --farm F01 --source walk.mp4     # replay a recorded video
  python -m bollbot.edge.cart --farm F01 --no-sync             # offline only

Per frame: detect + track -> read row markers -> count tracks.
When a new row marker is confirmed, the previous segment closes: its counts,
a weather reading and up to 3 evidence photos become one SegmentScan record
in the outbox. A background thread uploads the outbox when online.
Stop with Ctrl-C; the open segment is closed and saved.
"""
from __future__ import annotations

import argparse
import logging
import signal
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

import yaml

from bollbot.core.config import CONFIG_DIR
from bollbot.core.models import SegmentScan
from .counting import Detection, TrackCounter
from .markers import ArucoReader, MarkerMap
from .segments import ClosedSegment, SegmentTracker
from .sensors import WeatherSource
from .store import Outbox

log = logging.getLogger("bollbot.cart")
PACKAGE_DIR = CONFIG_DIR.parent


def resolve(path: str) -> Path:
    """Paths in cart.yaml are relative to the bollbot/ folder."""
    p = Path(path)
    return p if p.is_absolute() else PACKAGE_DIR / p


def load_cart_config(path: str | Path | None = None) -> dict:
    p = Path(path) if path else CONFIG_DIR / "cart.yaml"
    cfg = yaml.safe_load(p.read_text(encoding="utf-8"))
    for key in ("cart_id", "farm", "detector", "markers", "counting", "evidence", "store"):
        if key not in cfg:
            raise ValueError(f"{p}: missing '{key}'")
    return cfg


class CartSession:
    """All per-frame logic, independent of the camera, so it can be tested."""

    def __init__(self, cfg: dict, farm: str, outbox: Outbox, markers: MarkerMap,
                 marker_reader, weather: WeatherSource, model_name: str,
                 save_image: Optional[Callable[[Path, object], None]] = None):
        self.cfg, self.farm, self.outbox = cfg, farm, outbox
        self.reader, self.weather, self.model_name = marker_reader, weather, model_name
        self.segments = SegmentTracker(markers, farm, cfg["markers"]["confirm_frames"])
        self.counter = TrackCounter(cfg["counting"]["min_hits"], cfg["detector"]["conf"])
        ev = cfg["evidence"]
        self.evidence_dir = resolve(ev["dir"]) / farm
        self.max_photos, self.photo_gap = ev["max_per_segment"], ev["min_gap_s"]
        self._save_image = save_image or _cv2_save
        self._photos: list[str] = []
        self._last_photo: Optional[datetime] = None
        self.frames_seen = 0
        self.frames_outside = 0
        self.scans_written = 0

    # ------------------------------------------------------------ per frame
    def process(self, ts: datetime, frame, dets: list[Detection]) -> Optional[dict]:
        """Handle one frame. Returns the scan record if a segment just closed."""
        self.frames_seen += 1
        closed = self.segments.observe(self.reader.detect(frame), ts)
        record = self._close(closed) if closed else None
        if closed:
            self._photos, self._last_photo = [], None
        if self.segments.current is None:
            self.frames_outside += 1
            self.counter.discard()            # before the first marker: not in any segment
            return record
        self.counter.update(dets)
        self._maybe_photo(ts, frame, dets)
        return record

    def end(self, ts: datetime) -> Optional[dict]:
        closed = self.segments.end(ts)
        return self._close(closed) if closed else None

    def heartbeat(self, ts: datetime, fps: float, cart_id: str) -> dict:
        cur = self.segments.current
        w = self.weather.read()
        payload = {
            "cart_id": cart_id, "farm": self.farm, "ts": ts.isoformat(), "fps": fps,
            "segment": cur.key if cur else None, "frames_seen": self.frames_seen,
            "scans_written": self.scans_written, "outbox": self.outbox.stats(),
            "untracked_detections": self.counter.untracked,
            "ignored_tags": {str(k): v for k, v in self.segments.ignored_tags.items()},
            "weather": w.to_dict() if w else None,
        }
        self.outbox.put("heartbeat", cart_id, payload)
        return payload

    # -------------------------------------------------------------- helpers
    def _maybe_photo(self, ts: datetime, frame, dets: list[Detection]) -> None:
        if not dets or len(self._photos) >= self.max_photos:
            return
        if self._last_photo and (ts - self._last_photo).total_seconds() < self.photo_gap:
            return
        ref = self.segments.current
        path = self.evidence_dir / f"{self.farm}_{ref.key}_{ts:%Y%m%dT%H%M%S}_{len(self._photos)}.jpg"
        try:
            self._save_image(path, frame)
        except Exception as e:  # noqa: BLE001 - a full SD card must not stop counting
            log.warning("could not save evidence photo: %s", e)
            return
        self._photos.append(str(path))
        self._last_photo = ts

    def _close(self, closed: ClosedSegment) -> dict:
        counts = self.counter.finalize()
        w = self.weather.read()
        scan = SegmentScan(farm=closed.ref.farm, row=closed.ref.row, segment=closed.ref.segment,
                           ts=closed.ended, counts=counts, model=self.model_name, weather=w,
                           source="cart")
        payload = scan.to_dict()
        payload.update({"started": closed.started.isoformat(), "frames": closed.frames,
                        "duration_s": round((closed.ended - closed.started).total_seconds(), 1),
                        "evidence_local": list(self._photos)})
        self.outbox.put("scan", scan.scan_id, payload)
        self.scans_written += 1
        log.info("segment %s closed: %s", closed.ref.key,
                 {k: v for k, v in counts.items() if v})
        return payload


def _cv2_save(path: Path, frame) -> None:
    import cv2
    path.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(path), frame, [cv2.IMWRITE_JPEG_QUALITY, 85]):
        raise OSError(f"cv2.imwrite failed for {path}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="BollBot cart scanner")
    ap.add_argument("--config", help="cart.yaml (default: bollbot/config/cart.yaml)")
    ap.add_argument("--farm", help="override the farm in cart.yaml")
    ap.add_argument("--source", help="camera index or video file (ultralytics detector)")
    ap.add_argument("--no-sync", action="store_true", help="do not upload; outbox only")
    ap.add_argument("--max-frames", type=int, default=0, help="stop after N frames (0 = no limit)")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    from .detectors import fps_meter, make_source
    from .sensors import make_weather
    from .sync import MqttCloudUploader, SyncService

    cfg = load_cart_config(a.config)
    farm = a.farm or cfg["farm"]
    markers = MarkerMap.load(resolve(cfg["markers"]["csv"]))
    if not any(markers.get(t).farm == farm for t in markers.tags()):
        print(f"no markers for farm {farm} in {cfg['markers']['csv']}", file=sys.stderr)
        return 1
    outbox = Outbox(resolve(cfg["store"]["db"]))
    model_name = Path(cfg["detector"]["oak_blob" if cfg["detector"]["kind"] == "oak" else "model"]).stem
    session = CartSession(cfg, farm, outbox, markers, ArucoReader(cfg["markers"]["dictionary"]),
                          make_weather(cfg), model_name)

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    sync_thread, uploader = None, None
    if not a.no_sync:
        s = cfg["sync"]
        pw_file, ca_file = resolve(s["password_file"]), resolve(s["ca_file"])
        if pw_file.exists() and ca_file.exists() and s.get("broker_host"):
            try:
                uploader = MqttCloudUploader(cfg["cart_id"], s["broker_host"], int(s["broker_port"]),
                                             str(ca_file), pw_file.read_text(encoding="utf-8").strip(),
                                             outbox.next_seq)
            except ImportError:
                log.warning("paho-mqtt not installed: running offline, data stays in the outbox")
            else:
                svc = SyncService(outbox, uploader, s["min_backoff_s"], s["max_backoff_s"], s["batch"])
                sync_thread = threading.Thread(target=svc.run, args=(stop.is_set,), daemon=True)
                sync_thread.start()
        else:
            log.warning("broker not configured (sync.broker_host, %s, %s): running offline, "
                        "data stays in the outbox", pw_file, ca_file)

    try:
        source = make_source(cfg, a.source)
    except ImportError as e:
        need = {"ultralytics": "pip install ultralytics",
                "depthai": 'pip install "depthai<3"'}.get(e.name, f"pip install {e.name}")
        print(f"missing package '{e.name}' for detector '{cfg['detector']['kind']}': {need}",
              file=sys.stderr)
        outbox.close()
        return 2
    tick = fps_meter()
    last_hb, fps, ts = 0.0, 0.0, None
    try:
        for n, (ts, frame, dets) in enumerate(source.frames(), 1):
            fps = tick()
            session.process(ts, frame, dets)
            if time.monotonic() - last_hb >= cfg.get("heartbeat_s", 30):
                session.heartbeat(ts, fps, cfg["cart_id"])
                last_hb = time.monotonic()
            if stop.is_set() or (a.max_frames and n >= a.max_frames):
                break
    finally:
        if ts is not None:
            session.end(ts)
            session.heartbeat(ts, fps, cfg["cart_id"])
        stop.set()
        if sync_thread:
            sync_thread.join(timeout=10)
        if uploader:
            uploader.close()
        st = outbox.stats()
        log.info("stopped: %d frames, %d scans written, outbox pending %d",
                 session.frames_seen, session.scans_written, st["pending"])
        outbox.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
