"""Battery power logger for experiment E11 (INA219 on the Pi's I2C bus).

Writes one row per interval: ts (with time zone), voltage_v, current_a. Start it at full charge
and stop it (Ctrl-C) at the end of the scan day, or let the low-voltage cut-off end it for a
measured runtime. Analysed by bollbot.analysis (E11).

    pip install pi-ina219
    python -m bollbot.edge.power_log --out bollbot/experiments/E11/power_day1.csv

Wiring: INA219 in series with the battery's positive lead, VIN+ on the battery side; SDA/SCL to
GPIO2/GPIO3; address 0x40 by default. Shunt 0.1 ohm on the common breakout boards.
"""
from __future__ import annotations

import argparse
import csv
import sys
import time
from datetime import datetime
from pathlib import Path

from bollbot.core.rules import IST


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Log battery voltage and current (E11)")
    p.add_argument("--out", required=True)
    p.add_argument("--interval", type=float, default=5.0, help="seconds between readings")
    p.add_argument("--shunt-ohms", type=float, default=0.1)
    p.add_argument("--max-amps", type=float, default=3.0)
    p.add_argument("--address", type=lambda s: int(s, 0), default=0x40)
    a = p.parse_args(argv)
    try:
        from ina219 import INA219
    except ImportError:
        print("pi-ina219 is not installed: pip install pi-ina219 (on the Pi, with I2C enabled)", file=sys.stderr)
        return 2
    ina = INA219(a.shunt_ohms, a.max_amps, address=a.address)
    ina.configure(ina.RANGE_16V)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    new = not out.exists()
    with open(out, "a", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        if new:
            w.writerow(["ts", "voltage_v", "current_a"])
        print(f"logging every {a.interval} s to {out} (Ctrl-C to stop)")
        try:
            while True:
                # supply_voltage = bus voltage + shunt drop = the battery terminal voltage
                w.writerow([datetime.now(IST).isoformat(timespec="seconds"), round(ina.supply_voltage(), 3), round(ina.current() / 1000, 4)])
                fh.flush()
                time.sleep(a.interval)
        except KeyboardInterrupt:
            print("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
