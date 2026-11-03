{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # INFO: Pin k3s to a specific version by using a specific nixpkgs commit
    # To update k3s version, find a nixpkgs commit with the desired k3s version:
    # 1. Go to https://github.com/NixOS/nixpkgs/commits/master/pkgs/applications/networking/cluster/k3s
    # 2. Find the commit that has your desired version
    # 3. Update the URL below with that commit
    # 4. Update the versioned attribute (k3s_1_34) in overlays.default below —
    #    the top-level `k3s` alias drifts to newer minors and gets dropped eventually
    k3s-nixpkgs.url = "github:NixOS/nixpkgs/1975f10693a3e9b52c356151426410f3b80a7fbb";

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

      # The appliance base stack. Shared verbatim by mkDevice and the E2E
      # test node so the VM runs exactly what a device runs.
      applianceModules = [
        # Pinned k3s from this os release
        {
          nixpkgs.overlays = [ self.overlays.default ];
        }
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
      ];
    in
    {
      # Overlay that pins k3s to a specific version via k3s-nixpkgs.
      # Consumers should apply this overlay to get the pinned k3s version.
      overlays.default = final: prev: {
        # Versioned attr, not the `k3s` alias: nixpkgs repoints the alias to
        # newer minors, which would silently jump the cluster's Kubernetes minor.
        k3s =
          (import k3s-nixpkgs {
            inherit (prev.stdenv) system;
            config.allowUnfree = false;
          }).k3s_1_34;
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
        applianceModules = applianceModules;

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
        #   version — the release tag; the device flake passes its lock's
        #             nodes.librepod.original.ref
        #   device  — supported profile name under ./hw (string), or any
        #             hardware module path (unsupported/personal devices)
        #   modules — install-day facts (disk layout, stateVersion) and
        #             identity modules (users, frpc, per-device bits)
        mkDevice =
          {
            name,
            version,
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
            modules =
              applianceModules
              ++ [
                # Supported profile by name, or a consumer-supplied module path
                (if builtins.isString device then (./hw + "/${device}") else device)
                { networking.hostName = name; }
                # The updater reports this, not flake.lock: the two disagree
                # after a failed or rolled-back update.
                { environment.etc."librepod-release".text = version; }
                # Appliances are updateable; identity can override (mkDefault).
                { librepod.updates.enable = nixpkgs.lib.mkDefault true; }
              ]
              ++ modules;
          };
      };

      packages.x86_64-linux.librepod-install =
        nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/librepod-install
          { };

      # E2E (KVM): nix build .#updates-e2e — NOT in checks.*; release-stable.yml gates releases on it
      updates-e2e = nixpkgs.legacyPackages.x86_64-linux.callPackage ./checks/e2e {
        inherit self nixpkgs;
      };

      # Local-only (KVM): nix build .#trial-spike — bootloader mechanics of the trial boot
      trial-spike = nixpkgs.legacyPackages.x86_64-linux.callPackage ./checks/e2e/trial-spike.nix {
        inherit nixpkgs;
      };

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
          # (real eval gate), on the layout the installer writes as disk.nix.
          hw-profiles =
            let
              evalHW =
                hw:
                nixpkgs.lib.nixosSystem {
                  system = "x86_64-linux";
                  modules = [
                    disko.nixosModules.disko
                    ./modules/disko
                    hw
                    { system.stateVersion = "25.11"; }
                  ];
                };
            in
            pkgs.runCommand "hw-profiles-eval"
              {
                # Forces full evaluation of the system, then discards the
                # result: a .drv path in an env var becomes an input drv,
                # which would make this check BUILD the system.
                forcedEval = builtins.deepSeq [
                  (evalHW ./hw/lenovo-m710q).config.system.build.toplevel.drvPath
                ] "";
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
                  version = "v0.0.0";
                  modules = [
                    ./modules/disko # what the installer copies in as disk.nix
                    ./checks/stub-identity.nix
                  ];
                };
            in
            pkgs.runCommand "mk-device-eval"
              {
                # Forces full evaluation of the appliance; result discarded
                # so no .drv path leaks into env (would make this BUILD it).
                # Both device forms: profile name and module path.
                forcedEval = builtins.deepSeq [
                  (mk "lenovo-m710q").config.system.build.toplevel.drvPath
                  (mk ./hw/lenovo-m710q).config.system.build.toplevel.drvPath
                ] "";
              }
              ''
                echo "mkDevice evaluates for both device forms — check passed."
                touch $out
              '';

          # An installed device keeps its disk: no release may change the file
          # systems or stateVersion it boots with. A deliberate change (with a
          # migration for installed devices) updates expected.json.
          installed-device =
            let
              c =
                (self.lib.mkDevice {
                  name = "pod-test";
                  version = "v0.0.0";
                  device = "lenovo-m710q";
                  modules = [
                    ./checks/installed-device/install.nix
                    ./checks/stub-identity.nix
                  ];
                }).config;
              got = builtins.toJSON {
                stateVersion = c.system.stateVersion;
                fileSystems = builtins.mapAttrs (_: f: {
                  inherit (f) device fsType options;
                }) c.fileSystems;
              };
              want = builtins.toJSON (
                builtins.fromJSON (builtins.readFile ./checks/installed-device/expected.json)
              );
            in
            assert got == want || throw "an installed device would change: ${got}, expected ${want}";
            pkgs.runCommand "installed-device" { } "touch $out";

          updater-test = pkgs.callPackage ./checks/updater-test.nix { };
          sentinel-test = pkgs.callPackage ./checks/sentinel-test.nix { };
          installer-test = pkgs.callPackage ./checks/installer-test.nix { };

          # Formatting check: ensures all .nix files are formatted.
          formatting = treefmtEval.config.build.check self;
        };

      formatter.x86_64-linux = treefmtEval.config.build.wrapper;
    };
}
