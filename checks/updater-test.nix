# checks/updater-test.nix — runCommand derivation, not a module.
# Exercises modules/updates/updater.sh end-to-end with stubbed nix/kubectl.
{ pkgs }:

let
  # The package modules/updates ships; the stubs below stand in for nix, k3s
  # and systemd.
  inherit
    (import ../modules/updates/scripts.nix {
      inherit (pkgs) writeShellApplication;
      runtimeInputs = [ pkgs.jq ];
    })
    updater
    ;
in
pkgs.runCommand "updater-test"
  {
    buildInputs = with pkgs; [
      bash
      jq
    ];
  }
  ''
    set -euo pipefail
    STUBS=$(mktemp -d)
    LOG="$STUBS/calls.log"
    export CALLS_LOG="$LOG"
    FLAKE="$STUBS/flake"
    STATE="$STUBS/state"

    UPDATER="${updater}/bin/librepod-updater"

    # ---- stubs -------------------------------------------------------------
    mkdir -p "$STUBS/bin" "$STUBS/fake-out/bin" "$STUBS/old-system/bin" "$FLAKE" "$STATE"
    touch "$STUBS/fake-out/nixos-version"   # clan activation step 1 passes

    # fake switch-to-configuration in NEW (the build output the nix stub
    # returns) and in OLD (the running system)
    for sys in fake-out old-system; do
      cat > "$STUBS/$sys/bin/switch-to-configuration" <<EOF
    #!/bin/sh
    echo "$sys switch-to-configuration \$*" >> "$CALLS_LOG"
    EOF
      chmod +x "$STUBS/$sys/bin/switch-to-configuration"
    done
    ln -s old-system "$STUBS/current-system"   # relative, like /run/current-system
    export LIBREPOD_CURRENT_SYSTEM="$STUBS/current-system"

    cat > "$STUBS/bin/bootctl" <<EOF
    #!/bin/sh
    echo "bootctl \$*" >> "$CALLS_LOG"
    if [ "\$1" = list ]; then
      if [ -n "\$FAKE_NO_ENTRY" ]; then echo '[]'; exit 0; fi
      echo '[{"id":"old.conf","options":"init=$STUBS/old-system/init"},'
      echo ' {"id":"new.conf","options":"init=$STUBS/fake-out/init"}]'
    fi
    EOF
    chmod +x "$STUBS/bin/bootctl"

    cat > "$STUBS/bin/k3s" <<'EOF'
    #!/bin/sh
    # stub k3s: `k3s kubectl ...` — logs and fakes kubectl
    echo "k3s $*" >> "$CALLS_LOG"
    case "$*" in
      # killed (TimeoutStartSec, a cut) just as it reports `building`
      *"patch"*building*) [ -z "$FAKE_KILL_AT_BUILDING" ] || kill -9 $PPID;;
      *"get node"*) echo "True";;
      *"get configmap"*) cat "$SPEC_FILE" 2>/dev/null || true;;
      *"create"*|*"patch"*|*"label"*) exit 0;;
      *) exit 0;;
    esac
    EOF
    chmod +x "$STUBS/bin/k3s"

    cat > "$STUBS/bin/nix" <<EOF
    #!/bin/sh
    echo "nix \$*" >> "$CALLS_LOG"
    case " \$* " in
      *" flake update "*)  # like real nix: the lock follows the pin in flake.nix
        for dir; do :; done  # --flake DIR comes last
        ref="\$(sed -n 's/.*\(v[0-9][0-9.]*\)".*/\1/p' "\$dir/flake.nix")"
        jq -n --arg r "\$ref" '{nodes:{librepod:{original:{ref:\$r}}}}' > "\$dir/flake.lock";;
      *" build "*) [ -z "\$FAKE_BUILD_FAIL" ] || exit 1; echo "$STUBS/fake-out";;
    esac
    EOF
    chmod +x "$STUBS/bin/nix"

    cat > "$STUBS/bin/nix-env" <<EOF
    #!/bin/sh
    echo "nix-env \$*" >> "$CALLS_LOG"
    # ENOSPC, once, on the profile write that sets FAKE_SET_FAIL
    if [ -n "\$FAKE_SET_FAIL" ] && [ "\$4" = "\$FAKE_SET_FAIL" ] && ! [ -e "$STUBS/set-failed" ]; then
      touch "$STUBS/set-failed"; exit 1
    fi
    EOF
    chmod +x "$STUBS/bin/nix-env"

    cat > "$STUBS/bin/systemctl" <<EOF
    #!/bin/sh
    echo "systemctl \$*" >> "$CALLS_LOG"
    # never actually reboot in tests
    if [ "\$1" = is-active ]; then echo "\''${FAKE_SENTINEL:-activating}"; fi
    EOF
    chmod +x "$STUBS/bin/systemctl"

    # deterministic clock for the unattended-window scenarios
    REAL_DATE="$(command -v date)"
    cat > "$STUBS/bin/date" <<EOF
    #!/bin/sh
    if [ "\$*" = "+%H%M" ]; then echo "\$FAKE_TIME"; exit 0; fi
    exec "$REAL_DATE" "\$@"
    EOF
    chmod +x "$STUBS/bin/date"

    export PATH="$STUBS/bin:$PATH"

    # The booted system's release tag (the current version for report/label)
    booted() { echo "$1" > "$STUBS/release"; }
    export LIBREPOD_RELEASE_FILE="$STUBS/release"
    pin() { printf 'inputs.librepod.url = "github:librepod/os/%s";\n' "$1" > "$FLAKE/flake.nix"; }

    # ---- scenario 1: gate rejects non-tag ref + first-boot label stamp ------
    export SPEC_FILE="$STUBS/spec-master.json"
    echo '{"requestId":1,"desiredVersion":"master","apply":"now"}' > "$SPEC_FILE"
    pin v0.3.5
    booted v0.3.5
    echo '{}' > "$FLAKE/flake.lock"
    export LIBREPOD_FLAKE_DIR="$FLAKE" LIBREPOD_STATE_DIR="$STATE" \
           LIBREPOD_NODE_NAME="pod-test" LIBREPOD_BOOT_ID="boot-1"

    bash "$UPDATER"

    grep -q 'v0.3.5' "$FLAKE/flake.nix" \
      || { echo "FAIL: gate let a non-tag ref repin the flake"; exit 1; }
    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: reboot attempted for invalid ref"; exit 1; }
    grep -q "label node pod-test librepod.os/version=v0.3.5" "$LOG" \
      || { echo "FAIL: first-boot version label not stamped"; exit 1; }

    # ---- scenario 2: manual consent applies a valid tag ---------------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-v9.json"
    echo '{"requestId":2,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"

    bash "$UPDATER"

    grep -q 'github:librepod/os/v9.9.9' "$STATE/staged/flake.nix" \
      || { echo "FAIL: staged flake.nix not repinned to v9.9.9"; exit 1; }
    jq -e '.nodes.librepod.original.ref == "v9.9.9"' "$STATE/staged/flake.lock" >/dev/null \
      || { echo "FAIL: staged flake.lock not updated to v9.9.9"; exit 1; }
    grep -qF -- "--out-link $STATE/staged/result" "$LOG" \
      || { echo "FAIL: NEW not rooted until it has a profile generation"; exit 1; }
    grep -q 'v0.3.5' "$FLAKE/flake.nix" \
      || { echo "FAIL: the device flake changed before the update committed"; exit 1; }
    # The trial: NEW gets an entry, OLD stays the profile and the default,
    # and the one-shot points at NEW.
    [ "$(grep -o 'nix-env -p [^ ]* --set .*' "$LOG")" = "$(printf '%s\n' \
        "nix-env -p /nix/var/nix/profiles/system --set $STUBS/fake-out" \
        "nix-env -p /nix/var/nix/profiles/system --set $STUBS/old-system")" ] \
      || { echo "FAIL: profile not set to NEW, then back to OLD"; exit 1; }
    grep -qx "old-system switch-to-configuration boot" "$LOG" \
      || { echo "FAIL: boot entries not written from OLD"; exit 1; }
    ! grep -q "fake-out switch-to-configuration" "$LOG" \
      || { echo "FAIL: NEW was made the default"; exit 1; }
    grep -qx "bootctl set-oneshot new.conf" "$LOG" \
      || { echo "FAIL: one-shot not pointed at NEW"; exit 1; }
    grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: reboot missing"; exit 1; }
    # 'from' resolved: a relative link would never match the booted system.
    jq -e --arg old "$STUBS/old-system" --arg new "$STUBS/fake-out" \
      '.phase == "trial" and .from == $old and .to == $new
       and .version == "v9.9.9" and .requestId == 2 and .bootId == "boot-1"' "$STATE/update-pending" >/dev/null \
      || { echo "FAIL: update-pending wrong: $(cat "$STATE/update-pending")"; exit 1; }

    # ---- scenario 3: the owner's downgrade request is refused ---------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-down.json"
    echo '{"requestId":3,"desiredVersion":"v0.1.0","apply":"now"}' > "$SPEC_FILE"
    pin v0.3.5
    booted v0.3.5
    rm -rf "$STATE/update-pending" "$STATE/staged"

    bash "$UPDATER"

    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: a manual downgrade was applied"; exit 1; }
    grep -qF 'state\": \"rejected' "$LOG" && grep -q "only upgrades" "$LOG" \
      || { echo "FAIL: the downgrade was not reported as rejected"; exit 1; }
    [ "$(cat "$STATE/request-id")" = 3 ] \
      || { echo "FAIL: request 3 not recorded as handled"; exit 1; }

    # ---- scenario 4: window crossing midnight -------------------------------
    export SPEC_FILE="$STUBS/spec-win.json"
    echo '{"requestId":4,"desiredVersion":"v9.9.9","policy":{"unattended":true,"window":"22:30-06:00"}}' > "$SPEC_FILE"

    FAKE_TIME=2215 bash "$UPDATER"   # minutes count
    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: update applied outside the window"; exit 1; }

    pin v0.3.5
    booted v0.3.5
    rm -rf "$STATE/update-pending" "$STATE/staged"
    FAKE_TIME=2345 bash "$UPDATER"   # same request 4: waiting did not use it up
    grep -q 'github:librepod/os/v9.9.9' "$STATE/staged/flake.nix" \
      || { echo "FAIL: update not applied inside a midnight-wrapping window"; exit 1; }

    # ---- scenario 5: custom URI prefix (E2E uses git+file) ------------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-prefix.json"
    echo '{"requestId":5,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    export LIBREPOD_URI_PREFIX="git+file:///srv/os?ref="
    printf 'inputs.librepod.url = "git+file:///srv/os?ref=v0.3.5";\n' > "$FLAKE/flake.nix"
    rm -rf "$STATE/update-pending" "$STATE/staged"

    bash "$UPDATER"

    grep -q 'git+file:///srv/os?ref=v9.9.9' "$STATE/staged/flake.nix" \
      || { echo "FAIL: custom URI prefix not repinned"; exit 1; }
    unset LIBREPOD_URI_PREFIX

    # ---- scenario 6: NODE_NAME falls back to the kernel hostname ---------
    # (E2E found this: the service PATH has no `hostname` binary.)
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-hn.json"
    echo '{}' > "$SPEC_FILE"   # no request → silent, label reconcile still runs
    pin v0.3.5
    booted v0.3.5
    rm -rf "$STATE/update-pending" "$STATE/staged"
    unset LIBREPOD_NODE_NAME
    HN="$(cat /proc/sys/kernel/hostname)"
    bash "$UPDATER"
    grep -q "label node $HN librepod.os/version=v0.3.5" "$LOG" \
      || { echo "FAIL: hostname fallback broken"; exit 1; }
    export LIBREPOD_NODE_NAME="pod-test"

    # ---- scenario 7: an update in flight → the poll stands down -------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-v9.json"
    echo '{"to":"v9.9.9"}' > "$STATE/update-pending"
    bash "$UPDATER"
    [ ! -s "$LOG" ] \
      || { echo "FAIL: poll touched the cluster while an update was in flight"; exit 1; }
    rm -rf "$STATE/update-pending" "$STATE/staged"

    # ---- scenario 8: the booted version wins over flake.lock -----------------
    # After a failed update the lock can name the new tag while the old one runs.
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-lock.json"
    echo '{"requestId":6,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    pin v0.3.5
    booted v0.3.5
    echo '{"nodes":{"librepod":{"original":{"ref":"v9.9.9"}}}}' > "$FLAKE/flake.lock"
    bash "$UPDATER"
    grep -q "label node pod-test librepod.os/version=v0.3.5" "$LOG" \
      || { echo "FAIL: label not from the booted system"; exit 1; }
    grep -qF 'currentVersion\": \"v0.3.5' "$LOG" \
      || { echo "FAIL: status currentVersion not from the booted system"; exit 1; }
    grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: a lock naming v9.9.9 masked the update as up to date"; exit 1; }
    rm -rf "$STATE/update-pending" "$STATE/staged"

    # ---- scenario 9: a request acts once; later polls stay silent -----------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-once.json"
    echo '{"requestId":7,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    pin v0.3.5
    bash "$UPDATER"
    grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: request 7 not applied"; exit 1; }
    grep -qF 'observedRequestId\": 7' "$LOG" \
      || { echo "FAIL: status does not name request 7"; exit 1; }
    # Back on v0.3.5 (say the trial failed) with the same request in the mailbox.
    : > "$LOG"
    rm -rf "$STATE/update-pending" "$STATE/staged"
    pin v0.3.5
    bash "$UPDATER"
    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: request 7 applied twice"; exit 1; }
    ! grep -q "patch" "$LOG" \
      || { echo "FAIL: a poll with nothing new overwrote the status"; exit 1; }

    # ---- scenario 10: a re-created ConfigMap with an old requestId ----------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-old.json"
    echo '{"requestId":3,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    bash "$UPDATER"
    ! grep -q "systemctl reboot\|patch" "$LOG" \
      || { echo "FAIL: an old requestId acted"; exit 1; }

    # ---- scenario 11: a version whose trial failed is not retried unattended -
    : > "$LOG"
    echo v9.9.9 > "$STATE/failed-versions"
    export SPEC_FILE="$STUBS/spec-auto.json"
    echo '{"requestId":8,"desiredVersion":"v9.9.9","policy":{"unattended":true,"window":"22:00-06:00"}}' > "$SPEC_FILE"
    FAKE_TIME=2300 bash "$UPDATER"
    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: a failed version was retried unattended"; exit 1; }
    grep -qF 'state\": \"rejected' "$LOG" \
      || { echo "FAIL: the skipped retry was not reported"; exit 1; }
    [ "$(cat "$STATE/request-id")" = 8 ] \
      || { echo "FAIL: request 8 not recorded as handled"; exit 1; }

    # ---- scenario 12: a new request from the owner retries it ---------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-retry.json"
    echo '{"requestId":9,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    bash "$UPDATER"
    grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: the owner's new request did not retry the failed version"; exit 1; }
    rm -rf "$STATE/update-pending" "$STATE/staged"

    # ---- scenario 13: a failed build leaves the device flake untouched ------
    : > "$LOG"
    pin v0.3.5
    before="$(sha256sum "$FLAKE"/*)"
    export SPEC_FILE="$STUBS/spec-fail.json"
    echo '{"requestId":10,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    FAKE_BUILD_FAIL=1 bash "$UPDATER" || true
    [ "$(sha256sum "$FLAKE"/*)" = "$before" ] \
      || { echo "FAIL: a failed build changed the device flake"; exit 1; }
    grep -qF 'state\": \"failed' "$LOG" \
      || { echo "FAIL: the failed build was not reported"; exit 1; }
    test ! -e "$STATE/staged" \
      || { echo "FAIL: a failed build left its staged copy"; exit 1; }
    # The owner asks again: the device builds again, not "already on v9.9.9".
    : > "$LOG"
    echo '{"requestId":11,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    bash "$UPDATER"
    ! grep -q "already on" "$LOG" && grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: the poll after a failed build claimed up to date"; exit 1; }
    rm -rf "$STATE/update-pending" "$STATE/staged"

    # ---- scenario 14: no boot entry for NEW → no trial, no reboot -----------
    : > "$LOG"
    echo '{"requestId":12,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    FAKE_NO_ENTRY=1 bash "$UPDATER" || true
    ! grep -q "systemctl reboot\|set-oneshot" "$LOG" \
      || { echo "FAIL: rebooted without a trial entry"; exit 1; }
    test ! -e "$STATE/update-pending" \
      || { echo "FAIL: update-pending left behind; the updater would stand down for good"; exit 1; }
    grep -qF 'state\": \"failed' "$LOG" \
      || { echo "FAIL: the failed trial setup was not reported"; exit 1; }

    # ---- scenario 15: unattended downgrade refused; same version a no-op ----
    : > "$LOG"
    pin v0.3.5
    booted v0.3.5
    echo '{"requestId":13,"desiredVersion":"v0.1.0","policy":{"unattended":true,"window":"22:00-06:00"}}' > "$SPEC_FILE"
    FAKE_TIME=2300 bash "$UPDATER"
    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: an unattended downgrade was applied"; exit 1; }
    grep -qF 'state\": \"rejected' "$LOG" && grep -q "only upgrades" "$LOG" \
      || { echo "FAIL: the unattended downgrade was not reported as rejected"; exit 1; }
    : > "$LOG"
    echo '{"requestId":14,"desiredVersion":"v0.3.5","apply":"now"}' > "$SPEC_FILE"
    bash "$UPDATER"
    ! grep -q "systemctl reboot\|nix-env" "$LOG" && grep -q "already on v0.3.5" "$LOG" \
      || { echo "FAIL: a request for the booted version did more than report done"; exit 1; }

    # ---- scenario 16: a window it can't read → rejected, not parked ---------
    : > "$LOG"
    echo '{"requestId":15,"desiredVersion":"v9.9.9","policy":{"unattended":true,"window":"22:00-06:00 PST"}}' > "$SPEC_FILE"
    FAKE_TIME=2300 bash "$UPDATER"
    ! grep -q "systemctl reboot" "$LOG" && grep -qF 'state\": \"rejected' "$LOG" \
      || { echo "FAIL: a malformed window was not rejected"; exit 1; }
    [ "$(cat "$STATE/request-id")" = 15 ] \
      || { echo "FAIL: request 15 not recorded as handled"; exit 1; }

    # ---- scenario 17: a build that never finished → failed, not `building` --
    : > "$LOG"
    mkdir -p "$STATE/staged"   # killed mid-build; request 15 is already handled
    bash "$UPDATER"
    grep -qF 'state\": \"failed' "$LOG" && grep -q "interrupted" "$LOG" \
      || { echo "FAIL: an interrupted build was not reported"; exit 1; }
    test ! -e "$STATE/staged" \
      || { echo "FAIL: the interrupted build's staged copy left behind"; exit 1; }

    # ---- scenario 18: the sentinel failed on the trial boot → trial ends ----
    : > "$LOG"
    # the booted system is the trial one
    jq -nc --arg to "$STUBS/old-system" '{to:$to, version:"v9.9.9", phase:"trial"}' > "$STATE/update-pending"
    bash "$UPDATER"   # the sentinel is still checking
    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: rebooted while the sentinel was still checking"; exit 1; }
    FAKE_SENTINEL=failed bash "$UPDATER"
    grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: a trial whose sentinel failed was not ended"; exit 1; }
    jq -e '.phase == "trial" and .reason == "sentinel-failed"' "$STATE/update-pending" >/dev/null \
      || { echo "FAIL: the OLD boot needs update-pending and the reason"; exit 1; }

    # ---- scenario 19: the trial setup fails after NEW's --set → profile on OLD
    : > "$LOG"
    rm -rf "$STATE/update-pending" "$STATE/staged"
    echo '{"requestId":16,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    FAKE_SET_FAIL="$STUBS/old-system" bash "$UPDATER" || true
    [ -e "$STUBS/set-failed" ] && [ "$(grep -c -- "--set $STUBS/old-system" "$LOG")" = 2 ] \
      || { echo "FAIL: the profile was left on NEW"; exit 1; }
    test ! -e "$STATE/update-pending" && grep -qF 'state\": \"failed' "$LOG" \
      || { echo "FAIL: the failed trial setup was not reported"; exit 1; }

    # ---- scenario 20: killed as the build starts → failed, not lost ---------
    : > "$LOG"
    echo '{"requestId":17,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    FAKE_KILL_AT_BUILDING=1 bash "$UPDATER" || true
    [ "$(cat "$STATE/request-id")" = 17 ] && ! grep -q "nix build" "$LOG" \
      || { echo "FAIL: the kill did not land between handled and the build"; exit 1; }
    : > "$LOG"
    bash "$UPDATER"
    grep -qF 'state\": \"failed' "$LOG" && grep -qF 'observedRequestId\": 17' "$LOG" \
      || { echo "FAIL: request 17 was used up with no final state"; exit 1; }

    # ---- scenario 21: staged on this boot, never rebooted into → reboot ------
    : > "$LOG"
    jq -nc --arg to "$STUBS/fake-out" '{to:$to, version:"v9.9.9", phase:"trial", bootId:"boot-1"}' > "$STATE/update-pending"
    FAKE_SENTINEL=inactive bash "$UPDATER"   # killed between `report verifying` and its reboot
    grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: a trial its updater never rebooted into was left in flight"; exit 1; }
    : > "$LOG"
    LIBREPOD_BOOT_ID=boot-2 bash "$UPDATER"   # a later boot: the sentinel's to resolve
    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: rebooted for an update staged on an earlier boot"; exit 1; }

    # ---- scenario 22: the sentinel died after its verdict → sent, cleared ---
    : > "$LOG"
    mkdir -p "$STATE/staged"
    jq -nc '{version:"v9.9.9", phase:"trial", bootId:"boot-0",
             verdict:{state:"rolled_back", detail:"v9.9.9 failed its trial boot (unhealthy)"}}' > "$STATE/update-pending"
    FAKE_SENTINEL=failed bash "$UPDATER"
    grep -qF 'state\": \"rolled_back' "$LOG" && grep -qF '(unhealthy)' "$LOG" \
      || { echo "FAIL: the sentinel's verdict was not sent"; exit 1; }
    test ! -e "$STATE/update-pending" && test ! -e "$STATE/staged" \
      || { echo "FAIL: update-pending or the staged copy left behind"; exit 1; }
    ! grep -q "systemctl reboot\|interrupted" "$LOG" \
      || { echo "FAIL: a resolved update was rebooted for, or read as interrupted"; exit 1; }

    echo "updater scenarios passed"
    touch $out
  ''
