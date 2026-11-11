{ lib, ... }:

{
  networking = {
    enableIPv6 = false;
    hostName = lib.mkDefault "librepod";

    # The global useDHCP flag is deprecated, therefore explicitly set to false here.
    # Per-interface useDHCP will be mandatory in the future, so this generated config
    # replicates the default behaviour.
    useDHCP = lib.mkDefault false;

    # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
    # (the default) this is the recommended approach. When using systemd-networkd it's
    # still possible to use this option, but it's recommended to use it in conjunction
    # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
    # useDHCP = lib.mkDefault true;
    # These needs to be applied in each machine root module i.e. ./machines/<machine>/default.nix
    # depending on the ethernet adapter name.
    # interfaces.enp1s0.useDHCP = lib.mkDefault true;
    # interfaces.wlp2s0.useDHCP = lib.mkDefault true;

    # TODO: Enable firewall and configure it properly
    firewall.enable = lib.mkDefault false;
  };

  # mDNS: every appliance answers at <hostname>.local on the LAN
  # (librepod-dev.local, librepod-m90q.local, ...). Per-device names only:
  # a shared "librepod" alias would collide once two devices share a LAN —
  # mDNS conflict resolution makes the winner nondeterministic.
  services.avahi = {
    enable = lib.mkDefault true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };
}
