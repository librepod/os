# Phase 2: appliance as an image, identity out of Nix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Tracking is in **bd**, not checkboxes (repo rule: no markdown TODO lists): one child bead of `librepod-os-8ss.2` per task, steps numbered.

**Goal:** The appliance stack (k3s, NFS, ssh, mDNS…) builds as one update-ready disk image per hardware profile. Nothing per-device stays in the Nix config: the device name is a file on the root partition, and the login is generic, changeable after install.

**Architecture:**
- The spike's `checks/ab-spike/image.nix` becomes `modules/image`.
- frp is deleted from the repo (legacy).
- A small `modules/identity` makes the hostname come from `/etc/hostname`, and gives one generic login whose password survives updates once changed.
- `flake.nix` gets `imageModules` + `lib.mkImage`, next to the untouched `applianceModules` + `lib.mkDevice`.
- A KVM test boots the image and checks all of it, with k3s.

**Tech Stack:** NixOS 26.05 (`image.repart`, `profiles/image-based-appliance.nix`, systemd 260 sysupdate), NixOS test driver (KVM).

**Spec:** `docs/superpowers/specs/2026-11-11-ab-image-updates-design.md` (approved 2026-11-11; phase 2 of 7). Owner's changes on 2026-11-11 replace the spec's "Per-device identity" section:
- frp is legacy and is removed;
- no SSH keys are provisioned (consumer devices);
- a generic static login is baked in, and onboarding overwrites it.

## Global Constraints

- nixpkgs `nixos-26.05`; `allowUnfree = false`; scripts via `writeShellApplication` with `runtimeInputs`.
- No Nix on the device: the image stack excludes `modules/nix`, `modules/updates` (phase 5 replaces it), `modules/disko`, `modules/users`.
- `applianceModules`, `lib.mkDevice`, `modules/{users,disko,updates}` keep their behavior. Only shared code may be factored out. frp is the one deliberate break (Task 2).
- No frp anywhere. No SSH keys shipped or provisioned.
- The device installs only images signed by the pinned keyring; the sysupdate timer stays off; `ProtectVersion=%A`, `InstancesMax=2` (unchanged from the spike).
- Two disks by product contract (master `d495f1c`): OS disk + data disk at `/mnt/k3s`.
- `nix fmt -- --check` clean and `nix flake check` passes after every task.
- Git: start by merging `origin/master` (PR #22 is open and pushed, so merge, don't rebase). One commit per task on `feat/ota-updates`. Push only when the user asks.

## What an image device carries outside the image

| Where (root partition / data disk) | What | Written by |
|---|---|---|
| `/etc/hostname` | device name, `^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$`, newline | installer (phase 3) |
| `/etc/shadow` | passwords; first boot creates `librepod` / `librepod`, `root` locked | onboarding (`chpasswd`) |
| `/etc/ssh/ssh_host_*`, `/etc/machine-id` | generated on first boot | systemd / sshd |
| data disk: GPT partition label `librepod-data`, ext4 → `/mnt/k3s` | PVs | installer (phase 3) |

Our calls, for review:
- **Login `librepod` / `librepod`, `root` locked.** One generic credential, not two; `librepod` has sudo through `wheel`.
- **sshd keeps today's rule: key and password together.** No keys ship, so the generic password works only at the console, never from the LAN. A power user who adds a key to `~/.ssh/authorized_keys` gets ssh.
- **`users.mutableUsers = true`**, overriding the appliance profile. Passwords then live in `/etc/shadow` on the root partition, and updates never touch that partition. If `/etc` becomes immutable (phase 7), this moves to userborn's `/var/lib/nixos`.
- **`/etc/hostname` is a plain file NixOS doesn't manage,** so `hostnamectl set-hostname` keeps working.

## Review Focus

1. **The generic password is not a network login.** ssh with `librepod` / `librepod` and no key is refused. Covered by Task 4, "the generic login".
2. **A password changed after install survives a reboot** (and so an update, which never writes the root partition), and the old one stops working. Covered by Task 4, "a changed password … survive a reboot".
3. **The k3s node gets the device's name**, not `librepod` (the networking module's default) or `localhost`. Later phases key the node and ConfigMap on it. Covered by Task 4, "the k3s node is named after the device".
4. **The SSH host key and machine-id stay the same across reboots.** A changed host key looks like a MITM warning to the owner after every update. Covered by Task 4, the reboot subtest.
5. **`root` stays locked**, so there is no second generic credential. Covered by Task 4, "the generic login".

---

### Task 1: Promote the spike's image module to `modules/image`

