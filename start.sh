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
#   home/                   — owner's writable home dir.  Where SSH
#                             and SFTP sessions land by default.
#                             Files put here via rsync/sftp/scp
#                             are persisted; sessions started via
#                             ssh start their cwd here.

HOST_KEY_DIR="$PERSIST/sshd-host-keys"
AUTHORIZED_KEYS="$PERSIST/authorized_keys"
OWNER_HOME="$PERSIST/home"

mkdir -p "$HOST_KEY_DIR" "$OWNER_HOME"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

# sshd's StrictModes refuses an authorized_keys file whose containing
# directory is group-writable.  compute_space mounts the persistent
# data dir with 0775 perms by default; tighten to 0755 so sshd
# accepts the key file.  The container's idmap means this only
# affects what the container sees, not the host-side perms.
chmod 0755 "$PERSIST"

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
    # /bin/bash as the shell so SSH login lands the user in an
    # interactive shell.  Home is the persistent OWNER_HOME so
    # any files dropped there via SFTP / rsync survive
    # container rebuilds.
    useradd --uid "$PUID" --gid "$PGID" \
            --no-create-home \
            --home-dir "$OWNER_HOME" \
            --shell /bin/bash \
            owner 2>/dev/null || true
fi

# Unlock the password field so sshd doesn't reject the account as
# "locked".  By default useradd leaves the shadow entry as "!" which
# sshd's UsePAM-aware checks treat as "this account cannot be used"
# even though we never authenticate via password (PubkeyAuthentication
# is the only enabled method).  We don't WANT a usable password — we
# just want the account to not be flagged as locked.  ``passwd -d``
# clears the shadow password field entirely; combined with
# PasswordAuthentication=no in sshd_config that means the only path
# in is the public-key one we want.
passwd -d owner >/dev/null 2>&1 || true

# -----------------------------------------------------------------
# Owner home + authorized_keys ownership
# -----------------------------------------------------------------
#
# Owner needs a writable home dir so login shells and SFTP
# sessions can chdir there cleanly.  The home dir lives under
# the persistent app_data dir so uploads survive rebuilds.
chown "$PUID:$PGID" "$OWNER_HOME"
chmod 0755 "$OWNER_HOME"

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

# -----------------------------------------------------------------
# Render sshd_config with the real persist path
# -----------------------------------------------------------------
#
# Compute_space mounts the per-app persistent dir at
# /data/app_data/<app-name>/ inside the container, NOT at /data.
# Our shipped sshd_config uses a __PERSIST__ placeholder for paths
# (HostKey, AuthorizedKeysFile, ChrootDirectory) that we
# substitute here with the real $PERSIST value before launching
# sshd.  Writing the rendered config to /run (which is in-memory
# tmpfs) keeps the on-disk image read-only-friendly.
RENDERED_SSHD_CONFIG="/run/sshd_config"
sed "s|__PERSIST__|$PERSIST|g" /opt/openhost-sftp/sshd_config > "$RENDERED_SSHD_CONFIG"
chmod 0600 "$RENDERED_SSHD_CONFIG"

echo "[start.sh] Starting sshd on container port 22 (config: $RENDERED_SSHD_CONFIG)"
/usr/sbin/sshd -D -e -f "$RENDERED_SSHD_CONFIG" &
SSHD_PID=$!

# -----------------------------------------------------------------
# Launch frontend
# -----------------------------------------------------------------

echo "[start.sh] Starting frontend on container port 8080"
export AUTHORIZED_KEYS_PATH="$AUTHORIZED_KEYS"
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
