# checks/ab-spike/default.nix — throwaway spike: A/B image updates with
# systemd-sysupdate, signed releases and boot counting, on a minimal image (no
# k3s). Pass criteria: docs/superpowers/specs/2026-11-11-ab-image-updates-design.md
# Run locally (KVM): nix build .#ab-spike -L
{ nixpkgs }:
let
  hostPkgs = nixpkgs.legacyPackages.x86_64-linux;
  inherit (nixpkgs) lib;

  keyring =
    name:
    hostPkgs.runCommand "ab-spike-key-${name}" { nativeBuildInputs = [ hostPkgs.gnupg ]; } ''
      mkdir -p $out/home
      export GNUPGHOME=$out/home
      gpg --batch --passphrase "" --quick-gen-key "LibrePod spike ${name} <${name}@librepod.invalid>" ed25519 sign never
      gpg --export > $out/pubring.pgp
      rm -f $out/home/S.*
    '';
  trusted = keyring "trusted";
  evil = keyring "evil";

  # Releases the device is offered. v1 is the installed image (the test node).
  behaviors = {
    good = { };
    unhealthy = {
      librepod.image.healthCheck = lib.mkForce "${hostPkgs.coreutils}/bin/false";
    };
    # Before the health gate, so the boot is never blessed.
    panic = {
      systemd.services.ab-spike-panic = {
        wantedBy = [ "multi-user.target" ];
        before = [ "librepod-health.service" ];
        serviceConfig.Type = "oneshot";
        script = "echo c > /proc/sysrq-trigger";
      };
    };
    # A frozen PID 1 stops feeding the watchdog: what a hung kernel or init
    # looks like to it. (A real-time spin doesn't do it: since Linux 6.12 the
    # fair server keeps normal tasks, PID 1 included, running.)
    hang = {
      systemd.services.ab-spike-hang = {
        wantedBy = [ "multi-user.target" ];
        before = [ "librepod-health.service" ];
        serviceConfig.Type = "oneshot";
        script = "echo 1 > /sys/fs/cgroup/init.scope/cgroup.freeze";
      };
    };
  };
  releases = {
    "2" = "good";
    "3" = "unhealthy";
    "4" = "panic";
    "5" = "hang";
  };
