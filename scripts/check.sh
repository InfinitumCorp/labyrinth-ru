#!/bin/bash
# Checks the live Labyrinth host in Russia from wherever this runs. Exit 1 on any failure.
set -uo pipefail
H=${LBRNTH_HOST:-lbrnth.cumuluscloud.app}
fail=0
expect() { # label want got
  if [ "$2" = "$3" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: want $2, got $3"; fail=1; fi
}
code() { curl -s -m 20 -o /dev/null -w '%{http_code}' "$@"; }
expect "health" 200 "$(code "https://$H/health")"
expect "health says configured" '{"ok":true,"configured":true}' "$(curl -s -m 20 "https://$H/health")"
expect "API without a bearer" 401 "$(code -X POST "https://$H/api/labyrinth" -H 'content-type: application/json' -H 'x-labyrinth: 1' -d '{"product":"spectre","action":"session"}')"
expect "API with a made-up bearer" 401 "$(code -X POST "https://$H/api/labyrinth" -H 'authorization: Bearer lbrnth_not-a-real-credential' -H 'content-type: application/json' -H 'x-labyrinth: 1' -d '{"product":"spectre","action":"session"}')"
expect "API GET" 403 "$(code "https://$H/api/labyrinth")"
expect "other paths" 404 "$(code "https://$H/")"
expect "http redirects" 301 "$(code "http://$H/health")"
exit $fail
