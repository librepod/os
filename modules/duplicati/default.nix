# Duplicati backup module with FluxCD integration
#
# This module enables Duplicati web UI for monitoring and provides:
# 1. Pre/post backup scripts that suspend/resume FluxCD and scale K8s deployments
# 2. A declarative systemd timer for automated nightly per-PVC backups
#
# Backup configuration is fully declarative - no web UI setup required.
# The web UI at http://<server>:8200 is available for viewing logs and manual operations.
#
# Scripts docs: https://docs.duplicati.com/detailed-descriptions/scripts

{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./per-pvc.nix
  ];

  config = {
    # Enable base Duplicati service with web UI (for monitoring and manual operations)
    services.duplicati = {
      enable = lib.mkDefault true;
      interface = "any"; # Allow web UI access from network (default: 127.0.0.1)
      user = "root";
      parameters = ''
        --webservice-password=pass@w0rd
        --webservice-disable-signin-tokens=true
      '';
    };

    # Disable Duplicati usage telemetry on the server service
    systemd.services.duplicati.environment.USAGEREPORTER_Duplicati_LEVEL = "none";
  };
}
