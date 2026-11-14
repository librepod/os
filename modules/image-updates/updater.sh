# librepod-update: the owner's CLI (status, check, install, settings) and the
# units' entry points (tick: what the timer runs; fallback: before k3s on every
# boot; finish: once the new version is blessed). Settings commands keep the
# status's state and detail.

usage() { echo "usage: librepod-update status | check | install now|tonight | channel stable|beta | auto on|off | timezone ZONE" >&2; exit 2; }

current_state() { current_status | jq -r '.state // "up-to-date"'; }

# Rewrites STATUS keeping its state and detail; the args are set_status's
# filter and its jq args.
refresh_status() { status_locked refresh_status_unlocked "$@"; } # [jq filter [, jq args...]]
refresh_status_unlocked() { set_status_unlocked "$(current_state)" "$(current_status | jq -r '.detail // ""')" "$@"; }

write_settings() { # channel, auto (true|false), timezone
  write_state "$SETTINGS" "$(jq -nc --arg c "$1" --argjson a "$2" --arg z "$3" '{channel: $c, auto: $a, timezone: $z}')"
}

start_service() { systemctl start "$@" librepod-update.service; }

# ---- tick: check, download, decide, install --------------------------------

sysupdate() { systemd-sysupdate --definitions="$DEFINITIONS/$(setting channel)" "$@"; }

request() { cat "$REQUEST" 2>/dev/null || true; }
# A stale one (the booted version after its own update, say) is not one to install.
available() {
  local v; v=$(current_status | jq -r '.available // empty')
  if [ -n "$v" ] && newer "$v" "$(booted_version)"; then echo "$v"; fi
}
downloaded_version() { cat "$DOWNLOADED" 2>/dev/null || true; }
# A download that failed waits for the next check or the owner's install. In the
# run dir: every boot checks first.
failed_download() { cat "$RUN_DIR/download-failed" 2>/dev/null || true; }
in_failed() { grep -qxF "$1" "$FAILED" 2>/dev/null; } # version
# Rewritten whole, not appended to: a power cut can't tear the line.
fail_version() { in_failed "$1" || write_state "$FAILED" "$({ cat "$FAILED" 2>/dev/null || true; echo "$1"; })"; } # version
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; } # is $1 above $2

local_date() { TZ=$(setting timezone) date "$@"; } # in the owner's zone
in_window() { [[ $(local_date -d "@$(now)" +%H) == 0[234] ]]; }
install_at() { # now inside the window, else the next 02:00 local
  local at day rel=today; at=@$(now)
  day=$(local_date -d "$at" +%F)
  [ "$((10#$(local_date -d "$at" +%H)))" -lt 2 ] || rel=tomorrow # "+1 day" would read +1 as a zone
  if in_window; then local_date -d "$at" --iso-8601=seconds
  else local_date -d "$day 02:00 $rel" --iso-8601=seconds 2>/dev/null || local_date -d "$day 03:00 $rel" --iso-8601=seconds; fi # 02:00 doesn't exist when the clocks spring forward
}

# Automatic updates are on and the version hasn't failed here.
auto_applies() {
  local v; v=$(available)
  [ "$(setting auto)" = true ] && [ -n "$v" ] && ! in_failed "$v"
}
wants_night() { [ "$(request)" = tonight ] || auto_applies; }
install_due() { [ "$(request)" = now ] || { in_window && wants_night; }; }

# lastCheck missing, 6 h or more ago, or in the future (the clock moved back).
stale() {
  local last t; last=$(current_status | jq -r '.lastCheck // empty')
  [ -n "$last" ] || return 0
  t=$(date -d "$last" +%s 2>/dev/null) || return 0
  t=$(( $(now) - t ))
  [ "$t" -ge 21600 ] || [ "$t" -lt 0 ]
}

