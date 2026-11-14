# Phase 3: the installer writes the image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Tracking is in **bd**, not checkboxes (repo rule: no markdown TODO lists): one child bead of `librepod-os-8ss.3` per task, steps numbered.

**Goal:** `librepod-install` puts the appliance image on a device: OS disk, name, data disk and boot entry. The device mounts only its own disks, and it boots even when its data disk is missing.

**Architecture:**
- Device side (`modules/image`, `modules/identity`):
  - root becomes the last partition;
  - one udev rule links the boot disk's partitions by label, and `/`, `/boot` and `/nix/store` mount through it;
  - a second rule finds the data partition by the UUID written on root;
  - `/mnt/k3s` is `nofail`, and NFS waits for it.
- Installer (`pkgs/librepod-install`): a shell script that checks everything first, then:
  - writes the image and gives it fresh GUIDs;
  - grows root, then writes the hostname and the data UUID to root;
  - formats or keeps the data disk;
  - registers the UEFI entry.
- `checks/image-e2e` grows an installer VM, and the pod boots what that VM installed.

**Tech Stack:**
- NixOS 26.05: `image.repart`, systemd 260 udev, the NixOS test driver (KVM).
- Shell tools: util-linux 2.42 (`lsblk`, `sfdisk`, `wipefs`, `partx`), gptfdisk, zstd, e2fsprogs, efibootmgr.

**Spec:** `docs/superpowers/specs/2026-11-11-ab-image-updates-design.md`, section "Phase 3 design: the installer writes the image (2026-11-12)". Approved by the owner on 2026-11-12.

## Global Constraints

- nixpkgs `nixos-26.05`; `allowUnfree = false`; scripts via `writeShellApplication` with `runtimeInputs`.
- CLI: `librepod-install --image FILE --name NAME [--disk DEV] [--data-disk DEV] [--keep-data | --wipe-data]`; defaults `/dev/nvme0n1`, `/dev/sda`. `--device`, `--identity`, `--os-tag` and the disko/nixos-install path are gone.
- Name: `^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$` (unchanged).
- Partition labels: `librepod-esp`, `librepod-root`, `store_<v>` / `_empty` (unchanged), `librepod-data` on the data disk.
- Files on root: `/etc/hostname` = NAME + `\n`; `/etc/librepod/data-partuuid` = the data partition's GPT UUID (lowercase) + `\n`.
- Boot entry label `LibrePod`, loader `\EFI\BOOT\BOOTX64.EFI` on the OS disk's ESP, first in `BootOrder`.
- Nothing is written to any disk before every check passes.
- `applianceModules`, `lib.mkDevice`, `modules/{nfs,disko,updates,users}` keep their behavior.
- `nix fmt -- --check` and `nix flake check` pass after every task.
- Git: one commit per task on `feat/ota-updates`. Commit the spec change and this plan first, as `docs: phase 3 design and plan`. Push only when the user asks.

## Review Focus

1. **`--image` is not a whole disk image**, e.g. the release's `*.store.raw` slot or a truncated download. The installer refuses before wiping anything. Covered by Task 2, installer-test "not a disk image".
2. **`--disk` or `--data-disk` names a partition** (`/dev/nvme0n1p1`) instead of a disk. Refused, so no image lands inside a partition. Covered by Task 2, e2e "refusals".
3. **The installer's own stick shows up as `/dev/sda`** (booted with copytoram, so it is no longer mounted). The USB/removable check refuses it as the data disk. Covered by Task 2, e2e "refusals" (USB as `--data-disk`).
4. **A bench re-run after an interrupted install:** the data disk already has `librepod-data`. The refusal names both flags, so the operator knows `--wipe-data` is the way on. Covered by Task 2, e2e "existing data" (asserts the message).
5. **Another LibrePod's data disk is plugged in next to the device's own,** and it is the first `librepod-data` udev sees. `/mnt/k3s` still mounts the device's own disk. Covered by Task 1, the `otherdata` drive.

