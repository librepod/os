# A/B image updates with systemd-sysupdate — design

Status: draft; spike passed (`checks/ab-spike`). 2026-11-11.

## Why

LibrePod devices sit in homes. Nobody from LibrePod can reach them, so a bad
update must never need a human to recover. The owner wants the router or phone
experience: an update is offered, the user agrees, and overnight the device is
on the new version — or, if anything went wrong, still on the old one.

Today's updater is home-grown: each device evaluates and builds its own NixOS
config on the device, then trial-boots it with a one-shot boot entry. It works
(it passed on a real M710q), but it is ~430 lines of shell guarding many edge
cases, every device runs a closure CI never tested, and updates are trusted
only as far as GitHub and TLS.

Replace it with the UAPI/systemd image-based model: CI builds one signed image
per release; the device downloads it into a spare slot and boots it under boot
counting; a failed boot falls back by itself.

## Goals

- **Atomic A/B:** the running version is never written to. A new version goes
  into the other slot; a power cut at any moment leaves a bootable device.
- **Automatic fallback, no human:** a new version that panics, hangs, or fails
  its health check is abandoned after N tries and the old version boots.
- **Signed:** the device installs only images signed with the LibrePod key. A
  hijacked GitHub account, moved tag, mirror or CDN can't push an update.
- **Router UX:** consent in the Marketplace, download by day, switch at night.
- **One image per hardware profile** for the whole fleet — byte-identical to
  what CI tested. No Nix on the device.

## Non-goals (for now)

- Migrating installed devices. There are no real users yet; new installs only.
- Delta updates. Every release is a full image download.
- dm-verity and Secure Boot. Planned next phase; the layout leaves room.
- Rolling back application data in PVs.

## Anti-goals

- Anything that needs someone at the device to recover.
- A device accepting an image not signed by the LibrePod key, over any channel.
- A failed update replacing the last good version.

## Design

### Disk layout (systemd-repart, `image.repart`)

| Partition | Type | Content |
|---|---|---|
| `esp` | ESP, vfat, 1 GiB | systemd-boot, UKIs `librepod_<v>[+tries].efi` |
| `store_<v>` | usr, squashfs, read-only, 8 GiB | the `/nix/store` closure of version v |
| `_empty` | usr-verity, 128 MiB | reserved: slot A's verity hashes (phase 7) |
| `_empty` → `store_<v'>` | usr, same size | the other slot |
| `_empty` | usr-verity, 128 MiB | reserved: slot B's verity hashes (phase 7) |
| `root` | root, ext4, writable | `/etc` (generated at boot), `/var`, device identity |

Each UKI bakes its own version into the initrd's mount of
`/dev/disk/by-partlabel/store_<v>`, so a UKI always boots its own slot.
*(Our call: label binding, as in the nixcademy demo. Verity binds by UUID
derived from the root hash instead; that comes with the verity phase.)*

### Release artifacts

Per version: `librepod_<v>.efi` (UKI), `librepod_<v>.store.raw.zst` (the slot
image), listed in one `SHA256SUMS` with a detached `SHA256SUMS.gpg`. One folder
lists all offered versions. The device trusts only
`/etc/systemd/import-pubring.pgp` (ships in the image); when that file exists
the vendor keyring is not consulted.

Key custody: the signing key lives off GitHub (hardware token); signing is the
one manual release step. *(Our call; open to a protected CI environment.)*

### Update flow

1. Marketplace offers the version; the owner consents (`spec.json`, unchanged
   contract: requestId, desiredVersion, apply/now or window).
2. Updater: `systemd-sysupdate acquire <v>` — download, verify, write into the
   spare slot. The running system is untouched.
3. In the window: snapshot the k3s datastore, `systemd-sysupdate update
   --offline <v>`, reboot. The UKI is installed with `TriesLeft=N`.
4. systemd-boot boots the newest entry with tries left. A health unit
   (`requiredBy=boot-complete.target`, `FailureAction=reboot`) runs the
   existing checks (k3s, sshd, node Ready, update source reachable).
   Passing → `systemd-bless-boot` marks the UKI good. Done.
5. Failure → reboot: health fails (`FailureAction`), kernel panic (`panic=10`),
   failed initrd (`boot.panic_on_fail`), a failed mount (emergency mode
   reboots: root is locked, so it has no shell anyway), hang (hardware
   watchdog via `RuntimeWatchdogSec`; iTCO on the M710q). Tries exhausted →
   the entry sorts last, the old version boots.
6. The old version sees `systemd-sysupdate pending` (a newer version is
   installed but not running) → restores the k3s snapshot, reports
   `rolled_back`.

`ProtectVersion=%A` keeps the running version's slot and UKI from being
reused. `InstancesMax=2` everywhere. The sysupdate timer is off: only the
consent updater triggers it.

