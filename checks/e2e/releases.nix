# checks/e2e/releases.nix — host-side release artifacts for the E2E VM.
# The toplevels are evaluated exactly as the device flake will evaluate them
# in-VM (mkDevice + hw-vm + stub identity + the tag's marker module), so the
# in-VM `nix build` substitutes from the store instead of compiling.
{
  self,
  hostPkgs,
}:
let
  mk =
    extraModules:
    self.lib.mkDevice {
      name = "pod-e2e";
      device = ./hw-vm.nix;
      modules = [ ../stub-identity.nix ] ++ extraModules;
    };
in
rec {
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
