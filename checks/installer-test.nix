{ pkgs }:

pkgs.runCommand "installer-test"
  {
    buildInputs = with pkgs; [
      bash
      jq
      nix # parses the generated install.nix
    ];
  }
  ''
    set -euo pipefail
    ROOT=$(mktemp -d)
    export CALLS_LOG="$ROOT/calls.log"
    : > "$CALLS_LOG"
    export PATH="$ROOT/bin:$PATH"
    mkdir -p "$ROOT/bin" "$ROOT/mnt" "$ROOT/identity"
    INSTALL="${../pkgs/librepod-install/install.sh}"
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
      *getFlake*) printf %s "$ROOT/src" ;;  # the fetched release source
      *system.nixos.release*) printf 26.05 ;;
    esac
    EOF
    chmod +x "$ROOT/bin/nix"
    mkdir -p "$ROOT/src/modules/disko"
    cp ${../modules/disko/default.nix} "$ROOT/src/modules/disko/default.nix"

    export LIBREPOD_TARGET_MNT="$ROOT/mnt" LIBREPOD_WORKDIR="$ROOT/work" \
           DISKO_BIN="$ROOT/bin/disko" NIXOS_INSTALL_BIN="$ROOT/bin/nixos-install" \
           NIX_BIN="$ROOT/bin/nix"

    # ---- scenario 0: flag missing its value → usage, not a crash ------------
    if bash "$INSTALL" --device >/dev/null 2>&1; then
      echo "FAIL: missing flag value not rejected"; exit 1
    fi

    # ---- scenario 1: profile-name device form --------------------------------
    bash "$INSTALL" \
      --device lenovo-m710q --name pod-test --os-tag v0.3.5 \
      --identity "$ROOT/identity/identity.nix"

    grep -q "disko --flake .*#pod-test --mode destroy,format,mount" "$CALLS_LOG" \
      || { echo "FAIL: disko invocation wrong"; exit 1; }
    grep -q "nixos-install --flake .*#pod-test --no-root-passwd" "$CALLS_LOG" \
      || { echo "FAIL: nixos-install invocation wrong"; exit 1; }
    grep -q 'github:librepod/os/v0.3.5' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: pin line missing/wrong"; exit 1; }
    grep -q 'name = "pod-test"' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: device name missing"; exit 1; }
    grep -qF 'version = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.librepod.original.ref;' \
      "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: version not taken from the lock"; exit 1; }
    grep -q 'device = "lenovo-m710q"' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: hw profile missing"; exit 1; }
    grep -q './identity.nix' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: identity not referenced"; exit 1; }
    [ "$(stat -c %a "$ROOT/mnt/etc/nixos/identity.nix")" = "600" ] \
      || { echo "FAIL: identity.nix not 0600"; exit 1; }
    # Install-day facts: the release's layout copied in, the disk and the
    # stateVersion written down, so later releases cannot change them.
    FACTS="$ROOT/mnt/etc/nixos/install.nix"
    grep -q '\./install\.nix' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: install.nix not referenced"; exit 1; }
    cmp -s "$ROOT/src/modules/disko/default.nix" "$ROOT/mnt/etc/nixos/disk.nix" \
      || { echo "FAIL: disk.nix is not the release's layout"; exit 1; }
    grep -qF 'imports = [ ./disk.nix ];' "$FACTS" \
      && grep -qF 'disko.devices.disk.main.device = "/dev/nvme0n1";' "$FACTS" \
      && grep -qF 'system.stateVersion = "26.05";' "$FACTS" \
      || { echo "FAIL: install.nix wrong: $(cat "$FACTS")"; exit 1; }
    NIX_STATE_DIR="$ROOT/nix" nix-instantiate --store dummy:// --parse "$FACTS" >/dev/null \
      || { echo "FAIL: install.nix does not parse"; exit 1; }

    # ---- scenario 2: module-path device form ---------------------------------
    : > "$CALLS_LOG"
    echo '{ ... }: { }' > "$ROOT/my-hardware.nix"
    bash "$INSTALL" \
      --device "$ROOT/my-hardware.nix" --name pod-test --os-tag v0.3.5 \
      --identity "$ROOT/identity/identity.nix"

    # path form must land as a Nix path, not a quoted ./hw/<name> string
    grep -q 'device = \./hardware\.nix;' "$ROOT/mnt/etc/nixos/flake.nix" \
      || { echo "FAIL: module-path device not emitted as a path"; exit 1; }
    [ -f "$ROOT/mnt/etc/nixos/hardware.nix" ] \
      || { echo "FAIL: hardware module not installed next to the flake"; exit 1; }

    # ---- scenario 3: --disk for a SATA-only machine ----------------------------
    bash "$INSTALL" \
      --device lenovo-m710q --name pod-test --os-tag v0.3.5 --disk /dev/sda \
      --identity "$ROOT/identity/identity.nix"
    grep -qF 'disko.devices.disk.main.device = "/dev/sda";' "$ROOT/mnt/etc/nixos/install.nix" \
      || { echo "FAIL: --disk not written to install.nix"; exit 1; }

    # ---- scenario 4: a disk value that would break out of the Nix string -------
    : > "$CALLS_LOG"
    if bash "$INSTALL" \
      --device lenovo-m710q --name pod-test --os-tag v0.3.5 --disk '/dev/sda"; x = "' \
      --identity "$ROOT/identity/identity.nix" >/dev/null 2>&1; then
      echo "FAIL: an invalid --disk was accepted"; exit 1
    fi
    ! grep -q disko "$CALLS_LOG" || { echo "FAIL: disko ran for an invalid --disk"; exit 1; }

    # ---- scenario 5: names that are no hostname, or break out of the Nix ------
    : > "$CALLS_LOG"
    for name in 'a" ; x = import ./evil ; #' pod.e2e 1pod Pod; do
      if bash "$INSTALL" \
        --device lenovo-m710q --name "$name" --os-tag v0.3.5 \
        --identity "$ROOT/identity/identity.nix" >/dev/null 2>&1; then
        echo "FAIL: invalid --name '$name' was accepted"; exit 1
      fi
    done
    ! grep -q disko "$CALLS_LOG" || { echo "FAIL: disko ran for an invalid --name"; exit 1; }

    echo "installer scenarios passed"
    touch $out
  ''
