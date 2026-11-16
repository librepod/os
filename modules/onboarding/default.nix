# The setup code librepod-install minted (printed on the sticker) is logged for
# the console, with its link and a QR code. The OS agent publishes its bcrypt
# hash in Device.status.setupCodeHash (modules/os-agent), which the Marketplace's
# setup wizard checks the typed code against.
{ lib, pkgs, ... }:

{
  systemd.services.librepod-setup-code = {
    description = "Log the device setup code for the console";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "librepod-publish-setup-code";
          runtimeInputs = [ pkgs.qrencode ];
          text = builtins.readFile ./publish-setup-code.sh;
        }
      );
    };
  };
}
