# LibrePod OS updater — poll consent, validate, repin, apply, stage sentinel.
# Spec: docs/superpowers/specs/2026-10-10-device-layer-os-updates-design.md
# (common.sh is prepended by modules/updates/default.nix.)

BOOTCTL="${BOOTCTL:-bootctl}"

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

# An update is in flight (staged, or the sentinel is verifying it): stand
# down, so a poll neither overwrites its status nor stages a second one on top.
if [ -e "$PENDING" ]; then
  echo "[librepod] update in flight; skipping this poll"; exit 0
fi

# ---- 1. ensure ConfigMap exists (first boot: create + stamp status) --------
if ! kctl -n "$NS" get configmap "$NODE_NAME" >/dev/null 2>&1; then
  kctl create namespace "$NS" >/dev/null 2>&1 || true
  kctl -n "$NS" create configmap "$NODE_NAME" \
    --from-literal=status.json="{}" >/dev/null 2>&1 || true
fi

CURRENT="$(current_version)"
reconcile_label

SPEC_JSON="$(kctl -n "$NS" get configmap "$NODE_NAME" -o 'jsonpath={.data.spec\.json}' 2>/dev/null || true)"

# Each request is handled once (docs/updates.md). A poll with nothing new
# stays silent, so it never overwrites a final status, and a re-created
# ConfigMap carrying an old requestId does nothing.
REQ="$(echo "$SPEC_JSON" | jq -r '.requestId // empty' 2>/dev/null || true)"
LAST="$(cat "$STATE_DIR/request-id" 2>/dev/null || true)"
if ! [[ "$REQ" =~ ^[0-9]{1,15}$ ]] || [ "$REQ" -le "${LAST:-0}" ]; then
  exit 0
fi

DESIRED="$(echo "$SPEC_JSON" | jq -r '.desiredVersion // empty')"
APPLY="$(echo "$SPEC_JSON" | jq -r '.apply // empty')"
UNATTENDED="$(echo "$SPEC_JSON" | jq -r '.policy.unattended // false')"
WINDOW="$(echo "$SPEC_JSON" | jq -r '.policy.window // empty')"

handled() { echo "$REQ" > "$STATE_DIR/request-id"; }
finish() { handled; report "$1" "$2"; exit 0; } # state, detail

# ---- 2. gate ----------------------------------------------------------------
if [ -z "$DESIRED" ]; then
  finish rejected "no desiredVersion"
fi
# Global constraint: tags only, ever.
if ! [[ "$DESIRED" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  finish rejected "desiredVersion '$DESIRED' is not a release tag"
fi
if [ "$DESIRED" = "$CURRENT" ]; then
  finish "done" "already on $DESIRED"
fi

if [ "$APPLY" = "now" ]; then
  : # the owner asked: any existing tag, downgrades and failed versions too (UI warns)
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
    exit 0   # not handled yet: waits for consent or the window
  fi
  if [ "$CURRENT" != "unknown" ] \
     && ! [ "$(printf '%s\n%s\n' "$CURRENT" "$DESIRED" | sort -V | tail -1)" = "$DESIRED" ]; then
    finish rejected "unattended downgrade to $DESIRED"
  fi
  if grep -qxF "$DESIRED" "$STATE_DIR/failed-versions" 2>/dev/null; then
    finish rejected "$DESIRED failed its trial on this device; the owner can ask again"
  fi
fi

# ---- 3. repin, in the staged copy: FLAKE_DIR changes only at commit ---------
handled   # from here on a failed build or rollback never retries it by itself
report building "repinning to $DESIRED"
rm -rf "$STAGED"
# Contents, not the dir: were FLAKE_DIR a symlink, sed would edit the original.
{ mkdir "$STAGED" && cp -a "$FLAKE_DIR/." "$STAGED/"; } || die "could not copy $FLAKE_DIR"
if ! grep -q "inputs\\.librepod\\.url = \"${URI_PREFIX}v[0-9.]*\"" "$STAGED/flake.nix"; then
  die "pin line not found in $FLAKE_DIR/flake.nix — refusing to edit unknown file"
fi
sed -i "s|${URI_PREFIX}v[0-9.]*|${URI_PREFIX}${DESIRED}|" "$STAGED/flake.nix"
"$NIX_BIN" flake update librepod --flake "$STAGED" >/dev/null \
  || die "nix flake update failed for $DESIRED"

# The next boot, and only that one, runs NEW: NEW gets a boot entry and OLD
# stays the default. Boot counting (GitHub #17) replaces only this.
# Chained with &&: set -e does not apply inside a function called with ||.
start_trial() { # old toplevel, new toplevel
  local entry
  # --set OLD, not --rollback: after an earlier trial, rollback would land on
  # that trial's generation.
  "$NIX_ENV_BIN" -p "$PROFILE" --set "$2" \
    && "$NIX_ENV_BIN" -p "$PROFILE" --set "$1" \
    && "$1/bin/switch-to-configuration" boot \
    && entry="$("$BOOTCTL" list --json=short | jq -r --arg new "$2" \
      'first(.[] | select(tostring | contains($new)) | .id) // empty')" \
    && [ -n "$entry" ] \
    && "$BOOTCTL" set-oneshot "$entry"
}

# ---- 4. build (no live switch) -------------------------------------------------
OUT="$("$NIX_BIN" build --no-link --print-out-paths \
  "$STAGED#nixosConfigurations.$NODE_NAME.config.system.build.toplevel" 2>/dev/null)" \
  || die "build failed for $DESIRED"

[ -e "$OUT/nixos-version" ] || die "build output missing nixos-version — refusing to activate"

# ---- 5. trial boot: the sentinel commits NEW or the next boot is OLD again ----
FROM="$(readlink -f "$CURRENT_SYSTEM")"
write_pending "$(jq -nc --arg from "$FROM" --arg to "$OUT" --arg v "$DESIRED" --argjson rid "$REQ" \
  '{from:$from, to:$to, version:$v, requestId:$rid, phase:"staged", stagedAt:(now|todate)}')"
start_trial "$FROM" "$OUT" || { rm -f "$PENDING"; die "could not set up the trial boot of $DESIRED"; }
set_phase trial
report verifying "rebooting into $DESIRED once; it stays only if healthy"
"$SYSTEMCTL" reboot
