#!/usr/bin/env bash
# LibrePod OS updater — poll consent, validate, repin, apply, stage sentinel.
# Spec: docs/superpowers/specs/2026-10-10-device-layer-os-updates-design.md
# All state-changing commands are env-overridable for the stub test.
set -euo pipefail

FLAKE_DIR="${LIBREPOD_FLAKE_DIR:-/etc/nixos}"
STATE_DIR="${LIBREPOD_STATE_DIR:-/var/lib/librepod}"
NODE_NAME="${LIBREPOD_NODE_NAME:-$(hostname)}"
NS="${LIBREPOD_CM_NAMESPACE:-librepod-os}"
KUBECTL="${KUBECTL:-k3s kubectl}"
NIX_BIN="${NIX_BIN:-nix}"
NIX_ENV_BIN="${NIX_ENV_BIN:-nix-env}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
PROFILE="/nix/var/nix/profiles/system"

# shellcheck disable=SC2086  # KUBECTL may be multiple words ("k3s kubectl")
kctl() { $KUBECTL "$@"; }

current_version() {
  jq -r '.nodes.librepod.original.ref // "unknown"' "$FLAKE_DIR/flake.lock" 2>/dev/null || echo "unknown"
}

report() { # state, detail, currentVersion
  local now; now="$(date -u +%FT%TZ)"
  local json
  json=$(jq -n \
    --arg cv "$3" --arg st "$1" --arg ts "$now" --arg d "$2" \
    '{currentVersion:$cv, state:$st, lastTransition:$ts, detail:$d}')
  kctl -n "$NS" patch configmap "$NODE_NAME" --type merge \
    -p "$(jq -n --arg s "$json" '{data:{"status.json":$s}}')" >/dev/null 2>&1 || true
  echo "[librepod-updater][$1] $2"
}

die() { report failed "$1" "$(current_version)"; exit 1; }

# ---- 1. ensure ConfigMap exists (first boot: create + stamp status) --------
if ! kctl -n "$NS" get configmap "$NODE_NAME" >/dev/null 2>&1; then
  kctl create namespace "$NS" >/dev/null 2>&1 || true
  kctl -n "$NS" create configmap "$NODE_NAME" \
    --from-literal=status.json="{}" >/dev/null 2>&1 || true
fi

CURRENT="$(current_version)"
SPEC_JSON="$(kctl -n "$NS" get configmap "$NODE_NAME" -o 'jsonpath={.data.spec\.json}' 2>/dev/null || true)"

if [ -z "$SPEC_JSON" ] || [ "$SPEC_JSON" = "null" ]; then
  report idle "no spec" "$CURRENT"
  exit 0
fi

DESIRED="$(echo "$SPEC_JSON" | jq -r '.desiredVersion // empty')"
APPLY="$(echo "$SPEC_JSON" | jq -r '.apply // empty')"
UNATTENDED="$(echo "$SPEC_JSON" | jq -r '.policy.unattended // false')"
WINDOW="$(echo "$SPEC_JSON" | jq -r '.policy.window // empty')"

# ---- 2. gate ----------------------------------------------------------------
if [ -z "$DESIRED" ]; then
  report idle "no desiredVersion" "$CURRENT"; exit 0
fi
# Global constraint: tags only, ever.
if ! [[ "$DESIRED" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  report idle "rejected: desiredVersion '$DESIRED' is not a release tag" "$CURRENT"; exit 0
fi
if [ "$DESIRED" = "$CURRENT" ]; then
  report idle "up to date" "$CURRENT"; exit 0
fi

if [ "$APPLY" = "now" ]; then
  : # manual consent: any existing tag, downgrades allowed (UI warns)
else
  # unattended: policy must opt in, now within window, upgrades only
  in_window() {
    [ -n "$WINDOW" ] || return 1
    local h; h="$(date +%H)"
    local lo hi
    lo="${WINDOW%%-*}"; hi="${WINDOW##*-}"
    lo="${lo%%:*}"; hi="${hi%%:*}"
    [ "$h" -ge "$lo" ] && [ "$h" -lt "$hi" ]
  }
  if [ "$UNATTENDED" != "true" ] || ! in_window; then
    report idle "waiting: consent or window" "$CURRENT"; exit 0
  fi
  if [ "$CURRENT" != "unknown" ] \
     && ! [ "$(printf '%s\n%s\n' "$CURRENT" "$DESIRED" | sort -V | tail -1)" = "$DESIRED" ]; then
    report idle "rejected: unattended downgrade to $DESIRED" "$CURRENT"; exit 0
  fi
fi

# ---- 3. repin ----------------------------------------------------------------
report building "repinning to $DESIRED" "$CURRENT"
if ! grep -q 'inputs\.librepod\.url = "github:librepod/os/v[0-9.]*"' "$FLAKE_DIR/flake.nix"; then
  die "pin line not found in $FLAKE_DIR/flake.nix — refusing to edit unknown file"
fi
sed -i "s|github:librepod/os/v[0-9.]*|github:librepod/os/$DESIRED|" "$FLAKE_DIR/flake.nix"
"$NIX_BIN" flake update librepod --flake "$FLAKE_DIR" >/dev/null \
  || die "nix flake update failed for $DESIRED"

# ---- 4. apply (clan activation sequence; no live switch in v1) ---------------
OUT="$("$NIX_BIN" build --no-link --print-out-paths \
  "$FLAKE_DIR#nixosConfigurations.$NODE_NAME.config.system.build.toplevel" 2>/dev/null)" \
  || die "build failed for $DESIRED"

[ -e "$OUT/nixos-version" ] || die "build output missing nixos-version — refusing to activate"

PREV="$(readlink "$PROFILE" || true)"
"$NIX_ENV_BIN" -p "$PROFILE" --set "$OUT"
"$OUT/bin/switch-to-configuration" boot

# ---- 5. stage sentinel + reboot ------------------------------------------------
mkdir -p "$STATE_DIR"
jq -nc --arg from "${PREV:-none}" --arg to "$DESIRED" \
  '{from:$from, to:$to, stagedAt:(now|todate)}' > "$STATE_DIR/update-pending"
report verifying "rebooting into $DESIRED; sentinel will verify" "$DESIRED"
"$SYSTEMCTL" reboot
