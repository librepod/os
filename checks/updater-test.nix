# checks/updater-test.nix — runCommand derivation, not a module.
# Exercises modules/updates/updater.sh end-to-end with stubbed nix/kubectl.
{ pkgs }:

pkgs.runCommand "updater-test"
  {
    buildInputs = with pkgs; [
      bash
      jq
      shellcheck
    ];
  }
  ''
    set -euo pipefail
    STUBS=$(mktemp -d)
    LOG="$STUBS/calls.log"
    export CALLS_LOG="$LOG"
    FLAKE="$STUBS/flake"
    STATE="$STUBS/state"

    # Same concatenation modules/updates/default.nix ships.
    UPDATER="$STUBS/updater"
    cat "${../modules/updates/common.sh}" "${../modules/updates/updater.sh}" > "$UPDATER"
    shellcheck "$UPDATER"   # writeShellApplication runs it at build time too

    # ---- stubs -------------------------------------------------------------
    mkdir -p "$STUBS/bin" "$STUBS/fake-out/bin" "$FLAKE" "$STATE"
    touch "$STUBS/fake-out/nixos-version"   # clan activation step 1 passes

    # fake switch-to-configuration inside the build output the nix stub returns
    cat > "$STUBS/fake-out/bin/switch-to-configuration" <<EOF
    #!/bin/sh
    echo "switch-to-configuration \$*" >> "$CALLS_LOG"
    EOF
    chmod +x "$STUBS/fake-out/bin/switch-to-configuration"

    cat > "$STUBS/bin/k3s" <<'EOF'
    #!/bin/sh
    # stub k3s: `k3s kubectl ...` — logs and fakes kubectl
    echo "k3s $*" >> "$CALLS_LOG"
    case "$*" in
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
      *" flake update "*) : ;;  # sed already wrote the pin; lock update is a no-op
      *" build "*) echo "$STUBS/fake-out";;
    esac
    EOF
    chmod +x "$STUBS/bin/nix"

    cat > "$STUBS/bin/nix-env" <<EOF
    #!/bin/sh
    echo "nix-env \$*" >> "$CALLS_LOG"
    EOF
    chmod +x "$STUBS/bin/nix-env"

    cat > "$STUBS/bin/systemctl" <<EOF
    #!/bin/sh
    echo "systemctl \$*" >> "$CALLS_LOG"
    # never actually reboot in tests
    EOF
    chmod +x "$STUBS/bin/systemctl"

    # deterministic clock for the unattended-window scenarios
    REAL_DATE="$(command -v date)"
    cat > "$STUBS/bin/date" <<EOF
    #!/bin/sh
    if [ "\$*" = "+%H" ]; then echo "\$FAKE_HOUR"; exit 0; fi
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
    echo '{}' > "$FLAKE/flake.lock"   # backup_pin copies it
    export LIBREPOD_FLAKE_DIR="$FLAKE" LIBREPOD_STATE_DIR="$STATE" \
           LIBREPOD_NODE_NAME="pod-test"

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

    grep -q 'github:librepod/os/v9.9.9' "$FLAKE/flake.nix" \
      || { echo "FAIL: flake.nix not repinned to v9.9.9"; exit 1; }
    grep -q "nix-env -p /nix/var/nix/profiles/system --set" "$LOG" \
      || { echo "FAIL: profile not set"; exit 1; }
    grep -q "switch-to-configuration boot" "$LOG" \
      || { echo "FAIL: boot staging missing"; exit 1; }
    grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: reboot missing"; exit 1; }
    test -f "$STATE/update-pending" \
      || { echo "FAIL: sentinel flag not staged"; exit 1; }
    grep -q '"to":"v9.9.9"' "$STATE/update-pending" \
      || { echo "FAIL: sentinel flag missing target version"; exit 1; }
    # 'from' must be fully resolved (absolute store path) or none — a relative
    # generation link here would make the sentinel's rollback check miss.
    case "$(jq -r '.from' "$STATE/update-pending")" in
      none|/*) :;;
      *) echo "FAIL: staged 'from' is not a resolved path"; exit 1;;
    esac
    test -f "$STATE/flake.nix.bak" && test -f "$STATE/flake.lock.bak" \
      || { echo "FAIL: pin backup not staged for sentinel rollback"; exit 1; }
    # v1 has no live switch:
    ! grep -q "switch-to-configuration switch" "$LOG" \
      || { echo "FAIL: live switch attempted (v1 is boot+reboot only)"; exit 1; }

    # ---- scenario 3: unattended path ignores downgrade ----------------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-down.json"
    echo '{"requestId":3,"desiredVersion":"v0.1.0"}' > "$SPEC_FILE"   # no apply:now → window path
    pin v0.3.5
    booted v0.3.5
    rm -f "$STATE/update-pending"

    bash "$UPDATER"

    grep -q 'v0.3.5' "$FLAKE/flake.nix" \
      || { echo "FAIL: unattended downgrade was applied"; exit 1; }

    # ---- scenario 4: window crossing midnight -------------------------------
    export SPEC_FILE="$STUBS/spec-win.json"
    echo '{"requestId":4,"desiredVersion":"v9.9.9","policy":{"unattended":true,"window":"22:00-06:00"}}' > "$SPEC_FILE"

    FAKE_HOUR=12 bash "$UPDATER"
    grep -q 'v0.3.5' "$FLAKE/flake.nix" \
      || { echo "FAIL: update applied outside the window"; exit 1; }

    pin v0.3.5
    booted v0.3.5
    rm -f "$STATE/update-pending"
    FAKE_HOUR=23 bash "$UPDATER"   # same request 4: waiting did not use it up
    grep -q 'github:librepod/os/v9.9.9' "$FLAKE/flake.nix" \
      || { echo "FAIL: update not applied inside a midnight-wrapping window"; exit 1; }

    # ---- scenario 5: custom URI prefix (E2E uses git+file) ------------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-prefix.json"
    echo '{"requestId":5,"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"
    export LIBREPOD_URI_PREFIX="git+file:///srv/os?ref="
    printf 'inputs.librepod.url = "git+file:///srv/os?ref=v0.3.5";\n' > "$FLAKE/flake.nix"
    rm -f "$STATE/update-pending"

    bash "$UPDATER"

    grep -q 'git+file:///srv/os?ref=v9.9.9' "$FLAKE/flake.nix" \
      || { echo "FAIL: custom URI prefix not repinned"; exit 1; }
    unset LIBREPOD_URI_PREFIX

    # ---- scenario 6: NODE_NAME falls back to the kernel hostname ---------
    # (E2E found this: the service PATH has no `hostname` binary.)
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-hn.json"
    echo '{}' > "$SPEC_FILE"   # no request → silent, label reconcile still runs
    pin v0.3.5
    booted v0.3.5
    rm -f "$STATE/update-pending"
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
    rm -f "$STATE/update-pending"

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
    rm -f "$STATE/update-pending"

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
    rm -f "$STATE/update-pending"
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
    FAKE_HOUR=23 bash "$UPDATER"
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
    rm -f "$STATE/update-pending"

    echo "updater scenarios passed"
    touch $out
  ''