**Files:**
- Move: `checks/ab-spike/image.nix` → `modules/image/default.nix` (`git mv`)
- Modify: `flake.nix` (`nixosModules.image = ./modules/image;`)
- Modify: `checks/ab-spike/default.nix` (import `../../modules/image`; `librepod.ab` → `librepod.image` in the node and in `behaviors.unhealthy`)

**Interfaces:**
- Produces: module `modules/image` with options `librepod.image.{updateUrl, pubring, slotSize, tries, healthCheck}`, same types and defaults as the spike's `librepod.ab.*`. Partition labels: `librepod-esp`, `librepod-root`, `store_<version>` / `_empty`.

1. `git merge origin/master` (already checked: it merges cleanly). Then run `nix flake check`. Expected: passes.
2. Move the file and rename the option namespace to `librepod.image`. Rename the partition labels `esp` → `librepod-esp` and `root` → `librepod-root`, in both `fileSystems` and `image.repart.partitions.*.repartConfig.Label`. Replace the header's "(spike) … candidate" wording with what the module is. Comment the label change in one line: a generic label like `root` can collide with any plugged-in disk. Leave the store slot labels alone: sysupdate's `MatchPattern` owns them.
3. Run `nix build .#ab-spike -L` (KVM, ~20 min). Expected: `ab-spike: all scenarios passed`. This is the regression test for the move and the relabel.
4. Run `nix fmt` and `nix flake check`. Commit: `refactor(image): promote the A/B spike module to modules/image`.

### Task 2: Remove frp

**Files:**
- Delete: `modules/frpc/`
- Modify: `flake.nix`: drop `nixosModules.frpc`, and drop "frpc" from the `mkDevice` doc comment (`modules — … identity modules (users, frpc, …)`).
- Modify: `checks/eval-modules.nix`: drop `../modules/frpc` and the `librepod.frpc` stub block.
- Modify: `modules/k3s/default.nix`: drop port `7400` and its `# 7400 - frpc admin port` comment.
- Modify: `README.md` (the `frpc` module row; "users, keys, frpc" in the example comment), `AGENTS.md:29` (`frpc` as the example option-based module → `users` alone), `checks/stub-identity.nix:2` comment.

1. Make the deletions and edits above.
2. Run `git grep -n -i frp -- ':!docs/superpowers'`. Expected: only the false positive in `modules/k3s/charts/flux-instance.nix` (a hash).
3. Run `nix flake check` and `nix fmt`. Expected: passes.
4. Commit: `chore: remove frp (legacy)`. The body must say: a device whose `identity.nix` still sets `librepod.frpc` will fail to evaluate its next update, and stays on its current version until that block is deleted.

### Task 3: `imageModules` and `lib.mkImage`, evaluated per hardware profile

**Files:**
- Modify: `flake.nix`

**Interfaces:**
- Consumes: `self.nixosModules.image` (Task 1).
- Produces:
  - `lib.imageModules`: list of modules, the image base stack, shared verbatim by `mkImage` and the Task 4 test node.
  - `lib.mkImage { device, version, modules ? [ ] }` → `nixosSystem`. `device` takes the same two forms as `mkDevice`. `version` becomes `system.image.version` (the sysupdate `@v`).
  - Check `checks.x86_64-linux.image-profiles`.

1. Write the check first, beside `mk-device`. For every `hwProfiles` entry, deepSeq `(self.lib.mkImage { device = hw; version = "0"; modules = [ stub ]; }).config.system.build.image.drvPath`. Use the same `forcedEval` pattern so nothing gets built. `stub` sets:
   - `librepod.image.updateUrl = "https://updates.invalid/"`;
   - `pubring = pkgs.writeText "empty.pgp" ""`;
   - `healthCheck = "${pkgs.coreutils}/bin/true"`.
