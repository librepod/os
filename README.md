### Development
Clone the repo with your newly generated Personal Access Token (PAT):
```sh
git clone https://{username}:{PAT}@github.com/librepod/librepod.git
```

### Https with Traefik

We use self-signed certificates generated by the `mkcert` utility on the
LibrePod host. `mkcert` creates a default Certificate Authority located in the
`/root/.local/share/mkcert` folder. This CA is the default one and is used to
generate all the self-signed certificates which are used by Traefik Proxy.
The mechanics of this as follows:
1. File __ca-certs.nix__ defines few systemd services. One of them calls `mkcert
   install` which creates default CA, then it creates self-signed certificates
   in the __/exports/k3s/certs__ folder. After that it creates a K8S TLS secret
   refering to newly generated certificates.
2. The other systemd service is triggered monthly by a corresponding systemd timer
   service and just creates another pair of certificates as well as
   deletes old K8S TLS secret and creates a new one referring to new
   certs.
3. There is Traefik CRD named TLSStore which sets default Traefik TLS key to
   the TLS secret we create based on the self-signed certs produced by
   `mkcert`.

## How to install

### Install on a non-NixOS host

For LibrePod purposes we have adopted the [nixos-infect](https://github.com/librepod/nixos-infect)
script that installs NixOS on a non-Nix Linux system. It was tested with
Debian based Linux and it should work work with other Linux systems as well since
the original author [states](https://github.com/elitak/nixos-infect#tested-on) that it does.

1. Deploy an SSH key for the `root` user to the host where you want LibrePod be
   installed.
2. Make sure that you can connect via SSH as `root` user to that host.
3. Having SSH-ed to your host as `root` user, execute:

💣 WARNING! This script wipes out the targeted host's root filesystem when it runs
to completion. Any errors halt execution.
A failure will leave the system in an inconsistent state, and so it is advised to
run with `bash -x`.
💡 If your host supports disk snapshots, please make a snapshot before executing
this script so you could restore to the previous state just in case. Otherwise
there is no way to revert the state of your host after script execution.

```sh
  curl https://raw.githubusercontent.com/librepod/librepod-install/master/librepod-install | bash -x
```
