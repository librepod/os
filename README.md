# LibrePod OS

LibrePod OS is the **OS/firmware layer** for [LibrePod Marketplace](https://github.com/librepod/marketplace) — an OCI-based app marketplace for self-hosted Kubernetes clusters. LibrePod OS provisions the bare-metal node (disk, networking, K3S, DNS, NFS, backups, tunneling) so that FluxCD can bootstrap the marketplace atop it.

The marketplace deploys system infrastructure (Traefik, cert-manager, Gogs, Casdoor SSO, NFS provisioner) via OCI artifacts, then users install apps (Vaultwarden, open-webui, Seafile, etc.) git-first through a private Gogs repo on the cluster. This repo handles everything *below* the Kubernetes layer; the marketplace repo handles everything *above* it.

## Quick Start

Add LibrePod as a flake input in your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    librepod.url = "github:librepod/os";
  };

  outputs = { self, nixpkgs, librepod, ... }@inputs: {
    nixosConfigurations.my-machine = librepod.lib.mkNixosConfig {
      path = ./machines/my-machine;
      inputs = inputs;
    };
  };
}
```

Then configure your machine:

```nix
# machines/my-machine/default.nix
{ config, lib, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
  ];

  # Required: set user credentials
  librepod.users = {
    root.hashedPassword = "$6$...";  # mkpasswd -m sha-512
    root.sshKeys = [ "ssh-ed25519 AAAA..." ];
    normalUser.hashedPassword = "$6$...";
  };
}
```

## Available Modules

| Module | Description |
|--------|-------------|
| `common` | Base system (zsh/grml, neovim, git, jq, NTP) |
| `users` | User management with `librepod.users` options |
| `ssh` | OpenSSH server with banner |
| `networking` | IPv6 disabled, DHCP defaults, mDNS (`<hostname>.local` via avahi) |
| `nix` | Nix GC, store optimization |
| `disko` | Two-disk appliance layout: GPT+LVM OS disk, ext4 data disk at `/mnt/k3s` |
| `k3s` | K3S Kubernetes server (pinned version) |
| `nfs` | NFS server for K3S persistent volumes |
| `borgmatic` | Automated PVC backups with Borgmatic |
| `gobackup` | Declarative backup with GoBackup |
| `casdoor` | Casdoor IAM CLI |
| `gitolite` | Git repository hosting with Flux integration |
| `onboarding` | Hands the installer's setup code (the sticker's) to the Marketplace |
| `usb-automount` | USB drive auto-mount (standalone or via `common`) |

## Device Profiles

Hardware profiles for supported devices:

- **`hw/lenovo-m710q/`** — Lenovo ThinkCentre M710Q Tiny (generic Intel mini-PC)

## Appliances (device layer)

`librepod.lib.mkDevice` assembles a complete appliance from a hardware profile
plus per-device identity — used by the small flake an installed device owns at
`/etc/nixos`:

```nix
{
  inputs.librepod.url = "github:librepod/os/v0.3.5";
  outputs = { librepod, ... }: {
    nixosConfigurations.pod-abc123 = librepod.lib.mkDevice {
      name = "pod-abc123";
      # the tag above, from the lock (master when none); written to /etc/librepod-release
      version = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.librepod.original.ref or "master";
      device = "lenovo-m710q";          # ./hw/<name>
      modules = [
        ./install.nix   # disk layout + stateVersion, frozen on install day
        ./identity.nix  # users, keys — never hardware
      ];
    };
  };
}
```

`install.nix` (and the `disk.nix` layout it imports) is written once by the
installer. Releases never touch it, so a later change to the default layout or
`stateVersion` reaches new installs only, never a disk already formatted.

Unsupported devices work too — `device` also accepts any hardware module
path (kernel/boot config, file systems, disko layout), so a personal device
can be a full appliance without a profile in `hw/`:

```nix
      device = ./my-hardware.nix;       # instead of a ./hw/<name> string
```

Provision a device from a live USB booted through UEFI with `librepod-install
--image librepod_1.raw.zst --name pod-1` (`--disk`, default `/dev/nvme0n1`;
`--data-disk`, default `/dev/sda`). It writes the appliance image, the name and
the `LibrePod` boot entry; a data disk that already holds LibrePod data needs
`--keep-data` or `--wipe-data`. The installer also mints the device's setup
code, the claim code for the Marketplace setup wizard. It goes on the sticker;
the last line prints it with the device's address, `http://<name>.local`.
`--setup-code XXXX-XXXX-XXXX` keeps a code already printed, e.g. on a
reinstall. The code lives in `/var/lib/librepod/setup-code` (root-only) and
reaches the Marketplace on every boot (`onboarding` module). Without the sticker,
`journalctl -u librepod-setup-code -o cat` on the device shows the code, its
link and the link as a QR code.
SSH takes public keys only, as `librepod`: `--ssh-key FILE` (one or more
public keys, one per line as in a `.pub` file, no options) puts them in `/etc/ssh/authorized_keys.d/librepod` on the device.
Without it the device has no SSH until a key is added at the console, to
`~librepod/.ssh/authorized_keys`; the generic `librepod` / `librepod` login
works at the console only. A reinstall writes root again, so it needs
`--ssh-key` again.