# An install about to be due gets the newest version, so it checks too; the
# other checks also try a failed download again.
check_due() {
  if [ -e "$CHECK_NOW" ] || [ ! -e "$RUN_DIR/checked" ] || stale; then
    rm -f "$CHECK_NOW" "$RUN_DIR/download-failed"; return 0
  fi
  install_due
}

# The newest version the channel offers above the booted one; fails when the
# source can't be read. Not check-new: on 260 it offers an acquired download,
# another channel's too. `list` names every version; `list V` says if the source has it.
offered() {
  local json v
  json=$(sysupdate --json=short list) || return 1
  while read -r v; do
    if [[ $v =~ ^[0-9]+(\.[0-9]+)*$ ]] && newer "$v" "$(booted_version)"; then
      json=$(sysupdate --json=short list "$v") || return 1
      if jq -e '.available == true' <<< "$json" > /dev/null; then echo "$v"; return 0; fi
    fi
  done < <(jq -r '.all[]? | strings' <<< "$json" | sort -rV)
}

# Sets available and lastCheck; or UNREACHABLE, leaving everything else as it was.
check() {
  local new
  if ! new=$(offered); then
    UNREACHABLE="could not reach the $(setting channel) update source"
    set_status "$(current_state)" "$UNREACHABLE"
    return
  fi
  # shellcheck disable=SC2016 # jq variables
  refresh_status '.available = (if $v == "" then null else $v end) | .lastCheck = $t' --arg v "$new" --arg t "$(iso_now)"
  mkdir -p "$RUN_DIR" # not RuntimeDirectory=: systemd removes that when the oneshot stops
  touch "$RUN_DIR/checked"
}

download() {
  local v; v=$(available)
  if [ -z "$v" ] || [ "$v" = "$(downloaded_version)" ] || [ "$v" = "$(failed_download)" ]; then return; fi
  # A failed version stays where it is (and a final state with it) until the owner asks.
  if in_failed "$v" && [ -z "$(request)" ]; then return; fi
  set_status downloading "downloading $v"
  # Vacuum drops any other download; the booted version is protected by
  # ProtectVersion=%A. Never vacuum between acquire and update --offline.
  if sysupdate vacuum --instances-max=1 && rm -f "$DOWNLOADED" && sysupdate acquire "$v"; then
    write_state "$DOWNLOADED" "$v"
  else
    set_status failed "could not download $v"
    echo "$v" > "$RUN_DIR/download-failed"
    [ "$(request)" != now ] || rm -f "$REQUEST"
  fi
}

# In two steps, so a cut never leaves a half-deleted snapshot for fallback to
# restore: a .partial is never restored.
drop_snapshot() {
  if [ -e "$SNAPSHOT" ]; then
    rm -rf "$SNAPSHOT.partial"; mv -T "$SNAPSHOT" "$SNAPSHOT.partial"; sync "$STATE_DIR"
  fi
  rm -rf "$SNAPSHOT.partial"
}

snapshot_k3s_db() { # k3s is stopped
  # An older one goes first: cut mid-copy, fallback must find no snapshot (the data is untouched), not a stale one.
  drop_snapshot
  if [ -d "$K3S_DB" ]; then cp -a "$K3S_DB" "$SNAPSHOT.partial"; else mkdir "$SNAPSHOT.partial"; fi
  sync -f "$SNAPSHOT.partial"
  mv -T "$SNAPSHOT.partial" "$SNAPSHOT"; sync "$STATE_DIR" # -T: never into a directory that is already there
}

write_record() { write_state "$RECORD" "$(jq -nc --arg f "$1" --arg t "$2" --arg p "$3" '{from: $f, to: $t, phase: $p}')"; } # from, to, phase

# The one way out of an install that fails: k3s runs again and only FAILED is
# left behind. Best effort, in a subshell without errexit: k3s must start even
# if a step before it fails. Reads the globals install_version sets, as the
# EXIT trap runs after its locals are gone.
abort_install() {
  (
    set +e
    rm -rf "$RECORD"; drop_snapshot
    fail_version "$INSTALL_TO" # automatic updates skip it; the owner's request still retries
    sync "$STATE_DIR" # the record is gone for good before k3s writes again, or a cut would restore a stale snapshot
    systemctl start k3s.service
    set_status failed "could not install $INSTALL_TO; still on $INSTALL_FROM"
  )
}

