# LibrePod OS updater — poll consent, validate, repin, apply, stage sentinel.
# Spec: docs/superpowers/specs/2026-10-10-device-layer-os-updates-design.md
# (common.sh is prepended by modules/updates/default.nix.)

NIX_BIN="${NIX_BIN:-nix}"

die() { report failed "$1"; exit 1; }

# Stamp/heal librepod.os/version from the lock: first boot (discovery gate
# for the Marketplace card, design: within 5 min) and self-heal for a label
# dropped at sentinel commit time. Idempotent — runs on every poll.
reconcile_label() {
  local cv labelled
  cv="$(current_version)"
  [ "$cv" != "unknown" ] || return 0
  labelled="$(kctl get node "$NODE_NAME" -o 'jsonpath={.metadata.labels.librepod\.os/version}' 2>/dev/null || true)"
  [ "$labelled" = "$cv" ] \
    || kctl label node "$NODE_NAME" "librepod.os/version=$cv" --overwrite >/dev/null 2>&1 || true
}

# ---- 1. ensure ConfigMap exists (first boot: create + stamp status) --------
if ! kctl -n "$NS" get configmap "$NODE_NAME" >/dev/null 2>&1; then
  kctl create namespace "$NS" >/dev/null 2>&1 || true
  kctl -n "$NS" create configmap "$NODE_NAME" \
    --from-literal=status.json="{}" >/dev/null 2>&1 || true
fi

CURRENT="$(current_version)"
reconcile_label

SPEC_JSON="$(kctl -n "$NS" get configmap "$NODE_NAME" -o 'jsonpath={.data.spec\.json}' 2>/dev/null || true)"

if [ -z "$SPEC_JSON" ] || [ "$SPEC_JSON" = "null" ]; then
  report idle "no spec"; exit 0
fi

DESIRED="$(echo "$SPEC_JSON" | jq -r '.desiredVersion // empty')"
APPLY="$(echo "$SPEC_JSON" | jq -r '.apply // empty')"
UNATTENDED="$(echo "$SPEC_JSON" | jq -r '.policy.unattended // false')"
WINDOW="$(echo "$SPEC_JSON" | jq -r '.policy.window // empty')"

# ---- 2. gate ----------------------------------------------------------------
if [ -z "$DESIRED" ]; then
  report idle "no desiredVersion"; exit 0
fi
# Global constraint: tags only, ever.
if ! [[ "$DESIRED" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  report idle "rejected: desiredVersion '$DESIRED' is not a release tag"; exit 0
fi
if [ "$DESIRED" = "$CURRENT" ]; then
  report idle "up to date"; exit 0
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
    if [ "$lo" -gt "$hi" ]; then   # window crosses midnight (e.g. 22:00-06:00)
      [ "$h" -ge "$lo" ] || [ "$h" -lt "$hi" ]
    else
      [ "$h" -ge "$lo" ] && [ "$h" -lt "$hi" ]
    fi
  }
  if [ "$UNATTENDED" != "true" ] || ! in_window; then
    report idle "waiting: consent or window"; exit 0
  fi
  if [ "$CURRENT" != "unknown" ] \
     && ! [ "$(printf '%s\n%s\n' "$CURRENT" "$DESIRED" | sort -V | tail -1)" = "$DESIRED" ]; then
    report idle "rejected: unattended downgrade to $DESIRED"; exit 0
  fi
fi

# ---- 3. repin ----------------------------------------------------------------
report building "repinning to $DESIRED"
backup_pin   # sentinel restores this on rollback or stale-flag clear
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

# -f: profile symlinks are relative generation links (system-N-link)
PREV="$(readlink -f "$PROFILE" || true)"
"$NIX_ENV_BIN" -p "$PROFILE" --set "$OUT"
"$OUT/bin/switch-to-configuration" boot

# ---- 5. stage sentinel + reboot ------------------------------------------------
jq -nc --arg from "${PREV:-none}" --arg to "$DESIRED" \
  '{from:$from, to:$to, stagedAt:(now|todate)}' > "$STATE_DIR/update-pending"
report verifying "rebooting into $DESIRED; sentinel will verify"
"$SYSTEMCTL" reboot
