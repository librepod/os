# The setup code librepod-install minted (printed on the sticker) reaches
# marketplace-ui's setup wizard as Secret marketplace-ui/librepod-setup-code.
{ lib, pkgs, ... }:

{
  systemd.services.librepod-setup-code = {
    description = "Publish the device setup code to marketplace-ui";
    after = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "librepod-publish-setup-code";
          runtimeInputs = [ pkgs.kubectl ];
          text = builtins.readFile ./publish-setup-code.sh;
        }
      );
    };
  };
}