# Leaves the record when it has asked for the reboot. Any failure before that
# ends in abort_install.
install_version() { # version
  INSTALL_TO=$1; INSTALL_FROM=$(booted_version)
  trap abort_install EXIT # before the record: a failing sync inside its write would leave it behind
  drop_snapshot # before the record too: with a record, an older snapshot is one fallback would restore
  write_record "$INSTALL_FROM" "$1" snapshot
  set_status installing "installing $1"
  systemctl stop k3s.service
  snapshot_k3s_db
  # shortcut: a test hook for the VM's power-cut scenario; nothing in production sets it
  if [ -n "${LIBREPOD_TEST_HOLD:-}" ] && [ -e "$LIBREPOD_TEST_HOLD" ]; then
    touch "$LIBREPOD_TEST_HOLD.held"
    while [ -e "$LIBREPOD_TEST_HOLD" ]; do sleep 1; done
  fi
  if ! sysupdate update --offline "$1"; then
    trap - EXIT; abort_install
    return
  fi
  write_record "$INSTALL_FROM" "$1" installed || true # the new entry boots next either way
  trap - EXIT
  systemctl reboot
}

# Not due: say what is coming. A final state stays until something new turns
# up, and so does the state while the source is unreachable.
settle() { # available version or empty
  local v=$1
  [ -z "$UNREACHABLE" ] || return 0
  case $(current_state) in
    done | rolled-back | failed) if [ -z "$v" ] || in_failed "$v" || [ "$v" = "$(failed_download)" ]; then return 0; fi ;;
  esac
  if wants_night; then
    # shellcheck disable=SC2016 # jq variable
    set_status scheduled "installs in the night window" '.installAt = $at' --arg at "$(install_at)"
  elif [ -z "$v" ]; then
    set_status up-to-date "up to date"
  elif [ "$v" = "$(downloaded_version)" ]; then
    set_status ready "$v is ready to install"
  fi
}

decide() {
  local v; v=$(available)
  if ! install_due; then
    settle "$v"
  elif [ -z "$v" ]; then
    rm -f "$REQUEST"
    [ -n "$UNREACHABLE" ] || set_status up-to-date "nothing newer to install" # unreachable: check kept the state and said so
  elif [ "$v" = "$(downloaded_version)" ]; then
    rm -f "$REQUEST"
    install_version "$v"
  fi
}

tick() {
  for _ in 1 2 3; do
    if [ -e "$RECORD" ]; then finish; return; fi
    UNREACHABLE=
    if check_due; then check; fi
    if [ -z "$UNREACHABLE" ]; then download; fi # a stale available would acquire from the new channel's definitions
    decide
    [ ! -e "$RECORD" ] || return 0 # install_version rebooted
    [ -e "$CHECK_NOW" ] || [ "$(request)" = now ] || break
  done
}

# ---- after the reboot: fallback (before k3s) and finish (once blessed) -------

BLESS_BOOT="${LIBREPOD_BLESS_BOOT:-systemd-bless-boot}"

record_ok() { jq -e 'type == "object" and all(.from, .to, .phase; type == "string" and . != "")' "$RECORD" >/dev/null 2>&1; }
record_field() { jq -r --arg k "$1" '.[$k] | strings' "$RECORD" 2>/dev/null || true; } # from | to | phase | reason

# Copy beside the data, then swap by rename: K3S_DB is never missing or half-written.
restore_k3s_db() {
  mkdir -p "$K3S_DB" && rm -rf "$K3S_DB.restore" && cp -a "$SNAPSHOT" "$K3S_DB.restore" &&
    sync -f "$K3S_DB.restore" && mv -T --exchange "$K3S_DB.restore" "$K3S_DB" || return 1
  # The swap is the commit: nothing after it may report a failed restore.
  sync "$(dirname "$K3S_DB")" || true
  rm -rf "$K3S_DB.restore" || true # what the swap put aside
}