---

### Task 1: The device mounts only its own disks; a missing data disk doesn't stop boot

**Files:**
- Modify: `modules/image/default.nix`. Rename the partitions so root sorts last: `"10-esp"`, `"20-store-a"`, `"30-store-b"`, `"40-root"` (`image.repart` writes them in attribute-name order; today root is second). Repoint the three `fileSystems`. Add the boot-disk udev rule.
- Modify: `modules/identity/default.nix`. It takes over the data disk: the mount, its udev rule, `nofail`, and the NFS ordering. Update the header contract.
- Modify: `flake.nix`. Drop the inline `/mnt/k3s` block from `imageModules`; `modules/identity` owns it now.
- Test: `checks/image-e2e/default.nix`

**Interfaces:**
- Produces:
  - `/dev/disk/librepod-os/<partlabel>`: one link per partition on the boot disk.
  - `/dev/disk/librepod-data`: the partition whose UUID equals the line in `/etc/librepod/data-partuuid`.
  - `fileSystems."/".device = "/dev/disk/librepod-os/librepod-root"`, `"/boot"` → `…/librepod-esp`, `"/nix/store"` → `…/store_${version}`.
  - `fileSystems."/mnt/k3s" = { device = "/dev/disk/librepod-data"; fsType = "ext4"; options = [ "nofail" ]; }`.

1. **Write the failing test.** In `checks/image-e2e/default.nix`:
   - Pin our data disk's partition UUID with `UUID = "4c1e2f7a-9b3d-4e5f-8a6b-1c2d3e4f5a60"` in `dataDisk`'s repart config.
   - Add `otherDataDisk`: the same partition with `UUID = "7d2a0c55-3e1b-4f6a-9c8d-2b3a4c5d6e70"` and another seed. Attach it as NVMe `serial=otherdata`, ahead of `data`.
   - Put `contents."/etc/librepod/data-partuuid"` (our UUID and `\n`) into the root partition, under its new name `"40-root"`.
   - In `check_drives`, add `"otherdata"` to the expected serials.
   - Append the subtest:
   ```python
   with subtest("a missing data disk doesn't stop boot; NFS stays off"):
       pod.shutdown()
       os.environ["DATA_DISK"] = disk()  # blank: no partition with our UUID
       pod.start(allow_reboot=True)
       pod.wait_for_unit("multi-user.target")
       pod.wait_for_unit("sshd.service")
       pod.fail("findmnt /mnt/k3s")
       pod.fail("findmnt /exports/k3s")
       pod.fail("systemctl is-active nfs-server.service")
   ```
2. Run `nix build .#image-e2e -L`. Expected: FAIL. Without `nofail` the boot drops into emergency mode and reboot-loops, so the last subtest times out. The `otherdata` check may also fail, because `/dev/disk/by-partlabel/librepod-data` points at whichever disk udev saw last.
3. **`modules/image`.** One rules string, used in both `boot.initrd.services.udev.rules` and `services.udev.extraRules`:
   ```
   SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", IMPORT{parent}="ID_PART_GPT_AUTO_ROOT_DISK"
   SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_GPT_AUTO_ROOT_DISK}=="1", ENV{ID_PART_ENTRY_NAME}=="?*", SYMLINK+="disk/librepod-os/$env{ID_PART_ENTRY_NAME}"
   ```
   Comment in one line: systemd 260's udev marks the disk systemd-boot started from (in the initrd) and the disk holding `/` (after the switch). A copy of this image on another drive therefore can't be mounted, once the installer has made the partition UUIDs unique. Rename the partitions and repoint `fileSystems`. Keep the "Prefixed labels" comment, and say that the links make the labels unique per disk.
