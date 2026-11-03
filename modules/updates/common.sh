#!/usr/bin/env bash
# Shared preamble for librepod-updater and librepod-update-sentinel.
# Concatenated ahead of each script by modules/updates/default.nix —
# one place for env defaults and the status.json contract, so the two
# scripts can't drift. All commands are env-overridable for the stub tests.

FLAKE_DIR="${LIBREPOD_FLAKE_DIR:-/etc/nixos}"
STATE_DIR="${LIBREPOD_STATE_DIR:-/var/lib/librepod}"
# /proc, not `hostname`: the service PATH carries no hostname binary.
NODE_NAME="${LIBREPOD_NODE_NAME:-$(cat /proc/sys/kernel/hostname)}"
NS="${LIBREPOD_CM_NAMESPACE:-librepod-os}"
KUBECTL="${KUBECTL:-k3s kubectl}"
NIX_BIN="${NIX_BIN:-nix}"
NIX_ENV_BIN="${NIX_ENV_BIN:-nix-env}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
PROFILE="${LIBREPOD_PROFILE:-/nix/var/nix/profiles/system}"
RELEASE_FILE="${LIBREPOD_RELEASE_FILE:-/run/current-system/etc/librepod-release}"
# Where releases come from: prefix + tag. The E2E suite points this at a
# local git+file repo. BRE-safe prefixes only (+ ? / : are literal).
URI_PREFIX="${LIBREPOD_URI_PREFIX:-github:librepod/os/}"
# What runs now: OLD while the updater stages, NEW on the trial boot.
CURRENT_SYSTEM="${LIBREPOD_CURRENT_SYSTEM:-/run/current-system}"
# The updater repins and builds in this copy of FLAKE_DIR; the sentinel
# copies the pin back only when the update commits.
STAGED="$STATE_DIR/staged"
# The update in flight: {from, to, version, requestId, phase}, where phase
# goes staged → trial → committing.
PENDING="$STATE_DIR/update-pending"

# shellcheck disable=SC2086  # KUBECTL may be multiple words ("k3s kubectl")
kctl() { $KUBECTL "$@"; }

# The booted system's tag (mkDevice writes it), never flake.lock: the lock
# can name a version that failed to build or was rolled back.
current_version() {
  cat "$RELEASE_FILE" 2>/dev/null || echo "unknown"
}

report() { # state, detail — best-effort telemetry; cv from the booted system
  local now; now="$(date -u +%FT%TZ)"
  local json
  json=$(jq -n \
    --arg rid "$(cat "$STATE_DIR/request-id" 2>/dev/null || true)" \
    --arg cv "$(current_version)" --arg st "$1" --arg ts "$now" --arg d "$2" \
    '{observedRequestId:($rid | tonumber? // null), currentVersion:$cv,
      state:$st, lastTransition:$ts, detail:$d}')
  kctl -n "$NS" patch configmap "$NODE_NAME" --type merge \
    -p "$(jq -n --arg s "$json" '{data:{"status.json":$s}}')" >/dev/null 2>&1 || true
  echo "[librepod][$1] $2"
}

# Write-then-rename: the sentinel reads it after a power cut.
write_pending() { echo "$1" > "$PENDING.new" && mv -f "$PENDING.new" "$PENDING"; }
set_phase() { write_pending "$(jq -c --arg p "$1" '.phase = $p' "$PENDING")"; }
