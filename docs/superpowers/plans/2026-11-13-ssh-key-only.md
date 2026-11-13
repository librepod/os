# Image devices: SSH by key only, `--ssh-key`, data disk out of identity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Tracking is in **bd**, not checkboxes (repo rule: no markdown TODO lists): one child bead of `librepod-os-8ss.14` per task, steps numbered.

**Goal:** An image device accepts SSH with a public key only, the installer can put that key on it, and the data-disk config leaves `modules/identity` unchanged in behaviour.

**Architecture:**
- `modules/data-disk` (new, in `imageModules`): the udev rule, `/mnt/k3s`, `/exports/k3s` nofail and the NFS ordering, moved verbatim from `modules/identity`.
- `modules/identity`: sshd takes `publickey` only; password and keyboard-interactive are off. `modules/ssh` and the fleet are unchanged.
- `librepod-install --ssh-key FILE`: checks every line of FILE is a public key before any write, then writes it to `/etc/ssh/authorized_keys.d/librepod` on the new root. The image's sshd already reads that path.
- `checks/image-e2e` installs with `--ssh-key` and logs in with it, with nothing set up on the pod. `checks/installer-test.nix` covers the refusals.

**Tech Stack:** NixOS 26.05 modules, bash (`writeShellApplication`), OpenSSH `ssh-keygen`, the NixOS test driver (KVM).

**Spec:** bead `librepod-os-8ss.14` (`bd show librepod-os-8ss.14`; owner-agreed 2026-11-13), within `docs/superpowers/specs/2026-11-11-ab-image-updates-design.md`.

## Global Constraints

