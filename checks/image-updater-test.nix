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
        util-linux
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
      util-linux
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
    stub systemctl 'case "$*" in "start k3s"*) r=no; [ ! -e "$LIBREPOD_UPDATES_DIR/record.json" ] || r=yes; echo "record=$r" >> "$CALLS_LOG";;
      "stop k3s"*) [ ! -e "$STUBS/cut-on-stop" ] || kill -9 $PPID;; esac'
    stub systemd-bless-boot 'cat "$STUBS/bless-status"; [ ! -e "$STUBS/bless-fails" ]'
    # list as 260 answers it: `list` names every version, a download held in the
    # slot (STUBS/held, any channel's) too; `list V` says whether the source has V.
    stub systemd-sysupdate '
    ch=; last=; for a; do case $a in --definitions=*) ch=''${a##*/};; esac; last=$a; done
    new=$(cat "$STUBS/new-$ch" 2>/dev/null || true)
    case " $* " in
      *" list "*) [ ! -e "$STUBS/list-fails" ] || exit 1
        case $last in
          list) printf "{\"all\":[%s]}\n" "$(for v in $(cat "$STUBS/held" 2>/dev/null) $new; do printf "\"%s\"," "$v"; done | sed "s/,\$//")";;
          *) a=false; [ "$last" != "$new" ] || a=true; echo "{\"version\":\"$last\",\"available\":$a}";;
        esac;;
      *" acquire "*) if [ -e "$STUBS/press-now-during-acquire" ]; then rm "$STUBS/press-now-during-acquire"; echo now > "$LIBREPOD_UPDATES_DIR/request"; fi
                     [ ! -e "$STUBS/acquire-fails" ];;
      *" update "*) [ ! -e "$STUBS/update-fails" ];;
      *" pending "*) [ -e "$STUBS/pending" ];; # 260 says yes while a download is acquired
    esac'
    fresh() { rm -rf $D $T/run $T/db $T/db.restore $STUBS/new-* $STUBS/*-fails $STUBS/pending $STUBS/held; mkdir -p $D $T/run $T/db
              echo before > $T/db/state.db; booted 0.5.0; echo good > $STUBS/bless-status; : > $CALLS_LOG; unset LIBREPOD_NOW; }
    booted() { echo "IMAGE_VERSION=$1" > $LIBREPOD_OS_RELEASE; }
    offer() { echo "$2" > $STUBS/new-$1; }                       # channel, version
    at() { export LIBREPOD_NOW=$(TZ=$1 date -d "$2" +%s); }      # zone, local time
    st() { jq -r "$1" $D/status.json; }
    called() { grep -qF -- "$1" $CALLS_LOG; }
    not() { ! "$@"; }
    has() { [[ "$1" == *"$2"* ]]; }                              # text, substring
    rec() { echo "$1" > $D/record.json; }
    snap() { mkdir -p $D/k3s-db && echo "$1" > $D/k3s-db/state.db; }
    # An exported function beats the updater's own PATH (its runtimeInputs go first).
    sync() { [ ! -e "$STUBS/sync-fails" ] || [ "$*" != "$LIBREPOD_UPDATES_DIR" ] || return 1; command sync "$@"; }
    export -f sync
    # A cut during the snapshot's copy: part of the data is written, then the updater dies without its trap.
    cp() { [ ! -e "$STUBS/cut-in-cp" ] || { mkdir -p "''${!#}"; echo junk > "''${!#}/state.db"; kill -9 $$; }; command cp "$@"; }
    export -f cp
    # A cut while a snapshot is deleted: its state.db goes, then the updater dies.
    rm() { if [ -e "$STUBS/cut-in-rm" ]; then for a; do case $a in */k3s-db | */k3s-db.partial) [ ! -e "$a" ] || { command rm -f "$a/state.db"; kill -9 $$; };; esac; done; fi; command rm "$@"; }
    export -f rm
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
    expect called "--definitions=/defs/stable --json=short list"; expect called "acquire 0.5.1"
    expect [ "$(st .available)/$(st .downloaded)/$(st .state)" = 0.5.1/true/ready ]; expect not called "update --offline"
    rm -rf $T/run; expect $U tick; expect [ -e $T/run/checked ]          # the tick makes its own run dir
    # never a lower version
    fresh; offer stable 0.4.9; expect $U tick; expect [ "$(st .available)" = null ]; expect not called acquire
    # once per boot, then every 6 h
    fresh; offer stable 0.5.1; at UTC "2026-11-14 12:00"; $U tick; : > $CALLS_LOG; $U tick; expect not called "short list"
    at UTC "2026-11-14 18:00"; $U tick; expect called "short list"
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
    expect called "record=no"; expect not called "record=yes"
    expect grep -qx 0.5.1 $D/failed-versions
    $U install now; $U tick; expect [ "$(grep -cx 0.5.1 $D/failed-versions)" = 1 ]   # the owner retries it; no second line
    # a failure before update --offline (cp on a full disk) takes the same way out
    fresh; offer stable 0.5.1; dd if=/dev/zero of=$T/db/big bs=1k count=16 2>/dev/null; $U install now
    ( ulimit -c 0; ulimit -f 4; expect not $U tick 2>/dev/null )
    expect not called "update --offline"; expect not called reboot; expect called "start k3s"
    expect called "record=no"; expect not called "record=yes"
    expect [ ! -e $D/record.json ]; expect [ ! -e $D/k3s-db ]; expect [ ! -e $D/k3s-db.partial ]
    expect [ "$(st .state)" = failed ]; expect grep -qx 0.5.1 $D/failed-versions
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
    # a failed version isn't downloaded again unless the owner asks, and its final state stays
    fresh; offer stable 0.5.1; echo 0.5.1 > $D/failed-versions
    echo '{"state":"rolled-back","available":null,"lastCheck":null,"installAt":null,"detail":"d"}' > $D/status.json
    expect $U tick; expect [ "$(st .state)" = rolled-back ]; expect not called acquire
    $U install now; expect $U tick; expect called "acquire 0.5.1"; expect called "update --offline 0.5.1"
    # a failed download stays failed, not tried again until a check or the owner's install; a newer version is
    fresh; offer stable 0.5.1; touch $STUBS/acquire-fails; $U auto on; at UTC "2026-11-15 01:00"; $U tick
    expect [ "$(st .state)/$(st .detail)" = "failed/could not download 0.5.1" ]
    : > $CALLS_LOG; $U tick; at UTC "2026-11-15 03:00"; $U tick                     # the window's own check too
    expect not called acquire; expect [ "$(st .state)/$(st .detail)" = "failed/could not download 0.5.1" ]
    $U check; $U tick; expect called "acquire 0.5.1"
    : > $CALLS_LOG; $U install now; $U tick; expect called "acquire 0.5.1"
    offer stable 0.5.2; : > $CALLS_LOG; $U tick; expect called "acquire 0.5.2"
    # the update's own boot: a stale available is not the booted version's to install
    fresh; booted 0.5.1; touch $STUBS/list-fails
    echo '{"state":"done","available":"0.5.1","lastCheck":null,"installAt":null,"detail":"d"}' > $D/status.json
    expect $U tick; expect not called acquire; expect [ "$(st .state)" = done ]
    # an unreachable source keeps the state
    fresh; touch $STUBS/list-fails; $U tick; expect [ "$(st .state)" = up-to-date ]
    expect [ "$(st .detail)" = "could not reach the stable update source" ]
    # channel switch drops the other channel's download
    fresh; offer beta 0.5.3; offer stable 0.5.1; $U channel beta; $U tick; expect [ "$(cat $D/downloaded)" = 0.5.3 ]
    $U channel stable; $U tick; expect called "acquire 0.5.1"; expect [ "$(cat $D/downloaded)" = 0.5.1 ]
    # another channel's download held in the slot is not what this channel offers
    fresh; offer stable 0.5.2; echo 0.5.3 > $STUBS/held; $U tick
    expect [ "$(st .available)" = 0.5.2 ]; expect called "acquire 0.5.2"

    # ---- fixes carried from the install's review ------------------------------
    # a failing final sync in the record's write still ends in the one way out
    fresh; at UTC "2026-11-14 12:00"; offer stable 0.5.1; $U tick; $U install now; touch $STUBS/sync-fails
    expect not $U tick
    expect [ ! -e $D/record.json ]; expect called "start k3s"; expect not called reboot
    # spring forward: 02:00 does not exist that night, so 03:00
    fresh; offer stable 0.5.1; $U timezone Europe/Berlin; $U auto on; at Europe/Berlin "2026-03-29 00:30"; $U tick
    expect [ "$(st .installAt)" = 2026-03-29T03:00:00+02:00 ]
    # an unreachable source downloads nothing: a stale available belongs to the old channel
    fresh; offer stable 0.5.1; $U tick; $U channel beta; touch $STUBS/list-fails; : > $CALLS_LOG; $U tick
    expect not called acquire; expect [ "$(st .state)" != downloading ]
    # a snapshot left from before is not the one to restore after a later install is cut mid-copy
    fresh; at UTC "2026-11-14 12:00"; offer stable 0.5.1; $U tick; snap stale; touch $STUBS/cut-in-cp
    $U install now; expect not $U tick 2>/dev/null; rm $STUBS/cut-in-cp
    expect [ -e $D/record.json ]; $U fallback; expect [ "$(cat $T/db/state.db)" = before ]
    # a cut right after the record is written, with an older snapshot around: not the one to restore
    fresh; at UTC "2026-11-14 12:00"; offer stable 0.5.1; $U tick; snap stale; touch $STUBS/cut-on-stop
    $U install now; expect not $U tick 2>/dev/null; rm $STUBS/cut-on-stop
    expect [ -e $D/record.json ]; $U fallback; expect [ "$(cat $T/db/state.db)" = before ]
    # a cut while the snapshot is dropped after a restore: what is left is never restored over the data
    fresh; rec '{"from":"0.5.0","to":"0.5.1","phase":"installed"}'; snap before; echo after > $T/db/state.db; touch $STUBS/cut-in-rm
    expect not $U fallback 2>/dev/null; rm $STUBS/cut-in-rm
    expect [ -e $D/record.json ]; $U fallback; expect [ "$(cat $T/db/state.db)" = before ]
    # a .partial left by an interrupted drop is never restored
    fresh; rec '{"from":"0.5.0","to":"0.5.1","phase":"installed"}'; mkdir $D/k3s-db.partial; echo junk > $D/k3s-db.partial/state.db
    echo after > $T/db/state.db; $U fallback; expect [ "$(cat $T/db/state.db)" = after ]; expect [ ! -e $D/k3s-db.partial ]
    # status rewrites take turns: the CLI waits for one in progress
    fresh; rm -f $T/held $T/released
    ( exec 8> $D/.status.lock; flock 8; : > $T/held; sleep 1; : > $T/released ) &
    while [ ! -e $T/held ]; do sleep 0.05; done
    expect $U status; expect [ -e $T/released ]; wait

    # ---- after the reboot: fallback and finish --------------------------------
    # rolled back: restored, failed list, vacuumed for a retry
    fresh; rec '{"from":"0.5.0","to":"0.5.1","phase":"installed","reason":"node-not-ready"}'
    snap before; echo after > $T/db/state.db; echo 0.5.1 > $D/downloaded; $U fallback
    expect [ "$(cat $T/db/state.db)" = before ]; expect [ "$(st .state)" = rolled-back ]
    expect grep -qx 0.5.1 $D/failed-versions; expect has "$(st .detail)" node-not-ready
    expect called "vacuum --instances-max=1"
    expect [ ! -e $D/record.json ]; expect [ ! -e $D/k3s-db ]; expect [ ! -e $D/downloaded ]; expect [ ! -e $T/db.restore ]
    # no reason: it never got as far as the gate
    fresh; rec '{"from":"0.5.0","to":"0.5.1","phase":"installed"}'; snap before; $U fallback
    expect has "$(st .detail)" "did not finish"
    # interrupted after a complete snapshot: restored, not in the failed list, download kept,
    # though the download is acquired (sysupdate pending would say a newer version is installed)
    fresh; rec '{"from":"0.5.0","to":"0.5.1","phase":"snapshot"}'; snap before; echo 0.5.1 > $D/downloaded
    touch $STUBS/pending; $U fallback
    expect [ "$(st .state)" = failed ]; expect has "$(st .detail)" interrupted
    expect not grep -qsx 0.5.1 $D/failed-versions; expect [ -e $D/downloaded ]; expect not called vacuum
    # interrupted mid-copy: a partial snapshot is never restored
    fresh; rec '{"from":"0.5.0","to":"0.5.1","phase":"snapshot"}'; mkdir $D/k3s-db.partial; echo junk > $D/k3s-db.partial/state.db
    $U fallback; expect [ "$(cat $T/db/state.db)" = before ]; expect [ ! -e $D/k3s-db.partial ]
    # phase never written, but the new version booted and its gate gave a reason
    fresh; rec '{"from":"0.5.0","to":"0.5.1","phase":"snapshot","reason":"k3s"}'; snap before; $U fallback
    expect [ "$(st .state)" = rolled-back ]
    # on the new version: left to the health gate
    fresh; booted 0.5.1; rec '{"from":"0.5.0","to":"0.5.1","phase":"installed"}'; echo after > $T/db/state.db; $U fallback
    expect [ -e $D/record.json ]; expect [ "$(cat $T/db/state.db)" = after ]
    # unreadable record: moved aside, updates go on
    fresh; echo garbage > $D/record.json; $U fallback; expect [ -e $D/record.json.bad ]; expect [ "$(st .state)" = failed ]
    offer stable 0.5.1; $U tick; expect called "acquire 0.5.1"
    # a failed restore keeps the record, the snapshot and the data as they were
    fresh; rec '{"from":"0.5.0","to":"0.5.1","phase":"installed"}'; snap before; echo after > $T/db/state.db
    dd if=/dev/zero of=$D/k3s-db/big bs=1k count=16 2>/dev/null
    ( ulimit -c 0; ulimit -f 4; expect not $U fallback 2>/dev/null )
    expect [ -e $D/record.json ]; expect [ -e $D/k3s-db/state.db ]; expect [ "$(cat $T/db/state.db)" = after ]
    expect has "$(st .detail)" "could not restore k3s data from before 0.5.1"; expect not grep -qsx 0.5.1 $D/failed-versions
    # finish: only once blessed; a failing bless-boot is not blessed
    fresh; booted 0.5.1; rec '{"from":"0.5.0","to":"0.5.1","phase":"installed"}'; snap before; echo 0.5.1 > $D/failed-versions
    echo indeterminate > $STUBS/bless-status; expect $U finish; expect [ -e $D/record.json ]
    echo good > $STUBS/bless-status; touch $STUBS/bless-fails; expect $U finish; expect [ -e $D/record.json ]
    rm $STUBS/bless-fails; expect env LIBREPOD_BLESS_BOOT=$T/no-such-bless-boot $U finish; expect [ -e $D/record.json ]
    $U finish
    expect [ "$(st .state)" = done ]; expect [ ! -e $D/record.json ]; expect [ ! -e $D/k3s-db ]
    expect not grep -qsx 0.5.1 $D/failed-versions
    # tick finishes a record left over from a power cut after blessing
    fresh; booted 0.5.1; rec '{"from":"0.5.0","to":"0.5.1","phase":"installed"}'; echo clean > $STUBS/bless-status
    $U tick; expect [ "$(st .state)" = done ]

    echo "image-updater scenarios passed"; touch $out
  ''
