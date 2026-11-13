# librepod-update: the owner's CLI (status, check, install, settings) and the
# units' entry points (tick: what the timer runs). Settings commands keep the
# status's state and detail.

usage() { echo "usage: librepod-update status | check | install now|tonight | channel stable|beta | auto on|off | timezone ZONE" >&2; exit 2; }

current_state() { current_status | jq -r '.state // "up-to-date"'; }

# Rewrites STATUS keeping its state and detail; the args are set_status's
# filter and its jq args.
refresh_status() { # [jq filter [, jq args...]]
  set_status "$(current_state)" "$(current_status | jq -r '.detail // ""')" "$@"
}

write_settings() { # channel, auto (true|false), timezone
  write_state "$SETTINGS" "$(jq -nc --arg c "$1" --argjson a "$2" --arg z "$3" '{channel: $c, auto: $a, timezone: $z}')"
}

start_service() { systemctl start "$@" librepod-update.service; }

# ---- tick: check, download, decide, install --------------------------------

finish() { :; } # settles the install a record says was in flight (a no-op stub until the next task)

sysupdate() { systemd-sysupdate --definitions="$DEFINITIONS/$(setting channel)" "$@"; }

request() { cat "$REQUEST" 2>/dev/null || true; }
# A stale one (the booted version after its own update, say) is not one to install.
available() {
  local v; v=$(current_status | jq -r '.available // empty')
  if [ -n "$v" ] && newer "$v" "$(booted_version)"; then echo "$v"; fi
}
downloaded_version() { cat "$DOWNLOADED" 2>/dev/null || true; }
in_failed() { grep -qxF "$1" "$FAILED" 2>/dev/null; } # version
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; } # is $1 above $2

local_date() { TZ=$(setting timezone) date "$@"; } # in the owner's zone
in_window() { [[ $(local_date -d "@$(now)" +%H) == 0[234] ]]; }
install_at() { # now inside the window, else the next 02:00 local
  local at day rel=today; at=@$(now)
  day=$(local_date -d "$at" +%F)
  [ "$((10#$(local_date -d "$at" +%H)))" -lt 2 ] || rel=tomorrow # "+1 day" would read +1 as a zone
  if in_window; then local_date -d "$at" --iso-8601=seconds
  else local_date -d "$day 02:00 $rel" --iso-8601=seconds; fi
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

# An install about to be due gets the newest version, so it checks too.
check_due() {
  if [ -e "$CHECK_NOW" ]; then rm -f "$CHECK_NOW"; return 0; fi
  [ ! -e "$RUN_DIR/checked" ] || stale || install_due
}

# Sets available and lastCheck; or UNREACHABLE, leaving everything else as it was.
check() {
  local out new=''
  if out=$(sysupdate check-new); then
    if [[ $out =~ ^[0-9]+(\.[0-9]+)*$ ]] && newer "$out" "$(booted_version)"; then new=$out; fi
  elif ! sysupdate list >/dev/null; then # check-new also fails when nothing is newer
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
  if [ -z "$v" ] || [ "$v" = "$(downloaded_version)" ]; then return; fi
  # A failed version stays where it is (and a final state with it) until the owner asks.
  if in_failed "$v" && [ -z "$(request)" ]; then return; fi
  set_status downloading "downloading $v"
  # Vacuum drops any other download; the booted version is protected by
  # ProtectVersion=%A. Never vacuum between acquire and update --offline.
  if sysupdate vacuum --instances-max=1 && rm -f "$DOWNLOADED" && sysupdate acquire "$v"; then
    write_state "$DOWNLOADED" "$v"
  else
    set_status failed "could not download $v"
    [ "$(request)" != now ] || rm -f "$REQUEST"
  fi
}

snapshot_k3s_db() { # k3s is stopped
  rm -rf "$SNAPSHOT.partial"
  if [ -d "$K3S_DB" ]; then cp -a "$K3S_DB" "$SNAPSHOT.partial"; else mkdir "$SNAPSHOT.partial"; fi
  sync -f "$SNAPSHOT.partial"
  rm -rf "$SNAPSHOT"; mv "$SNAPSHOT.partial" "$SNAPSHOT"; sync "$STATE_DIR"
}

write_record() { write_state "$RECORD" "$(jq -nc --arg f "$1" --arg t "$2" --arg p "$3" '{from: $f, to: $t, phase: $p}')"; } # from, to, phase

# The one way out of an install that fails: k3s runs again and only FAILED is
# left behind. Best effort, in a subshell without errexit: k3s must start even
# if a step before it fails. Reads the globals install_version sets, as the
# EXIT trap runs after its locals are gone.
abort_install() {
  (
    set +e
    rm -rf "$RECORD" "$SNAPSHOT" "$SNAPSHOT.partial"
    in_failed "$INSTALL_TO" || echo "$INSTALL_TO" >> "$FAILED" # automatic updates skip it; the owner's request still retries
    sync "$FAILED" "$STATE_DIR" # the record is gone for good before k3s writes again, or a cut would restore a stale snapshot
    systemctl start k3s.service
    set_status failed "could not install $INSTALL_TO; still on $INSTALL_FROM"
  )
}

# Leaves the record when it has asked for the reboot. Any failure before that
# ends in abort_install.
install_version() { # version
  INSTALL_TO=$1; INSTALL_FROM=$(booted_version)
  write_record "$INSTALL_FROM" "$1" snapshot
  trap abort_install EXIT
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
    done | rolled-back | failed) if [ -z "$v" ] || in_failed "$v"; then return 0; fi ;;
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
    set_status up-to-date "${UNREACHABLE:-nothing newer to install}"
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
    download
    decide
    [ ! -e "$RECORD" ] || return 0 # install_version rebooted
    [ -e "$CHECK_NOW" ] || [ "$(request)" = now ] || break
  done
}

case "${1:-}" in
  status)
    refresh_status; cat "$STATUS" ;;
  check)
    touch "$CHECK_NOW"; start_service
    refresh_status; cat "$STATUS" ;;
  install)
    case "${2:-}" in now|tonight) ;; *) usage ;; esac
    write_state "$REQUEST" "$2"; start_service --no-block ;;
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
  *) usage ;;
esac
