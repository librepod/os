{ pkgs }:

pkgs.runCommand "installer-test"
  {
    buildInputs = with pkgs; [
      bash
      zstd
      openssh
    ];
  }
  ''
    set -euo pipefail
    ROOT=$(mktemp -d)
    export CALLS_LOG="$ROOT/calls.log"
    : > "$CALLS_LOG"
    export PATH="$ROOT/bin:$PATH"
    mkdir -p "$ROOT/bin"
    INSTALL="${../pkgs/librepod-install/install.sh}"

    # Every tool that writes a disk: a refusal must call none of them.
    for tool in wipefs dd sgdisk sfdisk mkfs.ext4 resize2fs efibootmgr mount; do
      printf '#!/bin/sh\necho "%s $*" >> "$CALLS_LOG"\n' "$tool" > "$ROOT/bin/$tool"
      chmod +x "$ROOT/bin/$tool"
    done

    # A whole disk image as far as the installer looks: GPT headers at the
    # second sector and in the last one.
    { head -c 512 /dev/zero; printf 'EFI PART'; head -c 504 /dev/zero; } > "$ROOT/ok.img"
    head -c 1024 /dev/zero > "$ROOT/zeros.img"
    { printf hsqs; head -c 1020 /dev/zero; } > "$ROOT/slot.img" # a squashfs store slot

    refused() { # expected message, then the installer's arguments
      local want="$1" msg
      shift
      if msg="$(bash "$INSTALL" "$@" 2>&1)"; then
        echo "FAIL: accepted: $*"; exit 1
      fi
      grep -qF -- "$want" <<< "$msg" || { echo "FAIL: '$*' refused without '$want': $msg"; exit 1; }
      [ ! -s "$CALLS_LOG" ] || { echo "FAIL: '$*' wrote a disk: $(cat "$CALLS_LOG")"; exit 1; }
    }

    refused usage: --image
    for name in 'a" ; x = import ./evil ; #' pod.e2e 1pod Pod; do
      refused "invalid name" --image "$ROOT/ok.img" --name "$name"
    done
    refused "no such file" --image "$ROOT/missing.img" --name pod-test
    refused "not a whole disk image" --image "$ROOT/zeros.img" --name pod-test
    refused "not a whole disk image" --image "$ROOT/slot.img" --name pod-test
    refused "not both" --image "$ROOT/ok.img" --name pod-test --keep-data --wipe-data
    refused "not a block device" --image "$ROOT/ok.img" --name pod-test --disk "$ROOT/ok.img"
    for code in 7KQM-X3RT-9VH0 7KQMX3RT9VH 7KQMX3RT9VHCC; do
      refused "invalid setup code" --image "$ROOT/ok.img" --name pod-test --setup-code "$code"
    done
    refused usage: --image "$ROOT/ok.img" --name pod-test --setup-code ""

    # --ssh-key: a bad file on a key-only device means no SSH at all.
    ssh-keygen -q -t ed25519 -N "" -C one -f "$ROOT/id"
    ssh-keygen -q -t ed25519 -N "" -C two -f "$ROOT/id2"
    { cat "$ROOT/id.pub"; echo "# the bench"; echo; cat "$ROOT/id2.pub"; } > "$ROOT/keys.pub"
    # ssh-keygen -lf passes these, sshd refuses them: a known_hosts line, an option
    printf 'myhost %s\n' "$(cat "$ROOT/id.pub")" > "$ROOT/known_hosts"
    printf 'ssh-gw %s\n' "$(cat "$ROOT/id.pub")" > "$ROOT/known_hosts_ssh"
    printf 'from="10.0.0.0/8" %s\n' "$(cat "$ROOT/id.pub")" > "$ROOT/options.pub"
    { cat "$ROOT/id.pub"; echo "ssh-ed25519 AAAAtrunc"; } > "$ROOT/half.pub"
    printf '# no keys yet\n\n' > "$ROOT/empty.pub"
    ok=(--image "$ROOT/ok.img" --name pod-test)
    refused usage: "''${ok[@]}" --ssh-key
    refused usage: "''${ok[@]}" --ssh-key ""
    refused "--ssh-key $ROOT/missing.pub: no such file" "''${ok[@]}" --ssh-key "$ROOT/missing.pub"
    refused "line 1 is not a public key" "''${ok[@]}" --ssh-key "$ROOT/id" # the private key
    refused "line 1 is not a public key" "''${ok[@]}" --ssh-key "$ROOT/ok.img"
    refused "line 2 is not a public key" "''${ok[@]}" --ssh-key "$ROOT/half.pub"
    refused "line 1 is not a public key" "''${ok[@]}" --ssh-key "$ROOT/known_hosts"
    refused "line 1 is not a public key" "''${ok[@]}" --ssh-key "$ROOT/known_hosts_ssh"
    refused "line 1 is not a public key" "''${ok[@]}" --ssh-key "$ROOT/options.pub"
    refused "no public key in it" "''${ok[@]}" --ssh-key "$ROOT/empty.pub"
    # a good file passes its check: the next one refuses
    refused "not a block device" "''${ok[@]}" --ssh-key "$ROOT/keys.pub" --disk "$ROOT/ok.img"

    echo "installer scenarios passed"
    touch $out
  ''