4. **`modules/identity`.** Stage-2 rule (`services.udev.extraRules`):
   ```
   SUBSYSTEM=="block", ENV{ID_PART_ENTRY_NAME}=="librepod-data", PROGRAM="${pkgs.gnugrep}/bin/grep -qxF $env{ID_PART_ENTRY_UUID} /etc/librepod/data-partuuid", SYMLINK+="disk/librepod-data"
   ```
   Add:
   - the `/mnt/k3s` filesystem from Interfaces;
   - `fileSystems."/exports/k3s".options = [ "nofail" ]`, which merges with `modules/nfs`'s `bind`;
   - `systemd.services.nfs-server.unitConfig.RequiresMountsFor = "/exports/k3s"`.

   One-line why: without the data disk the bind and NFS stay down, so PVs never land on root. A bind mount already requires the mount of its source; if the test shows `/exports/k3s` mounted anyway, add `x-systemd.requires-mounts-for=/mnt/k3s`. Header contract: replace the data disk line with `/etc/librepod/data-partuuid` (installer) and "data disk: one GPT partition labelled `librepod-data`, ext4, found by that UUID → `/mnt/k3s`". Remove the inline block from `flake.nix`.
5. Run `nix build .#image-e2e -L`. Expected: PASS. Then run `nix build .#ab-spike -L` (it boots through `modules/image`). Expected: `ab-spike: all scenarios passed`.
6. `nix fmt`, `nix flake check`. Commit: `feat(image): mount only the boot disk and the recorded data disk; a missing data disk keeps the device up`.

### Task 2: `librepod-install` writes the image; image-e2e boots an installed disk

**Files:**
- Rewrite: `pkgs/librepod-install/install.sh`
- Modify: `pkgs/librepod-install/default.nix`. `runtimeInputs`: `coreutils util-linux gptfdisk zstd e2fsprogs efibootmgr gnugrep gawk systemd` (`udevadm`); drop curl, jq, nix, disko, nixos-install-tools.
- Rewrite: `checks/installer-test.nix`
- Modify: `checks/image-e2e/default.nix`
- Modify: `README.md` (the "Provision a device" paragraph), plus the Device Profiles paragraph in both `AGENTS.md` and `CLAUDE.md`: they are identical, and their `librepod-install … writes the device flake` sentence becomes the image install.

**Interfaces:**
- Consumes: the Task 1 contract (labels, `/etc/librepod/data-partuuid`).
- Produces: the CLI in Global Constraints. Exit 0 means installed. Any refusal exits 1, before any disk write, with one line saying why.

