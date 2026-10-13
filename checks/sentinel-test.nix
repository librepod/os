{ pkgs }:

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

    # Same concatenation modules/updates/default.nix ships.
    SENTINEL="$ROOT/sentinel"
    cat "${../modules/updates/common.sh}" "${../modules/updates/sentinel.sh}" > "$SENTINEL"

    # Real Nix profile layout: generation dirs live in the profile dir, and
    # the profile link target is relative to that dir (system → system-N-link).
    mkdir -p "$ROOT/bin" "$ROOT/state" "$ROOT/profiles/new" "$ROOT/profiles/prev/bin" "$ROOT/flake"
    touch "$ROOT/profiles/new/nixos-version" "$ROOT/profiles/prev/nixos-version"
    # flake.lock the shared report/current_version read
    echo '{"nodes":{"librepod":{"original":{"ref":"v9.9.9"}}}}' > "$ROOT/flake/flake.lock"

    cat > "$ROOT/bin/k3s" <<'EOF'
    #!/bin/sh
    echo "k3s $*" >> "$CALLS_LOG"
    case "$*" in
      *"get node"*) cat "$HEALTH_FILE" 2>/dev/null || true;;
      *"patch"*|*"label"*|*"create"*) exit 0;;
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

    cat > "$ROOT/bin/nix-env" <<EOF
    #!/bin/sh
    echo "nix-env \$*" >> "$CALLS_LOG"
    EOF
    chmod +x "$ROOT/bin/nix-env"

    # Real Nix profiles are relative generation links (system-N-link) —
    # model that so path resolution is exercised the way production does it.
    # relative generation link, like production's system-N-link
    ln -sfn new "$ROOT/profiles/system"

    export LIBREPOD_STATE_DIR="$ROOT/state" \
           LIBREPOD_NODE_NAME="pod-test" \
           LIBREPOD_FLAKE_DIR="$ROOT/flake" \
           LIBREPOD_HEALTH_TIMEOUT=0 LIBREPOD_HEALTH_STABLE=0 LIBREPOD_POLL_INTERVAL=0 \
           LIBREPOD_PROFILE="$ROOT/profiles/system"

    # ---- scenario 1: healthy → label + done ---------------------------------
    export HEALTH_FILE="$ROOT/health"
    echo "True" > "$ROOT/health"   # node Ready condition status
    echo "{\"from\":\"$ROOT/profiles/prev\",\"to\":\"v9.9.9\"}" > "$ROOT/state/update-pending"
    echo old-pin > "$ROOT/state/flake.nix.bak"
    echo old-lock > "$ROOT/state/flake.lock.bak"
    bash "$SENTINEL"
    grep -q "label node pod-test librepod.os/version=v9.9.9" "$CALLS_LOG" \
      || { echo "FAIL: success label missing"; exit 1; }
    test ! -e "$ROOT/state/update-pending" \
      || { echo "FAIL: flag not cleared on success"; exit 1; }
    test ! -e "$ROOT/state/flake.nix.bak" && test ! -e "$ROOT/state/flake.lock.bak" \
      || { echo "FAIL: pin backup not cleared on commit"; exit 1; }

    # ---- scenario 2: unhealthy → rollback + reboot ----------------------------
    : > "$CALLS_LOG"
    echo "NotReady" > "$ROOT/health"
    echo "{\"from\":\"$ROOT/profiles/prev\",\"to\":\"v9.9.9\"}" > "$ROOT/state/update-pending"
    ln -sfn new "$ROOT/profiles/system"
    echo old-pin > "$ROOT/state/flake.nix.bak"
    echo old-lock > "$ROOT/state/flake.lock.bak"
    echo new-pin > "$ROOT/flake/flake.nix"
    echo new-lock > "$ROOT/flake/flake.lock"
    cat > "$ROOT/profiles/prev/bin/switch-to-configuration" <<EOF
    #!/bin/sh
    echo "prev-s2c \$*" >> "$CALLS_LOG"
    EOF
    chmod +x "$ROOT/profiles/prev/bin/switch-to-configuration"
    bash "$SENTINEL"
    grep -q "nix-env -p .* --set .*/prev" "$CALLS_LOG" \
      || { echo "FAIL: rollback did not set previous profile"; exit 1; }
    grep -q "prev-s2c boot" "$CALLS_LOG" \
      || { echo "FAIL: previous generation not boot-staged"; exit 1; }
    grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: no reboot after rollback"; exit 1; }
    test ! -e "$ROOT/state/update-pending" \
      || { echo "FAIL: flag not cleared on rollback"; exit 1; }
    [ "$(cat "$ROOT/flake/flake.lock")" = "old-lock" ] \
      || { echo "FAIL: rollback left the lock claiming the failed version"; exit 1; }

    # ---- scenario 3: stale flag (power loss mid-flow) → clear, no rollback ----
    : > "$CALLS_LOG"
    echo "{\"from\":\"$ROOT/profiles/prev\",\"to\":\"v0.3.5\"}" > "$ROOT/state/update-pending"
    ln -sfn prev "$ROOT/profiles/system"   # current == from → stale
    echo old-pin > "$ROOT/state/flake.nix.bak"
    echo old-lock > "$ROOT/state/flake.lock.bak"
    echo new-pin > "$ROOT/flake/flake.nix"
    echo new-lock > "$ROOT/flake/flake.lock"
    bash "$SENTINEL"
    test ! -e "$ROOT/state/update-pending" \
      || { echo "FAIL: stale flag not cleared"; exit 1; }
    ! grep -q "systemctl reboot" "$CALLS_LOG" \
      || { echo "FAIL: stale flag triggered reboot"; exit 1; }
    [ "$(cat "$ROOT/flake/flake.nix")" = "old-pin" ] \
      || { echo "FAIL: stale clear left the lock claiming an unbooted version"; exit 1; }

    echo "sentinel scenarios passed"
    touch $out
  ''
