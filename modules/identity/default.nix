# modules/identity — an image device's identity lives outside Nix, so one image
# serves every device. What it carries outside the image (phase 3's contract):
# - /etc/hostname: the device name and a newline,
#   ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ (installer, phase 3)
# - /etc/shadow: passwords; first boot creates librepod / librepod with root
#   locked (onboarding changes it with chpasswd)
# - /etc/ssh/ssh_host_*, /etc/machine-id: generated on first boot
# - /etc/librepod/data-partuuid: the data partition's GPT UUID and a newline
#   (installer, phase 3)
# - data disk: one GPT partition labelled librepod-data, ext4, found by that
#   UUID: PVs at /mnt/k3s (modules/data-disk)
# - /var/lib/librepod/setup-code: the sticker's claim code, root-only
#   (installer; modules/onboarding hands it to marketplace-ui)
# - /etc/ssh/authorized_keys.d/librepod: SSH public keys, root's, 0644
#   (installer, --ssh-key); without it no SSH until a key is added at the
#   console to ~librepod/.ssh/authorized_keys
# SSH takes keys only; the generic password is console-only.
{ pkgs, lib, ... }:
{
  # The name lives in /etc/hostname, and NixOS writes none when this is
  # empty; avahi then publishes the system's name.
  networking.hostName = "";

  # Onboarding changes the password and it must outlive updates: /etc/shadow
  # sits on the root partition, which updates never write. The appliance
  # profile sets this false.
  users.mutableUsers = lib.mkForce true;

  # Keys only: the generic password must never be a LAN login. modules/ssh
  # sets PasswordAuthentication without a priority, for the fleet.
  services.openssh.settings = {
    AuthenticationMethods = "publickey";
    PasswordAuthentication = lib.mkForce false;
    KbdInteractiveAuthentication = false;
  };

  users.defaultUserShell = pkgs.zsh;
  # initialPassword applies once, when the account is created on first boot.
  # root gets no password, so it is created locked.
  users.users.librepod = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "librepod";
  };
}