### Updates

An **image device** (written by `librepod-install`) updates itself, with k3s
stopped or broken. It checks its channel, `stable` or `beta` (`stable` until
set), at boot and at least every 6 hours, and downloads a new version as soon
as it finds one. It installs when the owner chooses now or tonight, or, with
automatic updates on, in the night window (02:00-05:00 in the owner's time
zone). The new version boots with a limited number of tries and must pass its
health gate; if it fails, the old version boots again and k3s's data is
restored to what it was before. Over ssh,
`librepod-update status | check | install now|tonight | channel stable|beta | auto on|off | timezone ZONE`
does the same. The Marketplace shows the status and passes on the owner's
answers through a ConfigMap ([contract](docs/updates.md)).

A **library device** (the flake above) has no updater. Bump its pin, to
`github:librepod/os/vX.Y.Z`, to `github:librepod/os` (master) or to the
`unstable` tag, then run `nix flake update librepod` and
`nixos-rebuild switch`.

## Installation

**Bare metal (via nixos-anywhere):**

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#my-machine root@<ip>
```

**Existing Linux (via nixos-infect):**

```bash
curl https://raw.githubusercontent.com/librepod/librepod-install/master/librepod-install | bash -x
```

## Testing

```bash
nix flake check            # eval checks, stubbed installer/onboarding scenarios, the updater, health gate and bridge (image-updater-test, image-health-test, image-bridge-test), formatting
nix build .#image-e2e -L   # the image installed, booted and updated in a QEMU VM
```

`image-e2e` installs the appliance image on a VM's disks with `librepod-install` and boots it, with the device's identity outside Nix (see `modules/identity`). It also covers the update flow: stable and beta updates, a rollback with k3s's data restored, and a power cut during an install. It takes 45–90 min and needs x86_64-linux with KVM (`/dev/kvm` writable). Nix caches the result, so add `--rebuild` to run it again on unchanged code.

## Branching & Releases

LibrePod OS uses trunk-based development — there is no `develop` branch.

- **`master` is the trunk and is *unstable*** — always CI-green, but not release-grade. Changes land via short-lived feature branches merged through PRs (required checks: `check`, `fmt`).
- **The `unstable` tag** is force-moved to `master` HEAD on every push and publishes a rolling pre-release. Track the trunk in consumer flakes:

  ```nix
  librepod.url = "github:librepod/os";  # rolling unstable; flake.lock pins the exact rev
  ```

- **`vX.Y.Z` tags are release candidates**, cut from a `master` commit that has soaked on `unstable`. Cut one via **Actions → Release (Stable) → Run workflow** (enter e.g. `0.2.0`), or manually:

  ```bash
  git tag v0.2.0 && git push origin v0.2.0
  ```

  The dispatch path validates semver ordering and tags `master` HEAD. Both paths build every hardware profile's image, sign `SHA256SUMS` and publish a GitHub **prerelease**, never Latest. A candidate higher than what the rolling **`beta`** release holds is also copied to it (the device files and the signed sums only), and devices on the beta channel follow `releases/download/beta/`. A hotfix for an older line never moves `beta` back.

  The cluster bootstrap artifact follows the same discipline: `modules/k3s/charts/flux-instance.nix` pins `ref = "vX.Y.Z"` — bumped deliberately like any other input, never tracking `latest`.
- **Promote** turns a candidate into the stable release: **Actions → Promote → Run workflow** (enter e.g. `0.2.0`). It marks that release **Latest**, with no rebuild and the same signature, and devices on the stable channel follow `releases/latest/download/`. It refuses a version not above the current Latest, a draft, a release that is not a candidate, and one without a signed `SHA256SUMS`. A candidate that fails on beta is never promoted; its fix is the next patch number.
- **Tags containing `-` are refused** (no `v0.5.0-rc.1`): systemd and `sort -V` order them above their release, so a device on one would never take its stable. Versions are plain `X.Y.Z`.
- Library devices pin any tag with `github:librepod/os/vX.Y.Z`, promoted or not.

If a dispatch run fails after the tag has already landed (for example the release-publishing step errored), do **not** delete the tag — re-dispatching will refuse ("Tag vX.Y.Z already exists"). Use **Re-run failed jobs** on the same run, within 3 days: the built images are kept that long. After that, cut the next patch tag. Don't create the release by hand: without the images and the signed `SHA256SUMS` devices refuse it, and Promote does too.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
