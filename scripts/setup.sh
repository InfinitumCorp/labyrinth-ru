#!/bin/bash
# Labyrinth *LBRNTH host on Yandex Cloud (labyrinth-russia, Ubuntu 24.04): the authoritative
# Labyrinth service, with its Postgres on this server. Re-runnable; run again to upgrade.
#
# Before the first run, install the CID directory key (the same one id.cumuluscloud.app knows by
# its SHA-256) root-only, without printing it, for example from Secret Manager:
#   gcloud secrets versions access latest --secret lbrnth-cid-directory-key --project infinitum-identity \
#     | ssh labyrinth-russia 'sudo install -D -m 0600 /dev/stdin /etc/lbrnth/cid-directory-key'
set -euo pipefail
# infinitum-nexus commit to run (full 40-char SHA from main). Bump to upgrade.
SHA=${NEXUS_SHA:-691909c8674acb4d90b6275dc78ca0f169556a4d}
HOST_NAME=${LBRNTH_HOST:-lbrnth.cumuluscloud.app}
NODE_VERSION=v24.11.0
PNPM_VERSION=10.28.0
log() { echo "[labyrinth] $*"; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y postgresql nginx certbot xz-utils >/dev/null
log "postgres $(psql --version | awk '{print $3}')"

# Node (official build, checksum-verified)
if [ "$(/usr/local/bin/node -v 2>/dev/null || true)" != "$NODE_VERSION" ]; then
  f="node-$NODE_VERSION-linux-x64.tar.xz"
  curl -fsSL -o "$TMP/$f" "https://nodejs.org/dist/$NODE_VERSION/$f"
  curl -fsSL -o "$TMP/SHASUMS256.txt" "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt"
  (cd "$TMP" && grep " $f\$" SHASUMS256.txt | sha256sum -c - >/dev/null)
  sudo tar -xJf "$TMP/$f" -C /usr/local --strip-components=1 --no-same-owner
fi
log "node $(/usr/local/bin/node -v)"

id lbrnth >/dev/null 2>&1 || sudo useradd --system --home-dir /var/lib/lbrnth --shell /usr/sbin/nologin lbrnth
sudo install -d -o lbrnth -g lbrnth -m 0750 /var/lib/lbrnth
sudo install -d -m 0755 /opt/lbrnth/releases /var/www/acme
sudo install -d -m 0700 /etc/lbrnth

# Code: InfinitumCorp/infinitum-nexus at a pinned commit, only what the host needs.
REL=/opt/lbrnth/releases/$SHA
if ! sudo test -f "$REL/apps/lbrnth-host/src/main.ts"; then
  sudo rm -rf "$REL.tmp" && sudo mkdir -p "$REL.tmp"
  # GitHub is often unreachable from Russia: use a tarball uploaded to /tmp when present
  # (see README), else download it.
  TARBALL=/tmp/infinitum-nexus-$SHA.tar.gz
  { if [ -s "$TARBALL" ]; then cat "$TARBALL"; else curl -fsSL -m 120 "https://codeload.github.com/InfinitumCorp/infinitum-nexus/tar.gz/$SHA"; fi; } \
    | sudo tar -xz --strip-components=1 -C "$REL.tmp" --no-same-owner \
        --wildcards '*/package.json' '*/pnpm-lock.yaml' '*/pnpm-workspace.yaml' '*/packages/*' '*/apps/lbrnth-host/*' '*/supabase/migrations/*lbrnth*'
  (cd "$REL.tmp" && sudo env PATH=/usr/local/bin:$PATH COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    /usr/local/bin/corepack "pnpm@$PNPM_VERSION" install --prod --filter "@infinitum/lbrnth-host..." --frozen-lockfile --ignore-scripts --reporter=silent)
  (cd "$REL.tmp" && sudo /usr/local/bin/node --experimental-strip-types --input-type=module \
    -e "await import('./apps/lbrnth-host/src/server.ts'); await import('./apps/lbrnth-host/src/pg.ts')")
  sudo chown -R root:root "$REL.tmp"; sudo chmod -R a+rX "$REL.tmp"
  sudo mv "$REL.tmp" "$REL"
fi
sudo ln -sfn "$REL" /opt/lbrnth/current
log "code $SHA"

# Database: local Postgres, loopback only. Roles anon/authenticated exist only so the shared
# Supabase migrations apply unchanged; they cannot log in.
sudo -u postgres psql -qtA -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
SQL
if ! sudo -u postgres psql -qtA -c "select 1 from pg_database where datname = 'lbrnth'" | grep -q 1; then
  sudo -u postgres createdb lbrnth
fi
if ! sudo test -f /etc/lbrnth/db-password; then
  openssl rand -hex 32 | sudo install -m 0600 /dev/stdin /etc/lbrnth/db-password
fi
DBPW=$(sudo cat /etc/lbrnth/db-password)
sudo -u postgres psql -qtA -v ON_ERROR_STOP=1 -v pw="$DBPW" <<'SQL' >/dev/null
select format('create role lbrnth_host login noinherit password %L', :'pw') where not exists (select 1 from pg_roles where rolname = 'lbrnth_host') \gexec
select format('alter role lbrnth_host password %L', :'pw') \gexec
SQL
if ! sudo -u postgres psql -d lbrnth -qtA -c "select 1 from pg_namespace where nspname = 'lbrnth'" | grep -q 1; then
  sudo -u postgres psql -d lbrnth -q -v ON_ERROR_STOP=1 -f "$REL/supabase/migrations/20261111_lbrnth_store.sql" >/dev/null
fi
sudo -u postgres psql -d lbrnth -q -v ON_ERROR_STOP=1 -f "$REL/supabase/migrations/20261111_lbrnth_host_role_grants.sql" >/dev/null
log "database lbrnth: $(sudo -u postgres psql -d lbrnth -qtA -c "select count(*) from lbrnth.org_snapshots") org snapshots"

# Secrets, root-only. The master key is generated here once and never leaves the server
# except in the encrypted backup below; keep an offline copy.
if ! sudo test -f /etc/lbrnth/master-key; then
  openssl rand -base64 32 | tr -d '\n' | sudo install -m 0600 /dev/stdin /etc/lbrnth/master-key
fi
if ! sudo test -s /etc/lbrnth/cid-directory-key; then
  echo "[labyrinth] /etc/lbrnth/cid-directory-key is missing; install it first (see the top of this script)" >&2
  exit 1
fi
{
  echo "# Labyrinth host. Root-only (600). Never commit or print."
  echo "LBRNTH_MASTER_KEY=$(sudo cat /etc/lbrnth/master-key)"
  echo "DATABASE_URL=postgresql://lbrnth_host:$DBPW@127.0.0.1:5432/lbrnth"
  echo "CID_DIRECTORY_KEY=$(sudo cat /etc/lbrnth/cid-directory-key)"
  if sudo test -f /etc/lbrnth/entitled-orgs; then echo "LBRNTH_ENTITLED_ORGS=$(sudo cat /etc/lbrnth/entitled-orgs)"; fi
} | sudo install -m 0600 /dev/stdin /etc/lbrnth/env
unset DBPW

sudo tee /etc/systemd/system/lbrnth-host.service >/dev/null <<'EOF'
[Unit]
Description=Labyrinth host (Russia)
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
User=lbrnth
Group=lbrnth
WorkingDirectory=/opt/lbrnth/current
EnvironmentFile=/etc/lbrnth/env
Environment=NODE_ENV=production PORT=8080
ExecStart=/usr/local/bin/node --experimental-strip-types apps/lbrnth-host/src/main.ts
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryMax=1G

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable lbrnth-host >/dev/null 2>&1
sudo systemctl restart lbrnth-host
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1 && break; sleep 1; done
log "health: $(curl -s http://127.0.0.1:8080/health)"
log "anonymous API: $(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8080/api/labyrinth -H 'content-type: application/json' -H 'x-labyrinth: 1' -d '{}')"

# Port 8080 stays local: the security group only opens 22/80/443, and this drops it on the host too.
if ! sudo iptables -C INPUT -p tcp --dport 8080 ! -i lo -j DROP 2>/dev/null; then
  sudo iptables -I INPUT -p tcp --dport 8080 ! -i lo -j DROP
fi
sudo ip6tables -C INPUT -p tcp --dport 8080 ! -i lo -j DROP 2>/dev/null || sudo ip6tables -I INPUT -p tcp --dport 8080 ! -i lo -j DROP
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y iptables-persistent >/dev/null 2>&1 || true
sudo sh -c 'iptables-save > /etc/iptables/rules.v4; ip6tables-save > /etc/iptables/rules.v6' 2>/dev/null || true

# Backups: a clean dump before the daily 00:00 UTC disk snapshot (daily-data-servers).
sudo install -d -m 0700 /var/backups/lbrnth
sudo tee /usr/local/sbin/lbrnth-pgdump >/dev/null <<'EOF'
#!/bin/sh
set -eu
out=/var/backups/lbrnth/lbrnth-$(date -u +%Y%m%d).dump
sudo -u postgres pg_dump -Fc lbrnth > "$out.tmp" && chmod 600 "$out.tmp" && mv "$out.tmp" "$out"
ls -1t /var/backups/lbrnth/lbrnth-*.dump | tail -n +8 | xargs -r rm -f
EOF
sudo chmod 0750 /usr/local/sbin/lbrnth-pgdump
sudo tee /etc/systemd/system/lbrnth-pgdump.service >/dev/null <<'EOF'
[Unit]
Description=Labyrinth database dump
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lbrnth-pgdump
EOF
sudo tee /etc/systemd/system/lbrnth-pgdump.timer >/dev/null <<'EOF'
[Unit]
Description=Daily Labyrinth database dump (before the 00:00 UTC snapshot)
[Timer]
OnCalendar=*-*-* 23:40:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now lbrnth-pgdump.timer >/dev/null 2>&1

# HTTP: ACME challenges only, everything else to HTTPS
sudo tee /etc/nginx/sites-available/default >/dev/null <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    server_tokens off;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://$host$request_uri; }
}
EOF
sudo nginx -t -q && sudo systemctl reload nginx

