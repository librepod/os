# LibrePod OS updater — poll consent, validate, repin, apply, stage sentinel.
# Spec: docs/superpowers/specs/2026-10-10-device-layer-os-updates-design.md
# (common.sh is prepended by modules/updates/default.nix.)

BOOTCTL="${BOOTCTL:-bootctl}"
# update-pending from this same boot means its updater died before the reboot.
BOOT_ID="${LIBREPOD_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id)}"

# The staged copy goes too: one left behind means a build that never finished.
die() { report failed "$1"; rm -rf "$STAGED"; exit 1; }

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
# First: a verdict below needs somewhere to go, also after the owner deleted it.
if ! kctl -n "$NS" get configmap "$NODE_NAME" >/dev/null 2>&1; then
  kctl create namespace "$NS" >/dev/null 2>&1 || true
  kctl -n "$NS" create configmap "$NODE_NAME" \
    --from-literal=status.json="{}" >/dev/null 2>&1 || true
fi

# An unreadable update-pending: nothing can finish its update. Moved aside,
# then a reboot to the boot default, as a power cut would: this may be a
# trial boot, with OLD the default.
if [ -e "$PENDING" ] && ! pending_ok; then
  mv -f "$PENDING" "$PENDING.bad"
  rm -rf "$STAGED"
  report failed "the record of the update in flight was unreadable; moved to $PENDING.bad"
  "$SYSTEMCTL" reboot
  exit 0
fi

# The sentinel died between its verdict and clearing up (killed, OOM), or its
# send failed: finish for it. The two never run at once (After= in default.nix).
if [ -e "$PENDING" ] && jq -e '.verdict' "$PENDING" >/dev/null; then
  send_verdict
fi

# An update is in flight (staged, or the sentinel is verifying it): stand
# down, so a poll neither overwrites its status nor stages a second one on top.
if [ -e "$PENDING" ]; then
  # Staged on this boot, and no updater runs alongside another: the one that
  # staged it died before its reboot. Reboot, as a power cut would.
  if [ "$(jq -r '.bootId' "$PENDING")" = "$BOOT_ID" ]; then
    "$SYSTEMCTL" reboot
  # The sentinel ends every update. It failed without a verdict (stopped at
  # its TimeoutStartSec, crashed, a full disk):
  elif [ "$("$SYSTEMCTL" is-active librepod-update-sentinel || true)" = failed ]; then
    if [ "$(readlink -f "$CURRENT_SYSTEM")" = "$(jq -r '.to' "$PENDING")" ] \
       && [ "$(jq -r '.phase' "$PENDING")" != committing ]; then
      # on the trial, end it here: OLD is still the default.
      write_pending "$(jq -c '.reason = "sentinel-failed"' "$PENDING")"
      "$SYSTEMCTL" reboot
    else
      # elsewhere its steps are safe to repeat: run it again, once a poll.
      "$SYSTEMCTL" start --no-block librepod-update-sentinel
    fi
  fi
  echo "[librepod] update in flight; skipping this poll"; exit 0
fi

# A build that never finished (TimeoutStartSec, a reboot, a power cut) left
# its staged copy; without this its request would show `building` for good.
if [ -d "$STAGED" ]; then
  report failed "update interrupted before its trial boot; nothing changed"
  rm -rf "$STAGED"
fi

CURRENT="$(current_version)"
reconcile_label

SPEC_JSON="$(kctl -n "$NS" get configmap "$NODE_NAME" -o 'jsonpath={.data.spec\.json}' 2>/dev/null || true)"

# Each request is handled once (docs/updates.md). A poll with nothing new
# stays silent, so it never overwrites a final status, and a re-created
# ConfigMap carrying an old requestId does nothing.
REQ="$(echo "$SPEC_JSON" | jq -r '.requestId // empty' 2>/dev/null || true)"
LAST="$(cat "$STATE_DIR/request-id" 2>/dev/null || true)"
handled() { write_state "$STATE_DIR/request-id" "$REQ"; }
finish() { handled; report "$1" "$2"; exit 0; } # state, detail
if ! [[ "$REQ" =~ ^[0-9]{1,15}$ ]]; then
  exit 0
fi
# A request-id it can't read (fs damage; write_state is atomic) fails closed:
# this request counts as handled and does nothing, in case it was already.
if ! [[ "${LAST:-0}" =~ ^[0-9]{1,15}$ ]]; then
  finish rejected "$STATE_DIR/request-id was unreadable; request $REQ may have been handled already, so ask again"
fi
if [ "$REQ" -le "${LAST:-0}" ]; then
  exit 0
