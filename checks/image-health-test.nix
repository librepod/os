# checks/image-health-test.nix — runCommand derivation, not a module.
# Exercises modules/image-updates/health.sh end-to-end with stubbed systemctl,
# k3s, curl and gpgv; the stubs win because the gate is built without them.
{ pkgs }:

let
  inherit
    (import ../modules/image-updates/scripts.nix {
      inherit (pkgs) writeShellApplication;
      runtimeInputs = with pkgs; [
        jq
        coreutils
        gnugrep
      ];
    })
    health
    ;
in
pkgs.runCommand "image-health-test"
  {
    buildInputs = with pkgs; [
      bash
      jq
    ];
  }
  ''
    set -euo pipefail
    T=$(mktemp -d); STUBS=$T/stubs; D=$T/state
    mkdir -p $STUBS/bin $T/tmp
    echo '{"stable":"http://stable.invalid/","beta":"http://beta.invalid/"}' > $T/channels.json
    export CALLS_LOG=$T/calls.log STUBS LIBREPOD_UPDATES_DIR=$D LIBREPOD_CHANNELS=$T/channels.json \
      LIBREPOD_PUBRING=$T/pubring.pgp LIBREPOD_HEALTH_DEADLINE=6 LIBREPOD_HEALTH_STABLE=2 \
      LIBREPOD_POLL_INTERVAL=1 TMPDIR=$T/tmp
    export PATH=$STUBS/bin:$PATH
    H=${health}/bin/librepod-update-health
    stub() { printf '#!/bin/sh\necho "%s $*" >> "$CALLS_LOG"\n%s\n' "$1" "$2" > $STUBS/bin/$1; chmod +x $STUBS/bin/$1; }
    stub systemctl 'for unit; do :; done; [ ! -e "$STUBS/down-$unit" ]'
    stub k3s 'cat "$STUBS/ready"'
    stub curl 'while [ $# -gt 1 ]; do [ "$1" != -o ] || out=$2; shift; done
    f=$STUBS/srv/$(basename "$1"); [ -e "$f" ] && cp "$f" "$out"'
    stub gpgv '[ ! -e "$STUBS/bad-sig" ]'
    fresh() { rm -rf $D $STUBS/down-* $STUBS/bad-sig; mkdir -p $D $STUBS/srv; echo True > $STUBS/ready
              touch $STUBS/srv/SHA256SUMS $STUBS/srv/SHA256SUMS.gpg; : > $CALLS_LOG
              echo '{"from":"0.5.0","to":"0.5.1","phase":"installed"}' > $D/record.json; }
    reason() { jq -r .reason $D/record.json; }
    called() { grep -qF -- "$1" $CALLS_LOG; }
    not() { ! "$@"; }
    expect() { "$@" || { echo "FAIL: $*"; echo "--- calls"; cat $CALLS_LOG; echo "--- record"; cat $D/record.json 2>/dev/null; exit 1; }; }

    # healthy: the source is fetched and checked, but only after the stable period
    fresh; s=$SECONDS; expect $H; expect [ $((SECONDS - s)) -ge 1 ]
    expect called "http://stable.invalid/SHA256SUMS"; expect called "gpgv --keyring $T/pubring.pgp"
    expect [ "$(jq -c . $D/record.json)" = '{"from":"0.5.0","to":"0.5.1","phase":"installed"}' ]
    fresh; echo '{"channel":"beta","auto":false,"timezone":"UTC"}' > $D/settings.json; expect $H; expect called "http://beta.invalid/SHA256SUMS.gpg"

    # each failing check is the reason, and nothing is fetched while one fails
    fresh; touch $STUBS/down-k3s; expect not $H; expect [ "$(reason)" = k3s ]; expect not called curl
    fresh; touch $STUBS/down-sshd; expect not $H; expect [ "$(reason)" = sshd ]; expect not called curl
    fresh; echo False > $STUBS/ready; expect not $H; expect [ "$(reason)" = node-not-ready ]; expect not called curl
    fresh; touch $STUBS/down-k3s $STUBS/down-sshd; expect not $H; expect [ "$(reason)" = k3s ]   # the first to fail
    fresh; touch $STUBS/bad-sig; expect not $H; expect [ "$(reason)" = update-source ]
    fresh; rm $STUBS/srv/SHA256SUMS.gpg; expect not $H; expect [ "$(reason)" = update-source ]
    fresh; echo '{"stable":"http://stable.invalid/"}' > $T/channels.json; echo '{"channel":"beta"}' > $D/settings.json
    expect not $H; expect [ "$(reason)" = update-source ]; expect not called curl         # no URL for the channel
    echo '{"stable":"http://stable.invalid/","beta":"http://beta.invalid/"}' > $T/channels.json

    # a record that isn't there, or isn't an object, is left alone
    fresh; rm $D/record.json; touch $STUBS/down-k3s; expect not $H; expect [ ! -e $D/record.json ]
    fresh; echo garbage > $D/record.json; touch $STUBS/down-k3s; expect not $H; expect [ "$(cat $D/record.json)" = garbage ]
    fresh; echo '[1]' > $D/record.json; touch $STUBS/down-k3s; expect not $H; expect [ "$(cat $D/record.json)" = '[1]' ]

    # downloads don't outlive the gate
    expect [ -z "$(ls $T/tmp)" ]

    echo "image-health scenarios passed"; touch $out
  ''
