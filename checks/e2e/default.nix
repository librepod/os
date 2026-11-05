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

  e2eNode = {
    imports = self.lib.applianceModules ++ [
      ./hw-vm.nix
      ../stub-identity.nix
      ./test-env.nix # the same test-only service env as every device generation
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
    environment.etc."librepod-release".text = "v0.3.5";

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
    import base64, json, time

    def kubectl_json(shellpath):
        return json.loads(pod_e2e.succeed(f"k3s kubectl {shellpath} -o json"))

    def marker():
        return pod_e2e.succeed("cat /etc/librepod-release").strip()

    def node_label():
        return kubectl_json("get node pod-e2e")["metadata"]["labels"].get("librepod.os/version")

    def status():
        cm = kubectl_json("-n librepod-os get cm pod-e2e")
        return json.loads(cm["data"].get("status.json", "{}"))

    def request(rid, version):
        # What the Marketplace writes when the owner clicks Update (docs/updates.md).
        spec = json.dumps({"requestId": rid, "desiredVersion": version, "apply": "now"})
        patch = json.dumps({"data": {"spec.json": spec}})
        pod_e2e.succeed(f"k3s kubectl -n librepod-os patch cm pod-e2e --type merge -p '{patch}'")

    def wait_state(state, timeout=300):
        pod_e2e.wait_until_succeeds(
            "k3s kubectl -n librepod-os get cm pod-e2e -o json"
            f" | jq -e '.data[\"status.json\"] | fromjson | .state == \"{state}\"'",
            timeout=timeout,
        )

    def wait_reboot_from(boots=None, timeout=600):
        # No wait_for_reboot in this driver. Polling the SHELL through a
        # reboot floods the reconnect with garbage (broken pipes, base64
        # desync, non-ascii) — count kernel-boot lines in the append-only
        # console log instead, then reconnect once, cleanly.
        if boots is None:
            boots = pod_e2e.get_console_log().count("Linux version")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if pod_e2e.get_console_log().count("Linux version") > boots:
                break
            time.sleep(5)
        else:
            raise Exception("reboot did not happen within timeout")
        time.sleep(10)  # let the guest settle before reclaiming the shell
        deadline = time.time() + timeout  # its own budget: the boot may have come late
        while time.time() < deadline:
            try:
                pod_e2e.connected = False
                pod_e2e.succeed("true")
                return
            except (BrokenPipeError, ValueError):  # binascii.Error, UnicodeEncodeError are ValueErrors
                time.sleep(5)
        raise Exception("shell did not come back within timeout")

    def start_and_reboot(cmd, reboots=1):
        # The command reboots the machine out from under the backdoor shell;
        # the pipe breaks mid-execute and the driver must not die on it.
        boots = pod_e2e.get_console_log().count("Linux version")
        try:
            pod_e2e.execute(cmd, check_return=False, timeout=300)
        except (BrokenPipeError, ValueError):  # binascii.Error, UnicodeEncodeError are ValueErrors
            pass
        wait_reboot_from(boots + reboots - 1, timeout=600 * reboots)

    def ended_on_old(version, old, reason):
        # The trial of a bad release is over and the device says why.
        wait_healthy()
        wait_state("rolled_back", timeout=300)
        assert marker() == old
        assert status()["currentVersion"] == old
        assert f"({reason})" in status()["detail"], status()
        pod_e2e.succeed(f"grep -qx {version} /var/lib/librepod/failed-versions")
        pod_e2e.succeed("test ! -e /var/lib/librepod/update-pending")
        assert old in pod_e2e.succeed("grep inputs.librepod.url /etc/nixos/flake.nix")

    def wait_healthy():
        pod_e2e.wait_for_unit("k3s.service", timeout=600)
        pod_e2e.wait_until_succeeds(
            "k3s kubectl get node pod-e2e -o json"
            " | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'",
            timeout=600,
        )

    def stage_only():
        # The updater with a no-op reboot: the trial is set up, and the test
        # looks at it before rebooting.
        pod_e2e.succeed("systemctl set-environment SYSTEMCTL=true")
        pod_e2e.succeed("systemctl start librepod-updater.service")
        pod_e2e.succeed("systemctl unset-environment SYSTEMCTL")

    def boot_entry(eid=None):
        # The default entry, or the one with this id, as JSON text. Default is
        # loader.conf's: bootctl's isDefault follows a pending one-shot.
        eid = eid or pod_e2e.succeed("sed -n 's/^default //p' /boot/loader/loader.conf").strip()
        entries = json.loads(pod_e2e.succeed("bootctl list --json=short"))
        hits = [e for e in entries if e["id"] == eid]
        assert len(hits) == 1, (eid, entries)
        return json.dumps(hits[0])

    def oneshot_entry():
        # LoaderEntryOneShot: 4 attribute bytes, then the entry id in UTF-16LE.
        raw = base64.b64decode(pod_e2e.succeed(
            "base64 -w0 /sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
        ))
        return boot_entry(raw[4:].decode("utf-16-le").rstrip("\x00"))

    def pending():
        return json.loads(pod_e2e.succeed("cat /var/lib/librepod/update-pending"))

    # allow_reboot: guest reboots must reset QEMU in-process, not exit it —
    # the updater/sentinel reboot the machine repeatedly.
    pod_e2e.start(allow_reboot=True)

    # ---- phase 0: boot, k3s, device flake, substitution gate -------------
    pod_e2e.wait_for_unit("k3s.service", timeout=600)
    pod_e2e.wait_until_succeeds(
        "k3s kubectl get node pod-e2e -o json"
        " | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'",
        timeout=600,
    )
    # A failed stage 1 must panic and reboot, not sit in emergency mode.
    cmdline = pod_e2e.succeed("cat /proc/cmdline").split()
    assert "panic=10" in cmdline and "boot.panic_on_fail" in cmdline, cmdline

    # Device flake exactly as librepod-install would lay it down.
    pod_e2e.succeed("mkdir -p /etc/nixos /srv")
    pod_e2e.succeed("ln -sfn ${releases.repo} /srv/os")
    pod_e2e.succeed("cp ${selfSrc}/checks/e2e/hw-vm.nix /etc/nixos/hw-vm.nix")
    pod_e2e.succeed("cp ${selfSrc}/checks/stub-identity.nix /etc/nixos/identity.nix")
    pod_e2e.succeed("cat > /etc/nixos/flake.nix <<'EOF'\n"
      "{\n"
      "  inputs.librepod.url = \"git+file:///srv/os?ref=v0.3.5\";\n"
      "  outputs = { librepod, ... }: {\n"
      "    nixosConfigurations.pod-e2e = librepod.lib.mkDevice {\n"
      "      name = \"pod-e2e\";\n"
      "      version = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.librepod.original.ref;\n"
      "      device = ./hw-vm.nix;\n"
      "      modules = [ ./identity.nix ${instrPath} (librepod + \"/checks/e2e/test-env.nix\")\n"
      "        (librepod + \"/checks/e2e/this-release.nix\") ];\n"
      "    };\n"
      "  };\n"
      "}\n"
      "EOF")
    pod_e2e.succeed("cd /etc/nixos && nix flake lock")  # resolves only librepod, offline

    # Models what the installer leaves behind: profile → baseline toplevel.
    pod_e2e.succeed("nix-env -p /nix/var/nix/profiles/system --set ${topPath.v0_3_5}")

    # SUBSTITUTION GATE: in-VM eval must land exactly on the host-prebuilt
    # path. If it builds instead, every later phase times out — fail here.
    out = pod_e2e.succeed(
        "nix build --no-link --print-out-paths"
        " /etc/nixos#nixosConfigurations.pod-e2e.config.system.build.toplevel"
    ).strip()
    assert out == "${topPath.v0_3_5}", f"substitution failed: {out} != ${topPath.v0_3_5}"

    assert marker() == "v0.3.5"

    # ---- phase 1: first updater run → label stamped, nothing reported ----
    pod_e2e.succeed("systemctl start librepod-updater.service")
    pod_e2e.wait_until_succeeds(
        "k3s kubectl get node pod-e2e -o json"
        " | jq -e '.metadata.labels[\"librepod.os/version\"] == \"v0.3.5\"'",
        timeout=120,
    )
    assert status() == {}  # no request yet, so the poll reports nothing

    # ---- phase 2: consent update v0.3.5 → v0.4.0: trial, then commit -----
    request(1, "v0.4.0")
    old = pod_e2e.succeed("readlink -f /run/current-system").strip()
    stage_only()
    assert old in boot_entry()  # OLD stays the default
    assert "${topPath.v0_4_0}" in oneshot_entry()  # the next boot runs NEW
    assert pending()["phase"] == "trial"
    # stage_only is an updater that died before its reboot: the next poll
    # finds the trial staged on this boot and reboots into it.
    start_and_reboot("systemctl start librepod-updater.service")

    wait_healthy()
    wait_state("done", timeout=300)
    assert status()["currentVersion"] == "v0.4.0"  # from the booted system
    assert status()["observedRequestId"] == 1

    assert marker() == "v0.4.0"
    assert node_label() == "v0.4.0"
    assert "${topPath.v0_4_0}" in pod_e2e.succeed("readlink -f /nix/var/nix/profiles/system")
    pod_e2e.succeed("test ! -e /var/lib/librepod/update-pending")
    pod_e2e.succeed("test ! -e /var/lib/librepod/staged")
    assert "v0.4.0" in pod_e2e.succeed("grep inputs.librepod.url /etc/nixos/flake.nix")
    # Committed: NEW is the default now, so it outlives the one-shot.
    assert "${topPath.v0_4_0}" in boot_entry()
    start_and_reboot("systemctl reboot")
    wait_healthy()
    assert marker() == "v0.4.0"

    # ---- phase 3: broken release v9.9.9 → the trial ends on OLD ----------
    request(2, "v9.9.9")
    start_and_reboot("systemctl start librepod-updater.service")

    # The trial boot: k3s absent, sentinel counting down (90 s), then reboot.
    pod_e2e.wait_until_succeeds(
        "test \"$(cat /etc/librepod-release)\" = v9.9.9", timeout=300
    )
    pod_e2e.fail("systemctl is-active --quiet k3s")
    assert pending()["phase"] == "trial"
    # The device flake keeps the old pin until the update commits.
    assert "v0.4.0" in pod_e2e.succeed("grep inputs.librepod.url /etc/nixos/flake.nix")
    wait_reboot_from(timeout=600)  # the sentinel ends the trial

    wait_healthy()
    assert marker() == "v0.4.0"  # the one-shot is used up: OLD again
    assert "${topPath.v0_4_0}" in pod_e2e.succeed(
        "readlink -f /nix/var/nix/profiles/system"
    )
    assert "v0.4.0" in pod_e2e.succeed("grep inputs.librepod.url /etc/nixos/flake.nix")
    pod_e2e.succeed(
        "jq -e '.nodes.librepod.original.ref == \"v0.4.0\"' /etc/nixos/flake.lock"
    )
    wait_state("rolled_back", timeout=300)
    assert status()["currentVersion"] == "v0.4.0"  # booted, not v9.9.9
    assert "(unhealthy)" in status()["detail"], status()
    pod_e2e.succeed("test ! -e /var/lib/librepod/update-pending")
    pod_e2e.succeed("test ! -e /var/lib/librepod/staged")
    pod_e2e.succeed("grep -qx v9.9.9 /var/lib/librepod/failed-versions")
    # Request 2 is still in the mailbox, but it was handled: a poll neither
    # retries v9.9.9 nor overwrites the result.
    pod_e2e.succeed("systemctl start librepod-updater.service")
    assert status()["state"] == "rolled_back"
    assert status()["observedRequestId"] == 2
    assert marker() == "v0.4.0"

    # ---- phase 4: power cut before the trial → clear, no reboot ----------
    from_before = pod_e2e.succeed("readlink -f /nix/var/nix/profiles/system").strip()
    # The cut came inside start_trial, between its two profile switches.
    pod_e2e.succeed("nix-env -p /nix/var/nix/profiles/system --set ${topPath.v9_9_2}")
    pod_e2e.succeed(
        f"jq -nc --arg from '{from_before}' --arg to ${topPath.v9_9_2}"
        " '{from:$from, to:$to, version:\"v9.9.2\", requestId:2, phase:\"staged\"}'"
        " > /var/lib/librepod/update-pending"
    )
    pod_e2e.succeed("systemctl start librepod-update-sentinel.service")
    pod_e2e.succeed("test ! -e /var/lib/librepod/update-pending")
    pod_e2e.fail("grep -qx v9.9.2 /var/lib/librepod/failed-versions")  # it never ran
    assert marker() == "v0.4.0"  # still the same generation
    assert (
        pod_e2e.succeed("readlink -f /nix/var/nix/profiles/system").strip()
        == from_before
    )
    # machine never rebooted — uptime not reset:
    assert int(pod_e2e.succeed("cat /proc/uptime").split(".")[0]) > 30

    # ---- phase 5: power cut mid-commit → the next boot finishes it -------
    request(3, "v0.5.0")
    stage_only()
    # The state a cut leaves after the commit's profile switch: the one-shot
    # used up, the profile on NEW, the boot entries still defaulting to OLD.
    pod_e2e.succeed("bootctl set-oneshot \"\"")
    pod_e2e.succeed("nix-env -p /nix/var/nix/profiles/system --set ${topPath.v0_5_0}")
    pod_e2e.succeed(
        "cd /var/lib/librepod && jq -c '.phase = \"committing\"' update-pending > p.new"
        " && mv p.new update-pending"
    )
    pod_e2e.succeed("sync")  # on disk, as the device's own writes are; a cut loses the rest
    pod_e2e.crash()
    pod_e2e.start(allow_reboot=True)  # restarts the console log
    # OLD boots, the sentinel finishes the commit and reboots into NEW.
    wait_reboot_from(boots=1, timeout=900)
    wait_healthy()
    wait_state("done", timeout=300)
    assert marker() == "v0.5.0"
    assert status()["observedRequestId"] == 3
    assert "${topPath.v0_5_0}" in boot_entry()
    pod_e2e.succeed("jq -e '.nodes.librepod.original.ref == \"v0.5.0\"' /etc/nixos/flake.lock")
    pod_e2e.succeed("test ! -e /var/lib/librepod/update-pending")

    # ---- phase 6: a release that does not build → failed, no reboot ------
    request(4, "v9.9.1")
    pod_e2e.fail("systemctl start librepod-updater.service")  # the build fails
    wait_state("failed", timeout=300)
    assert marker() == "v0.5.0"
    pod_e2e.succeed("test ! -e /var/lib/librepod/update-pending")

    # Each bad release below must land back on OLD with no help.
    # ---- phase 7: root never mounts → stage 1 panics and reboots ---------
    request(5, "v9.9.2")
    start_and_reboot("systemctl start librepod-updater.service", reboots=2)
    assert "Kernel panic" in pod_e2e.get_console_log()
    ended_on_old("v9.9.2", "v0.5.0", "trial-did-not-finish")

    # ---- phase 8: stage 1 hangs → only a power cut gets out --------------
    request(6, "v9.9.3")
    boots = pod_e2e.get_console_log().count("Linux version")
    try:
        pod_e2e.execute("systemctl start librepod-updater.service", check_return=False, timeout=300)
    except (BrokenPipeError, ValueError):  # binascii.Error, UnicodeEncodeError are ValueErrors
        pass
    deadline = time.time() + 600
    while pod_e2e.get_console_log().count("Linux version") <= boots:
        assert time.time() < deadline, "the trial boot never started"
        time.sleep(5)
    time.sleep(60)  # hung in stage 1
    pod_e2e.crash()
    pod_e2e.start(allow_reboot=True)  # restarts the console log
    wait_reboot_from(boots=0)
    ended_on_old("v9.9.3", "v0.5.0", "trial-did-not-finish")

    # ---- phase 9: runs, but cannot fetch updates → never committed -------
    request(7, "v9.9.4")
    start_and_reboot("systemctl start librepod-updater.service")
    assert marker() == "v9.9.4"
    wait_reboot_from(timeout=600)  # the sentinel ends the trial at its deadline
    ended_on_old("v9.9.4", "v0.5.0", "update-source-unreachable")

    print("updates-e2e: all scenarios passed")
  '';
}
