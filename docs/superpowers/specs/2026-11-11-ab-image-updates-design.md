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
one manual release step. *(Our call; open to a protected CI environment.)* Owner chose the CI environment in phase 4.

### Update flow

Phase 5 changes steps 1 and 6: the device finds the version itself (see
"Phase 5 design").

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
- 2026-11-13 (8ss.14): superseded. Image devices take SSH keys only
  (`publickey`); `librepod-install --ssh-key FILE` writes
  `/etc/ssh/authorized_keys.d/librepod`; the generic password stays
  console-only.
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

## Phase 4: release pipeline (2026-11-13)

Owner's calls: host on **GitHub Releases**, sign in a **protected CI
environment** (not the hardware token above). Owning the update URL's domain
stays open as `faq.4`.

- **Where devices look:** `updateUrl` defaults to
  `https://github.com/librepod/os/releases/latest/download/`. A device only
  sees the newest stable release; older ones stay under their tags, and full
  images make skipping versions free. A prerelease is never Latest, so no
  stable device sees it. (Phase 5: beta devices read a rolling `beta`
  release.)
- **One release, every profile:** files are named
  `librepod-<profile>_<v>.{efi,store.raw.zst,raw.zst}` (`librepod.image.profile`,
  set by `mkImage` for a profile under `hw/`), one `SHA256SUMS` lists them
  all, and a device's source pattern matches only its profile. The `.raw.zst`
  is the whole disk for `librepod-install`; devices never download it.
- **Build:** `lib.releaseFiles { device, version }` builds a profile's files
  (`system.build.releaseFiles`); `release-stable.yml` builds one per `hw/`
  profile on a tag, then signs and publishes. The release is created only
  after every image is built and `SHA256SUMS` is signed, so Latest never
  points at a half-made release. Until phase 5, release images bless every
  boot (`healthCheck = true`): only an update's new image runs it.
- **Signing:** the `release-signing` environment holds `RELEASE_SIGNING_KEY`
  (an unprotected ed25519 key). `keys/release.pgp` holds its public half
  (and later the offline backup key, `faq.3`); images trust only that file,
  and the publish job checks the signature against it before uploading. No
  `keys/release.pgp`, no release build.
- **Proof:** `image-e2e` serves the pod's own release, signed as CI signs
  it; the pod lists its version as available through sysupdate, and the
  installer writes that release's `.raw.zst`.

One-time setup (owner, a machine with `gh` logged in):

```sh
export GNUPGHOME="$(mktemp -d)"
gpg --batch --passphrase "" --quick-gen-key "LibrePod release <release@librepod.dev>" ed25519 sign never
mkdir -p keys && gpg --export > keys/release.pgp
gh api -X PUT repos/librepod/os/environments/release-signing
gpg --export-secret-keys --armor | gh secret set RELEASE_SIGNING_KEY --env release-signing --repo librepod/os
rm -rf "$GNUPGHOME"
```

Then in Settings → Environments → release-signing, allow only `master` and
`v*` tags (and, if wanted, required reviewers), and commit `keys/release.pgp`.

## Phase 5 design: the device updates itself (2026-11-13)

Bead: `librepod-os-8ss.5`. Replaces "Update flow" steps 1 and 6 above.

### Why

Until now the Marketplace was to name the version (`spec.json` in ConfigMap
`librepod-os/<hostname>`, `docs/updates.md`) and the device polled for it. An
update then needs k3s working, which is exactly when it may be needed most: an
update that fixes a broken k3s could never arrive. The Marketplace side was
never built (no code in the marketplace repo reads or writes that ConfigMap),
so the contract is free to change.

Owner (2026-11-13): reverse the flow. The device learns about updates from
GitHub Releases and updates without k3s. The Marketplace only shows that an
update is there and passes on the owner's answer, as on an iPhone: install
now, tonight, or automatically.

There are two kinds of device, with two update paths:

