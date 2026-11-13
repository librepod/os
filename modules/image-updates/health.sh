# librepod-update-health: runs on a new version's counted boot, before
# systemd-bless-boot marks the boot good. Exits 0 when the version stayed
# healthy and its update source checks out; 1 otherwise, and the unit's
# FailureAction reboots into the old version. Before giving up it writes the
# failed check into the install record, so the old version can say why.
# (common.sh is prepended by modules/image-updates/scripts.nix.)

# 12 min: with two 60 s fetches in the last poll, inside the unit's 15.
DEADLINE="${LIBREPOD_HEALTH_DEADLINE:-720}"
STABLE="${LIBREPOD_HEALTH_STABLE:-120}"
INTERVAL="${LIBREPOD_POLL_INTERVAL:-15}"
PUBRING="${LIBREPOD_PUBRING:-/etc/systemd/import-pubring.pgp}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The first check that fails, or nothing.
failing_check() {
  systemctl is-active --quiet k3s || { echo k3s; return; }
  systemctl is-active --quiet sshd || { echo sshd; return; }
  # Its own timeout: a hung API server must not eat the deadline.
  [ "$(k3s kubectl --request-timeout=10s get node "$(cat /proc/sys/kernel/hostname)" \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    || echo node-not-ready
}

# The channel's checksums, signed by a key this image trusts.
# -L: the channel URLs are GitHub redirects, which -f alone does not follow.
verify_source() {
  local url
  url=$(jq -r --arg c "$(setting channel)" '.[$c] // empty' "$CHANNELS" 2>/dev/null) && [ -n "$url" ] || return 1
  curl -fsSL --max-time 60 -o "$WORK/SHA256SUMS" "${url}SHA256SUMS" \
    && curl -fsSL --max-time 60 -o "$WORK/SHA256SUMS.gpg" "${url}SHA256SUMS.gpg" \
    && gpgv --keyring "$PUBRING" "$WORK/SHA256SUMS.gpg" "$WORK/SHA256SUMS"
}

# Never creates the record: without one, no install is in flight.
record_reason() { # reason
  local new
  new=$(jq -ce --arg r "$1" 'select(type == "object") | .reason = $r' "$RECORD" 2>/dev/null) || return 0
  write_state "$RECORD" "$new"
}

start=$SECONDS stable_since=$SECONDS reason=
while [ $((SECONDS - start)) -lt "$DEADLINE" ]; do
  check=$(failing_check)
  if [ -z "$check" ] && [ $((SECONDS - stable_since)) -ge "$STABLE" ]; then
    if verify_source; then exit 0; fi
    check=update-source
  fi
  if [ -n "$check" ]; then reason=$check; stable_since=$SECONDS; fi
  sleep "$INTERVAL"
done

record_reason "${reason:-update-source}"
exit 1
