# librepod-update-bridge: the one piece that talks to k3s. Every minute it
# copies the updater's status into the ConfigMap the Marketplace reads, and
# passes the owner's answers (settings, install now/tonight) to the
# librepod-update CLI. It changes no files of the updater's: a failure here
# stops this run, and the next one retries.
# (common.sh is prepended by modules/image-updates/scripts.nix.)

NAMESPACE=librepod-os # the OS's own: the OS doesn't hard-code app namespaces
CONFIGMAP=librepod-os-update
BRIDGE="$STATE_DIR/bridge.json" # {settings, install: the last rev and id handled, rejected: {at, detail} | null}

kc() { kubectl --request-timeout=20s "$@"; }

# Missing or unreadable: nothing handled yet, so an answer still in the
# ConfigMap (an install `now` too) is applied again.
state=$({ cat "$BRIDGE" 2>/dev/null || true; } | jq -Rsc 'try fromjson catch null
  | if type == "object" then . else {} end
  | {settings: (.settings // 0), install: (.install // 0), rejected: (.rejected // null)}')

# Applies a change to the state and writes it out.
put() { state=$(jq -c "$@" <<< "$state") && write_state "$BRIDGE" "$state"; } # jq args, then the filter

# The answer under a key: its JSON when it is an object, else {}. A missing
# .data or key reads as empty.
answer() { jq -c --arg k "$1" '(try .data[$k] catch null) | (try fromjson catch null) | if type == "object" then . else {} end' <<< "$cm"; } # key

# The answer's rev or id, when it is written as a whole number from 1 to
# 999999999999999 (no 3.0 or 1e3: the literal is echoed as written; bigger
# numbers stop being exact) and above the last one handled; else nothing.
fresh() { jq -r --arg f "$1" --argjson last "$(jq ".$2" <<< "$state")" \
  '.[$f] | select(type == "number" and (tojson | test("^[0-9]+$")) and . >= 1 and . <= 999999999999999 and . > $last)' <<< "$3"; } # field, state key, answer

# Marks a rev or id handled, with the reason when it was refused, in one write.
# `at` moves only for a reason not shown yet.
handled() { # state key, rev or id, reason ("" when applied)
  # shellcheck disable=SC2016 # jq variables
  put --arg k "$1" --argjson n "$2" --arg why "$3" --arg at "$(iso_now)" '.[$k] = $n
    | if $why == "" or .rejected.detail == $why then . else .rejected = {at: $at, detail: $why} end'
}

kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f - > /dev/null
# Never `apply`: it would overwrite the keys the Marketplace wrote.
kc -n "$NAMESPACE" get configmap "$CONFIGMAP" > /dev/null 2>&1 || kc -n "$NAMESPACE" create configmap "$CONFIGMAP" > /dev/null
cm=$(kc -n "$NAMESPACE" get configmap "$CONFIGMAP" -o json)

# ---- settings.json: {rev, channel, auto, timezone} -------------------------
a=$(answer settings.json)
if rev=$(fresh rev settings "$a") && [ -n "$rev" ]; then
  why=$(jq -r 'if (.channel | IN("stable", "beta") | not) then "the channel is not stable or beta"
    elif (.auto | type) != "boolean" then "auto is not true or false" else empty end' <<< "$a")
  zone=$(jq -r '.timezone | strings' <<< "$a")
  [ -n "$why" ] || valid_zone "$zone" || why="the time zone is unknown"
  if [ -z "$why" ]; then
    librepod-update channel "$(jq -r .channel <<< "$a")"
    librepod-update auto "$(jq -r 'if .auto then "on" else "off" end' <<< "$a")"
    librepod-update timezone "$zone"
    handled settings "$rev" ""
  else
    handled settings "$rev" "settings rev $rev rejected: $why"
  fi
fi

# ---- install.json: {id, when} ----------------------------------------------
a=$(answer install.json)
if id=$(fresh id install "$a") && [ -n "$id" ]; then
  when=$(jq -r '.when | strings' <<< "$a")
  case "$when" in
    now | tonight)
      librepod-update install "$when"
      handled install "$id" "" ;;
    *) handled install "$id" "install id $id rejected: when is not now or tonight" ;;
  esac
fi

# ---- status.json: the updater's, plus what was handled ---------------------
# A rejection stands in for the updater's detail until the updater's status moves on.
out=$({ cat "$STATUS" 2>/dev/null || true; } | jq -Rsc --argjson b "$state" 'try fromjson catch null
  | if type == "object" then . else {} end
  | . + {handled: {settings: $b.settings, install: $b.install}}
  | if $b.rejected != null and $b.rejected.at >= (.updated // "") then .detail = $b.rejected.detail else . end')
# Against what the ConfigMap holds, so a deleted one, or one k3s restored from
# before, gets it again.
live=$(jq -r '(try .data["status.json"] catch null) // ""' <<< "$cm")
if [ "$out" != "$live" ]; then
  kc -n "$NAMESPACE" patch configmap "$CONFIGMAP" --type merge \
    -p "$(jq -nc --arg s "$out" '{data: {"status.json": $s}}')" > /dev/null
fi
