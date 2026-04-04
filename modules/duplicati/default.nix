# Duplicati backup module with ArgoCD integration
#
# This module enables Duplicati web UI for monitoring and provides:
# 1. Pre/post backup scripts that pause/resume ArgoCD and scale K8s deployments
# 2. A declarative systemd timer for automated nightly backups
#
# Backup Strategy Selection
# ==========================
# This module supports two backup strategies. Choose ONE to import below:
#
# 1. Per-PVC Backup (RECOMMENDED)
#    - File: modules/duplicati/per-pvc.nix
#    - Creates a separate backup for each PVC
#    - Enables granular restore of individual PVCs
#    - No data loss for healthy services during restore
#    - Automatic discovery of new PVCs
#    - Mirrored directory structure for easy navigation
#
# 2. Legacy Single Backup
#    - File: modules/duplicati/single.nix
#    - Backs up all PVCs in a single job
#    - Restoring one PVC requires restoring ALL PVCs
#    - May cause data loss for healthy services
#    - Preserved for backward compatibility
#
# Backup configuration is fully declarative - no web UI setup required.
# The web UI at http://<server>:8200 is available for viewing logs and manual operations.
#
# Scripts docs: https://docs.duplicati.com/detailed-descriptions/scripts

{ config, pkgs, lib, ... }:

{
  imports = [
    # ==============================================================================
    # BACKUP STRATEGY SELECTION
    # ==============================================================================
    # Choose ONE of the following backup strategies:
    #
    # Option 1: Per-PVC Backup (RECOMMENDED)
    #   - Granular restore of individual PVCs
    #   - No data loss for healthy services
    #   - Automatic PVC discovery
    ./per-pvc.nix

    # Option 2: Legacy Single Backup
    #   - Single backup for all PVCs
    #   - Simpler but less flexible restore
    #   - Preserved for backward compatibility
    # ./single.nix
  ];

  options.services.duplicati.k3sPostBackupReconcile = lib.mkOption {
    type = lib.types.enum [ "argocd" "snapshot" "fluxcd" ];
    default = "snapshot";
    description = ''
      Mechanism for reconciling K8s workloads after backup completes.

      - argocd: Restores ArgoCD namespace deployments/statefulsets; other workloads
        are expected to be restored by GitOps controllers.

      - snapshot: Records exact replica counts before backup and restores all
        recorded workloads after backup.

      - fluxcd: Not yet implemented; scripts will fail fast with error.
    '';
  };

  config = {
    # Enable base Duplicati service with web UI (for monitoring and manual operations)
    services.duplicati = {
      enable = lib.mkDefault true;
      interface = "any";  # Allow web UI access from network (default: 127.0.0.1)
      user = "root";
      # No parameters needed - backups are managed via systemd timer
      #
      # TODO: Find a way to opt-out from usage statistics
    };
  };
}
