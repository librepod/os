# LibrePod OS

LibrePod OS is the **OS/firmware layer** for [LibrePod Marketplace](https://github.com/librepod/marketplace) — an OCI-based app marketplace for self-hosted Kubernetes clusters. LibrePod OS provisions the bare-metal node (disk, networking, K3S, DNS, NFS, backups, tunneling) so that FluxCD can bootstrap the marketplace atop it.

The marketplace deploys system infrastructure (Traefik, cert-manager, Gogs, Casdoor SSO, NFS provisioner) via OCI artifacts, then users install apps (Vaultwarden, open-webui, Seafile, etc.) git-first through a private Gogs repo on the cluster. This repo handles everything *below* the Kubernetes layer; the marketplace repo handles everything *above* it.

## Quick Start

Add LibrePod as a flake input in your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
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

- **`devices/lenovo-m710q/`** — Lenovo ThinkCentre M710Q Tiny
- **`devices/virtualbox-vm/`** — VirtualBox VM (for testing)

## Installation

**Bare metal (via nixos-anywhere):**

```bash
nix run github:nix-community/nixos-anywhere -- --flake .#my-machine root@<ip>
```

**Existing Linux (via nixos-infect):**

```bash
curl https://raw.githubusercontent.com/librepod/librepod-install/master/librepod-install | bash -x
```

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

  The workflow validates semver ordering, tags `master` HEAD, and publishes a GitHub Release marked **Latest**. Pin a stable input with `github:librepod/os/vX.Y.Z`.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
