{ lib, pkgs, ... }:
let
  config = import ./config.nix;
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./boot
  ];

  networking.hostName = config.hostName;
  networking.interfaces."${config.networkInterfaceName}".useDHCP = true;

  # Required for the Wireless firmware
  # hardware.enableRedistributableFirmware = true;
  # Wireless networking (1). You might want to enable this if your Pi is not attached via Ethernet.
  # networking = {
    # wireless = {
    #   enable = true;
    #   interfaces = [ "wlan0" ];
    #   networks = {
    #     "replace-with-my-wifi-ssid" = {
    #        psk = "replace-with-my-wifi-password";
    #      };
    #   };
    # };
  # };
}
