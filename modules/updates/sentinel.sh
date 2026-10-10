#!/usr/bin/env bash
# LibrePod update sentinel — runs at boot when an update was staged.
# Healthy → commit (label + done). Unhealthy → rollback previous generation.
# Stale flag → clear. No previous generation → failed (frp SSH is the rescue).
set -euo pipefail

STATE_DIR="${LIBREPOD_STATE_DIR:-/var/lib/librepod}"
NODE_NAME="${LIBREPOD_NODE_NAME:-$(hostname)}"
NS="${LIBREPOD_CM_NAMESPACE:-librepod-os}"
KUBECTL="${KUBECTL:-k3s kubectl}"
NIX_ENV_BIN="${NIX_ENV_BIN:-nix-env}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
PROFILE="${LIBREPOD_PROFILE:-/nix/var/nix/profiles/system}"
TIMEOUT="${LIBREPOD_HEALTH_TIMEOUT:-900}"
STABLE="${LIBREPOD_HEALTH_STABLE:-120}"
INTERVAL="${LIBREPOD_POLL_INTERVAL:-15}"

PENDING="$STATE_DIR/update-pending"
[ -f "$PENDING" ] || exit 0   # nothing staged (unit condition also gates this)

FROM="$(jq -r '.from' "$PENDING")"
TO="$(jq -r '.to' "$PENDING")"

# shellcheck disable=SC2086  # KUBECTL may be multiple words ("k3s kubectl")
kctl() { $KUBECTL "$@"; }

report() { # state, detail
  local cv
  cv="$(kctl get node "$NODE_NAME" -o 'jsonpath={.metadata.labels.librepod\.os/version}' 2>/dev/null || true)"
  local now; now="$(date -u +%FT%TZ)"
  local json
  json=$(jq -n \
    --arg cv "${cv:-unknown}" --arg st "$1" --arg ts "$now" --arg d "$2" \
    '{currentVersion:$cv, state:$st, lastTransition:$ts, detail:$d}')
  kctl -n "$NS" patch configmap "$NODE_NAME" --type merge \
    -p "$(jq -n --arg s "$json" '{data:{"status.json":$s}}')" >/dev/null 2>&1 || true
  echo "[librepod-sentinel][$1] $2"
}

healthy() {
  "$SYSTEMCTL" is-active --quiet k3s \
    && [ "$("$SYSTEMCTL" is-active sshd || true)" = "active" ] \
    && [ "$(kctl get node "$NODE_NAME" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

# Stale flag: profile unchanged since staging (power loss mid-flow) — the
# reboot never landed, nothing to verify or roll back.
CURRENT="$(readlink "$PROFILE" || true)"
if [ -n "$CURRENT" ] && [ "$CURRENT" = "$FROM" ]; then
  rm -f "$PENDING"
  report idle "stale sentinel flag cleared (update never landed)"
  exit 0
fi

# ponytail: a node healthy-but-not-yet-stable past the deadline keeps waiting;
# flapping resets the stability clock and rolls back once unhealthy past it.
deadline=$(( $(date +%s) + TIMEOUT ))
stable_deadline=0
while :; do
  if healthy; then
    if [ "$stable_deadline" -eq 0 ]; then
      stable_deadline=$(( $(date +%s) + STABLE ))
    fi
    if [ "$(date +%s)" -ge "$stable_deadline" ]; then
      break   # healthy and stable — commit
    fi
  else
    stable_deadline=0
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # ---- rollback ---------------------------------------------------------
      if [ "$FROM" != "none" ] && [ -e "$FROM/bin/switch-to-configuration" ]; then
        report rolled_back "health check failed — rolling back to $FROM"
        "$NIX_ENV_BIN" -p "$PROFILE" --set "$FROM"
        "$FROM/bin/switch-to-configuration" boot
        rm -f "$PENDING"
        "$SYSTEMCTL" reboot
        exit 0
      else
        rm -f "$PENDING"
        report failed "health check failed and no previous generation — manual rescue via frp SSH"
        exit 1
      fi
    fi
  fi
  sleep "$INTERVAL"
done

# ---- commit -----------------------------------------------------------------
rm -f "$PENDING"
kctl label node "$NODE_NAME" "librepod.os/version=$TO" --overwrite >/dev/null 2>&1 || true
report done "update to $TO verified healthy"
