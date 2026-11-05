# checks/e2e/trial-spike.nix — T1 spike: one-shot trial boot on systemd-boot.
# Bootloader mechanics only (no appliance, no k3s), so it runs in minutes.
# Run locally (KVM): nix build .#trial-spike
{ nixpkgs }:
let
  hostPkgs = nixpkgs.legacyPackages.x86_64-linux;
  inherit (nixpkgs) lib;
  instrPath = toString nixpkgs + "/nixos/modules/testing/test-instrumentation.nix";

  common = marker: {
    imports = [ ./hw-vm.nix ];
    system.stateVersion = "26.05";
    environment.etc."release-marker".text = marker;
    environment.systemPackages = [ hostPkgs.jq ];
  };

  # Standalone generations, booted from the VM's disk like a device update.
  mk =
    modules:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ instrPath ] ++ modules;
    }).config.system.build.toplevel;
  # Root disk that never appears: stage 1 waits for it, then fails. The test
  # instrumentation boots with panic=1 boot.panic_on_fail, and the systemd
  # initrd's panic-on-fail.service turns that failure into a panic + reboot.
  badRoot =
    marker:
    mk [
      (common marker)
      { fileSystems."/".device = lib.mkForce "/dev/disk/by-label/missing"; }
    ];
  new = mk [ (common "new") ];
  cut = badRoot "power-cut";
  panics = badRoot "panics";
in
hostPkgs.testers.runNixOSTest {
  name = "trial-spike";
  nodes.machine = {
    imports = [ (common "old") ];
    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;
    virtualisation.writableStore = true;
    virtualisation.writableStoreUseTmpfs = false;
    virtualisation.additionalPaths = [
      new
      cut
      panics
    ];
  };

  testScript = ''
    import json, time

    P = "/nix/var/nix/profiles/system"

    def marker():
        return machine.succeed("cat /etc/release-marker").strip()

    def console_count(text):
        return machine.get_console_log().count(text)

    def wait_console(text, n, timeout=600):
        deadline = time.time() + timeout
        while console_count(text) < n:
            if time.time() > deadline:
                raise Exception(f"{text!r}: wanted {n}, saw {console_count(text)}")
            time.sleep(5)

    def boots():
        return console_count("Linux version")

    def reconnect(timeout=300):
        # Same dance as updates-e2e: reclaim the backdoor shell once, cleanly.
        deadline = time.time() + timeout
        time.sleep(10)
        while time.time() < deadline:
            try:
                machine.connected = False
                machine.succeed("true")
                return
            except (BrokenPipeError, ValueError):  # binascii.Error, UnicodeEncodeError are ValueErrors
                time.sleep(5)
        raise Exception("shell did not come back within timeout")

    def reboot():
        n = boots() + 1
        try:
            machine.execute("systemctl reboot", check_return=False, timeout=30)
        except (BrokenPipeError, ValueError):  # binascii.Error, UnicodeEncodeError are ValueErrors
            pass
        return n

    def stage(new):
        # NEW gets a generation and a boot entry; OLD stays current and default.
        # --set OLD (not --rollback): after an earlier trial, rollback would land
        # on that trial's generation instead of OLD.
        machine.succeed(f"nix-env -p {P} --set {new}")
        machine.succeed(f"nix-env -p {P} --set {old}")
        machine.succeed(f"{old}/bin/switch-to-configuration boot")
        entries = json.loads(machine.succeed("bootctl list --json=short"))
        print(json.dumps(entries, indent=1))
        default = [e for e in entries if e.get("isDefault")]
        assert len(default) == 1 and old in json.dumps(default[0]), default
        ids = [e["id"] for e in entries if new in json.dumps(e)]
        assert len(ids) == 1, ids
        return ids[0]

    def trial(new):
        machine.succeed(f"bootctl set-oneshot {stage(new)}")
        return reboot()

    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")
    old = machine.succeed("readlink -f /run/current-system").strip()
    assert marker() == "old"

    with subtest("one-shot boots NEW once, then OLD"):
        n = trial("${new}")
        wait_console("Linux version", n)
        reconnect()
        assert marker() == "new"
        print(machine.succeed("ls /boot/loader/entries; cat /boot/loader/loader.conf"))
        n = reboot()
        wait_console("Linux version", n)
        reconnect()
        assert marker() == "old"

    with subtest("a power cut during the trial lands on OLD"):
        n = trial("${cut}")
        wait_console("Linux version", n)
        time.sleep(20)  # stage 1, waiting for the root disk
        machine.crash()
        machine.start(allow_reboot=True)
        machine.wait_for_unit("multi-user.target")
        assert marker() == "old"

    with subtest("a failed stage 1 panics, reboots and lands on OLD by itself"):
        panics = console_count("Kernel panic")
        n = trial("${panics}")
        wait_console("Linux version", n + 1, timeout=900)
        reconnect()
        assert marker() == "old"
        assert console_count("Kernel panic") > panics

    print("trial-spike: all scenarios passed")
  '';
}
