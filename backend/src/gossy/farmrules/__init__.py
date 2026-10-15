"""Farm rules (Phase II, Module 7b): harvest readiness, picking window, rain alert, pest
thresholds and spray blocking, computed per farm from cart scans, trap counts, scouting
counts, confirmed detections and the rain forecast.

``core/`` and ``config/`` are an exact copy of ``bollbot/core`` and the two threshold files in
``bollbot/config``. The repository CI fails if the copies differ, so the cart, the experiments
and the backend always apply the same rules. Change them in ``bollbot/`` and copy them here.

The rules ADVISE. Nothing here can reach a device: there is no command path (v1 boundary).
"""
