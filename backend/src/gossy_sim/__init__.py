"""Development-only device simulator.

Publishes contract-valid, clearly SYNTHETIC telemetry and events so backend and app work can
proceed before Raspberry Pi / ESP32 software exists. It only accepts ``sim-*`` device IDs so
simulated data can never be mistaken for a real field unit. It sends no commands and makes no
agricultural decisions (U-1 is unresolved).
"""