1. **Write the failing tests.**

   `checks/installer-test.nix` keeps its stub pattern. Stubs for `wipefs dd sgdisk sfdisk mkfs.ext4 resize2fs efibootmgr mount` log to `$CALLS_LOG`; the fixture `ok.img` is 1 KiB with `EFI PART` at offset 512. Scenarios, each asserting a non-zero exit and an empty `$CALLS_LOG`:
   - `--image` missing its value;
   - each invalid name from today's scenario 5;
   - `--image` names a missing file;
   - **not a disk image**: 1 KiB of zeros, and a file starting `hsqs` (squashfs);
   - `--keep-data --wipe-data` together;
   - `--disk "$ROOT/ok.img"`: not a block device.

   `checks/image-e2e/default.nix`:
   - Add a `nodes.installer`:
     - `virtualisation.useEFIBoot = true`, for the efivars;
     - `librepod-install` (callPackage) in `environment.systemPackages`;
     - targets via `qemu.options`: OS virtio `serial=os` (`$OS_DISK`), data NVMe `serial=data` (`$DATA_DISK`), USB `serial=usb` (`$USB_DISK`).
   - Image input: `imageZst = runCommand … "zstd -T0 -q ${image}/${filePath} -o $out"`.
   - The pod:
     - drops `"40-root"`'s 4G override and both root `contents`;
     - overrides `virtualisation.qemu.drives` with `lib.mkForce` to a root drive with `serial=root` and no `bootindex`, so OVMF follows the NVRAM `BootOrder`;
     - adds `efibootmgr` to `systemPackages`;
     - attaches one more extra drive: a copy of the raw image (`serial=otheros`, qcow2 backed by `${image}/${filePath}`).
   - Script order:
     1. Set `NIX_EFI_VARS` to one temp path for both VMs.
     2. Make `OS_DISK`: 10G, backed by `foreignDisk` (old signatures). Make `DATA_DISK`: 2G, backed by `foreignDisk` (a recycled disk).
     3. Start `installer` with `NIX_DISK_IMAGE` unset and run:
     ```python
     def dev(serial):  # kernel path of the disk with this serial
         return installer.succeed(f"lsblk -dnpo PATH,SERIAL | awk '$2==\"{serial}\" {{print $1}}'").strip()
     os_, data = dev("os"), dev("data")
     inst = "librepod-install --image ${imageZst} --name pod-image --disk {disk} --data-disk {data} {flags}"
     with subtest("refusals"):
         installer.fail(inst.format(disk=os_, data=dev("usb"), flags=""))  # USB
         installer.fail(inst.format(disk="/dev/vda", data=data, flags=""))  # mounted: the installer's own
         installer.fail(inst.format(disk=os_ + "1", data=data, flags=""))  # a partition
     with subtest("install; the data disk is ours"):
         installer.succeed(inst.format(disk=os_, data=data, flags=""))  # recycled disk: no flag needed
         installer.succeed(f"mount {data}p1 /mnt && touch /mnt/marker && umount /mnt")
     with subtest("existing data"):
         out = installer.fail(inst.format(disk=os_, data=data, flags="") + " 2>&1")
         assert "--keep-data" in out and "--wipe-data" in out, out
         installer.succeed(inst.format(disk=os_, data=data, flags="--keep-data"))
     installer.shutdown()
     ```
     4. Set `NIX_DISK_IMAGE = OS_DISK` and start the pod.
     5. Run today's subtests unchanged; they now read the installer's hostname and data UUID.
   - Add:
   ```python
   with subtest("installed: root fills the disk, our entry booted, old data kept"):
       assert int(pod.succeed("df -B1 --output=size / | tail -1")) > 5 * 2**30
       assert "LibrePod" in pod.succeed("efibootmgr | grep \"Boot$(efibootmgr | sed -n 's/^BootCurrent: //p')\"")
       pod.succeed("test -e /mnt/k3s/marker")
       # fresh GUIDs: our ESP differs from the image copy's
       assert part_uuid("root", "librepod-esp") != part_uuid("otheros", "librepod-esp")
   ```
   `part_uuid(serial, label)` uses `lsblk -nro SERIAL,…` the same way `disk_of` does. `check_drives` also expects `otheros`.
2. Run `nix build .#checks.x86_64-linux.installer-test` and `nix build .#image-e2e -L`. Expected: both FAIL. The old script doesn't know `--image`.
3. **Write `install.sh`.** Order, all checks before the first write:
   1. Parse the flags.
   2. Name regex; `--image` is a file whose decompressed bytes 512–519 are `EFI PART` (`zstd -dcf` passes raw files through). Mind `pipefail` with a closed pipe.
   3. Not both data flags.
   4. Each disk: `[ -b ]`; `lsblk -dno TYPE` is `disk`; `realpath`s differ; `lsblk -dno TRAN,RM` is not `usb` and not removable; `lsblk -nro MOUNTPOINTS` is empty.
   5. `/sys/firmware/efi/efivars` exists.
   6. Count `librepod-data` partitions on the data disk:
      - 0 → format;
      - ≥1 and no flag → refuse: `<disk> holds LibrePod data: pass --keep-data or --wipe-data`;
      - `--keep-data` and not exactly 1 → refuse.

   Then:
   1. `wipefs -a` the OS disk.
   2. `zstd -dcf IMAGE | dd of=DISK bs=4M conv=fsync`.
   3. `sgdisk -e -G` (backup GPT to the end, fresh GUIDs).
   4. `partx -u`, `udevadm settle`.
   5. Exactly one `librepod-root` and one `librepod-esp` partition on DISK, by `lsblk -nrpo PATH,PARTLABEL,PARTN` (never `/dev/disk/by-partlabel`).
   6. `echo ', +' | sfdisk -N <root PARTN> --no-reread DISK`, `partx -u`, `udevadm settle`.
   7. `e2fsck -fp` and `resize2fs` on root.
   8. Data disk: keep → read its UUID. Format → `wipefs -a`, `sgdisk -Z`, `sgdisk -n1:0:0 -t1:8300 -c1:librepod-data -u1:<uuid from /proc/sys/kernel/random/uuid>`, settle, `mkfs.ext4 -F`.
   9. Mount root on a `mktemp -d`; `install -D` the two files; unmount.
   10. `efibootmgr -q --create --disk DISK --part <esp PARTN> --label LibrePod --loader '\EFI\BOOT\BOOTX64.EFI'`.

   Print one `==>` line per stage, as today.