fallback() {
  [ -e "$RECORD" ] || return 0
  local from to phase reason booted
  booted=$(booted_version); from=$(record_field from); to=$(record_field to)
  if ! record_ok || { [ "$booted" != "$from" ] && [ "$booted" != "$to" ]; }; then
    mv -f "$RECORD" "$RECORD.bad"; sync "$STATE_DIR"
    set_status failed "the record of the update in flight was unreadable; moved aside"
    return
  fi
  [ "$booted" = "$from" ] || return 0 # on the new version: the health gate decides
  if [ -d "$SNAPSHOT" ] && ! restore_k3s_db; then
    set_status failed "could not restore k3s data from before $to"
    return 1
  fi
  phase=$(record_field phase); reason=$(record_field reason)
  # Gone as soon as the data is back: restored again after k3s ran, it would undo k3s's writes.
  drop_snapshot
  # By phase, not `sysupdate pending`: on 260 that counts an acquired download
  # as installed. A reason comes only from the new version's gate.
  if [ "$phase" = installed ] || [ -n "$reason" ]; then
    fail_version "$to"
    sysupdate vacuum --instances-max=1 || true # so that a retry downloads it again
    rm -f "$DOWNLOADED"
    set_status rolled-back "$to failed its health check (${reason:-did not finish}); back on $from"
  else
    set_status failed "the install of $to was interrupted; nothing changed"
  fi
  rm -f "$RECORD"; sync "$STATE_DIR" # last: until then a repeat of this run is harmless
}

blessed() { local s; s=$("$BLESS_BOOT" status 2>/dev/null) || return 1; [[ $s == good || $s == clean ]]; }

# Settles the install the record says was in flight once its version is blessed.
# Decides from the booted version, not the phase: the write of "installed" may have failed.
finish() {
  local to; to=$(record_field to)
  if [ -z "$to" ] || [ "$to" != "$(booted_version)" ] || ! blessed; then return 0; fi
  if in_failed "$to"; then write_state "$FAILED" "$(grep -vxF "$to" "$FAILED" || true)"; fi
  drop_snapshot; rm -f "$DOWNLOADED"
  set_status "done" "updated to $to" '.available = null' # quoted: shellcheck reads a bare done as the keyword
  rm -f "$RECORD"; sync "$STATE_DIR"
}

case "${1:-}" in
  status)
    refresh_status; cat "$STATUS" ;;
  check)
    touch "$CHECK_NOW"; start_service
    refresh_status; cat "$STATUS" ;;
  install)
    case "${2:-}" in now|tonight) ;; *) usage ;; esac
    write_state "$REQUEST" "$2"; rm -f "$RUN_DIR/download-failed"; start_service --no-block ;;
  channel)
    case "${2:-}" in stable|beta) ;; *) usage ;; esac
    if [ "$2" != "$(setting channel)" ]; then
      write_settings "$2" "$(setting auto)" "$(setting timezone)"
      rm -f "$DOWNLOADED"; touch "$CHECK_NOW"
      refresh_status; start_service --no-block
    else
      refresh_status
    fi ;;
  auto)
    case "${2:-}" in on) a=true;; off) a=false;; *) usage ;; esac
    write_settings "$(setting channel)" "$a" "$(setting timezone)"
    refresh_status; start_service --no-block ;;
  timezone)
    valid_zone "${2:-}" || { echo "librepod-update: unknown time zone: ${2:-}" >&2; exit 2; }
    write_settings "$(setting channel)" "$(setting auto)" "$2"
    refresh_status ;;
  tick)
    tick ;;
  fallback)
    fallback ;;
  finish)
    finish ;;
  *) usage ;;
esac
