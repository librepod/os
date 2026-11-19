# Netboot install with pixiecore

Booting the LibrePod installer over the network avoids burning a USB stick: a
workstation on the same LAN serves a netboot-minimal NixOS installer (with
`librepod-install` and SSH baked in) via [pixiecore][], the device PXE-boots
it, and the installer writes the appliance image to disk. The
[`modules/netboot`](../modules/netboot/) module packages the same thing as a
long-lived service on a LibrePod device; this page is the ad-hoc,
run-it-from-your-laptop variant.

[pixiecore]: https://github.com/danderson/netboot/tree/master/pixiecore

## 1. Build the netboot installer

A scratch flake is enough (the os flake exposes `librepod-install` as a
package):

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.librepod.url = "github:librepod/os"; # or git+file:///path/to/os
  outputs = { self, nixpkgs, librepod }: {
    packages.x86_64-linux.netboot =
      (nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit librepod; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
          ({ pkgs, ... }: {
            netboot.squashfsCompression = "zstd -Xcompression-level 6";
            services.openssh.enable = true;
            users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA… you@host" ];
            environment.systemPackages =
              (with pkgs; [ pciutils usbutils ])
              ++ [ librepod.packages.x86_64-linux.librepod-install ];
          })
        ];
      }).config.system.build;
  };
}
```

```bash
nix build .#netboot.kernel .#netboot.netbootRamdisk .#netboot.toplevel
# result (kernel), result-1 (initrd), result-2 (toplevel)
```

Also build the whole-disk image for the device's hardware profile:

```bash
nix build --impure --expr \
  '(builtins.getFlake (toString /path/to/os)).lib.releaseFiles { device = "lenovo-m90q"; version = "…"; }'
```

## 2. Serve it

```bash
sudo pixiecore boot <kernel>/bzImage <initrd>/initrd \
  --cmdline "init=<toplevel>/init loglevel=4 console=ttyS0,115200" \
  --dhcp-no-bind --listen-addr <LAN-ip> --debug
```

- `--dhcp-no-bind` keeps the LAN's real DHCP server in charge; pixiecore only
  answers the "boot from whom" question, then serves kernel and initrd over
  HTTP. Sudo is needed for the PXE ports (UDP 67/69/4011).
- The client must PXE-boot in **UEFI mode** (`X64` in pixiecore's log) —
  `librepod-install` writes a UEFI boot entry and refuses a legacy boot.
- A WiFi serving host works; only the DHCP handshake rides on broadcasts.

## 3. Boot the device

If the device has PXE'd and failed several times, many firmwares demote
network boot for subsequent boots — use the one-time boot menu (usually F12)
and pick the onboard NIC explicitly.

The installer DHCPs on its own; find its address by probing for SSH key auth
(`ssh -o BatchMode=yes root@<ip> true`) — see the mDNS note below.

## 4. Install

From the serving host, push the image (scp needs no inbound firewall rules on
the server, unlike an HTTP file server):

```bash
scp <profile>_<version>.raw.zst ~/.ssh/id_ed25519.pub root@<installer-ip>:/tmp/
ssh root@<installer-ip> 'lsblk -o NAME,SIZE,TYPE,SERIAL'   # verify by SERIAL
ssh root@<installer-ip> 'librepod-install --image /tmp/<image>.raw.zst \
  --name <hostname> --disk /dev/nvmeXn1 \
  --data-disk /dev/nvmeYn1 --wipe-data \
  --backup-disk /dev/sdZ --wipe-backup --ssh-key /tmp/id_ed25519.pub'
```

Then `ssh root@<installer-ip> reboot` and onboard at `http://<name>.local`
with the printed setup code.

## Gotchas (all earned the hard way)

- **Policy routing can hijack unicast replies.** The DHCP handshake is
  broadcast and works, but TFTP/HTTP are unicast — on a multi-homed serving
  host (VPN overlay, secondary bridge) they can leave through the wrong
  interface and the client refuses them. Check `ip route get <client-ip>`;
  if it does not name the LAN interface, pin LAN traffic to the main table
  and bind pixiecore to the LAN address:

  ```bash
  sudo ip rule add to 192.168.1.0/24 lookup main pref 5000
  # …plus --listen-addr above
  ```

- **`init=` must be the resolved store path.** The kernel consumes the
  cmdline verbatim inside the netbooted system, where only `/nix/store/…`
  exists. A flake symlink like `result-2/init` does not resolve there —
  the box loads everything, panics silently, and goes dark. Use
  `$(readlink -f result-2)/init`.

- **Never `pkill -f pixiecore` from a wrapper that mentions pixiecore.**
  `-f` matches the wrapper's own command line, so it kills itself before the
  restart (and any `&&`-chained commands after it). Use `pkill -x pixiecore`,
  or split kill and start into separate commands.

- **Don't trust mDNS during installs.** Another LAN device can answer for
  `<name>.local` (and DHCP leases rotate across reboots). Address the
  installer by IP, verified by SSH key auth, and give installed devices a
  static DHCP lease keyed to their NIC MAC.

- **Disk names shuffle between boots.** NVMe enumeration order is not stable
  across the installer and first boot (or between reboots). Match disks by
  SIZE/SERIAL before invoking `librepod-install`; the installer itself pins
  identity by PARTUUID, so the installed system is immune.
