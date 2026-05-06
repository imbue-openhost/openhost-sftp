"""SSO-gated admin UI for managing the SFTP server's authorized SSH keys.

Auth model: the OpenHost router redirects unauthenticated visitors to
/login on the parent zone before any request reaches us, so this app
does NOT do its own auth verification.  We trust that anyone reaching
us is the zone owner.  The router additionally strips client-supplied
``X-OpenHost-Is-Owner`` / ``X-OpenHost-User`` headers from the request,
so we don't need to validate them either; we just present the admin
UI and trust the layer above.

Storage: the canonical list of authorized keys lives in
``$AUTHORIZED_KEYS_PATH`` — the same file ``sshd`` reads.  We keep a
sidecar JSON file at ``${AUTHORIZED_KEYS_PATH}.meta.json`` that maps
each key's fingerprint to its (added_at, last_used_at) metadata.  The
sidecar is treated as a hint only — if it's lost, the keys still work,
the admin UI just shows ``-`` for the timestamp columns.

Concurrency: every write to authorized_keys goes through a per-process
threading.Lock plus an O_EXCL temp-file-and-rename atomic-replace.
sshd reads the file fresh for each connection so it doesn't matter
that we don't hold a file lock against the reader; the lock is purely
to keep two simultaneous frontend writes from clobbering each other.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import secrets
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from flask import (
    Flask,
    abort,
    flash,
    redirect,
    render_template,
    request,
    url_for,
)

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

# Path to the authorized_keys file — sshd reads this directly.  Default
# matches what start.sh sets up; can be overridden for tests.
AUTHORIZED_KEYS_PATH = Path(
    os.environ.get("AUTHORIZED_KEYS_PATH", "/data/authorized_keys")
)
META_PATH = Path(str(AUTHORIZED_KEYS_PATH) + ".meta.json")

# Public host:port the operator should connect with.  Composed from
# OpenHost-injected env vars where available; the operator can also
# hard-set them if their network exposes the SFTP port via a different
# hostname / port mapping.
SSH_PUBLIC_HOST = os.environ.get(
    "SSH_PUBLIC_HOST",
    os.environ.get("OPENHOST_ZONE_DOMAIN", "your-zone.example.com"),
)
SSH_PUBLIC_PORT = int(os.environ.get("SSH_PUBLIC_PORT", "9107"))
SSH_USER = "owner"

# Used by Flask for flash() session messages.  Generated fresh each
# boot — flash messages don't survive container restarts, which is
# fine for our admin-UI use case.
SECRET_KEY = secrets.token_urlsafe(32)

# How big is too big to read as an authorized_keys line?  RFC says SSH
# keys are bounded; in practice no real key+comment exceeds a few KiB,
# and any "key" longer than this is malformed or hostile.
MAX_KEY_LINE_BYTES = 16 * 1024

# Hard cap on the total number of keys we'll keep.  Prevents an
# accidental loop from filling the file.  Operators with more than
# this many keys can edit the file directly.
MAX_KEYS = 256

# ---------------------------------------------------------------------
# App
# ---------------------------------------------------------------------

logging.basicConfig(
    level=os.environ.get("FRONTEND_LOG_LEVEL", "INFO"),
    format="[frontend] %(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("frontend")

# Template folder: prefer the in-container path
# (/opt/openhost-sftp/templates) but fall back to the directory
# alongside this file so unit tests can render templates without
# being run inside the container.
_TEMPLATE_DIR = "/opt/openhost-sftp/templates"
if not os.path.isdir(_TEMPLATE_DIR):
    _TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")

app = Flask(__name__, template_folder=_TEMPLATE_DIR)
app.config["SECRET_KEY"] = SECRET_KEY

# Single in-process write lock for authorized_keys + meta.  Threading,
# not multiprocessing — Flask's dev server we run below is single-
# process, but the lock is cheap insurance if we ever switch to a
# multi-worker WSGI server.
_write_lock = threading.Lock()


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------


def _read_keys_file() -> list[str]:
    """Return the authorized_keys file as a list of raw text lines.

    Empty lines and comment lines (starting with ``#``) are dropped.
    Whitespace is stripped from line ends.  Returns ``[]`` if the file
    doesn't exist yet.
    """
    if not AUTHORIZED_KEYS_PATH.exists():
        return []
    out = []
    try:
        text = AUTHORIZED_KEYS_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        log.error("failed to read %s: %s", AUTHORIZED_KEYS_PATH, exc)
        return []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        out.append(stripped)
    return out


def _atomic_write(path: Path, content: str, mode: int) -> None:
    """Write ``content`` to ``path`` atomically via temp + rename.

    Uses ``os.O_CREAT | O_EXCL`` on the temp file so a racing writer
    can't accidentally clobber an in-flight write, and ``os.rename``
    for the swap (atomic on POSIX file systems).  ``mode`` is the
    final permission bits (e.g. 0o600).
    """
    tmp = path.with_suffix(path.suffix + f".tmp-{os.getpid()}-{secrets.token_hex(4)}")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
    except Exception:
        try:
            os.unlink(str(tmp))
        except OSError:
            pass
        raise
    os.rename(str(tmp), str(path))


def _read_meta() -> dict[str, dict]:
    """Load the meta sidecar.  Returns ``{}`` if missing or unreadable."""
    if not META_PATH.exists():
        return {}
    try:
        return json.loads(META_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        log.warning("failed to read meta sidecar %s: %s", META_PATH, exc)
        return {}


def _write_meta(meta: dict[str, dict]) -> None:
    _atomic_write(META_PATH, json.dumps(meta, indent=2, sort_keys=True), 0o600)


def _fingerprint(key_body_b64: str) -> str:
    """Compute the SHA256 fingerprint of an SSH public key.

    Matches the format ``ssh-keygen -lf <key-file>`` produces:
    ``SHA256:<base64-of-sha256-bytes>``, with trailing ``=`` stripped.
    """
    try:
        key_bytes = base64.b64decode(key_body_b64, validate=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise ValueError(f"invalid base64 in key body: {exc}") from exc
    digest = hashlib.sha256(key_bytes).digest()
    b64 = base64.b64encode(digest).decode("ascii").rstrip("=")
    return f"SHA256:{b64}"


# Recognised SSH key types.  We accept these and reject anything else.
# Including ``ssh-rsa`` which is older but still in widespread use.
_VALID_KEY_TYPES = {
    "ssh-ed25519",
    "ssh-rsa",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
}


def _parse_key_line(line: str) -> tuple[str, str, str]:
    """Validate and parse a single authorized_keys-format line.

    Returns ``(key_type, key_body, comment)`` on success.  Raises
    ``ValueError`` with a human-readable message on bad input.

    Accepts the standard format ``<type> <base64-body> [<comment>]``
    plus the OpenSSH "options" prefix (e.g. ``no-port-forwarding,
    from="1.2.3.4" ssh-ed25519 ... user``).  We strip and discard the
    options prefix on parse — this app's policy is sshd_config-driven,
    not per-key, and accepting per-key options would silently grant
    capabilities (port forwarding, environment, etc.) we explicitly
    deny in the global config.
    """
    line = line.strip()
    if not line:
        raise ValueError("empty input")
    if len(line) > MAX_KEY_LINE_BYTES:
        raise ValueError("key line too long")

    parts = line.split(None, 2)

    # OpenSSH allows a leading "options" field before the key type.
    # Detect that case and drop the options.  The options field looks
    # like a comma-separated list of name=value pairs and never starts
    # with one of the known key types.  This is a coarse sniff but
    # matches what real-world authorized_keys lines look like.
    if parts and parts[0] not in _VALID_KEY_TYPES:
        # Probably an options field; drop it and re-parse.
        parts = line.split(None, 3)
        if len(parts) < 3:
            raise ValueError("could not parse key line")
        # parts is [options, key_type, key_body, comment?]
        if parts[1] not in _VALID_KEY_TYPES:
            raise ValueError(f"unsupported key type: {parts[1]!r}")
        key_type = parts[1]
        key_body = parts[2]
        comment = parts[3] if len(parts) >= 4 else ""
    else:
        if len(parts) < 2:
            raise ValueError("expected '<type> <body> [<comment>]'")
        key_type, key_body = parts[0], parts[1]
        comment = parts[2] if len(parts) >= 3 else ""

    if key_type not in _VALID_KEY_TYPES:
        raise ValueError(f"unsupported key type: {key_type!r}")

    # Sanity check the body is base64.  _fingerprint will raise a
    # ValueError if it isn't decodable, which is the validation we want.
    _fingerprint(key_body)

    # Strip any control chars from the comment (it'll be displayed
    # verbatim in the admin UI; we don't want to embed escape codes
    # or newlines).
    comment = "".join(ch for ch in comment if ch.isprintable())[:200]

    return key_type, key_body, comment


def _key_view_models() -> list[dict]:
    """Return a list of dicts describing each currently-authorized key.

    Each dict has:
      * key_type      — e.g. "ssh-ed25519"
      * comment       — the user-supplied label (may be "")
      * fingerprint   — SHA256:... format
      * body_short    — first 16 chars of the base64 body, for display
      * added_at      — ISO timestamp from the meta sidecar, or "-"
    """
    lines = _read_keys_file()
    meta = _read_meta()
    out = []
    for line in lines:
        try:
            key_type, key_body, comment = _parse_key_line(line)
        except ValueError as exc:
            log.warning("skipping unparseable key in authorized_keys: %s", exc)
            continue
        try:
            fp = _fingerprint(key_body)
        except ValueError:
            continue
        out.append({
            "key_type": key_type,
            "comment": comment or "(no label)",
            "fingerprint": fp,
            "body_short": key_body[:16] + "…" if len(key_body) > 16 else key_body,
            "added_at": (meta.get(fp, {}) or {}).get("added_at", "-"),
        })
    return out


def _save_keys(lines: list[str]) -> None:
    """Atomically write the authorized_keys file from a list of full lines."""
    content = "\n".join(lines) + ("\n" if lines else "")
    _atomic_write(AUTHORIZED_KEYS_PATH, content, 0o600)


# ---------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------


@app.get("/health")
def health():
    """Plain-text liveness probe.  Always 200 once the process is up."""
    return ("ok\n", 200, {"Content-Type": "text/plain; charset=utf-8"})


@app.get("/")
def index():
    keys = _key_view_models()
    return render_template(
        "index.html",
        keys=keys,
        ssh_host=SSH_PUBLIC_HOST,
        ssh_port=SSH_PUBLIC_PORT,
        ssh_user=SSH_USER,
        max_keys=MAX_KEYS,
    )


@app.post("/keys/add")
def add_key():
    raw = request.form.get("key", "").strip()
    if not raw:
        flash("Paste a public key.", "error")
        return redirect(url_for("index"))

    try:
        key_type, key_body, comment_in_line = _parse_key_line(raw)
    except ValueError as exc:
        flash(f"Couldn't parse that as an SSH public key: {exc}", "error")
        return redirect(url_for("index"))

    # If the form provided a separate "label" field, prefer that over
    # any comment that happened to be embedded in the pasted line.
    label = request.form.get("label", "").strip()
    if label:
        # Strip control chars; cap length.
        label = "".join(ch for ch in label if ch.isprintable())[:200]
        comment = label
    else:
        comment = comment_in_line

    new_line = f"{key_type} {key_body}" + (f" {comment}" if comment else "")
    fp = _fingerprint(key_body)

    with _write_lock:
        existing = _read_keys_file()
        # De-dupe: refuse to add a key whose fingerprint is already
        # present.  The user probably forgot they added it; saying so
        # is more useful than silently appending a duplicate line.
        for line in existing:
            try:
                _, body, _ = _parse_key_line(line)
                if _fingerprint(body) == fp:
                    flash(f"That key is already authorized ({fp}).", "warning")
                    return redirect(url_for("index"))
            except ValueError:
                continue

        if len(existing) >= MAX_KEYS:
            flash(
                f"At the {MAX_KEYS}-key cap; remove one before adding another.",
                "error",
            )
            return redirect(url_for("index"))

        existing.append(new_line)
        _save_keys(existing)

        meta = _read_meta()
        meta[fp] = {
            "added_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        _write_meta(meta)

    log.info("added key fp=%s type=%s comment=%r", fp, key_type, comment)
    flash(f"Key added ({fp}).", "success")
    return redirect(url_for("index"))


@app.post("/keys/delete")
def delete_key():
    fp = request.form.get("fingerprint", "").strip()
    if not fp:
        abort(400, "fingerprint required")

    with _write_lock:
        existing = _read_keys_file()
        kept = []
        removed = False
        for line in existing:
            try:
                _, body, _ = _parse_key_line(line)
            except ValueError:
                # Keep unparseable lines verbatim — we don't want a
                # bad line to be silently lost on a delete-someone-else
                # operation.
                kept.append(line)
                continue
            if _fingerprint(body) == fp:
                removed = True
                continue
            kept.append(line)

        if not removed:
            flash("Key not found (already removed?).", "warning")
            return redirect(url_for("index"))

        _save_keys(kept)

        meta = _read_meta()
        meta.pop(fp, None)
        _write_meta(meta)

    log.info("deleted key fp=%s", fp)
    flash(f"Key deleted ({fp}).", "success")
    return redirect(url_for("index"))


# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------


def main() -> int:
    port = int(os.environ.get("FLASK_PORT", "8080"))
    log.info(
        "starting on 0.0.0.0:%d (authorized_keys=%s, ssh=%s:%d)",
        port,
        AUTHORIZED_KEYS_PATH,
        SSH_PUBLIC_HOST,
        SSH_PUBLIC_PORT,
    )
    # Flask's built-in dev server.  Single-threaded by default which
    # is fine for an operator-only admin UI; any contention would be
    # the operator double-clicking the submit button.
    app.run(host="0.0.0.0", port=port, debug=False, use_reloader=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
