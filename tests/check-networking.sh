#!/usr/bin/env bash
# Verifies the quadlet-managed services described in NETWORKING-GUIDE.md are
# actually in the state their config declares. Three checks, scoped narrowly
# per issue #6 — this is not a general drift-detector:
#
#   1. Every *.container quadlet's systemd service is active.
#   2. Every Network= line in a *.container quadlet has a matching live
#      attachment in `podman network inspect` (catches the exact bug behind
#      the 2026-09-14 skogai-mcphub / basic-memory 502s).
#   3. Every hostname in endpoints.txt resolves and responds without a
#      502/503 (catches a tunnel with ingress but no live connector).
#
# Run from anywhere: ./tests/check-networking.sh
# Exits non-zero if any check fails.

set -u

QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"
ENDPOINTS_FILE="$(dirname "$0")/endpoints.txt"
fail=0

pass() { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

if [ ! -d "$QUADLET_DIR" ]; then
  echo "Quadlet directory not found: $QUADLET_DIR" >&2
  exit 1
fi

echo "== 1. systemd service state =="
while IFS= read -r -d '' unit_file; do
  service="$(basename "$unit_file" .container).service"
  state="$(systemctl --user is-active "$service" 2>/dev/null || true)"
  if [ "$state" = "active" ]; then
    pass "$service"
  else
    bad "$service (state: ${state:-unknown})"
  fi
done < <(find "$QUADLET_DIR" -name '*.container' -print0)

echo
echo "== 2. declared Network= lines match live attachment =="
resolve_network_name() {
  # $1 = value of a Network= line, e.g. "skogai-tunnel.network" or "mcphub_mcphub-network"
  local ref="$1"
  case "$ref" in
    *.network)
      local net_file
      net_file="$(find "$QUADLET_DIR" -name "$ref" -print -quit)"
      if [ -n "$net_file" ] && grep -q '^NetworkName=' "$net_file"; then
        grep '^NetworkName=' "$net_file" | head -1 | cut -d= -f2-
      else
        basename "$ref" .network
      fi
      ;;
    *)
      echo "$ref"
      ;;
  esac
}

while IFS= read -r -d '' unit_file; do
  container_name="$(grep '^ContainerName=' "$unit_file" | head -1 | cut -d= -f2-)"
  [ -n "$container_name" ] || container_name="$(basename "$unit_file" .container)"

  while IFS= read -r net_line; do
    net_ref="${net_line#Network=}"
    net_name="$(resolve_network_name "$net_ref")"

    members="$(podman network inspect "$net_name" --format \
      '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null)"

    if [ -z "$members" ]; then
      bad "$container_name -> $net_name (network not found or empty)"
    elif echo "$members" | grep -qx "$container_name"; then
      pass "$container_name -> $net_name"
    else
      bad "$container_name -> $net_name (declared but not attached)"
    fi
  done < <(grep '^Network=' "$unit_file")
done < <(find "$QUADLET_DIR" -name '*.container' -print0)

echo
echo "== 3. tunnel-fronted endpoints respond =="
if [ ! -f "$ENDPOINTS_FILE" ]; then
  echo "  (skipped: $ENDPOINTS_FILE not found)"
else
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    case "$url" in \#*) continue ;; esac
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url")"
    case "$code" in
      502|503|000) bad "$url (HTTP $code)" ;;
      *)           pass "$url (HTTP $code)" ;;
    esac
  done < "$ENDPOINTS_FILE"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks passed."
else
  echo "One or more checks failed." >&2
fi
exit "$fail"
