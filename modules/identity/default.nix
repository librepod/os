# modules/identity — an image device's identity lives outside Nix, so one image
# serves every device. What it carries outside the image (phase 3's contract):
# - /etc/hostname: the device name and a newline,
#   ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ (installer, phase 3)
# - /etc/shadow: passwords; first boot creates librepod / librepod with root
#   locked (onboarding changes it with chpasswd)
# - /etc/ssh/ssh_host_*, /etc/machine-id: generated on first boot
# - data disk, GPT partition label librepod-data, ext4: PVs at /mnt/k3s
#   (installer, phase 3)
# The generic password is console-only: sshd wants a key and a password, and
# no key ships.
{ pkgs, lib, ... }:
{
  # The name lives in /etc/hostname, and NixOS writes none when this is
  # empty; avahi then publishes the system's name.
  networking.hostName = "";

  # Onboarding changes the password and it must outlive updates: /etc/shadow
  # sits on the root partition, which updates never write. The appliance
  # profile sets this false.
  users.mutableUsers = lib.mkForce true;

  # Key and password. modules/ssh's "publickey password" means key OR
  # password, which would make the generic password a LAN login.
  services.openssh.settings.AuthenticationMethods = "publickey,password";

  users.defaultUserShell = pkgs.zsh;
  # initialPassword applies once, when the account is created on first boot.
  # root gets no password, so it is created locked.
  users.users.librepod = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "librepod";
  };
}