- **Image devices** (supported hardware, `librepod-install`): this phase.
- **Library devices** (an owner's own flake on any hardware, `lib.mkDevice`):
  update by flake pin, nothing on the device (below). The old on-device updater
  retires.

### Goals

- An image device finds, downloads and installs updates with k3s stopped,
  broken or absent. Only showing the notice and receiving the owner's answer
  need k3s, and the Marketplace UI runs in k3s anyway.
- Onboarding asks for the channel (stable or beta) and automatic updates (on or
  off). Both can be changed later in the UI, or over ssh with the CLI.
- A new version shows as a notice with "Install now" and "Tonight". With
  automatic updates on, every new version installs in the night window.
- A new version downloads as soon as it is found, so installing is a reboot.
- A version whose new boot failed is never installed automatically again; the
  owner may retry it.
- k3s's changes made by a failed version are undone: its datastore is restored.
- Stable devices run the exact files beta devices ran (build once, promote).

### Non-goals

- The Marketplace side: the notice, the onboarding questions and the RBAC for
  the ConfigMap below live in the marketplace repo and code against the
  contract here.
- Installing at a time other than now or the night window.
- Images built from master. Master is for library devices
  (`github:librepod/os` or the `unstable` tag), as today.
- Updates or notices for library devices.
- Delta updates, metered connections, rolling back PV data.
- Reporting rollbacks to LibrePod: `librepod-os-8ss.15`, with the owner's
  consent, deferred until there is fleet monitoring (owner, 2026-11-13). This
  phase keeps the reason on the device, which that bead sends.

### Anti-goals

- The updater depending on k3s or kubectl.
- A device moving to a lower version on any channel: k3s does not start on a
  datastore a newer k3s wrote.
- An install the owner didn't choose: with automatic updates off, nothing
  installs by itself.
- Anything a pod writes reaching the host unvalidated: the Marketplace UI faces
  the internet.

### Channels and versions (release pipeline)

Owner (2026-11-13): build once, promote; rc tags retire.

- **Every tag `vX.Y.Z` is a candidate.** `release-stable.yml` builds and signs
  it as today and publishes it as a prerelease (never Latest) with all files.
- **The same publish job copies it into the rolling release `beta`:** the
  device files only (`*.efi`, `*.store.raw.zst`, `SHA256SUMS`,
  `SHA256SUMS.gpg`), then deletes the previous candidate's files there. Only
  when the candidate is higher than what `beta` holds: a hotfix for stable
  never moves beta back. New files go up first and `SHA256SUMS` and its
  signature last; a device checking mid-copy fails the signature or a checksum
  and retries at its next check. `SHA256SUMS` still lists the `.raw.zst` files
  `beta` doesn't hold; sysupdate fetches only files matching its pattern.
  About 2 GB per profile per candidate.
- **Promote** (a new manual workflow, version as input) turns `vX.Y.Z` into a
  full release marked Latest. No rebuild, same files, same signature. It
  refuses a version lower than the current Latest.
- **A failed candidate is never promoted;** its fix is the next patch number.
  Versions are plain `X.Y.Z`, so sysupdate orders them numerically.
- **Tags with `-` are refused,** and the cut compares against all `v*` tags.
  Why: systemd orders `0.5.0-rc.2` above `0.5.0` (`systemd-analyze
  compare-versions`), so an rc device would never take its stable. `~` sorts
  lower, but GitHub reportedly renames it to `.` in asset names, and
  `0.5.0.rc.2` sorts above `0.5.0` too.
- **Device URLs:** stable `https://github.com/librepod/os/releases/latest/download/`,
  beta `https://github.com/librepod/os/releases/download/beta/`. Every stable
  version was a candidate first, so beta never misses one.
- Latest moves only on promote, so tagging an old-line `0.4.x` no longer moves
  it by itself.
- Signing is unchanged (`release-signing`, `keys/release.pgp`). The
  `unstable` release for library devices is unchanged.

### On the device: the updater (no kubectl)

A module in `imageModules`. Its files live under `/var/lib/librepod/updates/`
on root, so they survive updates: the settings, the status, the record of the
install in flight, the failed versions, and the k3s snapshot.

- **Settings:** channel, automatic updates, time zone. Until onboarding sets
  them: stable, off, UTC.
- **Check:** at boot and at least every 6 hours, with jitter, through
  sysupdate against the channel's URL. A version higher than the booted one is
  `available`.
- **Download:** as soon as one is available, in both modes: `vacuum`, then
  `acquire <v>` (the spike: a failed acquire blocks the next one until
  vacuumed; never vacuum between `acquire` and `update --offline`). A newer
  version found later replaces it.
- **When to install:** "now" at once; "tonight" at the next night window;
  automatic at the first window after the download, unless the version is in
  the failed list.
- **What to install:** the newest version on the owner's channel at install
  time, not the one showing when the owner chose (owner, 2026-11-13). There
  is one spare slot, so a newer version's download replaces an older one; an
  install waits for a download in progress ("now" until it finishes,
  "tonight" while the window lasts, then the next night). The owner's install
  also retries a version in the failed list; automatic never does.
- **Night window:** 02:00–05:00 in the owner's time zone. Devices
  run on UTC (nothing sets a time zone), so onboarding sends the browser's
  IANA zone, and the updater uses it for the window only.
- **Install:** record `{from, to, phase: snapshot}`, stop k3s, copy
  `/var/lib/rancher/k3s/server/db` (SQLite, single server) to the snapshot,
  `update --offline <v>`, phase `installed`, reboot. If `update --offline`
  fails: start k3s, clear the record, report `failed`.
- **Health gate** (`librepod.image.healthCheck`, now set by this module; the
  `true` shortcut in `lib.releaseFiles` and the image-profiles stub go): k3s
  and sshd active, the node Ready, all of it stable for 2 minutes, and the
  channel's `SHA256SUMS` fetched and verified against the image's keyring,
  which proves the new version can still update itself. All within the gate's
  15 minutes; otherwise `FailureAction=reboot`, and after its tries the old
  version boots. These are the old sentinel's checks. Before giving up, the
  gate writes the check that failed last into the record.
- **After blessing,** the new version's updater clears the record, deletes the
  snapshot and reports `done`.
- **Fallback:** a unit ordered before `k3s.service`, on every boot. With a
  record whose `from` is the booted version:
  - phase `installed`: the new version used up its tries. Restore the
    snapshot, add `to` to the failed list, clear the record, report
    `rolled-back` with the record's reason in `detail` ("did not finish"
    when there is none: a panic, hang or power cut).
  - phase `snapshot`: the install never finished (a power cut). Restore the
    snapshot (k3s has not run since), clear the record, report `failed`
    ("interrupted"); not added to the failed list.

  A power cut after `update --offline` and before the reboot still boots the
  new version next: it is the newest entry with tries left.

