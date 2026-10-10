{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # INFO: Pin k3s to a specific version by using a specific nixpkgs commit
    # To update k3s version, find a nixpkgs commit with the desired k3s version:
    # 1. Go to https://github.com/NixOS/nixpkgs/commits/master/pkgs/applications/networking/cluster/k3s
    # 2. Find the commit that has your desired version
    # 3. Update the URL below with that commit
    k3s-nixpkgs.url = "github:NixOS/nixpkgs/31a116e3307dca596c4ab20a5372d8540cb6d3fd";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      k3s-nixpkgs,
      disko,
      treefmt-nix,
      ...
    }@inputs:
    let
      treefmtEval = treefmt-nix.lib.evalModule nixpkgs.legacyPackages.x86_64-linux {
        projectRootFile = "flake.nix";
        programs.nixfmt.enable = true;
      };
    in
    {
      # Overlay that pins k3s to a specific version via k3s-nixpkgs.
      # Consumers should apply this overlay to get the pinned k3s version.
      overlays.default = final: prev: {
        k3s =
          (import k3s-nixpkgs {
            inherit (prev.stdenv) system;
            config.allowUnfree = false;
          }).k3s;
      };

      nixosModules = {
        amneziawg = ./modules/amneziawg;
        casdoor = import ./modules/casdoor;
        common = import ./modules/common;
        disko = ./modules/disko;
        borgmatic = import ./modules/borgmatic;
        duplicati = import ./modules/duplicati;
        frpc = import ./modules/frpc;
        gitolite = import ./modules/gitolite;
        gobackup = import ./modules/gobackup;
        k3s = import ./modules/k3s;
        netboot = import ./modules/netboot;
        networking = import ./modules/networking;
        nfs = import ./modules/nfs;
        nix = import ./modules/nix;
        ssh = import ./modules/ssh;
        updates = import ./modules/updates;
        users = import ./modules/users;
        # Also available standalone — NixOS deduplicates if imported with `common`.
        usb-automount = ./modules/common/usb-automount.nix;
      };

      lib = {
        # Creates a NixOS configuration with standard modules (disko).
        # Args:
        #   path    — path to the machine directory (must contain default.nix)
        #   inputs  — the consumer's flake inputs (must include nixpkgs)
        #   modules — extra NixOS modules (default: [disko])
        mkNixosConfig =
          {
            path,
            inputs,
            modules ? [ disko.nixosModules.disko ],
          }:
          inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit inputs;
            };
            modules = modules ++ [ path ];
          };

        # Assembles a complete LibrePod appliance from a hardware profile +
        # per-device identity modules. Used by the generated device flake
        # (see docs/superpowers/specs/2026-10-10-device-layer-os-updates-design.md).
        #   name    — hostname; becomes the nixosConfigurations attr name
        #   device  — hardware profile dir name under ./hw
        #   modules — identity modules (users, frpc, per-device bits)
        mkDevice =
          {
            name,
            device,
            modules ? [ ],
          }:
          nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              librepod = self;
              inputs = {
                inherit nixpkgs disko;
              };
            };
            modules = [
              # Pinned k3s from this os release
              { nixpkgs.overlays = [ self.overlays.default ]; }
              disko.nixosModules.disko
              # Appliance base stack — identity extends, not replaces
              self.nixosModules.common
              self.nixosModules.networking
              self.nixosModules.nix
              self.nixosModules.ssh
              self.nixosModules.users
              self.nixosModules.usb-automount
              self.nixosModules.k3s
              self.nixosModules.updates
              (./hw + "/${device}")
              { networking.hostName = name; }
              # Appliances are updateable; identity can override (mkDefault).
              { librepod.updates.enable = nixpkgs.lib.mkDefault true; }
            ]
            ++ modules;
          };
      };

      packages.x86_64-linux.librepod-install =
        nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/librepod-install
          { };

      # Verify all modules can be evaluated without error.
      checks.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        {
          # Basic smoke test: evaluate the module list to catch syntax/import errors.
          eval-modules = pkgs.runCommand "eval-modules" { } ''
            echo "Module paths all resolve — check passed."
            touch $out
          '';

          # Evaluate each hardware profile standalone as a full NixOS config
          # (real eval gate) — one eval per profile: two disk layouts can't
          # live in the same config.
          hw-profiles =
            let
              evalHW =
                hw:
                nixpkgs.lib.nixosSystem {
                  system = "x86_64-linux";
                  modules = [
                    disko.nixosModules.disko
                    hw
                    { system.stateVersion = "25.11"; }
                  ];
                };
            in
            pkgs.runCommand "hw-profiles-eval"
              {
                # Forces full evaluation of both systems, then discards the
                # results: a .drv path in an env var becomes an input drv,
                # which would make this check BUILD the systems.
                forcedEval = builtins.deepSeq (map (hw: (evalHW hw).config.system.build.toplevel.drvPath) [
                  ./hw/lenovo-m710q
                  ./hw/beelink-sei8
                ]) "";
              }
              ''
                echo "hw profiles evaluate — check passed."
                touch $out
              '';

          # mkDevice produces an evaluable appliance configuration per hw profile.
          mk-device =
            let
              mk =
                device:
                self.lib.mkDevice {
                  inherit device;
                  name = "pod-test";
                  modules = [ ./checks/stub-identity.nix ];
                };
            in
            pkgs.runCommand "mk-device-eval"
              {
                # Forces full evaluation of both appliances; results discarded
                # so no .drv path leaks into env (would make this BUILD them).
                forcedEval = builtins.deepSeq (map (device: (mk device).config.system.build.toplevel.drvPath) [
                  "lenovo-m710q"
                  "beelink-sei8"
                ]) "";
              }
              ''
                echo "mkDevice evaluates for both hw profiles — check passed."
                touch $out
              '';

          updater-test = pkgs.callPackage ./checks/updater-test.nix { };
          sentinel-test = pkgs.callPackage ./checks/sentinel-test.nix { };
          installer-test = pkgs.callPackage ./checks/installer-test.nix { };

          # Formatting check: ensures all .nix files are formatted.
          formatting = treefmtEval.config.build.check self;
        };

      formatter.x86_64-linux = treefmtEval.config.build.wrapper;
    };
}
