# The updater and the sentinel as the module ships them; the checks build
# these same packages, with stubs on PATH in place of nix, k3s and systemd.
# common.sh goes first in both, so env defaults and the status contract
# can't drift.
{ writeShellApplication, runtimeInputs }:

let
  mkScript =
    name: file:
    writeShellApplication {
      inherit name runtimeInputs;
      text = builtins.readFile ./common.sh + builtins.readFile file;
    };
in
{
  updater = mkScript "librepod-updater" ./updater.sh;
  sentinel = mkScript "librepod-update-sentinel" ./sentinel.sh;
}