### The bridge to the Marketplace (the only kubectl)

A separate unit, after `k3s.service`, every minute. Its failures never touch
the updater. ConfigMap `marketplace-ui/librepod-os-update` (the namespace of
the setup-code Secret; the bridge creates both if absent). Each side
merge-patches only its own keys.

`status.json` (device → UI; the bridge copies the updater's status on change):

```json
{
  "current": "0.5.0",
  "available": "0.5.1",
  "downloaded": true,
  "state": "ready",
  "installAt": "2026-11-14T02:00:00+03:00",
  "settings": { "channel": "stable", "auto": false, "timezone": "Europe/Minsk" },
  "handled": { "settings": 3, "install": 7 },
  "failedVersions": [],
  "lastCheck": "2026-11-13T12:00:00Z",
  "detail": "0.5.1 is ready to install"
}
```

`state` is one of `up-to-date`, `downloading`, `ready`, `scheduled`,
`installing`, `done`, `rolled-back`, `failed`; `available` is null when up to
date; `installAt` is set while `scheduled`.

- A final state (`done`, `rolled-back`, `failed`) stays until the next
  install starts or a check finds a version not in `failedVersions`; a check
  that finds nothing new leaves it. *(Our call.)*
- `failedVersions` is the failed list, so the UI can show an `available`
  that failed here as "failed, try again" instead of an ordinary notice, and
  can explain why automatic updates skip it. *(Our call.)*

`settings.json` (UI → device; onboarding, and later changes):
`{ "rev": 3, "channel": "beta", "auto": true, "timezone": "Europe/Minsk" }`,
applied once per `rev`.

`install.json` (UI → device; the owner's click):
`{ "id": 7, "when": "now" }`, `when` being `now` or `tonight`; handled once
per `id`. It names no version: the device installs the newest at install time
(above).

- Two keys, so a click right after onboarding can't overwrite the settings.
- The bridge validates everything (integers, the channel and `when` enums, the
  zone exists in tzdata) and passes valid requests to the CLI; it
  changes no files itself. A rejected one is reported in `detail`.
- A change made with the CLI shows in `status.settings`. A `rev` or `id`
  already handled is never applied again, so the latest action wins.
- The node label `librepod.os/version` goes: nothing reads it, and the status
  carries the version.
- `docs/updates.md` is rewritten as this contract.

### CLI

`librepod-update status | check | install now|tonight | channel stable|beta |
auto on|off | timezone <Area/City>`. It works with k3s down, and the bridge
calls the same commands.

### Library devices (owner, 2026-11-13)

- Update by flake pin: `github:librepod/os/vX.Y.Z` (or master, or the
  `unstable` tag), then `nix flake update librepod` and `nixos-rebuild switch`.
  Nothing runs on the device.
- Keep working: `lib.mkDevice`, `applianceModules`, `nixosModules`, a hardware
  profile as a module path, and the `mk-device`, `hw-profiles` and
  `installed-device` checks. `mkDevice` keeps `version` and
  `/etc/librepod-release`, so existing device flakes still evaluate.
- Retire: `modules/updates` (its `applianceModules` entry and `mkDevice`'s
  `librepod.updates.enable` default), `checks/updater-test.nix`,
  `checks/sentinel-test.nix`, `checks/e2e` (`updates-e2e`, `trial-spike`),
  `.github/workflows/updates-e2e.yml`, and the README's sections on them.

### Proof

- A stub test in `nix flake check` (like `installer-test`), with sysupdate and
  systemctl stubbed: validation and once-only handling of `settings.json` and
  `install.json`, the window in a time zone, the failed-list rule, both
  fallback phases, never a lower version.
- A VM test (KVM, local; extends `image-e2e`, which already serves a signed
  release), a device on 0.5.0 with k3s, and releases served as CI signs them:
  0.5.1 (good) and 0.5.2 (fails its health gate) on stable; 0.5.3 only on beta.
  1. With k3s stopped: `check` finds 0.5.1 and downloads it; `install now`
     boots 0.5.1, k3s Ready, blessed, `done`, snapshot gone.
  2. Through the ConfigMap: `settings.json` turns automatic updates on, with a
     zone whose window is now: 0.5.2 installs by itself, fails, and the device
     is back on 0.5.1, `rolled-back`, with k3s's data as before 0.5.2 (an
     object made while 0.5.2 ran is gone).
  3. 0.5.2 is not installed again automatically; `install.json` with `now`
     retries it.
  4. Switching to beta offers 0.5.3; stable doesn't.
  5. A power cut after the snapshot, before `update --offline`: back on 0.5.1,
     `failed` "interrupted", not in the failed list; the next install works.
- The first real candidate: `beta` holds only its device files and sums;
  after promote, `latest/download/SHA256SUMS` serves it; a real device on
  each channel lists it through GitHub's redirects (systemd-pull following
  them is unverified so far).

