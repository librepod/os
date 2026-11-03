# LibrePod update sentinel — runs at boot while an update is in flight.
# On the trial boot (NEW): healthy → commit; unhealthy → reboot, and the
# used-up one-shot brings back OLD. Back on OLD: record how the update ended.
# (common.sh is prepended by modules/updates/default.nix.)

TIMEOUT="${LIBREPOD_HEALTH_TIMEOUT:-900}"
STABLE="${LIBREPOD_HEALTH_STABLE:-120}"
INTERVAL="${LIBREPOD_POLL_INTERVAL:-15}"

[ -f "$PENDING" ] || exit 0

TO="$(jq -r '.to // empty' "$PENDING")"
VERSION="$(jq -r '.version // empty' "$PENDING")"
PHASE="$(jq -r '.phase // empty' "$PENDING")"
BOOTED="$(readlink -f "$CURRENT_SYSTEM")"

healthy() {
  "$SYSTEMCTL" is-active --quiet k3s \
    && [ "$("$SYSTEMCTL" is-active sshd || true)" = "active" ] \
    && [ "$(kctl get node "$NODE_NAME" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

# Every step is safe to repeat: after a power cut the next boot runs it all
# again. Boot counting (GitHub #17) replaces only this.
commit_trial() {
  set_phase committing
  "$NIX_ENV_BIN" -p "$PROFILE" --set "$TO"
  "$TO/bin/switch-to-configuration" boot
  # Only now does FLAKE_DIR take the new pin. Write-then-rename, so a power
  # cut never leaves a half-written file.
  if [ -d "$STAGED" ]; then
    for f in flake.nix flake.lock; do
      cp "$STAGED/$f" "$FLAKE_DIR/.$f.new" && mv -f "$FLAKE_DIR/.$f.new" "$FLAKE_DIR/$f"
    done
    rm -rf "$STAGED"
  fi
  if [ "$BOOTED" != "$TO" ]; then
    # A power cut mid-commit brought back OLD; NEW is the default now.
    "$SYSTEMCTL" reboot
    exit 0
  fi
  # If this label is dropped, the updater's next-poll reconcile_label heals it.
  kctl label node "$NODE_NAME" "librepod.os/version=$VERSION" --overwrite >/dev/null 2>&1 || true
  report "done" "update to $VERSION verified healthy"
  rm -f "$PENDING"
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
    report rolled_back "$VERSION failed its trial boot; back on $(current_version)"
  else
    # A power cut before the trial boot: nothing ran, so nothing failed.
    report idle "update to $VERSION never started; cleared"
  fi
  rm -rf "$PENDING" "$STAGED"
  exit 0
fi

# ponytail: a node healthy-but-not-yet-stable past the deadline keeps waiting;
# flapping resets the stability clock and ends the trial once unhealthy past it.
deadline=$(( $(date +%s) + TIMEOUT ))
stable_deadline=0
while :; do
  if healthy; then
    if [ "$stable_deadline" -eq 0 ]; then
      stable_deadline=$(( $(date +%s) + STABLE ))
    fi
    if [ "$(date +%s)" -ge "$stable_deadline" ]; then
      # Healthy and stable. Last, once per stable window (GitHub rate limits):
      # can NEW still fetch updates? One fetch of the release source covers
      # DNS, HTTPS and the repo. A release that fails it is never committed.
      "$NIX_BIN" flake metadata --refresh "${URI_PREFIX}${VERSION}" >/dev/null && break
      echo "[librepod] cannot fetch ${URI_PREFIX}${VERSION}; not committing"
      stable_deadline=0
    fi
  else
    stable_deadline=0
  fi
  if [ "$stable_deadline" -eq 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
    # OLD is still the default, so a reboot ends the trial; the OLD boot reports it.
    "$SYSTEMCTL" reboot
    exit 0
  fi
  sleep "$INTERVAL"
done

commit_trial