in
hostPkgs.testers.runNixOSTest {
  name = "ab-spike";

  nodes.server = {
    networking.firewall.enable = false;
    services.nginx = {
      enable = true;
      # Slow enough that the power-cut scenario lands mid-transfer.
      virtualHosts.server = {
        root = "/srv/updates";
        extraConfig = "limit_rate 20m;";
      };
    };
  };

  nodes.machine =
    { pkgs, extendModules, ... }:
    {
      imports = [ ../../modules/image ];
      system.stateVersion = "26.05";
      system.image.version = lib.mkDefault "1";
      librepod.image = {
        updateUrl = "http://server/";
        pubring = "${trusted}/pubring.pgp";
        healthCheck = lib.mkDefault "${pkgs.coreutils}/bin/true";
      };
      # Boot the image's own disk through OVMF, not the framework's.
      virtualisation = {
        directBoot.enable = false;
        mountHostNixStore = false;
        useEFIBoot = true;
        fileSystems = lib.mkForce { };
        memorySize = 2048;
        qemu.options = [ "-device i6300esb" ];
      };
      # Loaded before anything can hang (the M710q's is iTCO_wdt).
      boot.initrd.kernelModules = [ "i6300esb" ];
      system.build.release =
        version: behavior:
        (extendModules {
          modules = [
            { system.image.version = version; }
            behaviors.${behavior}
          ];
        }).config;
    };

  testScript =
    { nodes, ... }:
    let
      m = nodes.machine;
      files =
        version: behavior:
        let
          c = m.system.build.release version behavior;
        in
        hostPkgs.runCommand "ab-spike-release-${version}" { nativeBuildInputs = [ hostPkgs.zstd ]; } ''
          mkdir $out
          cp ${c.system.build.uki}/${c.system.boot.loader.ukiFile} $out/
          zstd -q -T0 ${c.system.build.image}/${c.image.baseName}.store.raw -o $out/${c.image.baseName}.store.raw.zst
        '';
      all = lib.mapAttrsToList files releases;
      repo =
        name:
        {
          key ? trusted,
          tamper ? false,
        }:
        hostPkgs.runCommand "ab-spike-repo-${name}" { nativeBuildInputs = [ hostPkgs.gnupg ]; } ''
          mkdir $out && cd $out
          for r in ${toString all}; do ln -s $r/* .; done
          sha256sum * > SHA256SUMS
          ${lib.optionalString tamper ''
            cp --remove-destination "$(readlink librepod_2.efi)" librepod_2.efi
            chmod u+w librepod_2.efi && echo tampered >> librepod_2.efi
          ''}
          ${lib.optionalString (key != null) ''
            export GNUPGHOME=$(mktemp -d)
            cp -r ${key}/home/. $GNUPGHOME && chmod -R u+w $GNUPGHOME
            gpg --batch --detach-sign --output SHA256SUMS.gpg SHA256SUMS
          ''}
        '';
      good = repo "good" { };
    in
    ''
      import os, subprocess, tempfile, time

      def version():
          return machine.succeed(". /etc/os-release; echo $IMAGE_VERSION").strip()

      def ukis():
          return sorted(machine.succeed("ls /boot/EFI/Linux").split())

      def serve(repo):
          server.succeed(f"ln -sfn {repo} /srv/updates")

      def boots():
          return machine.get_console_log().count("Linux version")

      def wait_boots(n, timeout=900):
          deadline = time.time() + timeout
          while boots() < n:
              if time.time() > deadline:
                  raise Exception(f"wanted {n} boots, saw {boots()}")
              time.sleep(5)

      def reconnect(timeout=300):
          # Same dance as trial-spike: reclaim the backdoor shell once, cleanly.
          deadline = time.time() + timeout
          time.sleep(10)
          while time.time() < deadline:
              try:
                  machine.connected = False
                  machine.succeed("true")
                  return
              except (BrokenPipeError, ValueError):
                  time.sleep(5)
          raise Exception("shell did not come back within timeout")

      def reboot_and_wait(extra=0):
          # extra: boots beyond the first that happen without us (failed tries)
          n = boots() + 1 + extra
          try:
              machine.execute("systemctl reboot", check_return=False, timeout=30)
          except (BrokenPipeError, ValueError):
              pass
          wait_boots(n)
          reconnect()
          machine.wait_for_unit("multi-user.target")

      # The updater's sequence. A failed acquire (bad checksum, power cut) leaves
      # a partial update that blocks the next one until vacuumed; vacuum never
      # touches the running version (ProtectVersion=%A).
      def acquire(v, check=True):
          machine.succeed("systemd-sysupdate vacuum")
          return (machine.succeed if check else machine.fail)(f"systemd-sysupdate acquire {v}")

      def install(v):
          acquire(v)
          machine.succeed(f"systemd-sysupdate update --offline {v}")

      server.start()
      server.wait_for_unit("nginx.service")
      serve("${good}")

      # Only now: every VM started after this boots NIX_DISK_IMAGE.
      disk = tempfile.NamedTemporaryFile(suffix=".qcow2")
      subprocess.run(["${m.virtualisation.qemu.package}/bin/qemu-img", "create", "-f", "qcow2",
                      "-b", "${m.system.build.image}/${m.image.filePath}", "-F", "raw", disk.name], check=True)
      os.environ["NIX_DISK_IMAGE"] = disk.name
      machine.start(allow_reboot=True)
      machine.wait_for_unit("multi-user.target")
      assert version() == "1"
      print(machine.succeed("systemd-sysupdate list"))

      with subtest("refuses unsigned, foreign-key and tampered releases"):
          for repo in ["${repo "unsigned" { key = null; }}", "${repo "evil" { key = evil; }}",
                       "${repo "tampered" { tamper = true; }}"]:
              serve(repo)
              acquire("2", check=False)
              assert ukis() == ["librepod_1.efi"], ukis()
              assert version() == "1"
          serve("${good}")

      with subtest("a power cut while v2 is written leaves v1 running"):
          machine.succeed("systemd-sysupdate vacuum")
          machine.succeed("systemd-run --unit=ab-spike-update systemd-sysupdate acquire 2")
          time.sleep(3)
          # Still writing, so the cut really lands mid-transfer.
          machine.succeed("systemctl is-active ab-spike-update")
          machine.crash()
          machine.start(allow_reboot=True)
          machine.wait_for_unit("multi-user.target")
          assert version() == "1"
          assert ukis() == ["librepod_1.efi"], ukis()

      with subtest("v2: acquire by day, install at night, boot, bless"):
          t = time.time()
          acquire("2")
          acquire_s = time.time() - t
          assert ukis() == ["librepod_1.efi"], ukis()  # nothing bootable changed yet
          t = time.time()
          machine.succeed("systemd-sysupdate update --offline 2")
          install_s = time.time() - t
          print("installed:", ukis())
          t = time.time()
          reboot_and_wait()
          assert version() == "2"
          machine.wait_for_unit("systemd-bless-boot.service")
          boot_s = time.time() - t
          assert "librepod_2.efi" in ukis(), ukis()  # blessed: no tries counter left
          reboot_and_wait()
          assert version() == "2"

      for v, why in [("3", "unhealthy"), ("4", "panic"), ("5", "hang")]:
          with subtest(f"v{v} ({why}) falls back to v2 by itself"):
              install(v)
              # tries=2: v boots twice, then v2 comes back
              reboot_and_wait(extra=2)
              assert version() == "2", version()
              print(f"after v{v}:", ukis())
              # A newer version is installed than runs: the updater reports rolled_back.
              machine.succeed("systemd-sysupdate pending")

      size = os.path.getsize("${good}/librepod_2.store.raw.zst")
      print(f"ab-spike numbers: download {size / 2**20:.0f} MiB (store slot image, zstd), "
            f"acquire {acquire_s:.0f}s at 20 MB/s, install {install_s:.0f}s, "
            f"reboot to blessed {boot_s:.0f}s")
      print("ab-spike: all scenarios passed")
    '';
}
