# OpenHost SFTP container.
#
# Two services in one image:
#
#   1. sshd in SFTP-subsystem-only mode on container port 22, exposed
#      to the public via openhost.toml's [[ports]] mapping (host
#      port 9107).  Auth is SSH-key-only — passwords are disabled.
#      The single user "owner" is chrooted to
#      $OPENHOST_APP_DATA_DIR/sftp inside the container.
#
#   2. A Flask-based web admin UI on container port 8080.  Gated by
#      OpenHost SSO at the router layer (the router 302's
#      unauthenticated visitors to /login on the parent zone), so
#      the frontend itself is unauthenticated — it trusts that the
#      OpenHost router only forwards owner traffic.  The frontend
#      lets the operator list, add, and remove the SSH public keys
#      that are allowed to log in to the SFTP service.
#
# Auth model: same as openhost-minio.  No auth-proxy sidecar.  The
# OpenHost router does JWT verification + SSO redirect upstream of
# us; the only thing this container needs to do is be ready for
# owner-only traffic on its frontend port and accept SSH-key-auth
# on its SFTP port.
#
# We base on debian:trixie-slim (the same trixie codebase
# python:3.13-slim uses) because we need both openssh-server (apt
# package) and python3 + Flask (apt package) in the same image, and
# python:3.13-slim doesn't ship openssh-server.  No multi-stage
# build needed; everything we want comes from apt.

FROM debian:trixie-slim

# -- system deps ---------------------------------------------------
# openssh-server: provides /usr/sbin/sshd and friends.
# python3 + python3-flask: serve the admin UI without requiring
#   pip-install-time RUN steps (some operator hosts trip on
#   "unknown version specified" from crun on RUN).
# tini: tiny init that reaps zombies + forwards signals.  Useful
#   when supervising multiple processes in one container.
# openssl + ca-certificates: for sshd host-key generation.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
        openssh-server \
        python3 \
        python3-flask \
        python3-werkzeug \
        tini \
        openssl \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

# -- application files ---------------------------------------------
# All app files committed with mode 0755 in the git index so we
# don't need RUN chmod (which fails on some operator hosts).
COPY frontend.py        /opt/openhost-sftp/frontend.py
COPY sshd_config        /opt/openhost-sftp/sshd_config
COPY start.sh           /opt/openhost-sftp/start.sh
COPY templates          /opt/openhost-sftp/templates

# -- runtime -------------------------------------------------------
EXPOSE 8080
EXPOSE 22

# tini handles signal forwarding to start.sh's children.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/openhost-sftp/start.sh"]
