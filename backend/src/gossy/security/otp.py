"""OTP code issuing and delivery, isolated behind one interface.

The authentication flow (challenge storage, expiry, attempt limits, verification) is identical
for every environment. Only the ``OtpIssuer`` differs:

* ``TestOtpIssuer`` - development/staging only. Issues a challenge ONLY for allow-listed test
  numbers, using a fixed code from a secret file. Nothing is sent anywhere.
* ``UnavailableOtpIssuer`` - the default when test mode is off. Real SMS delivery is not
  implemented because the provider is undecided (U-4); requests fail with a clear 503.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
from typing import Protocol


class OtpDeliveryUnavailable(Exception):
    """No OTP delivery channel is configured for this environment."""


class OtpIssuer(Protocol):
    mode: str

    def issue(self, phone_e164: str) -> str | None:
        """Return the code to store (as a hash) for this phone, or None to silently decline.

        Declining silently (instead of an error) avoids revealing which numbers are accepted.
        Implementations that deliver codes must do so here.
        """


class TestOtpIssuer:
    __test__ = False  # not a pytest test class
    mode = "test"

    def __init__(self, allowed_phones: frozenset[str], fixed_code: str):
        self._allowed = allowed_phones
        self._code = fixed_code

    def issue(self, phone_e164: str) -> str | None:
        return self._code if phone_e164 in self._allowed else None


class UnavailableOtpIssuer:
    mode = "unavailable"

    def issue(self, phone_e164: str) -> str | None:
        raise OtpDeliveryUnavailable("OTP delivery is not configured (SMS provider undecided, U-4)")


def hash_code(key: bytes, phone_e164: str, code: str) -> str:
    """HMAC binds the code to the phone number so a stored hash cannot be reused elsewhere."""
    return hmac.new(key, f"{phone_e164}:{code}".encode(), hashlib.sha256).hexdigest()


def codes_match(expected_hash: str, key: bytes, phone_e164: str, code: str) -> bool:
    return hmac.compare_digest(expected_hash, hash_code(key, phone_e164, code))


def new_claim_code() -> str:
    """Device claim code shown once to an administrator (printed on the device label)."""
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I ambiguity
    return "-".join("".join(secrets.choice(alphabet) for _ in range(4)) for _ in range(3))
