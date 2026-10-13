# checks/e2e/releases.nix — host-side release artifacts for the E2E VM.
# The toplevels are evaluated exactly as the device flake will evaluate them
# in-VM (mkDevice + hw-vm + stub identity + the tag's marker module), so the
# in-VM `nix build` substitutes from the store instead of compiling.
{
  self,
  hostPkgs,
}:
let
  # Import nixpkgs the way the VM's path-rewritten lock does: as a locked
  # path reference with no git rev. The github-locked input's flake-level
  # lib bakes `self.rev` into nixos-version, which would make the prebuilt
  # toplevels differ from (and never substitute for) the in-VM evaluation.
  # A bare path: ref is "unlocked" under pure eval, hence the narHash from
  # our own flake.lock (percent-encoded into the query).
  lock = builtins.fromJSON (builtins.readFile "${self}/flake.lock");
  enc = builtins.replaceStrings [ "/" "+" "=" ] [ "%2F" "%2B" "%3D" ];
  nixpkgsPath = builtins.getFlake "path:${builtins.unsafeDiscardStringContext (toString self.inputs.nixpkgs)}?narHash=${enc lock.nodes.nixpkgs.locked.narHash}";

  # mkDevice's shape, but on the rev-less nixpkgs (see above). The module
  # list stays shared: applianceModules is verbatim what a device imports.
  mk =
    extraModules:
    nixpkgsPath.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        librepod = self;
        inputs = {
          nixpkgs = nixpkgsPath;
          disko = self.inputs.disko;
        };
      };
      modules =
        self.lib.applianceModules
        ++ [
          ./hw-vm.nix
          { networking.hostName = "pod-e2e"; }
          { librepod.updates.enable = hostPkgs.lib.mkDefault true; }
          # Every device generation must speak the test driver's backdoor
          # protocol (/dev/hvc0 root shell) or machine.succeed dies on the
          # first reboot into an updated generation.
          (toString self.inputs.nixpkgs + "/nixos/modules/testing/test-instrumentation.nix")
          ../stub-identity.nix
        ]
        ++ extraModules;
    };
in
rec {
  # The nixpkgs k3s module converts extraDeploy manifests via IFD (fromYaml →
  # runCommand). IFD outputs ride no closure, so the E2E VM must already hold
  # them or its offline eval tries to bootstrap stdenv from source and dies.
  # Reproduced here with the same pkgs instance so the drv is byte-identical.
  # ponytail: duplicated from nixpkgs' rancher module — re-sync the yq line
  # if it ever changes there, or when a chart adds another path-valued
  # values/extraDeploy file.
  ifdSeeds =
    let
      convInput = builtins.path {
        path = self + "/modules/k3s/charts/cosign-pub-secret.yaml";
        name = "cosign-pub-secret.yaml";
      };
      devPkgs = import (toString self.inputs.nixpkgs) {
        system = "x86_64-linux";
        overlays = [ self.overlays.default ];
        config = { };
      };
    in
    [
      (devPkgs.runCommand "${convInput}-converted.json" {
        nativeBuildInputs = [ devPkgs.yq-go ];
      } "yq --no-colors --output-format json ${convInput} > $out\n")
    ];

  repo = hostPkgs.callPackage ./release-repo.nix { inherit self hostPkgs; };
  toplevels = {
    v0_3_5 = mk [ { environment.etc."release-marker".text = "v0.3.5"; } ];
    v0_4_0 = mk [ { environment.etc."release-marker".text = "v0.4.0"; } ];
    v9_9_9 = mk [
      {
        environment.etc."release-marker".text = "v9.9.9";
        services.k3s.enable = hostPkgs.lib.mkForce false;
      }
    ];
  };
}
