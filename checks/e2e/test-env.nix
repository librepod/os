# checks/e2e/test-env.nix — test-only service env for the node and every DEVICE
# generation (imported by e2eNode, releases.nix's mk and the device flake the
# test writes). Without it an updated generation's updater greps for the
# default github: pin and its sentinel waits out the 15-min health budget.
{
  systemd.services.librepod-updater.environment.LIBREPOD_URI_PREFIX = "git+file:///srv/os?ref=";
  systemd.services.librepod-update-sentinel.environment = {
    LIBREPOD_URI_PREFIX = "git+file:///srv/os?ref="; # the fetch check
    LIBREPOD_HEALTH_TIMEOUT = "90";
    LIBREPOD_HEALTH_STABLE = "20";
    LIBREPOD_POLL_INTERVAL = "5";
  };
}
