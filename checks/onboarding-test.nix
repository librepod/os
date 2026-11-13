{ pkgs }:

pkgs.runCommand "onboarding-test"
  {
    buildInputs = with pkgs; [
      bash
      qrencode
    ];
  }
  ''
    set -euo pipefail
    ROOT=$(mktemp -d)
    export CALLS_LOG="$ROOT/calls.log"
    mkdir -p "$ROOT/bin"
    export PATH="$ROOT/bin:$PATH"
    PUBLISH="${../modules/onboarding/publish-setup-code.sh}"

    cat > "$ROOT/bin/kubectl" <<'STUB'
    #!/bin/sh
    echo "kubectl $*" >> "$CALLS_LOG"
    STUB
    chmod +x "$ROOT/bin/kubectl"

    # ---- scenario 1: the installer's code → Secret marketplace-ui/librepod-setup-code
    : > "$CALLS_LOG"
    echo 7KQMX3RT9VHC > "$ROOT/setup-code"
    log="$(LIBREPOD_SETUP_CODE_FILE="$ROOT/setup-code" bash "$PUBLISH")"
    # a device without its sticker: the log shows the code, its link and the link as a QR code
    grep -qxF "Setup code: 7KQM-X3RT-9VHC" <<< "$log" \
      && grep -qF "http://$(cat /proc/sys/kernel/hostname).local/#code=7KQM-X3RT-9VHC" <<< "$log" \
      && grep -qF "█" <<< "$log" \
      || { echo "FAIL: code, link or QR code not logged: $log"; exit 1; }
    grep -qF "kubectl create secret generic librepod-setup-code --namespace marketplace-ui --from-file=code=$ROOT/setup-code --dry-run=client -o yaml" "$CALLS_LOG" \
      || { echo "FAIL: Secret not published: $(cat "$CALLS_LOG")"; exit 1; }
    [ "$(cat "$ROOT/setup-code")" = 7KQMX3RT9VHC ] || { echo "FAIL: the code was rewritten"; exit 1; }

    # ---- scenario 2: no code (installed another way) → nothing; marketplace-ui mints one
    : > "$CALLS_LOG"
    LIBREPOD_SETUP_CODE_FILE="$ROOT/absent" bash "$PUBLISH"
    [ ! -s "$CALLS_LOG" ] || { echo "FAIL: kubectl ran without a code: $(cat "$CALLS_LOG")"; exit 1; }
    [ ! -e "$ROOT/absent" ] || { echo "FAIL: a code was minted"; exit 1; }

    echo "onboarding scenarios passed"
    touch $out
  ''
