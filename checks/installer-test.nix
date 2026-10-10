{ pkgs }:

pkgs.runCommand "installer-test"
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
    mkdir -p "$ROOT/bin" "$ROOT/mnt" "$ROOT/identity"
    cat > "$ROOT/identity/identity.nix" <<'EOF'
    { ... }: { }
    EOF

    cat > "$ROOT/bin/disko" <<'EOF'
    #!/bin/sh
    echo "disko $*" >> "$CALLS_LOG"
    EOF
    chmod +x "$ROOT/bin/disko"

    cat > "$ROOT/bin/nixos-install" <<'EOF'
    #!/bin/sh
    echo "nixos-install $*" >> "$CALLS_LOG"
    EOF
    chmod +x "$ROOT/bin/nixos-install"

    cat > "$ROOT/bin/nix" <<EOF
    #!/bin/sh
    echo "nix \$*" >> "$CALLS_LOG"
    case " \$* " in
      *" flake lock "*) : > flake.lock ;;  # would fetch the tag and write flake.lock
    esac
    EOF
    chmod +x "$ROOT/bin/nix"

    export LIBREPOD_TARGET_MNT="$ROOT/mnt" LIBREPOD_WORKDIR="$ROOT/work" \
           DISKO_BIN="$ROOT/bin/disko" NIXOS_INSTALL_BIN="$ROOT/bin/nixos-install" \
           NIX_BIN="$ROOT/bin/nix"

    bash "${../pkgs/librepod-install/install.sh}" \
      --device beelink-sei8 --name pod-test --os-tag v0.3.5 \
      --identity "$ROOT/identity/identity.nix"

    grep -q "disko --flake .*#pod-test --mode destroy,format,mount" "$CALLS_LOG" \
      || { echo "FAIL: disko invocation wrong"; exit 1; }
    grep -q "nixos-install --flake .*#pod-test --no-root-passwd" "$CALLS_LOG" \
      || { echo "FAIL: nixos-install invocation wrong"; exit 1; }
    grep -q 'github:librepod/os/v0.3.5' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: pin line missing/wrong"; exit 1; }
    grep -q 'name = "pod-test"' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: device name missing"; exit 1; }
    grep -q 'device = "beelink-sei8"' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: hw profile missing"; exit 1; }
    grep -q './identity.nix' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: identity not referenced"; exit 1; }
    [ "$(stat -c %a "$ROOT/mnt/etc/nixos/identity.nix")" = "600" ] \
      || { echo "FAIL: identity.nix not 0600"; exit 1; }

    echo "installer scenarios passed"
    touch $out
  ''
