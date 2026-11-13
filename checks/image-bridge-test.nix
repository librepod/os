# checks/image-bridge-test.nix — runCommand derivation, not a module.
# Exercises modules/image-updates/bridge.sh end-to-end with a stubbed kubectl
# (a ConfigMap in a file) and a stubbed librepod-update; the stubs win because
# the bridge is built without k3s or the updater.
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
    bridge
    ;
in
pkgs.runCommand "image-bridge-test"
  {
    buildInputs = with pkgs; [
      bash
      jq
    ];
  }
  ''
    set -euo pipefail
    T=$(mktemp -d); STUBS=$T/stubs; D=$T/state
    export CALLS_LOG=$T/calls.log STUBS LIBREPOD_UPDATES_DIR=$D TZDIR=${pkgs.tzdata}/share/zoneinfo
    export PATH=$STUBS/bin:$PATH
    B=${bridge}/bin/librepod-update-bridge
    mkdir -p $STUBS/bin $D
    stub() { printf '#!/bin/sh\necho "%s $*" >> "$CALLS_LOG"\n%s\n' "$1" "$2" > $STUBS/bin/$1; chmod +x $STUBS/bin/$1; }
    # The ConfigMap is $STUBS/cm.json: reading it fails until it is created, a patch merges into it.
    stub kubectl '[ ! -e "$STUBS/kubectl-fails" ] || exit 1
    case " $* " in
      *" get configmap "*) cat "$STUBS/cm.json";;
      *" create configmap "*) echo "{\"data\":{}}" > "$STUBS/cm.json";;
      *" patch configmap "*) while [ "$1" != -p ]; do shift; done
        echo "$2" >> "$STUBS/patches"; echo "$2" | jq -s ".[0] * .[1]" "$STUBS/cm.json" /dev/stdin > "$STUBS/cm.new" && mv "$STUBS/cm.new" "$STUBS/cm.json";;
    esac'
    stub librepod-update '[ ! -e "$STUBS/update-fails" ]'
    ui() { jq --arg k "$1" --arg v "$2" '.data[$k]=$v' $STUBS/cm.json > $T/c && mv $T/c $STUBS/cm.json; }
    pub() { jq -r '.data["status.json"]' $STUBS/cm.json | jq -r "$1"; }
    called() { grep -qF -- "$1" $CALLS_LOG; }
    not() { ! "$@"; }
    has() { [[ "$1" == *"$2"* ]]; }                              # text, substring
    expect() { "$@" || { echo "FAIL: $*"; echo "--- calls"; cat $CALLS_LOG; echo "--- bridge"; cat $D/bridge.json 2>/dev/null; echo "--- cm"; cat $STUBS/cm.json 2>/dev/null; exit 1; }; }

    echo '{"state":"ready","updated":"2026-11-14T10:00:00Z","detail":"0.5.1 is ready to install"}' > $D/status.json
    export LIBREPOD_NOW=$(date -d 2026-11-14T11:00:00Z +%s)
    expect $B; expect called "create configmap librepod-os-update"; expect [ "$(pub .state)/$(pub .handled.settings)" = ready/0 ]
    expect not called marketplace-ui; expect called "-n librepod-os "
    expect called "--request-timeout=20s"

    # settings once per rev
    ui settings.json '{"rev":3,"channel":"beta","auto":true,"timezone":"Europe/Minsk"}'; expect $B
    expect called "librepod-update channel beta"; expect called "librepod-update auto on"; expect called "librepod-update timezone Europe/Minsk"
    expect [ "$(pub .handled.settings)" = 3 ]
    : > $CALLS_LOG; expect $B; expect not called "librepod-update"
    ui settings.json '{"rev":2,"channel":"stable","auto":false,"timezone":"UTC"}'; expect $B; expect not called "librepod-update"
    expect [ "$(pub .handled.settings)" = 3 ]

    # install once per id
    ui install.json '{"id":7,"when":"now"}'; expect $B; expect called "librepod-update install now"; expect [ "$(pub .handled.install)" = 7 ]
    : > $CALLS_LOG; expect $B; expect not called "librepod-update"

    # hostile input: nothing applied, recorded as handled, shown in detail
    rev=10; for bad in '"channel":"nightly","auto":true,"timezone":"UTC"' '"channel":"beta","auto":"yes","timezone":"UTC"' \
                       '"channel":"beta","auto":true,"timezone":"../../etc/shadow"' '"channel":"beta","auto":true,"timezone":"Europe/Minsk; reboot"' \
                       '"channel":"beta","auto":true,"timezone":7' '"channel":"beta","auto":true'; do
      : > $CALLS_LOG; ui settings.json "{\"rev\":$rev,$bad}"; expect $B; expect not called "librepod-update"
      expect [ "$(pub .handled.settings)" = $rev ]; expect has "$(pub .detail)" "settings rev $rev rejected"; rev=$((rev+1))
    done
    # no usable rev: nothing applied, nothing recorded, nothing shown
    for bad in '{"channel":"beta","auto":true,"timezone":"UTC"}' '{"rev":"20","channel":"beta","auto":true,"timezone":"UTC"}' \
               '{"rev":20.5,"channel":"beta","auto":true,"timezone":"UTC"}' '{"rev":0,"channel":"beta","auto":true,"timezone":"UTC"}' \
               '{"rev":1e30,"channel":"beta","auto":true,"timezone":"UTC"}' '{"rev":"20; reboot","channel":"beta","auto":true,"timezone":"UTC"}' \
               'not json' '[]' '5'; do
      : > $CALLS_LOG; ui settings.json "$bad"; expect $B; expect not called "librepod-update"
      expect [ "$(pub .handled.settings)" = 15 ]; expect has "$(pub .detail)" "settings rev 15 rejected"
    done
    for bad in '{"id":8,"when":"later"}' '{"id":"9; reboot","when":"now"}' '{"id":9.5,"when":"now"}' '{"id":0,"when":"now"}' 'not json' '[]'; do
      : > $CALLS_LOG; ui install.json "$bad"; expect $B; expect not called "librepod-update"
    done
    expect [ "$(pub .handled.install)" = 8 ]; expect has "$(pub .detail)" "install id 8 rejected"

    # a rejection keeps its time when its detail has not changed
    at=$(jq -r .rejected.at $D/bridge.json); jq '.install = 7' $D/bridge.json > $T/b && mv $T/b $D/bridge.json
    ui install.json '{"id":8,"when":"later"}'; LIBREPOD_NOW=$((LIBREPOD_NOW + 60)) expect $B
    expect [ "$(jq -r .rejected.at $D/bridge.json)" = "$at" ]

    # rejection shows until the updater's status moves on
    jq '.updated="2026-11-14T12:00:00Z" | .detail="downloading 0.5.2"' $D/status.json > $T/s && mv $T/s $D/status.json
    expect $B; expect [ "$(pub .detail)" = "downloading 0.5.2" ]

    # an answer the updater could not take is not recorded: the next run applies it
    ui settings.json '{"rev":30,"channel":"stable","auto":false,"timezone":"UTC"}'; : > $CALLS_LOG
    touch $STUBS/update-fails; expect not $B; expect called "librepod-update channel stable"; expect [ "$(jq .settings $D/bridge.json)" = 15 ]
    rm $STUBS/update-fails; expect $B; expect [ "$(pub .handled.settings)" = 30 ]
    # the settings are recorded even when the install that follows fails
    ui settings.json '{"rev":31,"channel":"stable","auto":false,"timezone":"UTC"}'; ui install.json '{"id":9,"when":"tonight"}'
    stub librepod-update '[ "$1" != install ]'; expect not $B; expect [ "$(jq -c "[.settings, .install]" $D/bridge.json)" = "[31,8]" ]
    stub librepod-update '[ ! -e "$STUBS/update-fails" ]'; expect $B; expect called "librepod-update install tonight"; expect [ "$(pub .handled.install)" = 9 ]
    # kubectl failing is a failed run too
    touch $STUBS/kubectl-fails; expect not $B; rm $STUBS/kubectl-fails

    # published on change, and again when the ConfigMap lost it
    : > $STUBS/patches; expect $B; expect [ ! -s $STUBS/patches ]
    echo '{"metadata":{}}' > $STUBS/cm.json; expect $B; expect [ "$(pub .state)" = ready ]
    expect [ "$(jq -c 'keys' $STUBS/patches)" = '["data"]' ]; expect [ "$(jq -c '.data | keys' $STUBS/patches)" = '["status.json"]' ]

    echo "image-bridge scenarios passed"; touch $out
  ''
