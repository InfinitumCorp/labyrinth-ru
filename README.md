# labyrinth-ru

Labyrinth *LBRNTH™ in Russia, by **Infinitum Corporation®**. This repo holds what is specific to the
Russia deployment: server setup, TLS, backups and checks. The application code stays in
[InfinitumCorp/infinitum-nexus](https://github.com/InfinitumCorp/infinitum-nexus) (`apps/lbrnth-host`,
`packages/lbrnth`), pinned by commit in `scripts/setup.sh`. No secrets are in this repo: they are
generated on the server or piped in.

## What runs where

| | |
|---|---|
| Server | `labyrinth-russia`, Yandex Cloud ru-central1-e, Ubuntu 24.04, 2 vCPU / 4 GB / 20 GB SSD |
| Public name | `https://lbrnth.cumuluscloud.app` (Cloudflare DNS only, not proxied) |
| Service | `lbrnth-host.service` (systemd, user `lbrnth`), `127.0.0.1:8080`, behind nginx |
| Database | Postgres on the same server, database `lbrnth`, loopback only, role `lbrnth_host` |
| Backups | `lbrnth-pgdump.timer` daily 23:40 UTC to `/var/backups/lbrnth` (keeps 7), then the 00:00 UTC disk snapshot |
| Identity | Cumulus ID, live through `https://id.cumuluscloud.app/api/id/labyrinth-directory` |

The product sites (id.cumuluscloud.app, rchtch.app, mail.cumuluscloud.app) relay `POST /api/labyrinth`
here server to server. Each one's `LBRNTH_ENDPOINT` is `https://lbrnth.cumuluscloud.app/api/labyrinth`.
Every org's data is one AES-256-GCM envelope under a per-org key derived from the master key.

## Set up or upgrade

```bash
# once: the CID directory key, piped from Secret Manager, never printed
gcloud secrets versions access latest --secret lbrnth-cid-directory-key --project infinitum-identity \
  | ssh labyrinth-russia 'sudo install -D -m 0600 /dev/stdin /etc/lbrnth/cid-directory-key'
# then (again to upgrade after bumping SHA)
ssh labyrinth-russia 'bash -s' < scripts/setup.sh
bash scripts/check.sh
```

`setup.sh` is safe to re-run. It keeps the database, master key and DB password; to upgrade, bump
`SHA` to a newer infinitum-nexus main commit.

## Operate

- Grant a plan: `sudo -u postgres psql -d lbrnth -c "insert into lbrnth.entitlements (org_id, plan, active, source) values ('<cid org id>', 'standard', true, 'operator')"`
- Logs: `sudo journalctl -u lbrnth-host -n 100`
- Restore: stop `lbrnth-host`, then `sudo -u postgres pg_restore -d lbrnth --clean /var/backups/lbrnth/lbrnth-YYYYMMDD.dump`.
- **Master key**: `/etc/lbrnth/master-key`. Losing it loses every org's data. Keep an offline copy.

## Known limits

- The VM's public IP is dynamic until the static-IP quota increase lands. If the VM is stopped
  and the IP changes, update the DNS record and re-run `setup.sh`.
- Port 22 is open only to the admin IP.
