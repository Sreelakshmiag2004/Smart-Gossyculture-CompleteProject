from gossy.alerts.rules import derive_alerts
from gossy.contracts.topics import MessageKind


def test_pest_detection_raises_warning_with_label_and_confidence():
    [a] = derive_alerts(MessageKind.PEST, {"label": "bollworm", "confidence": 0.91, "bbox": [0.1, 0.1, 0.2, 0.2]})
    assert (a.alert_type, a.severity) == ("pest_detected", "warning")
    assert a.details == {"label": "bollworm", "confidence": 0.91}


def test_spray_is_informational_and_links_detection():
    [a] = derive_alerts(MessageKind.SPRAY, {"durationMs": 1500, "relatedMsgId": "01ABCDEFGHJKMNPQRSTVWXYZ01"})
    assert (a.alert_type, a.severity) == ("spray_performed", "info")
    assert a.details["relatedMsgId"] == "01ABCDEFGHJKMNPQRSTVWXYZ01"


def test_offline_status_raises_alert_online_does_not():
    assert [a.alert_type for a in derive_alerts(MessageKind.STATUS, {"state": "offline"})] == ["device_offline"]
    assert derive_alerts(MessageKind.STATUS, {"state": "online"}) == []


def test_no_threshold_based_alerts_are_invented():
    # Low battery / moisture alerts need thresholds that the requirements do not define (U-1).
    assert derive_alerts(MessageKind.TELEMETRY, {"batteryPct": 1.0, "moistureRhPct": 99.0}) == []
    assert derive_alerts(MessageKind.HARVEST, {"maturity": "mature", "picked": True, "moistureRhPct": 5.0}) == []
