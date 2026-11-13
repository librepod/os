
# librepod-update: the owner's CLI (status, check, install, settings) and the
# units' entry points. Settings commands keep the status's state and detail.

usage() { echo "usage: librepod-update status | check | install now|tonight | channel stable|beta | auto on|off | timezone ZONE" >&2; exit 2; }

refresh_status() {
  local s; s=$(current_status)
  set_status "$(jq -r .state <<<"$s")" "$(jq -r .detail <<<"$s")"
}

write_settings() { # channel, auto (true|false), timezone
  write_state "$SETTINGS" "$(jq -nc --arg c "$1" --argjson a "$2" --arg z "$3" '{channel: $c, auto: $a, timezone: $z}')"
}

start_service() { systemctl start "$@" librepod-update.service; }

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
  *) usage ;;
esac