# HTTPS once the name points here. Dynamic IPs change, so compare with this VM's public IP.
MYIP=$(curl -fsS -m 10 -H 'Metadata-Flavor: Google' 'http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' 2>/dev/null || curl -fsS -m 10 https://ifconfig.me)
resolves() {
  for _ in 1 2 3 4 5; do
    [ "$(getent ahostsv4 "$1" | awk '{print $1; exit}')" = "$MYIP" ] && return 0
    sleep 3
  done
  return 1
}
if ! resolves "$HOST_NAME"; then
  log "DNS for $HOST_NAME does not point at $MYIP yet; HTTPS skipped"
  exit 0
fi
if ! sudo test -f "/etc/letsencrypt/live/$HOST_NAME/fullchain.pem"; then
  sudo certbot certonly --webroot -w /var/www/acme -d "$HOST_NAME" --non-interactive --agree-tos --register-unsafely-without-email --quiet
fi
sudo tee /etc/nginx/sites-available/labyrinth >/dev/null <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $HOST_NAME;
    server_tokens off;
    ssl_certificate     /etc/letsencrypt/live/$HOST_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$HOST_NAME/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=63072000" always;
    client_max_body_size 2m;
    # Only the API and the health check exist; the host itself answers 404 to anything else.
    location = /api/labyrinth { limit_except POST { deny all; } proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$remote_addr; proxy_read_timeout 30s; }
    location = /health { proxy_pass http://127.0.0.1:8080; }
    location / { return 404; }
}
EOF
sudo ln -sf /etc/nginx/sites-available/labyrinth /etc/nginx/sites-enabled/labyrinth
sudo nginx -t -q && sudo systemctl reload nginx
echo -e '#!/bin/sh\nsystemctl reload nginx' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
log "cert: $(sudo openssl x509 -in "/etc/letsencrypt/live/$HOST_NAME/fullchain.pem" -noout -enddate)"
log "https health: $(curl -s -m 10 "https://$HOST_NAME/health")"
