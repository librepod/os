# checks/e2e/default.nix — full-cycle VM test for the update/rollback flow.
# Run locally (KVM): nix build .#updates-e2e   (~15–20 min)
# Debug:            nix run .#updates-e2e.driverInteractive
{
  self,
  nixpkgs,
}:
let
  hostPkgs = nixpkgs.legacyPackages.x86_64-linux;
  releases = hostPkgs.callPackage ./releases.nix { inherit self hostPkgs; };
  top = builtins.mapAttrs (_: c: c.config.system.build.toplevel) releases.toplevels;
  topPath = builtins.mapAttrs (_: d: toString d) top;
  # The flake source store path. Referenced as a WHOLE path: subpaths like
  # ${toString ./hw-vm.nix} scan as references to the parent store dir, which
  # then fails the disk image's exportReferencesGraph (not in input closure).
  selfSrc = toString self;
  # Test backdoor for the DEVICE generations: mkDevice-produced systems know
  # nothing of the test driver's root shell; without this the driver loses
  # the machine on the first update reboot. Passed identically here and in
  # the device flake so both evals stay identical.
  instrPath = toString nixpkgs + "/nixos/modules/testing/test-instrumentation.nix";

  # Test-only knobs; the scripts read these env vars.
  sentinelEnv = {
    LIBREPOD_HEALTH_TIMEOUT = "90";
    LIBREPOD_HEALTH_STABLE = "20";
    LIBREPOD_POLL_INTERVAL = "5";
  };

  e2eNode = {
    imports = self.lib.applianceModules ++ [
      ./hw-vm.nix
      ../stub-identity.nix
    ];
    networking.hostName = "pod-e2e";
    # mkDevice's tail module — applianceModules stops at the base stack.
    librepod.updates.enable = true;

    # Framework-mandated divergences from the appliance stack (qemu-vm.nix
    # sets these plain; the appliance sets them plain the other way).
    services.timesyncd.enable = nixpkgs.lib.mkForce false;
    # The appliance disables global DHCP (real hw declares per-interface);
    # the VM's virtio NIC has no profile entry, so DHCP must come back on.
    networking.useDHCP = nixpkgs.lib.mkForce true;

    # The device under test shipped at v0.3.5 — the node config models the
    # baseline generation the installer left behind.
    environment.etc."release-marker".text = "v0.3.5";

    # Real bootloader: directBoot VMs have no boot entries, so
    # switch-to-configuration boot + reboot would be a silent no-op.
    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 12288;
    virtualisation.writableStore = true;
    virtualisation.writableStoreUseTmpfs = false;

    # Host-prebuilt generations + the release repo + the flake source + the
    # k3s module's IFD seeds: the VM store serves them; in-VM nix build is
    # pure substitution.
    virtualisation.additionalPaths = [
      releases.repo
      selfSrc
    ]
    ++ releases.ifdSeeds
    ++ builtins.attrValues top;

    systemd.services.librepod-update-sentinel.environment = sentinelEnv;
    systemd.services.librepod-updater.environment.LIBREPOD_URI_PREFIX = "git+file:///srv/os?ref=";

    # The test drives nix, git (git+file fetch), and jq directly.
    environment.systemPackages = with hostPkgs; [
      nix
      git
      jq
    ];
  };