fi

DESIRED="$(echo "$SPEC_JSON" | jq -r '.desiredVersion // empty')"
APPLY="$(echo "$SPEC_JSON" | jq -r '.apply // empty')"
UNATTENDED="$(echo "$SPEC_JSON" | jq -r '.policy.unattended // false')"
WINDOW="$(echo "$SPEC_JSON" | jq -r '.policy.window // empty')"

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
# Upgrades only, also when the owner asks: an older release can pin an older
# k3s, which upstream does not support on a datastore a newer one wrote.
if [ "$CURRENT" != "unknown" ] \
   && ! [ "$(printf '%s\n%s\n' "$CURRENT" "$DESIRED" | sort -V | tail -1)" = "$DESIRED" ]; then
  finish rejected "$DESIRED is older than $CURRENT; only upgrades are allowed"
fi

if [ "$APPLY" != "now" ]; then
  # unattended: policy must opt in, now within window, no failed versions
  # (the owner's own request may retry one)
  [ "$UNATTENDED" = "true" ] || exit 0   # not handled yet: waits for consent
  # A window this can't read would hold the request back, silently, for good.
  hhmm='([01][0-9]|2[0-3]):[0-5][0-9]'
  [[ "$WINDOW" =~ ^$hhmm-$hhmm$ ]] && [ "${WINDOW%-*}" != "${WINDOW#*-}" ] \
    || finish rejected "policy.window '$WINDOW' is not a HH:MM-HH:MM window"
  in_window() {
    local now lo hi
    now="$(date +%H%M)"; lo="${WINDOW%-*}"; hi="${WINDOW#*-}"
    lo="${lo/:/}"; hi="${hi/:/}"   # 22:30 → 2230; [ ] reads 0600 as decimal
    if [ "$lo" -gt "$hi" ]; then   # window crosses midnight (e.g. 22:00-06:00)
      [ "$now" -ge "$lo" ] || [ "$now" -lt "$hi" ]
    else
      [ "$now" -ge "$lo" ] && [ "$now" -lt "$hi" ]
    fi
  }
  in_window || exit 0   # not handled yet: waits for the window
  if grep -qxF "$DESIRED" "$STATE_DIR/failed-versions" 2>/dev/null; then
    finish rejected "$DESIRED failed its trial on this device; the owner can ask again"
  fi
fi

# ---- 3. repin, in the staged copy: FLAKE_DIR changes only at commit ---------
# The staged copy comes before `handled`: a kill or a cut after it leaves the
# copy, and the next poll reports the request failed instead of losing it.
rm -rf "$STAGED"
mkdir "$STAGED"
handled   # from here on a failed build or rollback never retries it by itself
report building "repinning to $DESIRED"
# Contents, not the dir: were FLAKE_DIR a symlink, sed would edit the original.
cp -a "$FLAKE_DIR/." "$STAGED/" || die "could not copy $FLAKE_DIR"
{ mkdir -p "$PIN_BEFORE" && cp "$STAGED/flake.nix" "$STAGED/flake.lock" "$PIN_BEFORE/"; } \
  || die "could not copy $FLAKE_DIR"
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
# The out-link is NEW's GC root until start_trial gives it a profile generation;
# it goes with the staged copy.
OUT="$("$NIX_BIN" build --out-link "$STAGED/result" --print-out-paths \
  "$STAGED#nixosConfigurations.$NODE_NAME.config.system.build.toplevel")" \
  || die "build failed for $DESIRED"

[ -e "$OUT/nixos-version" ] || die "build output missing nixos-version — refusing to activate"

# ---- 5. trial boot: the sentinel commits NEW or the next boot is OLD again ----
FROM="$(readlink -f "$CURRENT_SYSTEM")"
write_pending "$(jq -nc --arg from "$FROM" --arg to "$OUT" --arg v "$DESIRED" --argjson rid "$REQ" \
  --arg boot "$BOOT_ID" \
  '{from:$from, to:$to, version:$v, requestId:$rid, phase:"staged", stagedAt:(now|todate), bootId:$boot}')"
# The profile may be left on NEW (the second --set failed): FROM again, which
# is a no-op when it already names FROM.
start_trial "$FROM" "$OUT" || {
  "$NIX_ENV_BIN" -p "$PROFILE" --set "$FROM" || true
  rm -f "$PENDING"; die "could not set up the trial boot of $DESIRED"
}
set_phase trial
report verifying "rebooting into $DESIRED once; it stays only if healthy"
"$SYSTEMCTL" reboot
