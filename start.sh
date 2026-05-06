#!/bin/bash
# Boot the openhost-sftp container.
#
# Two children:
#   * sshd, configured for SFTP-only chroot.
#   * Flask frontend on 8080 for managing authorized_keys.
#
# We use bash specifically (not /bin/sh) for `wait -n`, same
# pattern openhost-syncthing and openhost-minio use.
set -euo pipefail

# OpenHost mounts persistent storage at OPENHOST_APP_DATA_DIR.
# In a real deploy this resolves to /data inside the container;
# we fall back to /data so paths in sshd_config are stable.
PERSIST="${OPENHOST_APP_DATA_DIR:-/data}"

# -----------------------------------------------------------------
# Filesystem layout under PERSIST
# -----------------------------------------------------------------
#
#   sshd-host-keys/         — host keys generated on first boot.
#                             Persisting these means clients don't
#                             see "REMOTE HOST IDENTIFICATION HAS
#                             CHANGED" warnings after a rebuild.
#   authorized_keys         — the public keys allowed to log in.
#                             Edited by the web frontend.
#   sftp/                   — the chroot the SFTP user lands in.
#                             ChrootDirectory in sshd_config points
#                             here.  Owned by root; the writable
#                             subdir below is where files land.
#   sftp/files/             — the actual writable directory the
#                             owner uploads into.  Owned by the
#                             owner uid.

HOST_KEY_DIR="$PERSIST/sshd-host-keys"
AUTHORIZED_KEYS="$PERSIST/authorized_keys"
SFTP_CHROOT="$PERSIST/sftp"
SFTP_FILES="$SFTP_CHROOT/files"

mkdir -p "$HOST_KEY_DIR" "$SFTP_CHROOT" "$SFTP_FILES"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

# -----------------------------------------------------------------
# Owner user
# -----------------------------------------------------------------
#
# We create a non-root user "owner" that the SFTP service runs as.
# UID/GID are configurable via PUID/PGID for operators who want to
# match an existing host UID, but defaults of 1000 are fine for the
# OpenHost-rootless-podman deployment model.
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

if ! getent group owner >/dev/null 2>&1; then
    groupadd --gid "$PGID" owner 2>/dev/null || true
fi
if ! getent passwd owner >/dev/null 2>&1; then
    useradd --uid "$PUID" --gid "$PGID" \
            --no-create-home \
            --home-dir "$SFTP_CHROOT" \
            --shell /usr/sbin/nologin \
            owner 2>/dev/null || true
fi

# -----------------------------------------------------------------
# Chroot ownership and permissions
# -----------------------------------------------------------------
#
# sshd refuses to chroot into a directory that is not owned by
# root or that is writable by anyone other than root.  This is a
# protection against privilege escalation paths through the
# chroot.  So:
#   * /data/sftp     must be root:root, mode 0755.
#   * /data/sftp/files (inside the chroot) is owned by the owner
#     uid, mode 0755 — that's where uploads land.
chown root:root "$SFTP_CHROOT"
chmod 0755 "$SFTP_CHROOT"
chown "$PUID:$PGID" "$SFTP_FILES"
chmod 0755 "$SFTP_FILES"

# authorized_keys must be owned by the user reading it (sshd is
# strict about this) and not group/world writable.
chown "$PUID:$PGID" "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"

# -----------------------------------------------------------------
# Host keys: generate on first boot, persist across rebuilds
# -----------------------------------------------------------------
#
# Stable host keys mean a client that has trusted us once won't
# see a warning on every container redeploy.  Generate one ed25519
# (preferred) and one RSA (broad client compat).
if [[ ! -f "$HOST_KEY_DIR/ssh_host_ed25519_key" ]]; then
    echo "[start.sh] First boot: generating SSH host keys"
    ssh-keygen -q -t ed25519 -N "" -f "$HOST_KEY_DIR/ssh_host_ed25519_key"
    ssh-keygen -q -t rsa -b 4096 -N "" -f "$HOST_KEY_DIR/ssh_host_rsa_key"
fi
chmod 600 "$HOST_KEY_DIR"/*_key
chmod 644 "$HOST_KEY_DIR"/*.pub

# -----------------------------------------------------------------
# Launch sshd
# -----------------------------------------------------------------
#
# -D: don't fork into the background; foregrounded so wait-n works.
# -e: send logs to stderr (so they reach the OpenHost log pipeline).
# -f: use our config (which references /data paths above).

echo "[start.sh] Starting sshd on container port 22"
/usr/sbin/sshd -D -e -f /opt/openhost-sftp/sshd_config &
SSHD_PID=$!

# -----------------------------------------------------------------
# Launch frontend
# -----------------------------------------------------------------

echo "[start.sh] Starting frontend on container port 8080"
export AUTHORIZED_KEYS_PATH="$AUTHORIZED_KEYS"
export SFTP_FILES_DIR="$SFTP_FILES"
export FLASK_PORT="${FLASK_PORT:-8080}"
python3 /opt/openhost-sftp/frontend.py &
FRONTEND_PID=$!

# -----------------------------------------------------------------
# Supervision
# -----------------------------------------------------------------

trap 'kill -TERM "$SSHD_PID" "$FRONTEND_PID" 2>/dev/null; wait' TERM INT

# Block until either child exits, then tear down the survivor.
set +e
wait -n "$SSHD_PID" "$FRONTEND_PID"
EXIT_CODE=$?
set -e

echo "[start.sh] Child exited (code=$EXIT_CODE); shutting down"
kill -TERM "$SSHD_PID" "$FRONTEND_PID" 2>/dev/null || true
wait || true
exit "$EXIT_CODE"