4. Run both again. Expected: PASS. If OVMF ignores `BootOrder` and boots `otheros`, `check_drives` fails on serial `otheros`. Stop and report; don't put the `bootindex` back.
5. Update the docs listed above, then `nix fmt` and `nix flake check`. `bd close` `librepod-os-8ss.3.1`, `librepod-os-8ss.3.2` and this task's bead, and close `librepod-os-xbe` with the reason "image installs don't use disko; the installer always runs mkfs.ext4 -F". Commit: `feat(install): write the image, its identity and the boot entry; keep or wipe the data disk`.

### Task 3: One real install on librepod-dev (M710q)

With the owner: librepod-dev is disposable and both disks may be wiped (owner, 2026-11-12). No code unless something fails.

1. Build the image for `lenovo-m710q` and compress it. Use the same stub settings as the `image-profiles` check:
   ```bash
   nix build --impure --expr 'let f = builtins.getFlake (toString ./.); in (f.lib.mkImage { device = "lenovo-m710q"; version = "1"; modules = [ ({ pkgs, ... }: { librepod.image = { updateUrl = "https://updates.invalid/"; pubring = pkgs.writeText "empty.pgp" ""; healthCheck = "${pkgs.coreutils}/bin/true"; }; }) ]; }).config.system.build.image'
   zstd -T0 result/librepod_1.raw -o librepod_1.raw.zst
   ```
2. The owner boots the NixOS minimal USB **in UEFI mode** and enables ssh; the stick stays in the whole time. Copy the tools and the image over:
   ```bash
   nix copy --to ssh://root@<ip> .#librepod-install
   scp librepod_1.raw.zst root@<ip>:/tmp/
   ```
3. Show `lsblk -o NAME,SIZE,TRAN,RM,MODEL,PARTLABEL` and agree the two disks with the owner. Then run `librepod-install --image /tmp/librepod_1.raw.zst --name librepod-dev --disk <nvme> --data-disk <sata>`.
4. Reboot without touching the firmware menu. The owner logs in at the console as `librepod` / `librepod` and adds the dev key to `~/.ssh/authorized_keys`, as a power user would. Check over ssh:
   - `efibootmgr`: BootCurrent is `LibrePod`, with the stick still plugged in;
   - `hostname` is `librepod-dev`;
   - `df -h /` is about the NVMe's size minus ~4.3G;
   - `findmnt /mnt/k3s` is on the SATA disk;
   - the k3s node `librepod-dev` is Ready.
5. Add "Phase 3 results (date)" to the spec: what passed, the numbers, and the firmware's behavior. `bd close` this task's bead and `librepod-os-8ss.3`. Commit: `docs(image): phase 3 results on librepod-dev`.

---

## Not in this phase

- Downloading the image and `--os-tag`: phase 4, which must also publish the full disk image per hardware profile.
- Replacing a dead data disk (`8ss.10`) or a dead OS disk (`8ss.12`).
- A trial boot without its data disk fails NFS, and so the health gate (phase 5): a missing data disk must not count against a new version.
