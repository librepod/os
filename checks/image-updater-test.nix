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
    expect [ "$(jq -r .timezone $D/settings.json)" = Etc/GMT-3 ]
    expect $U auto off; expect [ "$(jq -r .auto $D/settings.json)" = false ]
    expect not $U channel nightly; expect not $U auto maybe; expect not $U install later; expect not $U frobnicate
    expect $U install tonight; expect [ "$(cat $D/request)" = tonight ]
    echo garbage > $D/settings.json; expect $U status; expect [ "$(st .settings.channel)" = stable ]

    # a file that parses but lacks a key, or has it of the wrong type, falls back per key
    echo '{"channel":"beta"}' > $D/settings.json; expect $U status
    expect [ "$(st .settings.channel)/$(st .settings.auto)/$(st .settings.timezone)" = beta/false/UTC ]
    echo '{"channel":5,"auto":"yes","timezone":["x"]}' > $D/settings.json; expect $U status
    expect [ "$(st .settings.channel)/$(st .settings.auto)/$(st .settings.timezone)" = stable/false/UTC ]
    echo '{"channel":"nightly"}' > $D/settings.json; expect $U status; expect [ "$(st .settings.channel)" = stable ]
    echo '{}' > $D/status.json; expect $U status; expect [ "$(st .state)/$(st .detail)" = up-to-date/ ]

    # `updated` is UTC and moves only when the status does
    fresh; at Europe/Minsk "2026-11-14 13:00"
    expect $U status; expect [ "$(st .updated)" = 2026-11-14T10:00:00Z ]
    at Europe/Minsk "2026-11-14 14:00"; expect $U status; expect [ "$(st .updated)" = 2026-11-14T10:00:00Z ]
    ino=$(stat -c %i $D/status.json); expect $U status; expect [ "$(stat -c %i $D/status.json)" = $ino ]  # unchanged: not rewritten
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

    # ---- the tick -----------------------------------------------------------
    # check finds and downloads; nothing installs by itself
    fresh; offer stable 0.5.1; expect $U tick
    expect called "--definitions=/defs/stable check-new"; expect called "acquire 0.5.1"
    expect [ "$(st .available)/$(st .downloaded)/$(st .state)" = 0.5.1/true/ready ]; expect not called "update --offline"
    # never a lower version
    fresh; offer stable 0.4.9; expect $U tick; expect [ "$(st .available)" = null ]; expect not called acquire
    # once per boot, then every 6 h
    fresh; offer stable 0.5.1; at UTC "2026-11-14 12:00"; $U tick; : > $CALLS_LOG; $U tick; expect not called check-new
    at UTC "2026-11-14 18:00"; $U tick; expect called check-new
    # a newer version replaces the download
    offer stable 0.5.2; touch $D/check-now; $U tick
    expect called "vacuum --instances-max=1"; expect called "acquire 0.5.2"; expect [ "$(cat $D/downloaded)" = 0.5.2 ]
    # install now: the newest at install time, k3s stopped and snapshotted first
    fresh; offer stable 0.5.1; $U tick; offer stable 0.5.2; $U install now; $U tick
    expect called "update --offline 0.5.2"; expect called "systemctl reboot"
    expect [ "$(grep -n 'stop k3s' $CALLS_LOG | cut -d: -f1)" -lt "$(grep -n 'update --offline' $CALLS_LOG | cut -d: -f1)" ]
    expect [ "$(jq -r '.from+" "+.to+" "+.phase' $D/record.json)" = "0.5.0 0.5.2 installed" ]
    expect [ "$(cat $D/k3s-db/state.db)" = before ]; expect [ ! -e $D/request ]
    # now during a download: one run, one install
    fresh; offer stable 0.5.1; touch $STUBS/press-now-during-acquire; $U tick; expect called "update --offline 0.5.1"
    # now with nothing newer
    fresh; $U install now; $U tick
    expect [ "$(st .state)" = up-to-date ]; expect [ ! -e $D/request ]; expect not called reboot
    # update --offline fails: record gone before k3s starts again
    fresh; offer stable 0.5.1; touch $STUBS/update-fails; $U install now; $U tick
    expect [ ! -e $D/record.json ]; expect [ ! -e $D/k3s-db ]; expect called "start k3s"; expect [ "$(st .state)" = failed ]
    # automatic only in the window, 05:00 excluded
    fresh; offer stable 0.5.1; $U timezone Europe/Minsk; $U auto on; at Europe/Minsk "2026-11-14 12:00"; $U tick
    expect [ "$(st .state)/$(st .installAt)" = "scheduled/2026-11-15T02:00:00+03:00" ]; expect not called "update --offline"
    at Europe/Minsk "2026-11-15 05:00"; $U tick; expect not called "update --offline"
    at Europe/Minsk "2026-11-15 02:10"; $U tick; expect called "update --offline 0.5.1"
    # tonight without automatic updates
    fresh; offer stable 0.5.1; $U timezone Europe/Minsk; $U install tonight; at Europe/Minsk "2026-11-14 23:00"; $U tick
    expect [ "$(st .state)" = scheduled ]; at Europe/Minsk "2026-11-15 03:00"; $U tick; expect called "update --offline 0.5.1"
    # failed list: automatic skips it, the owner's install retries it
    fresh; offer stable 0.5.1; echo 0.5.1 > $D/failed-versions; $U auto on; at UTC "2026-11-15 03:00"; $U tick
    expect not called "update --offline"; expect [ "$(st '.failedVersions[0]')" = 0.5.1 ]
    $U install now; $U tick; expect called "update --offline 0.5.1"
    # a final state stays until something new turns up
    fresh; offer stable 0.5.1; echo 0.5.1 > $D/failed-versions; $U tick
    jq '.state="rolled-back"' $D/status.json > $T/s && mv $T/s $D/status.json
    touch $D/check-now; $U tick; expect [ "$(st .state)" = rolled-back ]
    offer stable 0.5.2; touch $D/check-now; $U tick; expect [ "$(st .state)" = ready ]
    # an unreachable source keeps the state
    fresh; touch $STUBS/list-fails; $U tick; expect [ "$(st .state)" = up-to-date ]
    expect [ "$(st .detail)" = "could not reach the stable update source" ]
    # channel switch drops the other channel's download
    fresh; offer beta 0.5.3; offer stable 0.5.1; $U channel beta; $U tick; expect [ "$(cat $D/downloaded)" = 0.5.3 ]
    $U channel stable; $U tick; expect called "acquire 0.5.1"; expect [ "$(cat $D/downloaded)" = 0.5.1 ]

    echo "image-updater scenarios passed"; touch $out
  ''
