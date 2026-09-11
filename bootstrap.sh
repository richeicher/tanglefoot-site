#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# tanglefoot.dev — Lightsail launch script
#
# Paste this into the "Launch script" box when you create the instance.
# It runs once, as root, on first boot. Edit REPO_URL below first.
#
# Installs nginx, clones the site repo, installs a validating deploy script and
# a systemd timer that pulls every morning at 06:20 America/Los_Angeles.
# TLS is NOT set up here — that needs DNS to resolve first. Runbook step 5.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── EDIT THIS ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/richeicher/tanglefoot-site.git"
DOMAIN="tanglefoot.dev"
MARKER="OTIUM Conditions"   # must appear in index.html or the deploy is refused
MIN_BYTES=20000
# ─────────────────────────────────────────────────────────────────────────────

export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/tanglefoot-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
echo "=== bootstrap starting $(date -Is) ==="

timedatectl set-timezone America/Los_Angeles || true

apt-get update -y
apt-get install -y nginx git curl unattended-upgrades

# Unattended security updates.
dpkg-reconfigure -f noninteractive unattended-upgrades || true

install -d -m 755 /srv/tanglefoot /var/www/tanglefoot

# Shallow clone; this box only ever reads from the repo.
if [ ! -d /srv/tanglefoot/repo/.git ]; then
  git clone --depth 1 "$REPO_URL" /srv/tanglefoot/repo
fi

# ── deploy script ────────────────────────────────────────────────────────────
cat > /usr/local/bin/tanglefoot-deploy <<DEPLOY
#!/bin/bash
# Pull the latest page and install it, but only if it looks like a real page.
set -euo pipefail

REPO=/srv/tanglefoot/repo
WEBROOT=/var/www/tanglefoot
SRC="\$REPO/index.html"
DEST="\$WEBROOT/index.html"
MARKER="$MARKER"
MIN_BYTES=$MIN_BYTES

cd "\$REPO"
git remote set-head origin -a >/dev/null 2>&1 || true
git fetch --depth 1 origin HEAD
git reset --hard FETCH_HEAD

if [ ! -f "\$SRC" ]; then
  echo "refused: index.html missing from repo"; exit 1
fi

BYTES=\$(stat -c%s "\$SRC")
if [ "\$BYTES" -lt "\$MIN_BYTES" ]; then
  echo "refused: index.html is \$BYTES bytes, under \$MIN_BYTES"; exit 1
fi
if ! grep -qF "\$MARKER" "\$SRC"; then
  echo "refused: marker '\$MARKER' not found in index.html"; exit 1
fi

if [ -f "\$DEST" ] && cmp -s "\$SRC" "\$DEST"; then
  echo "unchanged (\$BYTES bytes) — nothing to do"; exit 0
fi

[ -f "\$DEST" ] && cp -p "\$DEST" "\$WEBROOT/index.prev.html"
install -m 644 "\$SRC" "\$DEST.tmp"
mv -f "\$DEST.tmp" "\$DEST"          # atomic swap; no half-written page is ever served
echo "published \$BYTES bytes at \$(date -Is)"
DEPLOY
chmod 755 /usr/local/bin/tanglefoot-deploy

# ── systemd timer ────────────────────────────────────────────────────────────
cat > /etc/systemd/system/tanglefoot-deploy.service <<'UNIT'
[Unit]
Description=Pull and publish the tanglefoot.dev page
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tanglefoot-deploy
UNIT

cat > /etc/systemd/system/tanglefoot-deploy.timer <<'UNIT'
[Unit]
Description=Publish tanglefoot.dev each morning

[Timer]
# 20 minutes after the 06:00 page refresh. The box is on Pacific time, so this
# follows daylight saving. Persistent catches up if the box was down.
OnCalendar=*-*-* 06:20:00
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now tanglefoot-deploy.timer

# ── nginx ────────────────────────────────────────────────────────────────────
cat > /etc/nginx/sites-available/tanglefoot <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    root /var/www/tanglefoot;
    index index.html;

    # www -> apex
    if (\$host = www.$DOMAIN) { return 301 https://$DOMAIN\$request_uri; }

    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "public, max-age=300";
    }

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    gzip on;
    gzip_types text/html text/css application/javascript image/svg+xml;
    gzip_min_length 1024;

    access_log /var/log/nginx/tanglefoot.access.log;
    error_log  /var/log/nginx/tanglefoot.error.log;
}
NGINX

sed -i 's/^\s*#\?\s*server_tokens.*/\tserver_tokens off;/' /etc/nginx/nginx.conf || true
ln -sf /etc/nginx/sites-available/tanglefoot /etc/nginx/sites-enabled/tanglefoot
rm -f /etc/nginx/sites-enabled/default

# First publish, so there is something to serve immediately.
/usr/local/bin/tanglefoot-deploy || echo "initial deploy failed - run it by hand later"

nginx -t && systemctl reload nginx
systemctl enable nginx

echo "=== bootstrap finished $(date -Is) ==="
