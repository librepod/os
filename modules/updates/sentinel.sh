# LibrePod update sentinel — runs at boot when an update was staged.
# Healthy → commit (label + done). Unhealthy → rollback previous generation.
# Stale flag → clear. No previous generation → failed (frp SSH is the rescue).
# (common.sh is prepended by modules/updates/default.nix.)

TIMEOUT="${LIBREPOD_HEALTH_TIMEOUT:-900}"
STABLE="${LIBREPOD_HEALTH_STABLE:-120}"
INTERVAL="${LIBREPOD_POLL_INTERVAL:-15}"

PENDING="$STATE_DIR/update-pending"
STASH="$STATE_DIR/rollback-pending"

if [ ! -f "$PENDING" ]; then
  # Post-rollback boot: the rolled_back report couldn't land while the
  # broken generation's k3s was down. Resend it now that the cluster is
  # back (the librepod-rollback-report unit runs us for exactly this).
  if [ -f "$STASH" ]; then
    TO="$(jq -r '.to' "$STASH")"
    rm -f "$STASH"
    report rolled_back "update to $TO rolled back after failed health checks"
  fi
  exit 0
fi

FROM="$(jq -r '.from' "$PENDING")"
TO="$(jq -r '.to' "$PENDING")"

healthy() {
  "$SYSTEMCTL" is-active --quiet k3s \
    && [ "$("$SYSTEMCTL" is-active sshd || true)" = "active" ] \
    && [ "$(kctl get node "$NODE_NAME" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

# Stale flag: profile unchanged since staging (power loss mid-flow) — the
# reboot never landed, nothing to verify or roll back. Restore the pin: the
# lock may claim a version that never booted.
# -f: profile symlinks are relative generation links (system-N-link)
CURRENT="$(readlink -f "$PROFILE" || true)"
if [ -n "$CURRENT" ] && [ "$CURRENT" = "$FROM" ]; then
  rm -f "$PENDING"
  restore_pin
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
        # Stash the intent: the report below goes through kubectl, which is
        # down on the broken generation — the post-rollback boot resends it.
        cp "$PENDING" "$STASH"
        # Revert the pin before reporting: report reads the restored lock, and
        # the next updater poll sees DESIRED != CURRENT instead of masking
        # this rollback as "up to date".
        restore_pin
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
rm -f "$PENDING" "$STASH" "$STATE_DIR"/flake.nix.bak "$STATE_DIR"/flake.lock.bak
# Label from $TO directly (the lock may be unreadable here); if this call is
# dropped, the updater's next-poll reconcile_label heals it.
kctl label node "$NODE_NAME" "librepod.os/version=$TO" --overwrite >/dev/null 2>&1 || true
report "done" "update to $TO verified healthy"
