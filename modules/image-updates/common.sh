#!/usr/bin/env bash
# Shared preamble for librepod-update, librepod-update-health and
# librepod-update-bridge. Concatenated ahead of each script by
# modules/image-updates/scripts.nix — one place for env defaults and the
# status.json contract, so the three can't drift. All paths are
# env-overridable for the stub tests.

# Each script uses a subset of these.
# shellcheck disable=SC2034
{
STATE_DIR="${LIBREPOD_UPDATES_DIR:-/var/lib/librepod/updates}"
SETTINGS="$STATE_DIR/settings.json"      # {channel, auto, timezone}
STATUS="$STATE_DIR/status.json"
RECORD="$STATE_DIR/record.json"          # the install in flight: {from, to, phase, reason?}
FAILED="$STATE_DIR/failed-versions"      # one per line
DOWNLOADED="$STATE_DIR/downloaded"       # the version in the spare slot
REQUEST="$STATE_DIR/request"             # the owner's answer: now | tonight
CHECK_NOW="$STATE_DIR/check-now"         # present: check even if the timer isn't due
SNAPSHOT="$STATE_DIR/k3s-db"             # $SNAPSHOT.partial while copying
RUN_DIR="${LIBREPOD_RUN_DIR:-/run/librepod-update}"
K3S_DB="${LIBREPOD_K3S_DB:-/var/lib/rancher/k3s/server/db}"
OS_RELEASE="${LIBREPOD_OS_RELEASE:-/etc/os-release}"
DEFINITIONS="${LIBREPOD_DEFINITIONS:-/etc/librepod/sysupdate}"   # one directory per channel
CHANNELS="${LIBREPOD_CHANNELS:-/etc/librepod/channels.json}"     # {stable: url, beta: url}
TZDIR="${TZDIR:-/etc/zoneinfo}"
}

INITIAL_STATUS='{"state":"up-to-date","available":null,"lastCheck":null,"installAt":null,"detail":"not checked yet"}'

# Write-then-rename: the scripts read these files after a power cut.
# Synced both sides of the rename: ext4 holds a rename in memory for ~5 s, and
# a power cut in that window would bring back the previous content.
write_state() { echo "$2" > "$1.new" && sync "$1.new" && mv -f "$1.new" "$1" && sync "$STATE_DIR"; } # file in STATE_DIR, content

now() { echo "${LIBREPOD_NOW:-$(date +%s)}"; } # epoch seconds
# One format everywhere: the bridge compares these as strings.
iso_now() { date -u -d @"$(now)" +%Y-%m-%dT%H:%M:%SZ; }

# The booted image's version, never a file the updater writes.
booted_version() {
  local v
  v=$(sed -n 's/^IMAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$OS_RELEASE" 2>/dev/null || true)
  echo "${v:-unknown}"
}

# The defaults stand until onboarding, and for a file that is missing,
# unreadable, or has the key missing or of the wrong type.
setting() { # key
  { cat "$SETTINGS" 2>/dev/null || true; } | jq -Rsr --arg k "$1" '
    {channel: "stable", auto: false, timezone: "UTC"} as $d
    | (try fromjson catch null | try .[$k] catch null) as $v
    | if ($v | type) == ($d[$k] | type) then $v else $d[$k] end'
}

# The zone becomes part of a path, so the shape is checked before the file.
valid_zone() { # zone
  [[ $1 =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]] && [ -f "$TZDIR/$1" ]
}

current_status() { jq -ce 'select(type == "object")' "$STATUS" 2>/dev/null || echo "$INITIAL_STATUS"; }

# Rewrites STATUS: sets state and detail, applies FILTER (available, lastCheck
# or installAt) with the jq args after it, then refreshes what the files decide.
# The filter's jq args must not be named ctx. `updated` moves only when
# something else in the status did.
set_status() { # state, detail [, jq filter [, jq args…]]
  local state=$1 detail=$2 filter=${3:-.} ctx new
  shift $(( $# < 3 ? $# : 3 ))
  ctx=$(jq -nc --arg state "$state" --arg detail "$detail" --arg current "$(booted_version)" \
    --arg updated "$(iso_now)" --arg channel "$(setting channel)" \
    --argjson auto "$(setting auto)" --arg timezone "$(setting timezone)" \
    --arg failed "$(cat "$FAILED" 2>/dev/null || true)" \
    --arg downloaded "$(cat "$DOWNLOADED" 2>/dev/null || true)" \
    '{state: $state, detail: $detail, current: $current, updated: $updated,
      settings: {channel: $channel, auto: $auto, timezone: $timezone},
      failed: ($failed | split("\n") | map(select(. != ""))), downloaded: $downloaded}')
  new=$(current_status | jq -c "$@" --argjson ctx "$ctx" '. as $old
    | .state = $ctx.state | .detail = $ctx.detail | ('"$filter"')
    | .current = $ctx.current | .settings = $ctx.settings | .failedVersions = $ctx.failed
    | .downloaded = (.available != null and .available == $ctx.downloaded)
    | .installAt = (if .state == "scheduled" then .installAt else null end)
    | .updated = (if del(.updated) == ($old | del(.updated)) then $old.updated else $ctx.updated end)')
  write_state "$STATUS" "$new"
}
