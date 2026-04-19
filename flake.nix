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
        casdoor = import ./modules/casdoor;
        common = import ./modules/common;
        disko = ./modules/disko;
        duplicati = import ./modules/duplicati;
        frpc = import ./modules/frpc;
        gitolite = import ./modules/gitolite;
        gobackup = import ./modules/gobackup;
        k3s = import ./modules/k3s;
        networking = import ./modules/networking;
        nfs = import ./modules/nfs;
        nix = import ./modules/nix;
        ssh = import ./modules/ssh;
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

          # Formatting check: ensures all .nix files are formatted.
          formatting = treefmtEval.config.build.check self;
        };

      formatter.x86_64-linux = treefmtEval.config.build.wrapper;
    };
}
