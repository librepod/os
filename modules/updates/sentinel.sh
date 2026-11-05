# LibrePod update sentinel — runs at boot while an update is in flight.
# On the trial boot (NEW): healthy → commit; unhealthy → reboot, and the
# used-up one-shot brings back OLD. Back on OLD: record how the update ended.
# (common.sh is prepended by modules/updates/default.nix.)

TIMEOUT="${LIBREPOD_HEALTH_TIMEOUT:-900}"
STABLE="${LIBREPOD_HEALTH_STABLE:-120}"
INTERVAL="${LIBREPOD_POLL_INTERVAL:-15}"
# Well inside the unit's 25 min: a fetch that hangs fails like one refused.
FETCH_TIMEOUT="${LIBREPOD_FETCH_TIMEOUT:-120}"

pending_ok || exit 0 # none, or unreadable: the updater moves that aside

# Decided, then killed or cut before clearing up: only the sending is left.
if jq -e '.verdict' "$PENDING" >/dev/null; then
  send_verdict
  exit 0
fi

FROM="$(jq -r '.from // empty' "$PENDING")"
TO="$(jq -r '.to // empty' "$PENDING")"
VERSION="$(jq -r '.version // empty' "$PENDING")"
PHASE="$(jq -r '.phase // empty' "$PENDING")"
BOOTED="$(readlink -f "$CURRENT_SYSTEM")"

healthy() {
  "$SYSTEMCTL" is-active --quiet k3s \
    && [ "$("$SYSTEMCTL" is-active sshd || true)" = "active" ] \
    && [ "$(kctl get node "$NODE_NAME" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

# Write-then-rename, so a power cut never leaves a half-written file. Synced:
# on disk before the staged copy and update-pending go.
take_pin() { # dir holding flake.nix and flake.lock
  for f in flake.nix flake.lock; do
    cp "$1/$f" "$FLAKE_DIR/.$f.new" && mv -f "$FLAKE_DIR/.$f.new" "$FLAKE_DIR/$f"
  done
  sync
}

# A commit that can't write the boot entries (ESP full, a vfat write error)
# would fail the same way on every boot: make OLD the default again and end
# the trial like a failed one.
abort_commit() {
  { "$NIX_ENV_BIN" -p "$PROFILE" --set "$FROM" && "$FROM/bin/switch-to-configuration" boot; } \
    || { report failed "could not write the boot entries for $VERSION, nor put the old ones back"; exit 1; }
  # A try before a power cut may have taken the new pin already. A failed
  # restore (full disk) must not die silently before the reboot below.
  if [ -d "$PIN_BEFORE" ]; then
    take_pin "$PIN_BEFORE" \
      || report failed "could not restore the device pin after aborting $VERSION"
  fi
  write_pending "$(jq -c '.phase = "trial" | .reason = "commit-failed"' "$PENDING")"
  "$SYSTEMCTL" reboot
  exit 0
}

# Every step is safe to repeat: after a power cut the next boot runs it all
# again. Boot counting (GitHub #17) replaces only this.
commit_trial() {
  set_phase committing
  { "$NIX_ENV_BIN" -p "$PROFILE" --set "$TO" && "$TO/bin/switch-to-configuration" boot; } \
    || abort_commit
  # Only now does FLAKE_DIR take the new pin. The staged copy stays until the
  # verdict is sent: until then a cut redoes this commit, or aborts it.
  if [ -d "$STAGED" ]; then
    # A failed copy (full disk) would otherwise kill the sentinel before any
    # verdict; abort ends the trial like a commit that cannot proceed.
    take_pin "$STAGED" || abort_commit
  fi
  if [ "$BOOTED" != "$TO" ]; then
    # A power cut mid-commit brought back OLD; NEW is the default now.
    "$SYSTEMCTL" reboot
    exit 0
  fi
  set_verdict "done" "update to $VERSION verified healthy"
  # If this label is dropped, the updater's next-poll reconcile_label heals it.
  kctl label node "$NODE_NAME" "librepod.os/version=$VERSION" --overwrite >/dev/null 2>&1 || true
  send_verdict
}

if [ "$PHASE" = committing ]; then
  commit_trial
  exit 0
fi

if [ "$BOOTED" != "$TO" ]; then
  if [ "$PHASE" = trial ]; then
    # The trial boot failed (health checks, panic, hang or power cut) and the
    # used-up one-shot brought back OLD. Unattended requests never retry it;
    # only the owner asking again does.
    echo "$VERSION" >> "$STATE_DIR/failed-versions"
    # NEW records why it gave up; no reason means it never got that far
    # (panic, hang, power cut).
    reason="$(jq -r '.reason // "trial-did-not-finish"' "$PENDING")"
    set_verdict rolled_back "$VERSION failed its trial boot ($reason); back on $(current_version)"
  else
    # A power cut before the trial boot: nothing ran, so nothing failed. A cut
    # inside start_trial can leave the profile on NEW; FROM is the boot default.
    # A profile that cannot be reset (corrupt, unwritable) must not wedge the
    # sentinel: the boot default is already FROM, and any later update re-sets it.
    "$NIX_ENV_BIN" -p "$PROFILE" --set "$FROM" \
      || echo "[librepod] could not reset the profile; the boot default is unaffected"
    set_verdict idle "update to $VERSION never started; cleared"
  fi
  send_verdict
  exit 0
fi

# ponytail: a node healthy-but-not-yet-stable past the deadline keeps waiting;
# flapping resets the stability clock and ends the trial once unhealthy past it.
deadline=$(( $(date +%s) + TIMEOUT ))
stable_deadline=0
reason=unhealthy # the last thing that failed, for the OLD boot's report
while :; do
  if healthy; then
    if [ "$stable_deadline" -eq 0 ]; then
      stable_deadline=$(( $(date +%s) + STABLE ))
    fi
    if [ "$(date +%s)" -ge "$stable_deadline" ]; then
      # Healthy and stable. Last, once per stable window (GitHub rate limits):
      # can NEW still fetch updates? One fetch of the release source covers
      # DNS, HTTPS and the repo. A release that fails it is never committed.
      timeout "$FETCH_TIMEOUT" "$NIX_BIN" flake metadata --refresh "${URI_PREFIX}${VERSION}" >/dev/null && break
      echo "[librepod] cannot fetch ${URI_PREFIX}${VERSION}; not committing"
      reason=update-source-unreachable
      stable_deadline=0
    fi
  else
    reason=unhealthy
    stable_deadline=0
  fi
  if [ "$stable_deadline" -eq 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
    # OLD is still the default, so a reboot ends the trial; the OLD boot reports it.
    write_pending "$(jq -c --arg r "$reason" '.reason = $r' "$PENDING")"
    "$SYSTEMCTL" reboot
    exit 0
  fi
  sleep "$INTERVAL"
done

commit_trial
