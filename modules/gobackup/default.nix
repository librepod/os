# GoBackup module - declarative backup configuration for NixOS
#
# This module provides:
# - gobackup package installation
# - Declarative backup model configuration via NixOS options
# - Automatic YAML config generation from Nix options
# - systemd timer-based scheduling for each backup model
# - Pre/post backup script support (K3S scripts included)
#
# Usage example:
#
#   services.gobackup = {
#     enable = true;
#     models.k3s-pv = {
#       schedule = "*-*-* 03:00:00";  # 3 AM daily
#       sourcePath = "/exports/k3s";
#       targetPath = "/media/USB DISK/librepod-backups";
#       compressWith = "tar.gz";
#       beforeScript = config.services.gobackup.scripts.k3s-pre;
#       afterScript = config.services.gobackup.scripts.k3s-post;
#     };
#   };

{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Import gobackup package
  gobackupPkg = pkgs.callPackage ./package.nix { };

  # Pre/post backup scripts wrapped with writeShellApplication
  k3sPreScript = pkgs.writeShellApplication {
    name = "gobackup-k3s-pre";
    runtimeInputs = with pkgs; [
      k3s
      jq
      coreutils
    ];
    text = builtins.readFile ./scripts/k3s-pre-backup.sh;
  };

  k3sPostScript = pkgs.writeShellApplication {
    name = "gobackup-k3s-post";
    runtimeInputs = with pkgs; [
      k3s
      jq
      coreutils
    ];
    text = builtins.readFile ./scripts/k3s-post-backup.sh;
  };

  # Get the actual binary paths from the wrapped scripts
  # writeShellApplication creates a wrapper directory, we need the bin/ subpath
  k3sPreScriptBin = "${k3sPreScript}/bin/gobackup-k3s-pre";
  k3sPostScriptBin = "${k3sPostScript}/bin/gobackup-k3s-post";

  # Generate gobackup YAML configuration from Nix options
  # GoBackup expects YAML format with models as top-level key
  generateModelConfig =
    modelName: modelConfig:
    lib.optionalAttrs (modelConfig.beforeScript != null) {
      before_script = "${modelConfig.beforeScript}";
    }
    // {
      archive = {
        includes = [ "${modelConfig.sourcePath}" ];
      };
    }
    // lib.optionalAttrs (modelConfig.compressWith != null) {
      compress_with = {
        type = modelConfig.compressWith;
      };
    }
    // {
      storages = {
        local = {
          type = "local";
          path = "${modelConfig.targetPath}";
        };
      };
    }
    // lib.optionalAttrs (modelConfig.afterScript != null) {
      after_script = "${modelConfig.afterScript}";
    };

  # Generate complete gobackup.yml content
  generateGobackupConfig =
    models:
    lib.generators.toYAML { } {
      models = lib.mapAttrs generateModelConfig models;
    };

  gobackupConfigFile = pkgs.writeText "gobackup.yml" (
    generateGobackupConfig config.services.gobackup.models
  );

in
{
  options.services.gobackup = {
    enable = lib.mkEnableOption "gobackup backup service";

    package = lib.mkOption {
      type = lib.types.package;
      default = gobackupPkg;
      defaultText = "pkgs.callPackage ./package.nix { }";
      description = "The gobackup package to use";
    };

    models = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, name, ... }:
          {
            options = {
              schedule = lib.mkOption {
                type = lib.types.str;
                example = "*-*-* 03:00:00";
                description = "Systemd timer calendar format (see systemd.time(7) for syntax)";
              };

              sourcePath = lib.mkOption {
                type = lib.types.path;
                example = "/exports/k3s";
                description = "Path to archive for backup";
              };

              targetPath = lib.mkOption {
                type = lib.types.path;
                example = "/media/USB DISK/librepod-backups";
                description = "Where to store backups";
              };

              compressWith = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.enum [
                    "tar"
                    "tar.gz"
                    "tar.bz2"
                    "tar.xz"
                    "zip"
                  ]
                );
                default = "tar.gz";
                example = "tar.gz";
                description = "Compression format (null for no compression)";
              };

              beforeScript = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                example = lib.literalExpression "config.services.gobackup.scripts.k3s-pre";
                description = "Script to run before backup (e.g., to stop services)";
              };

              afterScript = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                example = lib.literalExpression "config.services.gobackup.scripts.k3s-post";
                description = "Script to run after backup (e.g., to restart services)";
              };
            };
          }
        )
      );
      default = { };
      description = "Backup model configurations";
    };

    scripts = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      readOnly = true;
      default = {
        k3s-pre = k3sPreScriptBin;
        k3s-post = k3sPostScriptBin;
      };
      description = "Pre-built backup scripts for common use cases";
    };
  };

  config = lib.mkIf config.services.gobackup.enable {
    # Note: Not creating a dedicated gobackup user since we need root permissions
    # for accessing K8s API and writing to mounted filesystems
    # users.users.gobackup = {
    #   description = "GoBackup daemon user";
    #   isSystemUser = true;
    #   group = "gobackup";
    # };
    # users.groups.gobackup = { };

    # Install gobackup package
    environment.systemPackages = [ config.services.gobackup.package ];

    # Create gobackup config directory and file
    environment.etc."gobackup/gobackup.yml".source = gobackupConfigFile;

    # Create systemd target for all backup services
    systemd.targets.gobackup = {
      description = "GoBackup target for all backup timers";
      wantedBy = [ "timers.target" ];
    };

    # Create individual services for each backup model
    # Each service gets all required settings including ExecStart with the model name
    systemd.services = lib.mapAttrs' (
      modelName: modelConfig:
      lib.nameValuePair "gobackup@${modelName}" {
        description = "GoBackup backup for ${modelName}";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # ConditionPathIsDirectory goes in [Unit] section, not [Service]
        unitConfig = {
          ConditionPathIsDirectory = modelConfig.sourcePath;
        };
        path = with pkgs; [
          k3s
          coreutils
          jq
          gnutar
          bash
          gzip
        ];
        serviceConfig = {
          Type = "oneshot";
          # Run as root to access K8s API and write to mounted filesystems
          User = "root";
          Group = "root";
          ExecStart = "${config.services.gobackup.package}/bin/gobackup perform -m ${modelName}";
          # ProtectSystem=full allows writing to /media but protects rootfs
          # We can't use strict with paths containing spaces
          ProtectSystem = "full";
          ProtectHome = true;
          PrivateTmp = true;
        };
      }
    ) config.services.gobackup.models;

    # Create timer for each model
    systemd.timers = lib.mapAttrs' (
      modelName: modelConfig:
      lib.nameValuePair "gobackup-${modelName}" {
        description = "Timer for GoBackup model ${modelName}";
        wantedBy = [ "gobackup.target" ];
        timerConfig = {
          OnCalendar = modelConfig.schedule;
          Persistent = true; # Run immediately if last run was missed
          Unit = "gobackup@${modelName}.service";
        };
      }
    ) config.services.gobackup.models;
  };
}
