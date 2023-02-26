{ lib, pkgs, ... }:

{
  # Enable OpenSSH out of the box.
  services.sshd.enable = true;

  # The global useDHCP flag is deprecated, therefore explicitly set to false here.
  # Per-interface useDHCP will be mandatory in the future, so this generated config
  # replicates the default behaviour.
  networking.useDHCP = false;

  # Disable firewall
  networking.firewall.enable = false;

  # NTP time sync.
  services.timesyncd.enable = true;
}
