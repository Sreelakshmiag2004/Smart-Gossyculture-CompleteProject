from __future__ import annotations

import ssl
from pathlib import Path


def build_tls_context(ca_file: Path) -> ssl.SSLContext:
    """Server-authenticated TLS (TLS 1.2+, hostname verification on).

    Client certificates (mTLS) are not used yet: the production device credential type is
    unresolved (U-7). Development uses per-device username/password over TLS.
    """
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=str(ca_file))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context
