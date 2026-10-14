# checks/e2e/test-env.nix — test-only service env for every DEVICE generation
# (imported by releases.nix's mk and by the device flake the test writes).
# The node config sets the same values via e2eNode; without this module the
# first updated generation would lose them: its updater greps for the default
# github: pin and its sentinel waits out the production 15-min health budget.
{
  systemd.services.librepod-updater.environment.LIBREPOD_URI_PREFIX = "git+file:///srv/os?ref=";
  systemd.services.librepod-update-sentinel.environment = {
    LIBREPOD_HEALTH_TIMEOUT = "90";
    LIBREPOD_HEALTH_STABLE = "20";
    LIBREPOD_POLL_INTERVAL = "5";
  };
}
