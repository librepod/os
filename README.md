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
| `networking` | IPv6 disabled, DHCP defaults |
| `nix` | Nix GC, store optimization |
| `disko` | GPT + LVM disk partitioning |
| `k3s` | K3S Kubernetes server (pinned version) |
| `frpc` | FRP tunnel client with `librepod.frpc` options |
| `dns-server` | Unbound DNS for local domains |
| `nfs` | NFS server for K3S persistent volumes |
| `borgmatic` | Automated PVC backups with Borgmatic |
| `gobackup` | Declarative backup with GoBackup |
| `casdoor` | Casdoor IAM CLI |
| `gitolite` | Git repository hosting with Flux integration |
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
      # the tag above, from the lock; the updater reports it as the running version
      version = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.librepod.original.ref;
      device = "lenovo-m710q";          # ./hw/<name>
      modules = [
        ./install.nix   # disk layout + stateVersion, frozen on install day
        ./identity.nix  # users, keys, frpc — never hardware
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

Provision a device over netboot with `librepod-install --device lenovo-m710q
--name pod-1 --identity id.nix` (`--device` also takes a hardware module
path, e.g. `--device ./my-hardware.nix`; `--disk /dev/sda` for a machine
without NVMe, default `/dev/nvme0n1`). Updates are consent-driven: the Marketplace
writes intent to ConfigMap `librepod-os/<hostname>` ([contract](docs/updates.md)); the host updater applies
release tags only (`vX.Y.Z`) and boots the new version once as a trial; the
old version stays the boot default until the new one passes its health checks. Unattended updates need an
explicit per-device policy (`policy.unattended` + a nightly window).

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
nix flake check            # eval checks + stubbed updater/sentinel/installer scenarios, formatting
nix build .#updates-e2e -L # end-to-end OS updates in a QEMU VM
```

`updates-e2e` boots one VM with the real stack (UEFI, systemd-boot, k3s) and runs every update scenario against a generated local release repo: a healthy update, k3s down, power cuts, a build failure, a stage-1 panic and hang, no fetch. It needs x86_64-linux with KVM (`/dev/kvm` writable), takes about an hour, and leaves a ~5 GB disk image in the store (`nix-collect-garbage` frees it). A passing run prints `updates-e2e: all scenarios passed`. Nix caches the result, so add `--rebuild` to run it again on unchanged code. `nix build .#trial-spike -L` covers only the boot-loader mechanics of the trial boot.

## Branching & Releases

LibrePod OS uses trunk-based development — there is no `develop` branch.

- **`master` is the trunk and is *unstable*** — always CI-green, but not release-grade. Changes land via short-lived feature branches merged through PRs (required checks: `check`, `fmt`).
- **The `unstable` tag** is force-moved to `master` HEAD on every push and publishes a rolling pre-release. Track the trunk in consumer flakes:

  ```nix
  librepod.url = "github:librepod/os";  # rolling unstable; flake.lock pins the exact rev
  ```

- **`vX.Y.Z` tags are stable releases**, cut from a `master` commit that has soaked on `unstable`. Cut one via **Actions → Release (Stable) → Run workflow** (enter e.g. `0.2.0`), or manually:

  ```bash
  git tag v0.2.0 && git push origin v0.2.0
  ```

  The dispatch path validates semver ordering and tags `master` HEAD; both paths publish a GitHub Release marked **Latest**. Releases don't run `updates-e2e`: run it on the commit first, locally or via **Actions → Updates E2E → Run workflow** (manual only, about an hour). Pin a stable input with `github:librepod/os/vX.Y.Z`.

  The cluster bootstrap artifact follows the same discipline: `modules/k3s/charts/flux-instance.nix` pins `ref = "vX.Y.Z"` — bumped deliberately like any other input, never tracking `latest`.

If a dispatch run fails after the tag has already landed (for example the release-publishing step errored), do **not** delete the tag — re-running or re-dispatching will refuse ("Tag vX.Y.Z already exists"). Finish the release by hand: `gh release create vX.Y.Z --generate-notes --latest`.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
