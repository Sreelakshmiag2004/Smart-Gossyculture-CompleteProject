import base64
import json
import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest

from gossy.security.tokens import AccessTokenService, InvalidToken, hash_token, new_refresh_token

KEY = b"k" * 48


def svc(key=KEY, audience="gossy-app", ttl=900):
    return AccessTokenService(key, issuer="gossy-api", audience=audience, ttl_s=ttl)


def test_roundtrip_carries_user_session_role():
    uid, sid = uuid.uuid4(), uuid.uuid4()
    token, exp = svc().issue(user_id=uid, session_id=sid, role="farmer")
    claims = svc().verify(token)
    assert (claims.user_id, claims.session_id, claims.role) == (uid, sid, "farmer")
    assert abs((claims.expires_at - exp).total_seconds()) < 1


def test_expired_token_rejected():
    token, _ = svc(ttl=1).issue(user_id=uuid.uuid4(), session_id=uuid.uuid4(), role="farmer", now=datetime.now(UTC) - timedelta(minutes=5))
    with pytest.raises(InvalidToken):
        svc().verify(token)


def test_wrong_key_and_wrong_audience_rejected():
    token, _ = svc().issue(user_id=uuid.uuid4(), session_id=uuid.uuid4(), role="farmer")
    with pytest.raises(InvalidToken):
        svc(key=b"x" * 48).verify(token)
    with pytest.raises(InvalidToken):
        svc(audience="someone-else").verify(token)


def test_alg_none_and_tampered_tokens_rejected():
    token, _ = svc().issue(user_id=uuid.uuid4(), session_id=uuid.uuid4(), role="farmer")
    header, payload, sig = token.split(".")
    claims = json.loads(base64.urlsafe_b64decode(payload + "=="))
    claims["role"] = "admin"
    forged_payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    none_header = base64.urlsafe_b64encode(b'{"alg":"none","typ":"JWT"}').decode().rstrip("=")
    for forged in (f"{header}.{forged_payload}.{sig}", f"{none_header}.{forged_payload}.", "not-a-jwt"):
        with pytest.raises(InvalidToken):
            svc().verify(forged)


def test_missing_claims_rejected():
    token = jwt.encode({"sub": str(uuid.uuid4()), "aud": "gossy-app", "iss": "gossy-api", "exp": 9999999999}, KEY, algorithm="HS256")
    with pytest.raises(InvalidToken):
        svc().verify(token)


def test_short_key_refused():
    with pytest.raises(ValueError):
        AccessTokenService(b"short", issuer="i", audience="a", ttl_s=60)


def test_refresh_tokens_are_random_and_only_hash_is_derived():
    tokens = {new_refresh_token() for _ in range(200)}
    assert len(tokens) == 200 and all(len(t) >= 40 for t in tokens)
    t = next(iter(tokens))
    assert hash_token(t) == hash_token(t) and len(hash_token(t)) == 64 and t not in hash_token(t)