### Per-device identity

Moves out of the Nix config into files on `root`, written by the installer:
password hashes (`hashedPasswordFile`), SSH keys
(`services.openssh.authorizedKeysFiles`), `/etc/hostname`, frpc config.

## Phases

1. **Spike (now):** mechanics in a KVM VM test, minimal image, no k3s.
2. Identity out of Nix; appliance modules build as an image.
3. Installer: flash image + write identity; root grows on first boot.
4. Release pipeline: build, sign, host.
5. Port the consent updater/sentinel onto acquire/update/bless; k3s snapshot
   and restore.
6. Real M710q checkpoint (watchdog, firmware, boot counting).
7. dm-verity store + Secure Boot.

## Spike pass criteria

1. Unsigned, foreign-key-signed, or tampered releases are refused; nothing
   changes.
2. A power cut while v2 is written leaves v1 running; a retry succeeds.
3. A good v2: acquire by day (v1 still runs), install + reboot, v2 boots and
   is blessed, survives another reboot.
4. A v3 whose health check fails, a v4 that panics, a v5 that hangs, a v6
   whose mount fails: each lands back on v2 with no human action, and
   `pending` reports it.
5. Numbers: slot image size, download size, time to apply.

## Spike results (2026-11-11, `nix build .#ab-spike`, all 5 criteria pass)

- Refusals happen for the right reason: no `SHA256SUMS.gpg` → "cannot
  verify"; foreign key → "No public key"; tampered file under a good signature
  → checksum mismatch. The device stays on v1 each time.
- **A failed acquire blocks the next one** ("already acquired and partially
  installed. Vacuum it to try installing again"): the tampered release had
  already written v2's store slot before its UKI failed the checksum. The
  updater must run `systemd-sysupdate vacuum` before every `acquire` (a no-op
  otherwise; the running version is protected). Never between acquire and
  `update --offline`.
- **gpg must be in sysupdate's PATH.** In a unit's bare PATH, systemd-pull
  can't find gpg and every release is refused (fails closed). The image wraps
  `systemd-sysupdate` with gnupg in its PATH.
- Boot counting works as designed: installed `librepod_2+2-0.efi`, blessed to
  `librepod_2.efi`; failed versions end as `librepod_N+0-2.efi`, sorted last.
  `InstancesMax=2` + `ProtectVersion=%A` reuse the bad version's slot next time.
- Watchdog: a frozen PID 1 is reset after `RuntimeWatchdogSec`. A busy system
  is not a hang: since Linux 6.12 even a real-time CPU hog leaves PID 1 enough
  CPU to feed the watchdog, so slow-but-alive is the health gate's job (its
  `TimeoutStartSec` + `FailureAction=reboot`). The watchdog module must load
  in the initrd (VM: i6300esb; M710q: iTCO_wdt).
- Numbers (minimal image, no k3s): 341 MiB download per release (store slot,
  zstd) + 40 MiB UKI; acquire 35 s at 20 MB/s; install under 1 s; reboot to
  blessed 29 s. Built images are sparse: 4.8 GB apparent, ~390 MB on disk.

## Phase 2 results (2026-11-11, `nix build .#image-e2e`)

- Owner's changes to "Per-device identity": frp is removed (legacy); no SSH
  keys are provisioned; a generic login `librepod` / `librepod` is baked in
  and onboarding changes it. `root` stays locked. Identity outside the image
  is `/etc/hostname` and `/etc/shadow` on the root partition (see
  `modules/identity`); `users.mutableUsers = true` so a changed password
  survives updates.
- **The fleet's sshd rule was key OR password**, not both:
  `AuthenticationMethods publickey password` lists alternatives. Image
  devices override it with `publickey,password`, so the generic password is a
  console-only login. The fleet's `modules/ssh` is unchanged.
- The k3s node is named from `/etc/hostname` and reaches Ready offline.
- Extra drives (blank NVMe, a SATA disk with generic `esp`/`root` labels, a
  USB stick) change nothing: root, ESP and store mount from the OS disk, PVs
  from the data disk, before and after a reboot. Not covered: a drive with
  LibrePod's own labels and partition UUIDs (another LibrePod's disk, an
  installer USB), and firmware boot order.
- Slot size: the store with k3s takes 957 MiB of the 2 GiB slot.

## Phase 3 design: the installer writes the image (2026-11-12)

Beads: `librepod-os-8ss.3`, `.3.1` (bind to the boot disk), `.3.2` (boot
entry, missing data disk).

### Why

Phase 2 builds the appliance as one image per hardware profile, but nothing
puts it on a device: `librepod-install` still runs disko and nixos-install for
the old OS. Devices are installed on the LibrePod bench before they ship,
booted from netboot or a NixOS USB stick and driven over ssh. Old-OS installs
are done (owner, 2026-11-12): the image installer **replaces** the
disko/nixos-install path; the device flake, `--identity` and `--device` go.

