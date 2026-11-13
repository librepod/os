# checks/image-updater-test.nix — runCommand derivation, not a module.
# Exercises modules/image-updates/updater.sh end-to-end with stubbed systemctl
# and systemd-sysupdate; the stubs win because the updater is built without systemd.
{ pkgs }:

let
  inherit
    (import ../modules/image-updates/scripts.nix {
      inherit (pkgs) writeShellApplication;
      runtimeInputs = with pkgs; [
        jq
        coreutils
        gnugrep
        gnused
      ];
    })
    updater
    ;
in
pkgs.runCommand "image-updater-test"
  {
    buildInputs = with pkgs; [
      bash
      jq
    ];
  }
  ''
    set -euo pipefail
    T=$(mktemp -d); STUBS=$T/stubs; D=$T/state
    export CALLS_LOG=$T/calls.log STUBS LIBREPOD_UPDATES_DIR=$D LIBREPOD_RUN_DIR=$T/run \
      LIBREPOD_K3S_DB=$T/db LIBREPOD_OS_RELEASE=$T/os-release LIBREPOD_DEFINITIONS=/defs \
      TZDIR=${pkgs.tzdata}/share/zoneinfo LIBREPOD_BLESS_BOOT=$STUBS/bin/systemd-bless-boot
    export PATH=$STUBS/bin:$PATH
    U=${updater}/bin/librepod-update
    mkdir -p $STUBS/bin
    stub() { printf '#!/bin/sh\necho "%s $*" >> "$CALLS_LOG"\n%s\n' "$1" "$2" > $STUBS/bin/$1; chmod +x $STUBS/bin/$1; }
    stub systemctl ':'
    stub systemd-bless-boot 'cat "$STUBS/bless-status"'
    stub systemd-sysupdate '
    ch=; for a; do case $a in --definitions=*) ch=''${a##*/};; esac; done
    case " $* " in
      *" check-new "*) v=$(cat "$STUBS/new-$ch" 2>/dev/null) && [ -n "$v" ] && echo "$v";;
      *" list "*) [ ! -e "$STUBS/list-fails" ];;
      *" acquire "*) if [ -e "$STUBS/press-now-during-acquire" ]; then rm "$STUBS/press-now-during-acquire"; echo now > "$LIBREPOD_UPDATES_DIR/request"; fi
                     [ ! -e "$STUBS/acquire-fails" ];;
      *" update "*) [ ! -e "$STUBS/update-fails" ];;
      *" pending "*) [ -e "$STUBS/pending" ];;
    esac'
    fresh() { rm -rf $D $T/run $T/db $STUBS/new-* $STUBS/*-fails $STUBS/pending; mkdir -p $D $T/run $T/db
              echo before > $T/db/state.db; booted 0.5.0; echo good > $STUBS/bless-status; : > $CALLS_LOG; unset LIBREPOD_NOW; }
    booted() { echo "IMAGE_VERSION=$1" > $LIBREPOD_OS_RELEASE; }
    offer() { echo "$2" > $STUBS/new-$1; }                       # channel, version
    at() { export LIBREPOD_NOW=$(TZ=$1 date -d "$2" +%s); }      # zone, local time
    st() { jq -r "$1" $D/status.json; }
    called() { grep -qF -- "$1" $CALLS_LOG; }
    not() { ! "$@"; }
    expect() { "$@" || { echo "FAIL: $*"; echo "--- calls"; cat $CALLS_LOG; echo "--- status"; cat $D/status.json 2>/dev/null; exit 1; }; }

    # ---- settings, status and the CLI shell -------------------------------
    fresh
    expect $U status
    expect [ "$(st .settings.channel)/$(st .settings.auto)/$(st .settings.timezone)" = stable/false/UTC ]
    expect [ "$(st .current)/$(st .state)" = 0.5.0/up-to-date ]
    expect $U channel stable; expect not called "start"                 # unchanged: nothing to do
    expect $U channel beta; expect [ "$(st .settings.channel)" = beta ]
    expect called "systemctl start --no-block librepod-update.service"; expect [ -e $D/check-now ]
    expect $U auto on; expect [ "$(st .settings.auto)" = true ]
    expect $U timezone Europe/Minsk; expect $U timezone Etc/GMT-3; expect [ "$(st .settings.timezone)" = Etc/GMT-3 ]
    for bad in Mars/Base ../../etc/passwd Europe/../../etc/passwd "" "Europe/Minsk; reboot"; do
      expect not $U timezone "$bad"
    done
    expect [ "$(st .settings.timezone)" = Etc/GMT-3 ]
    expect not $U channel nightly; expect not $U auto maybe; expect not $U install later; expect not $U frobnicate
    expect $U install tonight; expect [ "$(cat $D/request)" = tonight ]
    echo garbage > $D/settings.json; expect $U status; expect [ "$(st .settings.channel)" = stable ]

    # a file that parses but lacks a key, or has it of the wrong type, falls back per key
    echo '{"channel":"beta"}' > $D/settings.json; expect $U status
    expect [ "$(st .settings.channel)/$(st .settings.auto)/$(st .settings.timezone)" = beta/false/UTC ]
    echo '{"channel":5,"auto":"yes","timezone":["x"]}' > $D/settings.json; expect $U status
    expect [ "$(st .settings.channel)/$(st .settings.auto)/$(st .settings.timezone)" = stable/false/UTC ]

    # `updated` is UTC and moves only when the status does
    fresh; at Europe/Minsk "2026-11-14 13:00"
    expect $U status; expect [ "$(st .updated)" = 2026-11-14T10:00:00Z ]
    at Europe/Minsk "2026-11-14 14:00"; expect $U status; expect [ "$(st .updated)" = 2026-11-14T10:00:00Z ]
    expect $U auto on; expect [ "$(st .updated)" = 2026-11-14T11:00:00Z ]

    # derived fields come from the files; installAt only while scheduled
    fresh
    printf '0.5.1\n0.5.2\n' > $D/failed-versions; echo 0.5.1 > $D/downloaded
    echo '{"state":"ready","available":"0.5.1","lastCheck":null,"installAt":"2026-11-14T02:00:00+03:00","detail":"d"}' > $D/status.json
    expect $U status
    expect [ "$(st '.failedVersions|join(",")')/$(st .downloaded)/$(st .installAt)/$(st .detail)" = 0.5.1,0.5.2/true/null/d ]
    echo '{"state":"scheduled","available":"0.5.1","installAt":"2026-11-14T02:00:00+03:00","detail":"d"}' > $D/status.json
    expect $U status; expect [ "$(st .installAt)" = 2026-11-14T02:00:00+03:00 ]
    expect $U channel beta; expect [ ! -e $D/downloaded ]; expect [ "$(st .downloaded)" = false ]

    # check starts the unit and waits; a refused install changes nothing
    fresh
    expect $U check; expect called "systemctl start librepod-update.service"; expect [ -e $D/check-now ]
    expect not $U install later; expect [ ! -e $D/request ]
    expect $U install now; expect [ "$(cat $D/request)" = now ]
    expect called "systemctl start --no-block librepod-update.service"
    echo "image-updater scenarios passed"; touch $out
  ''