in
hostPkgs.testers.runNixOSTest {
  name = "updates-e2e";
  # applianceModules sets nixpkgs.overlays (the k3s pin); read-only node
  # pkgs (the default) reject any nixpkgs.* definition with types.unique.
  node.pkgsReadOnly = false;
  nodes.pod-e2e = e2eNode;

  extraPythonPackages = ps: [ ];

  testScript = ''
    import binascii, json, time

    def kubectl_json(shellpath):
        return json.loads(machine.succeed(f"k3s kubectl {shellpath} -o json"))

    def marker():
        return machine.succeed("cat /etc/release-marker").strip()

    def node_label():
        return kubectl_json("get node pod-e2e")["metadata"]["labels"].get("librepod.os/version")

    def status():
        cm = kubectl_json("-n librepod-os get cm pod-e2e")
        return json.loads(cm["data"].get("status.json", "{}"))

    def wait_state(state, timeout=300):
        machine.wait_until_succeeds(
            "k3s kubectl -n librepod-os get cm pod-e2e -o json"
            f" | jq -e '.data[\"status.json\"] | fromjson | .state == \"{state}\"'",
            timeout=timeout,
        )

    def wait_reboot_from(bid=None, timeout=600):
        # No wait_for_reboot in this driver. Polling the SHELL through a
        # reboot floods the reconnect with garbage (broken pipes, base64
        # desync, non-ascii) — count kernel-boot lines in the append-only
        # console log instead, then reconnect once, cleanly.
        boots = machine.get_console_log().count("Linux version")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if machine.get_console_log().count("Linux version") > boots:
                break
            time.sleep(5)
        else:
            raise Exception("reboot did not happen within timeout")
        time.sleep(10)  # let the guest settle before reclaiming the shell
        while True:
            try:
                machine.connected = False
                machine.succeed("true")
                return
            except (BrokenPipeError, binascii.Error, UnicodeEncodeError):
                time.sleep(5)

    def start_and_reboot(cmd):
        # The command reboots the machine out from under the backdoor shell;
        # the pipe breaks mid-execute and the driver must not die on it.
        try:
            machine.execute(cmd, check_return=False, timeout=300)
        except (BrokenPipeError, binascii.Error, UnicodeEncodeError):
            pass
        wait_reboot_from(None)

    # allow_reboot: guest reboots must reset QEMU in-process, not exit it —
    # the updater/sentinel reboot the machine repeatedly.
    machine.start(allow_reboot=True)

    # ---- phase 0: boot, k3s, device flake, substitution gate -------------
    machine.wait_for_unit("k3s.service", timeout=600)
    machine.wait_until_succeeds(
        "k3s kubectl get node pod-e2e -o json"
        " | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'",
        timeout=600,
    )

    # Device flake exactly as librepod-install would lay it down.
    machine.succeed("mkdir -p /etc/nixos /srv")
    machine.succeed("ln -sfn ${releases.repo} /srv/os")
    machine.succeed("cp ${selfSrc}/checks/e2e/hw-vm.nix /etc/nixos/hw-vm.nix")
    machine.succeed("cp ${selfSrc}/checks/stub-identity.nix /etc/nixos/identity.nix")
    machine.succeed("cat > /etc/nixos/flake.nix <<'EOF'\n"
      "{\n"
      "  inputs.librepod.url = \"git+file:///srv/os?ref=v0.3.5\";\n"
      "  outputs = { librepod, ... }: {\n"
      "    nixosConfigurations.pod-e2e = librepod.lib.mkDevice {\n"
      "      name = \"pod-e2e\";\n"
      "      device = ./hw-vm.nix;\n"
      "      modules = [ ./identity.nix ${instrPath} (librepod + \"/checks/e2e/test-env.nix\") ];\n"
      "    };\n"
      "  };\n"
      "}\n"
      "EOF")
    machine.succeed("cd /etc/nixos && nix flake lock")  # resolves only librepod, offline

    # Models what the installer leaves behind: profile → baseline toplevel.
    machine.succeed("nix-env -p /nix/var/nix/profiles/system --set ${topPath.v0_3_5}")

    # SUBSTITUTION GATE: in-VM eval must land exactly on the host-prebuilt
    # path. If it builds instead, every later phase times out — fail here.
    out = machine.succeed(
        "nix build --no-link --print-out-paths"
        " /etc/nixos#nixosConfigurations.pod-e2e.config.system.build.toplevel"
    ).strip()
    assert out == "${topPath.v0_3_5}", f"substitution failed: {out} != ${topPath.v0_3_5}"

    assert marker() == "v0.3.5"

    # ---- phase 1: first updater run → label stamped, idle ----------------
    machine.succeed("systemctl start librepod-updater.service")
    machine.wait_until_succeeds(
        "k3s kubectl get node pod-e2e -o json"
        " | jq -e '.metadata.labels[\"librepod.os/version\"] == \"v0.3.5\"'",
        timeout=120,
    )
    assert status()["state"] == "idle"

    # ---- phase 2: consent update v0.3.5 → v0.4.0 → commit ----------------
    machine.succeed(
        "k3s kubectl -n librepod-os patch cm pod-e2e --type merge"
        " -p '{\"data\":{\"spec.json\":\"{\\\"desiredVersion\\\":\\\"v0.4.0\\\",\\\"apply\\\":\\\"now\\\"}\"}}'"
    )
    # The updater reboots the machine mid-command; the shell dies with it.
    start_and_reboot("systemctl start librepod-updater.service")

    machine.wait_for_unit("k3s.service", timeout=600)
    machine.wait_until_succeeds(
        "k3s kubectl get node pod-e2e -o json"
        " | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'",
        timeout=600,
    )
    wait_state("done", timeout=300)

    assert marker() == "v0.4.0"
    assert node_label() == "v0.4.0"
    assert "${topPath.v0_4_0}" in machine.succeed("readlink -f /nix/var/nix/profiles/system")
    machine.succeed("test ! -e /var/lib/librepod/update-pending")
    machine.succeed("test ! -e /var/lib/librepod/flake.nix.bak")
    machine.succeed("test ! -e /var/lib/librepod/flake.lock.bak")
    assert "v0.4.0" in machine.succeed("grep inputs.librepod.url /etc/nixos/flake.nix")

    # ---- phase 3: broken release v9.9.9 → auto-rollback ------------------
    machine.succeed(
        "k3s kubectl -n librepod-os patch cm pod-e2e --type merge"
        " -p '{\"data\":{\"spec.json\":\"{\\\"desiredVersion\\\":\\\"v9.9.9\\\",\\\"apply\\\":\\\"now\\\"}\"}}'"
    )
    start_and_reboot("systemctl start librepod-updater.service")

    # Broken gen: k3s absent, sentinel counting down (90 s), then rollback.
    machine.wait_until_succeeds(
        "test \"$(cat /etc/release-marker)\" = v9.9.9", timeout=300
    )
    machine.fail("systemctl is-active --quiet k3s")
    machine.succeed("test -e /var/lib/librepod/update-pending")  # staged while unhealthy
    wait_reboot_from(timeout=600)  # sentinel rollback reboot

    machine.wait_for_unit("k3s.service", timeout=600)

    # FIRST post-rollback action: withdraw consent before the 2-min updater
    # timer re-applies v9.9.9 (OnBootSec race — see plan constraints).
    machine.succeed(
        "k3s kubectl -n librepod-os patch cm pod-e2e --type merge"
        " -p '{\"data\":{\"spec.json\":null}}'"
    )

    machine.wait_until_succeeds(
        "k3s kubectl get node pod-e2e -o json"
        " | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'",
        timeout=600,
    )

    assert marker() == "v0.4.0"  # previous generation restored
    assert "${topPath.v0_4_0}" in machine.succeed(
        "readlink -f /nix/var/nix/profiles/system"
    )
    assert "v0.4.0" in machine.succeed("grep inputs.librepod.url /etc/nixos/flake.nix")
    machine.succeed(
        "jq -e '.nodes.librepod.original.ref == \"v0.4.0\"' /etc/nixos/flake.lock"
    )
    wait_state("rolled_back", timeout=300)
    machine.succeed("test ! -e /var/lib/librepod/update-pending")
  '';
}