### Goals

- `librepod-install --image FILE --name NAME [--disk DEV] [--data-disk DEV]
  [--keep-data | --wipe-data]`
  (defaults `/dev/nvme0n1`, `/dev/sda`, as today) leaves a device that boots
  the image, is named NAME, and keeps its PVs on the data disk.
- A device mounts root, ESP, store and data only from its own disks, with any
  other drive plugged in: another LibrePod's OS or data disk, a copy of the
  image (same labels, same partition UUIDs), a disk with generic labels.
- The device boots its OS disk with another bootable drive present (Windows
  SSD, Linux USB, the installer stick left in).
- A missing or dead data disk doesn't stop boot: the device comes up and is
  reachable; apps stay down until the disk is back.
- Root fills the OS disk.

### Non-goals

- Downloading the image. Phase 4 brings back `--os-tag` with a release URL;
  that release must then also publish the full disk image per hardware
  profile, not only the store slot and UKI.
- The setup code (epic `rks`), SSH keys, changing the generic password
  (`8ss.9`), telling the owner the data disk is missing.
- Replacing a dead data disk (`8ss.10`), except that it must come down to
  rewriting one file on root.
- Replacing a dead OS disk (`8ss.12`): an owner-made installer stick, and
  apps re-adopting their old PV folders (k3s state lived on the dead root).
  Phase 3 gives it `--keep-data` only.
- Unique file system UUIDs (ext4, vfat): nothing mounts by them.

### Anti-goals

- PVs written to the root partition while the data disk is missing: they
  would vanish from view once the disk is back.
- The installer writing to the drive it booted from, or to a disk picked by
  kernel name order it didn't mean.
- A device booting or mounting another LibrePod disk's root, ESP or store.

### Install steps

