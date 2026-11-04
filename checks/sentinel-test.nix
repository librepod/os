{ pkgs }:

let
  # The package modules/updates ships; the stubs below stand in for nix, k3s
  # and systemd.
  inherit
    (import ../modules/updates/scripts.nix {
      inherit (pkgs) writeShellApplication;
      runtimeInputs = [ pkgs.jq ];
    })
    sentinel
    ;
in
pkgs.runCommand "sentinel-test"
  {
    buildInputs = with pkgs; [
      bash
      jq
    ];
  }
  ''
    set -euo pipefail
    ROOT=$(mktemp -d)
    export CALLS_LOG="$ROOT/calls.log"
    : > "$CALLS_LOG"
    export PATH="$ROOT/bin:$PATH"

    SENTINEL="${sentinel}/bin/librepod-update-sentinel"

    # OLD and NEW toplevels, each with a switch-to-configuration that logs.
    mkdir -p "$ROOT/bin" "$ROOT/state" "$ROOT/flake"
    for sys in old new; do
      mkdir -p "$ROOT/$sys/bin"
      cat > "$ROOT/$sys/bin/switch-to-configuration" <<EOF
    #!/bin/sh
    echo "$sys switch-to-configuration \$*" >> "$CALLS_LOG"
    # the boot loader takes no writes (ESP full) for the systems in FAKE_STC_FAIL
    case " \$FAKE_STC_FAIL " in *" $sys "*) exit 1;; esac
    EOF
      chmod +x "$ROOT/$sys/bin/switch-to-configuration"
    done
    # the booted release the shared report/current_version read
    echo v0.4.0 > "$ROOT/release"

    cat > "$ROOT/bin/k3s" <<'EOF'
    #!/bin/sh
    echo "k3s $*" >> "$CALLS_LOG"
    case "$*" in
      *"get node"*) cat "$HEALTH_FILE" 2>/dev/null || true;;
    esac
    EOF
    chmod +x "$ROOT/bin/k3s"

    cat > "$ROOT/bin/systemctl" <<EOF
    #!/bin/sh
    echo "systemctl \$*" >> "$CALLS_LOG"
    case " \$* " in
      *" is-active "*) [ -f "\$HEALTH_FILE" ] && echo active || echo inactive;;
    esac
    EOF
    chmod +x "$ROOT/bin/systemctl"

    # the "can NEW fetch updates?" check
    cat > "$ROOT/bin/nix" <<EOF
    #!/bin/sh
    echo "nix \$*" >> "$CALLS_LOG"
    [ -z "\$FAKE_NO_FETCH" ]
    EOF
    chmod +x "$ROOT/bin/nix"

    cat > "$ROOT/bin/nix-env" <<EOF
    #!/bin/sh
    echo "nix-env \$*" >> "$CALLS_LOG"
    EOF
    chmod +x "$ROOT/bin/nix-env"

    export LIBREPOD_STATE_DIR="$ROOT/state" \
           LIBREPOD_NODE_NAME="pod-test" \
           LIBREPOD_FLAKE_DIR="$ROOT/flake" \
           LIBREPOD_RELEASE_FILE="$ROOT/release" \
           LIBREPOD_CURRENT_SYSTEM="$ROOT/current-system" \
           LIBREPOD_HEALTH_TIMEOUT=0 LIBREPOD_HEALTH_STABLE=0 LIBREPOD_POLL_INTERVAL=0 \
           LIBREPOD_PROFILE="$ROOT/profile"
    export HEALTH_FILE="$ROOT/health"

    # A fresh boot: the booted system, an update in flight in the given phase,
    # the device flake on the old pin and the updater's staged copy on the new.
    boot() { # old|new, phase
      : > "$CALLS_LOG"
      ln -sfn "$1" "$ROOT/current-system"   # relative, like /run/current-system
      jq -nc --arg from "$ROOT/old" --arg to "$ROOT/new" --arg p "$2" \
        '{from:$from, to:$to, version:"v9.9.9", requestId:7, phase:$p}' > "$ROOT/state/update-pending"
      printf 'old-pin\n' > "$ROOT/flake/flake.nix"
      printf 'old-lock\n' > "$ROOT/flake/flake.lock"
      mkdir -p "$ROOT/state/staged"
      printf 'new-pin\n' > "$ROOT/state/staged/flake.nix"
      printf 'new-lock\n' > "$ROOT/state/staged/flake.lock"
      rm -f "$ROOT/state/failed-versions"
      echo 7 > "$ROOT/state/request-id"   # the updater recorded the request
    }
    committed() {
      grep -qx "nix-env -p $ROOT/profile --set $ROOT/new" "$CALLS_LOG" \
        || { echo "FAIL: profile not set to NEW"; exit 1; }
      grep -qx "new switch-to-configuration boot" "$CALLS_LOG" \
        || { echo "FAIL: NEW not made the default"; exit 1; }
      [ "$(cat "$ROOT/flake/flake.nix" "$ROOT/flake/flake.lock")" = "$(printf 'new-pin\nnew-lock')" ] \
        || { echo "FAIL: commit did not take the staged pin"; exit 1; }
      test ! -e "$ROOT/state/staged" \
        || { echo "FAIL: staged copy not cleared on commit"; exit 1; }
    }
    flake_untouched() {
      [ "$(cat "$ROOT/flake/flake.nix" "$ROOT/flake/flake.lock")" = "$(printf 'old-pin\nold-lock')" ] \
        || { echo "FAIL: the device flake changed"; exit 1; }
    }

    # ---- scenario 1: healthy trial → commit --------------------------------
    echo "True" > "$ROOT/health"   # node Ready condition status
    boot new trial
    bash "$SENTINEL"
    committed
    grep -qx "nix flake metadata --refresh github:librepod/os/v9.9.9" "$CALLS_LOG" \
      || { echo "FAIL: committed without checking it can fetch updates"; exit 1; }
    grep -q "label node pod-test librepod.os/version=v9.9.9" "$CALLS_LOG" \
      || { echo "FAIL: success label missing"; exit 1; }
    grep -qF 'state\": \"done' "$CALLS_LOG" && grep -qF 'observedRequestId\": 7' "$CALLS_LOG" \
      || { echo "FAIL: done not reported for request 7"; exit 1; }
    test ! -e "$ROOT/state/update-pending" \
      || { echo "FAIL: flag not cleared on success"; exit 1; }
    ! grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: rebooted after a commit on NEW"; exit 1; }

    # ---- scenario 2: unhealthy trial → reboot, OLD is still the default ----
    echo "NotReady" > "$ROOT/health"
    boot new trial
    bash "$SENTINEL"
    grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: no reboot after failed health checks"; exit 1; }
    ! grep -q "nix-env\|switch-to-configuration" "$CALLS_LOG" \
      || { echo "FAIL: an unhealthy trial touched the profile or boot entries"; exit 1; }
    jq -e '.phase == "trial" and .reason == "unhealthy"' "$ROOT/state/update-pending" >/dev/null \
      || { echo "FAIL: the OLD boot needs update-pending and the reason to report the failure"; exit 1; }
    flake_untouched

    # ---- scenario 3: back on OLD after the trial → failed, recorded --------
    # No reason in update-pending: NEW never got as far as the sentinel.
    boot old trial
    bash "$SENTINEL"
    grep -qx v9.9.9 "$ROOT/state/failed-versions" \
      || { echo "FAIL: failed version not recorded"; exit 1; }
    grep -qF 'state\": \"rolled_back' "$CALLS_LOG" && grep -qF 'currentVersion\": \"v0.4.0' "$CALLS_LOG" \
      || { echo "FAIL: rolled_back on v0.4.0 not reported"; exit 1; }
    grep -qF '(trial-did-not-finish)' "$CALLS_LOG" \
      || { echo "FAIL: rolled_back detail does not say the trial did not finish"; exit 1; }
    test ! -e "$ROOT/state/update-pending" && test ! -e "$ROOT/state/staged" \
      || { echo "FAIL: update-pending or the staged copy left behind"; exit 1; }
    ! grep -q "systemctl reboot\|nix-env" "$CALLS_LOG" \
      || { echo "FAIL: the OLD boot rebooted or touched the profile"; exit 1; }
    flake_untouched

    # ---- scenario 4: power cut before the trial → cleared, nothing failed --
    boot old staged
    bash "$SENTINEL"
    test ! -e "$ROOT/state/failed-versions" \
      || { echo "FAIL: an update that never ran was recorded as failed"; exit 1; }
    grep -qF 'state\": \"idle' "$CALLS_LOG" \
      || { echo "FAIL: idle not reported"; exit 1; }
    grep -qx "nix-env -p $ROOT/profile --set $ROOT/old" "$CALLS_LOG" \
      || { echo "FAIL: profile not set back to FROM"; exit 1; }
    test ! -e "$ROOT/state/update-pending" && test ! -e "$ROOT/state/staged" \
      || { echo "FAIL: update-pending or the staged copy left behind"; exit 1; }
    flake_untouched

    # ---- scenario 5: power cut mid-commit → finish it, then boot NEW -------
    # The cut came after the profile switch and before the boot entries, so
    # the machine came back on OLD.
    boot old committing
    bash "$SENTINEL"
    committed
    grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: commit on OLD did not reboot into NEW"; exit 1; }
    jq -e '.phase == "committing"' "$ROOT/state/update-pending" >/dev/null \
      || { echo "FAIL: the NEW boot needs update-pending to report done"; exit 1; }
    : > "$CALLS_LOG"
    ln -sfn new "$ROOT/current-system"
    echo v9.9.9 > "$ROOT/release"
    bash "$SENTINEL"
    grep -qF 'state\": \"done' "$CALLS_LOG" && grep -qF 'currentVersion\": \"v9.9.9' "$CALLS_LOG" \
      || { echo "FAIL: done on v9.9.9 not reported after the interrupted commit"; exit 1; }
    test ! -e "$ROOT/state/update-pending" \
      || { echo "FAIL: flag not cleared after the interrupted commit"; exit 1; }
    ! grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: rebooted again on NEW"; exit 1; }

    # ---- scenario 6: healthy, but cannot fetch updates → never committed --
    echo "True" > "$ROOT/health"
    echo v0.4.0 > "$ROOT/release"
    boot new trial
    FAKE_NO_FETCH=1 bash "$SENTINEL"
    grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: a trial that cannot fetch updates did not end"; exit 1; }
    ! grep -q "nix-env\|switch-to-configuration" "$CALLS_LOG" \
      || { echo "FAIL: a trial that cannot fetch updates was committed"; exit 1; }
    flake_untouched
    # The OLD boot that follows names the reason (GitHub #18).
    : > "$CALLS_LOG"
    ln -sfn old "$ROOT/current-system"
    bash "$SENTINEL"
    grep -qF 'state\": \"rolled_back' "$CALLS_LOG" && grep -qF '(update-source-unreachable)' "$CALLS_LOG" \
      || { echo "FAIL: rolled_back detail does not name update-source-unreachable"; exit 1; }

    # ---- scenario 7: the commit can't write NEW's entries → OLD again -------
    boot new trial
    FAKE_STC_FAIL=new bash "$SENTINEL"
    grep -qx "nix-env -p $ROOT/profile --set $ROOT/old" "$CALLS_LOG" \
      && grep -qx "old switch-to-configuration boot" "$CALLS_LOG" \
      || { echo "FAIL: OLD not made the default again"; exit 1; }
    grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: a trial that could not commit did not end"; exit 1; }
    jq -e '.phase == "trial" and .reason == "commit-failed"' "$ROOT/state/update-pending" >/dev/null \
      || { echo "FAIL: the OLD boot needs update-pending and the reason"; exit 1; }
    flake_untouched
    : > "$CALLS_LOG"
    ln -sfn old "$ROOT/current-system"
    bash "$SENTINEL"
    grep -qF '(commit-failed)' "$CALLS_LOG" && grep -qx v9.9.9 "$ROOT/state/failed-versions" \
      || { echo "FAIL: the OLD boot did not report commit-failed"; exit 1; }

    # ---- scenario 8: no entries can be written at all → failed, no reboot --
    boot new trial
    if FAKE_STC_FAIL="new old" bash "$SENTINEL"; then
      echo "FAIL: a commit with no boot entries written exited 0"; exit 1
    fi
    grep -qF 'state\": \"failed' "$CALLS_LOG" && ! grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: not reported as failed, or rebooted into an unknown default"; exit 1; }
    jq -e '.phase == "committing"' "$ROOT/state/update-pending" >/dev/null \
      || { echo "FAIL: the next boot can't retry the commit"; exit 1; }

    echo "sentinel scenarios passed"
    touch $out
  ''
