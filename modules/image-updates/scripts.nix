# The updater, the health gate and the bridge as the module ships them; the
# checks build these same packages, with stubs on PATH in place of systemd and
# kubectl. common.sh goes first in each, so env defaults and the status
# contract can't drift.
{
  writeShellApplication,
  runtimeInputs,
  healthInputs ? [ ],
  bridgeInputs ? [ ],
}:

let
  mkScript =
    name: file: extraInputs:
    writeShellApplication {
      inherit name;
      # Each script uses a subset of common.sh.
      excludeShellChecks = [ "SC2329" ];
      runtimeInputs = runtimeInputs ++ extraInputs;
      text = builtins.readFile ./common.sh + builtins.readFile file;
    };
in
{
  updater = mkScript "librepod-update" ./updater.sh [ ];
  health = mkScript "librepod-update-health" ./health.sh healthInputs;
  bridge = mkScript "librepod-update-bridge" ./bridge.sh bridgeInputs;
}