### Our calls (for review)

- The night window is 02:00–05:00 local time, fixed.
- Downloads are automatic in both modes: about 2 GB per release.
- Before onboarding: stable, automatic updates off, UTC.
- The ConfigMap lives in `marketplace-ui`, with three keys.
- The health gate includes fetching the channel's signed `SHA256SUMS`.
- The bridge polls every minute; the updater checks every 6 hours.

### Left to the builder

Module and file names; how sysupdate gets each channel's definitions (two
directories, or `--definitions`); timers within the limits above; the format
of the record in flight; how the VM test changes k3s's data on 0.5.2; the
promote workflow's shape; README, AGENTS.md and CLAUDE.md.

### Risks

- GitHub refuses files of 2 GiB or more; rc.2's disk image is 1.95 GB and its
  store slot 1.90 GB. In this phase the release workflow only refuses to
  publish when a file is that big, checked before any upload; shrinking the
  image stays with `faq.2` (firmware) and `faq.17` (smaller store).
  *(Our call.)*
- The health gate needs k3s: a device whose k3s is broken for reasons no OS
  version fixes (its data, say) rolls back every update.
- borgmatic's nightly run (03:15) falls inside the night window; an install
  mid-backup can leave workloads scaled to 0 and Flux suspended. Not on image
  devices yet; designed later in `librepod-os-8ss.16`.

## Open questions

- Tries count (spike: 2). Each failed try costs up to the health budget.
- Hosting: settled as GitHub Releases (phase 4); a domain LibrePod owns in
  front of it is `faq.4`.
- A hang *after* blessing reboots into the same version forever; only a newer
  release fixes it. A stability window before blessing narrows it.
