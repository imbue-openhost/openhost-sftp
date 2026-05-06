# openhost-sftp

A simple SFTP-only SSH server for OpenHost, with an SSO-gated web UI for managing the public keys that are allowed to log in.

Deploy this on your zone and you get:

- An SFTP service at `<your-zone>:9107` (the host port mapped to the container's `:22`). Use it as a destination for `rsync`, `sftp`, `scp`, `rclone` (sftp backend), or any other SSH-aware tool.
- A web UI at `https://sftp.<your-zone>/` (gated by your zone's OpenHost SSO — only the owner can reach it). Paste public keys; the UI writes them to the SFTP server's `authorized_keys` file and they take effect immediately on the next connection.

The intended use case is "I want a place to drop files on my zone, accessed over a real encrypted protocol, with the simplest possible auth model." If you want a continuous-sync model use [openhost-syncthing](https://github.com/imbue-openhost/openhost-syncthing); if you want S3 semantics use [openhost-minio](https://github.com/imbue-openhost/openhost-minio); if you want WebDAV/calendar/contacts/general-purpose, use [openhost-nextcloud](https://github.com/imbue-openhost/openhost-nextcloud). This package is for the case where you just want to `rsync -e ssh` from cron.

## Quick start

1. Deploy the app (via the dashboard or `oh app add`).
2. Open `https://sftp.<your-zone>/`. You'll be redirected through OpenHost SSO; once signed in you'll land at the keys-management UI.
3. Paste the public key from your laptop (`cat ~/.ssh/id_ed25519.pub` on most setups). Give it a label so you'll remember which device it belongs to.
4. From your laptop:

```sh
sftp -P 9107 owner@<your-zone>
# or
rsync -e "ssh -p 9107" -avz ~/local-dir/ owner@<your-zone>:files/
```

Files land in `$OPENHOST_APP_DATA_DIR/sftp/files/` inside the container, persisted across container restarts.

## How auth works

- **Web UI**: gated entirely by OpenHost's router. Anyone without a valid `zone_auth` cookie is 302'd to `/login` on the parent zone before reaching this app. The frontend itself does no auth verification — it trusts that anyone reaching it is the zone owner. Same pattern as `openhost-minio`.
- **SFTP**: standard SSH public-key auth, scoped to the single user `owner`. Password auth is disabled; root login is disabled. Each successful auth is forced into the SFTP subsystem (no shell, no port forwarding, no agent forwarding, no X11 forwarding, no tunneling).
- **Chroot**: the `owner` user lands in `$OPENHOST_APP_DATA_DIR/sftp/` (a chrooted filesystem view) and can only reach files inside that directory.

## How to revoke access

Open the web UI, find the key, click **Delete**. The `authorized_keys` file is rewritten immediately. New connections from that key will be rejected. Existing already-open SSH sessions are NOT killed automatically — if you want to kill them too, restart the app from the OpenHost dashboard.

## Configuration

Sensible defaults; you don't need to set any of these in normal use.

| Env var                  | Purpose                                                                              | Default                          |
| ------------------------ | ------------------------------------------------------------------------------------ | -------------------------------- |
| `OPENHOST_APP_DATA_DIR`  | Persistent data dir; injected by compute_space at boot.                              | `/data`                          |
| `OPENHOST_ZONE_DOMAIN`   | Zone domain; injected. Used to render the connection examples in the web UI.         | `localhost`                      |
| `SSH_PUBLIC_HOST`        | Override the hostname shown in the connection-info card. Useful if SFTP is behind a different DNS name than the zone domain. | `$OPENHOST_ZONE_DOMAIN`          |
| `SSH_PUBLIC_PORT`        | Override the port shown in the connection-info card. Should match the `host_port` in `[[ports]]`. | `9107`                           |
| `PUID` / `PGID`          | UID/GID for the SFTP `owner` user inside the container. Match an existing host UID if you want to share data with other apps. | `1000` / `1000`                  |

## Filesystem layout (inside the container)

```
$OPENHOST_APP_DATA_DIR/
  sshd-host-keys/                  # ssh host keys — generated on first
                                   # boot, persisted across restarts so
                                   # clients don't see "host identity
                                   # changed" warnings after a redeploy
  authorized_keys                  # the canonical key list, written by
                                   # the web frontend, read by sshd
  authorized_keys.meta.json        # sidecar tracking added_at timestamps
                                   # for the UI; safe to lose
  sftp/                            # the SFTP chroot — owned by root,
                                   # mode 0755 (sshd refuses to chroot
                                   # into a non-root-owned dir)
    files/                         # the writable subdir inside the
                                   # chroot — owned by `owner`; this is
                                   # where uploads land
```

## Why a separate app?

Each existing OpenHost app handles "encrypted file transfer" differently:

| App | Wire encryption | Auth model | Server-side data | Best for |
|---|---|---|---|---|
| `openhost-syncthing` | TLS | Device pairing | Filesystem | Continuous sync between paired devices |
| `openhost-minio` | (HTTP today; HTTPS doable) | S3 access keys | Object store | Bucket-shaped storage with S3 client tooling |
| `openhost-nextcloud` | HTTPS via Caddy | OpenHost SSO + WebDAV app passwords | Filesystem | "I want everything Nextcloud has" |
| `openhost-sftp` (this) | SSH | SSH public keys | Filesystem (chrooted) | `rsync -e ssh` from cron, simplest possible "just drop files here" |

If you don't need an SFTP-shaped target, you probably want one of the others.

## Hardening notes

The sshd_config in this image is intentionally conservative:

- `PasswordAuthentication no`
- `PermitRootLogin no`
- `AllowUsers owner` (only one user can log in, regardless of `authorized_keys` contents)
- `ForceCommand internal-sftp` (no shell, no scp via legacy command, no rsync-direct — but rsync over SFTP works because rsync uses SFTP subsystem when invoked with `-e ssh`)
- `PermitTTY no`
- `AllowTcpForwarding no`, `AllowStreamLocalForwarding no`, `PermitTunnel no`, `X11Forwarding no`, `GatewayPorts no`
- `ChrootDirectory /data/sftp` — the user can't see anything outside their chroot
- The frontend rejects key lines with OpenSSH "options" prefixes — auth capabilities are configured globally in sshd_config, not per-key, so accepting per-key options would silently re-enable things we deny.

If you need to relax any of these (e.g. allow a shell for one user, or enable a SOCKS tunnel), edit `sshd_config` and rebuild. Don't try to do it via per-key `authorized_keys` options — the frontend will strip them.

## Limitations

- **Single user.** All `authorized_keys` entries authenticate the same `owner` user with access to the same chroot. If you want per-user separation you'd add multiple `Match User` blocks to sshd_config — out of scope for this package.
- **No upload size limit.** SFTP doesn't have a transparent quota; the only limit is the host's disk and the zone owner's `app_data` budget. Track disk usage from the OpenHost dashboard.
- **No bandwidth limit.** Same situation; sshd doesn't expose a clean throttle.
- **Logs are sshd's own format.** They land in the OpenHost log pipeline via stderr; reading them requires `oh app logs sftp` or equivalent.
