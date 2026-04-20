{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    ./boot.nix
    ../../modules/amneziawg
    ../../modules/disko
    ../../modules/common
    ../../modules/common/usb-automount.nix
    ../../modules/networking
    ../../modules/nix
    ../../modules/ssh
    ../../modules/users
    ../../modules/nfs
    ../../modules/duplicati
    (import ../../modules/k3s { inherit config pkgs lib; })
  ];

  # Common network interface for all Lenovo M710Qs
  networking.interfaces.enp0s31f6.useDHCP = lib.mkDefault true;

  # Common SSH banner
  services.openssh.banner = ''
      _    _ _            ___         _
     | |  (_) |__ _ _ ___| _ \___  __| |  ___ _ _
     | |__| | '_ \ '_/ -_)  _/ _ \/ _` | / _ \ ' \
     |____|_|_.__/_| \___|_| \___/\__,_| \___/_||_|

    _____ _    _      _    ___         _             __  __ ____ _  __
    |_   _| |_ (_)_ _ | |__/ __|___ _ _| |_ _ _ ___  |  \/  |__  / |/  \ __ _
     | | | ' \| | ' \| / / (__/ -_) ' \  _| '_/ -_) | |\/| | / /| | () / _` |
     |_| |_||_|_|_||_|_\_\\___\___|_||_\__|_| \___| |_|  |_|/_/ |_|\__/\__, |
                                                                          |_|
  '';

  system.stateVersion = lib.mkDefault "24.05";
}