1. Check everything before touching a disk: the name (today's regex), disk
   paths, `--disk` ≠ `--data-disk`, neither disk is USB or removable (owner,
   2026-11-12: no USB targets), neither has a mounted partition (the
   installer's own stick), the image file exists, and the installer was
   booted through UEFI (`/sys/firmware/efi`): without it no boot entry can be
   written.
2. Write the image to the OS disk (`.raw` or `.raw.zst`).
3. New disk and partition GUIDs; the backup GPT moves to the end of the disk.
4. Grow the root partition to the end of the disk, and its ext4 with it.
5. Mount the new root partition — found by label among the OS disk's own
   partitions, never through `/dev/disk/by-partlabel` — and write
   `/etc/hostname` (NAME and a newline) and `/etc/librepod/data-partuuid` (the
   data partition's UUID and a newline). Unmount.
6. Data disk: wipe all signatures, new GPT, one partition labelled
   `librepod-data` with a UUID the installer picks, ext4 always formatted
   (stale signatures can't skip it, unlike disko in `xbe`). A data disk that
   already has a `librepod-data` partition is an owner's data (a reinstall):
   the installer stops, before writing any disk, unless told `--wipe-data`
   (as above) or `--keep-data` (owner, 2026-11-12). `--keep-data` leaves the
   disk untouched and records its one `librepod-data` partition's UUID;
   none, or more than one, is refused. Blank and recycled disks are
   formatted without a flag.
7. UEFI boot entry `LibrePod` for the OS disk's ESP, `\EFI\BOOT\BOOTX64.EFI`,
   first in `BootOrder`.

### On the device

- `/`, `/boot` and `/nix/store` mount through links to the boot disk's
  partitions by label, made by one udev rule of ours (initrd and main
  system). systemd 260's udev marks the boot disk `ID_PART_GPT_AUTO_ROOT_DISK=1`:
  in the initrd, the disk holding systemd-boot's `LoaderDevicePartUUID`;
  after the switch, the disk holding `/`. (Our call over systemd's
  `/dev/disk/by-designator/`: one mechanism for all three, and the store
  slots have no designator anyway.)
- `/mnt/k3s`: a stage-2 udev rule links the partition whose UUID matches
  `/etc/librepod/data-partuuid` to a fixed `/dev` path, which the mount uses
  (so systemd still waits for the device). `nofail`.
- Without `/mnt/k3s`, the `/exports/k3s` bind and nfs-server don't start.
  This lives in the image stack; `modules/nfs` stays as the fleet has it.
- `modules/identity`'s contract gains `/etc/librepod/data-partuuid`. The
  image keeps its 512M root (it grows at install); image-e2e's 4G override
  goes.
- Root must be the last partition, as in the layout table above. Today it
  is second (esp, root, store_1, _empty): `image.repart` writes partitions
  in attribute-name order. `modules/image` renames them so root sorts last.
  Nothing has been installed from the phase 2 layout, so changing it is
  free.
- **Root fills the disk, so this layout is final for every device installed
  in this phase** (owner, 2026-11-12). Verity partitions (phase 7) or bigger
  store slots mean reinstalling those devices; the "layout leaves room" in
  Non-goals holds for the image, not for an installed disk. So the layout
  is set for the long run before more installs (2026-11-12): 8 GiB slots
  (the k3s closure is ~1.8 GiB), a 1 GiB ESP (a UKI is ~54 MiB), and an
  empty usr-verity partition after each slot. The slots are typed usr now,
  because an installed partition keeps its type.

### Our calls (for review)

- **Root grows at install, not on first boot** (the bead's wording). The
  installer has the disk offline anyway: two commands, instead of
  systemd-repart in the initrd, which on NixOS needs a whole-disk path before
  the boot disk is known. Cost: an image written by hand with `dd` keeps a
  512M root; that isn't a supported install.
- **The data disk's ID is its GPT partition UUID**, in a plain file on root,
  like `/etc/hostname`.
- **Missing data disk → NFS off, apps down, device reachable.** Proposed in
  chat on 2026-11-12, no objection.
- **A non-UEFI installer boot is refused**, since it can't write the entry.
- **Stale `LibrePod` entries from earlier installs stay**: they point at
  partition UUIDs that no longer exist, and the new entry goes first.

### Proof

- `checks/image-e2e` boots an installed disk instead of the raw image: an
  installer node runs `librepod-install` onto an OS disk and a data disk that
  carry old signatures. It then puts a file on the new data disk and installs
  again: refused with no flag, accepted with `--keep-data`. The pod boots
  that disk with no `bootindex` and finds the file in `/mnt/k3s`. Its
  extra drives gain a copy of the raw image and another LibrePod's data disk.
  Checks: what it checks today; root, ESP, store and `/mnt/k3s` mount from
  the right disks; root is about the disk's size; the `LibrePod` entry is
  first in `BootOrder`. Then the pod restarts with a blank disk in the data
  disk's place: it reaches `multi-user.target` and sshd, and `/mnt/k3s`,
  `/exports/k3s` and nfs-server are down.
- `checks/installer-test` (stubbed, in `nix flake check`) keeps its argument
  scenarios, rewritten for the new flags.
- One real run on `librepod-dev` (M710q, disposable, both disks may be wiped;
  owner, 2026-11-12): image built locally for `lenovo-m710q`, copied over ssh,
  installer run from a NixOS minimal USB. It boots with the stick still in
  and the firmware menu untouched; hostname, root size, data disk, k3s Ready.

### Left to the builder

The exact udev rules, the partitioning tools, image decompression, how the
installer and pod VMs share OVMF variables, how librepod-dev's image gets
built (an ad hoc expression is fine; release outputs are phase 4), and the
docs (README install section, the `librepod-install` lines in CLAUDE.md and
AGENTS.md, the `modules/identity` header).

## Phase 3 results (2026-11-12)

- `nix build .#image-e2e`: 12/12 subtests in 738 s. Refusals: USB, mounted,
  a partition, a disk held by device-mapper (LVM). OVMF boots the installed
  disk by the NVRAM entry alone, with no `bootindex`. An image copy and
  another LibrePod's data disk are never mounted; the installed ESP's UUID
  differs from the copy's. With the data disk missing, the device boots and
  the mount, the bind and nfs-server stay down past the device timeout
  (~300 s here, not 90 s); nothing falls back to root.
- librepod-dev (M710q): the installer refused the old OS's active LVM in 2 s,
  writing nothing; after `vgchange -an` it installed in 17.8 s (root 472.7G,
  entry first in `BootOrder`). Its first boot was never seen: the owner's
  monitor adapter fails. Unverified on hardware.
- librepod-m90q (M90q, image built for `lenovo-m90q`), the run that counts:
  its NVMe held a used Windows install, wiped on the owner's confirmation.
  Installed in 46 s from a NixOS 26.05 live stick. With the stick still in it
  boots LibrePod (BootCurrent 0001; the firmware moved Windows Boot Manager
  behind it), systemd-boot loads from the new ESP, root is 231G, `/mnt/k3s`
  and `/exports/k3s` are on sda1, nfs-server and k3s are active, and the node
  is Ready within 9 minutes.
- Found on hardware: the installed system gets a different DHCP lease than
  the live stick did (networkd's client ID), so look it up as
  `<name>.local`. `efibootmgr` isn't in the image (BootCurrent read from
  efivars). Adding the first SSH key means typing it at the console; on the
  bench `nc -l` worked only because the image's firewall is off.

## Open questions

- Tries count (spike: 2). Each failed try costs up to the health budget.
- Hosting: GitHub Pages / bucket vs Releases redirects.
- A hang *after* blessing reboots into the same version forever; only a newer
  release fixes it. A stability window before blessing narrows it.