2. Run `nix build .#checks.x86_64-linux.image-profiles`. Expected: FAIL, `mkImage` missing.
3. In the `let`, add `imageModules`:
   - the overlay attrset (same as `applianceModules`' first item);
   - `common`, `networking`, `ssh`, `usb-automount`, `k3s`, `nfs`, `image`;
   - `{ fileSystems."/mnt/k3s" = { device = "/dev/disk/by-partlabel/librepod-data"; fsType = "ext4"; }; }` — comment: the data disk, the image-side twin of disko's `disk.data`;
   - `{ system.stateVersion = "26.05"; }` — comment: every image install shares it, so it is frozen; changing it needs a migration for every installed device.

   Factor `mkDevice`'s inline `if builtins.isString device …` into a `let` helper `hwModule = device: …` and use it in both functions. Add `lib.imageModules` and `lib.mkImage`: `nixosSystem { system = "x86_64-linux"; modules = imageModules ++ [ (hwModule device) { system.image.version = version; } ] ++ modules; }`. No `specialArgs`: no image module needs one.
4. Run `nix build .#checks.x86_64-linux.image-profiles`. Expected: PASS for `lenovo-m710q` and `lenovo-m90q`. Already confirmed: the spike module, base stack and M710q profile evaluate together, with `systemd-boot.enable` left on.
5. Run `nix flake check` (the `mk-device` and `installed-device` checks prove the `hwModule` refactor changed nothing) and `nix fmt`. Commit: `feat(image): imageModules + lib.mkImage, evaluated per hw profile`.

### Task 4: Identity outside Nix: `modules/identity` and the `image-e2e` VM test

**Files:**
- Create: `checks/image-e2e/default.nix`
- Create: `modules/identity/default.nix`
- Modify: `flake.nix`:
  - `nixosModules.identity`;
  - append `identity` to `imageModules`;
  - output `image-e2e = …callPackage ./checks/image-e2e { inherit self nixpkgs; };`, with a comment in the `ab-spike` style (local only, KVM).
- Modify: `AGENTS.md` (Device Profiles: one sentence on `mkImage`, pointing at `modules/identity` for what lives outside the image)

**Interfaces:**
- Consumes: `self.lib.imageModules` (Task 3), `librepod.image.*` (Task 1).
- Produces: module `modules/identity`, with no options. Its header comment carries the table above, which is phase 3's contract.

1. **Write the test** `checks/image-e2e/default.nix` as `{ self, nixpkgs }:` → `runNixOSTest`. Set `node.pkgsReadOnly = false` (the k3s overlay). One node, `pod`:
   - `imports = self.lib.imageModules`; `system.image.version = "1"`; `librepod.image` as in Task 3's stub.
   - VM hardware, the hw profile's job on a device:
     - virtio modules in `boot.initrd.availableKernelModules` (list in `checks/e2e/hw-vm.nix`);
     - `networking.interfaces.eth0.useDHCP = true`.
   - Boot its own disk, as in `checks/ab-spike/default.nix:82-90`:
     - `directBoot.enable = false`, `mountHostNixStore = false`, `useEFIBoot = true`;
     - `fileSystems = lib.mkForce { }`;
     - `memorySize = 4096`.

     Also `services.timesyncd.enable = lib.mkForce false`, as `checks/e2e/default.nix:35`.
   - `image.repart.partitions`:
     - `root.repartConfig.{SizeMinBytes,SizeMaxBytes} = lib.mkForce "4G"`: k3s doesn't fit the spike's 512M. Root growth is phase 3.
     - `root.contents."/etc/hostname".source`: a file with `pod-image\n`, as the installer will write it.
   - **Disks (owner, 2026-11-11: an added NVMe, SATA or USB drive must not break boot or the data mount).** Besides the OS disk (virtio, `bootindex=1`, standing in for the installer's boot entry), every boot has, via `virtualisation.qemu.options` and env-var paths to qcow2 overlays made in the test script:
     - data disk, NVMe `serial=data`: GPT, one ext4 partition labeled `librepod-data` (built with `systemd-repart` like `image.repart`);
     - extra NVMe `serial=extra`: blank;
     - SATA (`ahci`) `serial=foreign`: a disk from another computer, ESP labeled `esp` plus ext4 labeled `root` (the generic labels Task 1 moved away from);
     - USB stick (`qemu-xhci` + `usb-storage`) `serial=usb`: blank.
     The VM initrd loads `nvme ahci xhci_pci usb_storage sd_mod` like `hw/lenovo-m90q`, so the extra drives are visible while root mounts.
   - `environment.systemPackages = [ pkgs.sshpass ]`.

   Test script:
   - Copy the helpers `boots`, `wait_boots`, `reconnect`, `reboot_and_wait` from `checks/ab-spike/default.nix:152-184`.
   - Start the same way as `checks/ab-spike/default.nix:201-207`: a qcow2 overlay of `${m.system.build.image}/${m.image.filePath}` as `NIX_DISK_IMAGE` (no server, so set it first), then `pod.start(allow_reboot=True)`.
   - The key is `snakeOilPrivateKey` / `snakeOilPublicKey` from `import "${nixpkgs}/nixos/tests/ssh-keys.nix" hostPkgs`. The private key is copied to `/tmp/key`, mode 600.
   - Subtests, in order:
     ```python
     ssh = "sshpass -p {pw} ssh -o StrictHostKeyChecking=no {opts} librepod@localhost true"
     with subtest("hostname comes from /etc/hostname"):
         assert pod.succeed("hostname").strip() == "pod-image"
     with subtest("the generic login: console only until a key is added; root locked"):
         assert pod.succeed("getent shadow root | cut -d: -f2").startswith("!")
         pod.fail(ssh.format(pw="librepod", opts="-o PubkeyAuthentication=no"))
         # a power user adds a key: install -d/-o librepod -g users, .ssh 700, authorized_keys 600
         pod.succeed(ssh.format(pw="librepod", opts="-i /tmp/key"))
     with subtest("extra NVMe, SATA and USB drives change nothing"):
         # disk serial behind each mount: / /boot /nix/store on the OS disk, /mnt/k3s on "data"; again after the reboot
     with subtest("PVs land on the data partition"):
         assert pod.succeed("findmnt -no PARTLABEL /mnt/k3s").strip() == "librepod-data"
         pod.succeed("findmnt /exports/k3s")
     with subtest("the k3s node is named after the device"):
         pod.wait_for_unit("k3s.service", timeout=600)
         # node pod-image Ready: same jq as checks/e2e/default.nix:204-207
         # and `k3s kubectl get nodes -o name` == "node/pod-image" only
     with subtest("a changed password, the host key and machine-id survive a reboot"):
         pod.succeed("echo librepod:new-pw | chpasswd")   # what onboarding will do
         # before = ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub, /etc/machine-id
         reboot_and_wait()
         # after == before; hostname still pod-image
         pod.succeed(ssh.format(pw="new-pw", opts="-i /tmp/key"))
         pod.fail(ssh.format(pw="librepod", opts="-i /tmp/key"))
     ```
   - Last, print the store slot's real size against `slotSize`: `os.stat(p).st_blocks * 512` of `${m.system.build.image}/${m.image.baseName}.store.raw`. That answers the spec's open slot-size question with k3s in.
2. Run `nix build .#image-e2e -L`. Expected: FAIL at "hostname comes from /etc/hostname", with the hostname `librepod` (the networking module's default).
3. **Write `modules/identity/default.nix`**, header comment = the table above:
   - `networking.hostName = ""`. One-line why: the name lives in `/etc/hostname`, and NixOS writes none when it is empty. Avahi publishes the system name then.
   - `users.mutableUsers = lib.mkForce true`. One-line why: onboarding changes the password and it must outlive updates. The appliance profile sets it `false`.
   - `users.defaultUserShell = pkgs.zsh`; `users.users.librepod = { isNormalUser = true; extraGroups = [ "wheel" ]; initialPassword = "librepod"; }`. `initialPassword` applies once, when the account is first created. Root keeps NixOS's locked default; set nothing for it.
4. Run `nix build .#image-e2e -L`. Expected: every subtest passes, and the slot size is printed. If k3s can't reach Ready offline, the node-Ready check is the only part that may need network. Stop and report; don't add network access to the test.
5. Add the `AGENTS.md` sentence. Add the spec's phase 2 results: the slot size, the owner's identity changes, and anything the test forced. Then `nix fmt`, `nix flake check`, and `bd close` the task beads and `librepod-os-8ss.2`. Commit: `feat(identity): image devices keep their name and password outside Nix`.

---

## Not in this phase (beads to file at session close)

- Drives carrying LibrePod's own labels (another LibrePod's OS or data disk, a LibrePod installer USB) are not covered by the extra-drives test: same image, same labels and even the same partition UUIDs. Root, ESP and store need binding to the boot disk (systemd 260 udev sets `ID_PART_GPT_AUTO_ROOT_DISK` on the disk holding systemd-boot's `LoaderDevicePartUUID`), plus unique partition UUIDs written at install; the data disk needs a per-device ID written at install. A drive with its own bootloader can still win the firmware boot order: the installer registers a boot entry; check on a real M90q (phase 6). A missing data disk fails `/mnt/k3s` at boot (no `nofail`).
- Partition labels are still a by-label lookup. A second LibrePod disk, or the installer's own USB in phase 3, carries the same labels, and udev picks one at random. Fix it by binding root and ESP to the boot disk (gpt-auto or UUID), together with verity in phase 7, or in phase 3 if the installer boots from a LibrePod image.
- Onboarding's password change (`chpasswd` on the host, from the Marketplace): its own design. This phase only guarantees the change persists.
- Watchdog module in each hw profile's initrd (`iTCO_wdt`): phase 6.
- Health check content, updater, k3s snapshot: phase 5. `mkImage` callers set `librepod.image.healthCheck` until then.
- `updateUrl` and `pubring` defaults: phase 4 (release pipeline, hosting, key).
