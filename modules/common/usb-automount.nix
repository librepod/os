# USB Auto-Mount Module
# Automatically mounts USB drives when plugged in, especially for NTFS-formatted flash drives
# on headless servers where the default services.devmon.enable (user service) won't work.
{ pkgs, ... }:
{
  # Enable NTFS filesystem support in the kernel
  boot.supportedFilesystems = [ "ntfs" ];

  # udisks2 provides device monitoring and management
  services.udisks2.enable = true;

  # Add ntfs3g to system packages for NTFS read/write support
  environment.systemPackages = with pkgs; [
    ntfs3g
  ];

  # Auto-mount USB drives using devmon (system service, not user service)
  # Based on nixpkgs services/misc/devmon.nix but adapted for headless servers
  # The vendor module uses systemd.user.services which only runs when a user is logged in,
  # making it unsuitable for headless servers. This uses systemd.services instead.
  systemd.services.devmon = {
    description = "Devmon automatic device mounting daemon";
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.udevil # The devmon automounter
      pkgs.procps # Provides 'ps' command
      pkgs.which # Provides 'which' command
    ];
    serviceConfig = {
      ExecStart = "${pkgs.udevil}/bin/devmon";
      Restart = "on-failure";
    };
  };
}
