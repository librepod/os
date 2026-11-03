# checks/e2e/release-modules.nix — what each E2E release changes, by tag.
# release-repo.nix tags every entry and points checks/e2e/this-release.nix at
# it, which the device flake imports from the tag it is locked to.
# releases.nix prebuilds the ones that build, so the VM substitutes them.
{
  "v0.3.5" = { };
  "v0.4.0" = { };
  "v0.5.0" = { };

  # Bad releases: each must fall back to the old one with no help.
  # Does not build.
  "v9.9.1" = {
    assertions = [
      {
        assertion = false;
        message = "e2e: release v9.9.1 does not build";
      }
    ];
  };
  # Root never mounts: stage 1 fails, panics (boot.panic_on_fail) and reboots.
  "v9.9.2" =
    { lib, ... }:
    {
      fileSystems."/".device = lib.mkForce "/dev/disk/by-label/missing";
    };
  # Stage 1 hangs for good: only a power cycle gets out.
  "v9.9.3" = {
    boot.initrd.systemd.services.e2e-hang = {
      requiredBy = [ "initrd.target" ];
      before = [ "initrd.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/bin/sleep infinity";
        TimeoutStartSec = "infinity";
      };
    };
  };
  # Runs, but cannot fetch updates, so it would never update again. The VM is
  # offline and its release source is local, so the fixture points the
  # sentinel's fetch at a name that never resolves (.invalid) instead.
  "v9.9.4" =
    { lib, ... }:
    {
      systemd.services.librepod-update-sentinel.environment.LIBREPOD_URI_PREFIX =
        lib.mkForce "git+https://updates.invalid/os?ref=";
    };
  # Boots, but k3s never starts.
  "v9.9.9" =
    { lib, ... }:
    {
      services.k3s.enable = lib.mkForce false;
    };
}
