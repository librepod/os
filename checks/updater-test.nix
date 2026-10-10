# checks/updater-test.nix — runCommand derivation, not a module.
# Exercises modules/updates/updater.sh end-to-end with stubbed nix/kubectl.
{ pkgs }:

pkgs.runCommand "updater-test"
  {
    buildInputs = with pkgs; [
      bash
      jq
    ];
  }
  ''
    set -euo pipefail
    UPDATER="${../modules/updates/updater.sh}"
    STUBS=$(mktemp -d)
    LOG="$STUBS/calls.log"
    export CALLS_LOG="$LOG"
    FLAKE="$STUBS/flake"
    STATE="$STUBS/state"

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

    export PATH="$STUBS/bin:$PATH"

    # ---- scenario 1: gate rejects non-tag ref ------------------------------
    export SPEC_FILE="$STUBS/spec-master.json"
    echo '{"desiredVersion":"master","apply":"now"}' > "$SPEC_FILE"
    printf 'inputs.librepod.url = "github:librepod/os/v0.3.5";\n' > "$FLAKE/flake.nix"
    export LIBREPOD_FLAKE_DIR="$FLAKE" LIBREPOD_STATE_DIR="$STATE" \
           LIBREPOD_NODE_NAME="pod-test"

    bash "$UPDATER"

    grep -q 'v0.3.5' "$FLAKE/flake.nix" \
      || { echo "FAIL: gate let a non-tag ref repin the flake"; exit 1; }
    ! grep -q "systemctl reboot" "$LOG" \
      || { echo "FAIL: reboot attempted for invalid ref"; exit 1; }

    # ---- scenario 2: manual consent applies a valid tag ---------------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-v9.json"
    echo '{"desiredVersion":"v9.9.9","apply":"now"}' > "$SPEC_FILE"

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
    # v1 has no live switch:
    ! grep -q "switch-to-configuration switch" "$LOG" \
      || { echo "FAIL: live switch attempted (v1 is boot+reboot only)"; exit 1; }

    # ---- scenario 3: unattended path ignores downgrade ----------------------
    : > "$LOG"
    export SPEC_FILE="$STUBS/spec-down.json"
    echo '{"desiredVersion":"v0.1.0"}' > "$SPEC_FILE"   # no apply:now → window path
    printf 'inputs.librepod.url = "github:librepod/os/v0.3.5";\n' > "$FLAKE/flake.nix"
    rm -f "$STATE/update-pending"

    bash "$UPDATER"

    grep -q 'v0.3.5' "$FLAKE/flake.nix" \
      || { echo "FAIL: unattended downgrade was applied"; exit 1; }

    echo "updater scenarios passed"
    touch $out
  ''
