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
NIX_ENV_BIN="${NIX_ENV_BIN:-nix-env}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
PROFILE="${LIBREPOD_PROFILE:-/nix/var/nix/profiles/system}"

# shellcheck disable=SC2086  # KUBECTL may be multiple words ("k3s kubectl")
kctl() { $KUBECTL "$@"; }

# flake.lock is the single source of truth for the running version.
current_version() {
  jq -r '.nodes.librepod.original.ref // "unknown"' "$FLAKE_DIR/flake.lock" 2>/dev/null || echo "unknown"
}

report() { # state, detail — best-effort telemetry; cv always from the lock
  local now; now="$(date -u +%FT%TZ)"
  local json
  json=$(jq -n \
    --arg cv "$(current_version)" --arg st "$1" --arg ts "$now" --arg d "$2" \
    '{currentVersion:$cv, state:$st, lastTransition:$ts, detail:$d}')
  kctl -n "$NS" patch configmap "$NODE_NAME" --type merge \
    -p "$(jq -n --arg s "$json" '{data:{"status.json":$s}}')" >/dev/null 2>&1 || true
  echo "[librepod][$1] $2"
}

# Pin backup/restore: the updater snapshots the flake before repinning; the
# sentinel restores it on rollback — the lock must never claim a version the
# device isn't running (it would mask DESIRED==CURRENT as "up to date").
backup_pin() {
  mkdir -p "$STATE_DIR"
  cp "$FLAKE_DIR/flake.nix" "$STATE_DIR/flake.nix.bak"
  cp "$FLAKE_DIR/flake.lock" "$STATE_DIR/flake.lock.bak"
}

restore_pin() { # best-effort; the profile switch is the critical action
  local f
  for f in flake.nix flake.lock; do
    if [ -f "$STATE_DIR/$f.bak" ]; then mv "$STATE_DIR/$f.bak" "$FLAKE_DIR/$f" || true; fi
  done
}