- Only image devices (`imageModules`, `mkImage`) change. `applianceModules`, `mkDevice`, `modules/ssh` behaviour and `modules/nfs` stay as the fleet has them (bead 8ss.8 owns the fleet's sshd).
- sshd on image devices: `AuthenticationMethods "publickey"`, `PasswordAuthentication false`, `KbdInteractiveAuthentication false`. `librepod` / `librepod` stays a console login; root stays locked.
- Key file on the device: `/etc/ssh/authorized_keys.d/librepod`, owner root, mode 0644; its directory is mode 0755 (sshd StrictModes).
- CLI: `librepod-install ... [--ssh-key FILE]`, optional; FILE holds one or more public keys. It is checked before the first write, like every other argument.
- No NixOS module at install time and no sysext/confext (bead: not in scope).
- `nix fmt -- --check` and `nix flake check` pass after every task.
- Git: one commit per task on `feat/ota-updates`; commit this plan first as `docs: plan for SSH by key only (8ss.14)`. Push only when the user asks.

## Our calls (for review)

- **The data disk gets its own module, not `modules/image`.** The bead allows either. `checks/ab-spike` imports `modules/image` without `modules/nfs`. There, the `/exports/k3s` options would declare a mount with no device.
- **`mkForce false` in `modules/identity`, not `mkDefault` in `modules/ssh`.** `modules/ssh` then doesn't change, so the fleet can't change either. Only its comment changes.
- **Per-line key check.** Tested on 2026-11-13: `ssh-keygen -lf FILE` exits 0 when FILE has one good key and a garbage line, and when FILE is a *private* key. So the installer checks each non-blank, non-`#` line with `ssh-keygen -lf -`. A private key's first line fails that check, so it is never copied to a world-readable 0644 file. A line with options (`from="…" ssh-ed25519 …`) passes, and so does a CRLF line.
- **CRs are stripped when the key is written.** A key file saved on Windows then can't depend on how sshd parses a `\r`.
- **The keyless device in the e2e is simulated by deleting the installed key file.** A second install and boot would take several more minutes, and `--ssh-key` writes nothing else, so the result is the same device.
- **The SSH client is the pod itself, as it is today.** `/root/key` is the client's private key. Nothing is written to `~librepod`.

## Review Focus

1. **A private key passed by mistake** (`--ssh-key ~/.ssh/id_ed25519`): it must be refused before any write and never copied. Pinned in Task 2's installer-test.
2. **A key file with one good line and one bad line** (a truncated paste): it must be refused, because a key-only device with a broken key file has no SSH. Pinned in Task 2.
3. **A reinstall with `--keep-data` but no `--ssh-key`**: root is rewritten, so the old key is gone and the device has no SSH. Pinned in the docs: usage text and README say a reinstall needs `--ssh-key` again.
4. **An empty or comment-only key file**: it must be refused ("no public key"), not accepted as a no-op. Pinned in Task 2.
5. **The key surviving first-boot `/etc` activation and a reboot** (bead: unverified): proven by Task 3's e2e, which logs in by key on first boot and again after the reboot subtest.

---

### Task 1: Data-disk config moves to `modules/data-disk`

**Files:**
- Create: `modules/data-disk/default.nix`
- Modify: `modules/identity/default.nix:40-53` (remove the block), `flake.nix:62-77` (`imageModules`, after `nfs`), `flake.nix:95-118` (`nixosModules.data-disk = ./modules/data-disk;`)

**Interfaces:** Produces `nixosModules.data-disk`, a direct-config module with no options. It is in `imageModules` only.

1. Record the baseline with this command, and save its output to the scratchpad:
   ```bash
   nix eval --json .#image-e2e.nodes.pod --apply 'c: { fs = builtins.mapAttrs (n: v: { inherit (v) device fsType options; }) c.fileSystems; nfs = c.systemd.services.nfs-server.unitConfig.RequiresMountsFor; rule = builtins.match ".*(SUBSYSTEM==\"block\", ENV\\{ID_PART_ENTRY_NAME\\}==\"librepod-data\"[^\n]*).*" c.services.udev.extraRules; }'
   ```
2. Move the last block of `modules/identity` (the udev rule, `fileSystems."/mnt/k3s"`, `fileSystems."/exports/k3s".options`, `systemd.services.nfs-server.unitConfig.RequiresMountsFor`) verbatim, with its comments, into `modules/data-disk/default.nix` (`{ pkgs, ... }:`). Give the new file a 2-line header: what the module does and that the data disk's format is listed in `modules/identity`. Register it and add it to `imageModules`.
3. Run step 1's command again. Expected: identical JSON.
4. Run `nix fmt -- --check && nix flake check`. Expected: pass. `checks/ab-spike` must still evaluate: `nix eval .#ab-spike.drvPath`.
5. Commit: `refactor(image): data-disk config out of modules/identity into modules/data-disk`.

### Task 2: `librepod-install --ssh-key FILE`

**Files:**
- Modify: `pkgs/librepod-install/install.sh` (usage, the argument loop, the checks block, the root-writing block), `pkgs/librepod-install/default.nix` (`runtimeInputs` += `openssh`)
- Modify: `checks/installer-test.nix` (`buildInputs` += `openssh`; new scenarios)
- Modify: `README.md:110-119` (install paragraph)

**Interfaces:**
- `--ssh-key FILE`: `[ $# -ge 2 ] && [ -n "$2" ] || usage`. An empty value is a usage error, the same as `--setup-code`.
- Refusal messages, exact:
  - `--ssh-key FILE: no such file`
  - `--ssh-key FILE: line N is not a public key`
  - `--ssh-key FILE: no public key in it`

1. Write the failing scenarios in `checks/installer-test.nix`. Generate the keys in the test with `ssh-keygen -q -t ed25519 -N "" -f "$ROOT/id"`. Build `$ROOT/keys.pub` from `$ROOT/id.pub`, a `#` comment line, a blank line, and a second key with a `from="10.0.0.0/8"` prefix. Then:
   ```bash
   refused usage: --image "$ROOT/ok.img" --name pod-test --ssh-key
   refused usage: --image "$ROOT/ok.img" --name pod-test --ssh-key ""
   refused "--ssh-key $ROOT/missing.pub: no such file" --image "$ROOT/ok.img" --name pod-test --ssh-key "$ROOT/missing.pub"
   refused "line 1 is not a public key" ... --ssh-key "$ROOT/id"          # the private key
   refused "line 1 is not a public key" ... --ssh-key "$ROOT/ok.img"      # not text
   refused "line 2 is not a public key" ... --ssh-key "$ROOT/half.pub"    # id.pub + "ssh-ed25519 AAAAtrunc"
   refused "no public key in it" ... --ssh-key "$ROOT/empty.pub"          # only "# comment" and a blank line
   # a good file passes its check: the next check refuses instead
   refused "not a block device" --image "$ROOT/ok.img" --name pod-test --ssh-key "$ROOT/keys.pub" --disk "$ROOT/ok.img"
   ```
2. Run `nix build .#checks.x86_64-linux.installer-test -L`. Expected: FAIL at the first `--ssh-key` scenario (`usage` falls through, or the message is missing).
3. Implement:
   - Usage line: `[--ssh-key FILE]  (public keys for SSH as librepod; the only SSH login)`.
   - The check goes after the image checks, before the disk loop. Check `[ -f FILE ] && [ -r FILE ]`. Then read FILE line by line, including a last line with no newline. Skip lines matching `^[[:space:]]*(#|$)`. Check each other line with `ssh-keygen -lf - <<< "$line" >/dev/null 2>&1`, and count the keys. Refuse on zero keys.
   - Writing to root, inside the existing mount block: `install -d -m 755 "$MNT/etc/ssh/authorized_keys.d"`, then write `tr -d '\r' < FILE` to `.../librepod` under `umask 022`. The `==>` line becomes `writing $NAME, its data disk, setup code[ and SSH key] to root`.
4. Run step 2's command. Expected: `installer scenarios passed`.
5. README: add `--ssh-key FILE` to the install paragraph. SSH takes keys only. Without the flag, a device has no SSH until a key is added at the console to `~librepod/.ssh/authorized_keys`. A reinstall writes root again, so it needs `--ssh-key` again.
6. Run `nix fmt -- --check && nix flake check`. Expected: pass. Commit: `feat(install): --ssh-key writes the device's SSH keys to root`.

### Task 3: sshd takes keys only; image-e2e proves it

**Files:**
- Modify: `modules/identity/default.nix` (sshd settings, header), `modules/ssh/default.nix:19` (comment only)
- Modify: `checks/image-e2e/default.nix` (header 1-13, `inst` at 268 / the second install at 290, subtests at 301, 325-342, 389-399; new subtest before 401)
- Modify: `AGENTS.md:46`, `docs/superpowers/specs/2026-11-11-ab-image-updates-design.md` (Phase 2 results, after line 170)

**Interfaces:** Consumes `--ssh-key` (Task 2) and the key-file path from Global Constraints.

1. Change the e2e first.
   - Key file: `sshPub = hostPkgs.writeText "librepod.pub" sshKeys.snakeOilPublicKey;` in the `let`. Add `--ssh-key ${sshPub}` to the second install (the one with `--keep-data`), which is the one the pod boots.
   - At the top of the test script, write the client key once with the existing `cat > /root/key` line.
   - Command templates. Keys log in with `ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /root/key {user}@localhost true`. Password attempts use `sshpass -p {pw} ssh -o PubkeyAuthentication=no ... librepod@localhost true 2>&1`.
   - Replace subtest 325-342 with `"SSH: the installed key only; root locked"`. Assert:
     - `stat -c '%a %U' /etc/ssh/authorized_keys.d/librepod` is `644 root` and the directory's is `755 root`;
     - the key logs in as `librepod`, and `scp` with the key copies `/etc/hostname` (sftp);
     - the key as `root` fails;
     - a password alone fails with `Permission denied (publickey)` in the output, which means sshd offers no password method at all;
     - root's shadow field starts with `!`.
   - Reboot subtest (389-399): keep `chpasswd librepod:new-pw`, the host key and the machine-id checks. Replace the two `ssh.format(pw=...)` lines: after the reboot the key still logs in (the file survived first-boot `/etc` activation and a reboot), and `new-pw` alone is refused.
   - New subtest before the missing-data-disk one, `"without a key: no SSH, the console login works"`:
     - `rm /etc/ssh/authorized_keys.d/librepod`; then the key login fails.
     - `pod.wait_until_tty_matches("1", "login: ")`, `send_chars("librepod\n")`, wait for `Password: `, `send_chars("new-pw\n")`; then `pod.wait_until_succeeds("pgrep -u librepod")`.
   - Update the header comment (lines 5-7) to say: SSH by the key the installer wrote, no password over SSH; the console keeps the generic login.
2. Skip a red e2e run, which would take 20+ minutes for a failure we already know: under `publickey,password` the key alone can't log in. Confirm the red state by eval instead: `nix eval .#image-e2e.nodes.pod.services.openssh.settings.AuthenticationMethods` prints `"publickey,password"`.
3. In `modules/identity`:
   - `services.openssh.settings` = `AuthenticationMethods = "publickey"`, `PasswordAuthentication = lib.mkForce false` (modules/ssh sets `true` without a priority), `KbdInteractiveAuthentication = false`. The one-line comment says why: the generic password must never be a LAN login.
   - Header: add `/etc/ssh/authorized_keys.d/librepod: SSH public keys, root 0644 (installer --ssh-key; none means no SSH until a key is added at the console)`. Replace the last two lines with "SSH takes keys only; the generic password is console-only."
   - `modules/ssh` comment: `# Key or password; image devices (modules/identity) take keys only.`
4. Run `nix build .#image-e2e -L`. Expected: every subtest passes, including the unchanged `/mnt/k3s`, `/exports/k3s` and missing-data-disk ones (they also verify Task 1 at runtime).
5. Docs:
   - `AGENTS.md:46`: "...with its name, data disk and optional SSH keys on root...".
   - Spec: under Phase 2 results add `- 2026-11-13 (8ss.14): superseded — image devices take SSH keys only ("publickey"); librepod-install --ssh-key writes /etc/ssh/authorized_keys.d/librepod; the generic password stays console-only.`
6. Run `nix fmt -- --check && nix flake check`. Expected: pass. Commit: `feat(identity): image devices take SSH keys only; e2e logs in with the installed key`. Then close the child beads and `bd close librepod-os-8ss.14`.
