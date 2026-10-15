import re

import pytest

from gossy.security.otp import OtpDeliveryUnavailable, TestOtpIssuer, UnavailableOtpIssuer, codes_match, hash_code, new_claim_code

KEY = b"h" * 48


def test_test_issuer_only_serves_allow_listed_numbers():
    issuer = TestOtpIssuer(frozenset({"+99900000001"}), "123456")
    assert issuer.issue("+99900000001") == "123456"
    assert issuer.issue("+919876543210") is None  # declined silently, never delivered
    assert issuer.mode == "test"


def test_production_default_has_no_delivery():
    with pytest.raises(OtpDeliveryUnavailable):
        UnavailableOtpIssuer().issue("+99900000001")


def test_code_hash_is_bound_to_phone_and_key():
    h = hash_code(KEY, "+99900000001", "123456")
    assert codes_match(h, KEY, "+99900000001", "123456")
    assert not codes_match(h, KEY, "+99900000002", "123456")
    assert not codes_match(h, KEY, "+99900000001", "654321")
    assert not codes_match(h, b"z" * 48, "+99900000001", "123456")
    assert "123456" not in h


def test_claim_codes_are_unambiguous_and_unique():
    codes = {new_claim_code() for _ in range(500)}
    assert len(codes) == 500
    assert all(re.fullmatch(r"[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}", c) for c in codes)
