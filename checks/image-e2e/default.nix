# checks/image-e2e/default.nix — librepod-install writes the appliance image,
# k3s included, to an OS disk and a recycled data disk; it refuses USB, mounted
# and partition targets, and existing LibrePod data unless told --keep-data.
# The installed disk boots by its UEFI entry with root grown to the disk, and
# keeps its identity outside Nix: the hostname comes from /etc/hostname, the
# generic login is console-only until a key is added, and a changed password,
# the host key and machine-id survive a reboot. Extra NVMe, SATA and USB
# drives, another LibrePod's data disk and a copy of the image among them,
# change nothing: the OS disk is the one booted from, the data disk the one
# recorded on root. Without its data disk the device still boots, NFS off.
# It reads a signed release, as CI publishes one, and finds its own profile's
# version there; the installer writes that release's disk image.
# Then it updates itself from 0.5.0, as the real units do: from stable with k3s
# stopped; automatically in the night window, set through the ConfigMap, to a
# version that fails its health gate and is rolled back with k3s's data
# restored; never automatically again, but when the owner asks; beta's version
# only on beta; and after a power cut mid-install, back on the old version.
# Run locally (KVM, about an hour and a half): nix build .#image-e2e -L
{ self, nixpkgs }:
let
  hostPkgs = nixpkgs.legacyPackages.x86_64-linux;
  inherit (nixpkgs) lib;
  sshKeys = import "${nixpkgs}/nixos/tests/ssh-keys.nix" hostPkgs;

  # A GPT disk built the way image.repart builds the OS disk.
  gptDisk =
    name: seed: partitions:
    let
      defs = hostPkgs.linkFarm "image-e2e-${name}-repart.d" (
        lib.imap1 (i: p: {
          name = "${toString i}.conf";
          path = hostPkgs.writeText "${toString i}.conf" (lib.generators.toINI { } { Partition = p; });
        }) partitions
      );
    in
    hostPkgs.runCommand "image-e2e-${name}.raw"
      {
        nativeBuildInputs = with hostPkgs; [
          systemd
          util-linux
          fakeroot
          e2fsprogs.bin
          dosfstools
          mtools
        ];
      }
      ''
        unshare --map-root-user fakeroot systemd-repart --dry-run=no --empty=create --size=auto \
          --architecture=x86-64 --seed=${seed} --definitions=${defs} $out
      '';
  # A release folder as release-stable.yml publishes it, signed with a test key.
  releaseKey =
    hostPkgs.runCommand "image-e2e-release-key" { nativeBuildInputs = [ hostPkgs.gnupg ]; }
      ''
        mkdir -p $out/home
        export GNUPGHOME=$out/home
        gpg --batch --passphrase "" --quick-gen-key "LibrePod image-e2e <e2e@librepod.invalid>" ed25519 sign never
        gpg --export > $out/release.pgp
        rm -f $out/home/S.*
      '';
  # A channel's folder holds one version (GitHub's latest/download, or beta):
  # the device files only, as the beta copy holds them.
  repo =
    c:
    hostPkgs.runCommand "image-e2e-repo-${c.system.image.version}"
      { nativeBuildInputs = [ hostPkgs.gnupg ]; }
      ''
        mkdir $out && cd $out
        ln -s ${c.system.build.releaseFiles}/*.efi ${c.system.build.releaseFiles}/*.store.raw.zst .
        sha256sum -- * > SHA256SUMS
        export GNUPGHOME=$(mktemp -d)
        cp -r ${releaseKey}/home/. $GNUPGHOME && chmod -R u+w $GNUPGHOME
        gpg --batch --detach-sign --output SHA256SUMS.gpg SHA256SUMS
        gpgv --keyring ${releaseKey}/release.pgp SHA256SUMS.gpg SHA256SUMS
      '';
  # Another LibrePod's data disk, plugged in next to ours.
  otherDataDisk = gptDisk "otherdata" "9a4f1c2e-6b7d-4e8f-a1b2-c3d4e5f60718" [
    {
      Type = "linux-generic";
      Label = "librepod-data";
      UUID = "7d2a0c55-3e1b-4f6a-9c8d-2b3a4c5d6e70";
      Format = "ext4";
      SizeMinBytes = "1G";
    }
  ];
  # A Linux disk from another computer, with the generic labels: also what the
  # installer's targets carry before it runs.
  foreignDisk = gptDisk "foreign" "0b6e2f61-2c1d-4a8e-b3f7-9e5a4c3d2b01" [
    {
      Type = "esp";
      Label = "esp";
      Format = "vfat";
      SizeMinBytes = "100M";
    }
    {
      Type = "root";
      Label = "root";
      Format = "ext4";
      SizeMinBytes = "100M";
    }
  ];
in
hostPkgs.testers.runNixOSTest {
  name = "image-e2e";
  # The default hour isn't enough with the update scenarios' ten-odd boots.
  globalTimeout = 3 * 3600;
  # The k3s overlay in imageModules
  node.pkgsReadOnly = false;

  # The bench: a live system booted through UEFI, with the device's two disks
  # and a USB stick.
  nodes.installer =
    { pkgs, ... }:
    {
      virtualisation = {
        useEFIBoot = true;
        qemu.options = [
          "-drive if=none,id=os,format=qcow2,file=$OS_DISK,detect-zeroes=on"
          "-device virtio-blk-pci,serial=os,drive=os"
          "-drive if=none,id=data,format=qcow2,file=$DATA_DISK"
          "-device nvme,serial=data,drive=data"
          "-device qemu-xhci,id=xhci"
          "-drive if=none,id=usb,format=qcow2,file=$USB_DISK"
          "-device usb-storage,bus=xhci.0,serial=usb,drive=usb"
        ];
      };
      environment.systemPackages = [
        self.packages.x86_64-linux.librepod-install
        pkgs.efibootmgr
      ];
    };

  # One folder per channel: the test points stable and beta at a version's repo.
  nodes.server = {
    networking.firewall.enable = false;
    services.nginx = {
      enable = true;
      virtualHosts.server.root = "/srv/updates";
    };
  };

  nodes.pod =
    { pkgs, extendModules, ... }:
    {
      imports = self.lib.imageModules;
      system.image.version = lib.mkDefault "0.5.0";
      librepod.image = {
        updateUrl = "http://server/stable/";
        betaUrl = "http://server/beta/";
        pubring = "${releaseKey}/release.pgp";
        profile = "vm";
      };
      systemd.services.librepod-update.environment.LIBREPOD_TEST_HOLD = "/run/librepod-test-hold";
      # A later version of this device, test backdoor and all.
      system.build.release =
        version: modules:
        (extendModules { modules = [ { system.image.version = version; } ] ++ modules; }).config;

      # VM hardware: a hw profile's job on a device. The M90q's storage
      # drivers too, so the extra drives are there while root mounts.
      networking.interfaces.eth0.useDHCP = true;
      boot.initrd.availableKernelModules = [
        "virtio_net"
        "virtio_pci"
        "virtio_blk"
        "virtio_scsi"
        "nvme"
        "ahci"
        "xhci_pci"
        "usb_storage"
        "sd_mod"
      ];
      # Boot the image's own disk through OVMF, not the framework's.
      virtualisation = {
        directBoot.enable = false;
        mountHostNixStore = false;
        useEFIBoot = true;
        fileSystems = lib.mkForce { };
        memorySize = 4096;
        # No bootindex: OVMF boots by the entry the installer registered.
        qemu.drives = lib.mkForce [
          {
            name = "root";
            file = ''"$NIX_DISK_IMAGE"'';
            driveExtraOpts = {
              cache = "writeback";
              werror = "report";
            };
            deviceExtraOpts.serial = "root";
          }
        ];
        qemu.options = [
          # The extra NVMe comes first: the data disk is not nvme0n1.
          "-drive if=none,id=extra,format=qcow2,file=$EXTRA_DISK"
          "-device nvme,serial=extra,drive=extra"
          "-drive if=none,id=otherdata,format=qcow2,file=$OTHERDATA_DISK"
          "-device nvme,serial=otherdata,drive=otherdata"
          "-drive if=none,id=data,format=qcow2,file=$DATA_DISK"
          "-device nvme,serial=data,drive=data"
          "-device ahci,id=ahci"
          "-drive if=none,id=foreign,format=qcow2,file=$FOREIGN_DISK"
          "-device ide-hd,bus=ahci.0,serial=foreign,drive=foreign"
          # A copy of the image: same labels, the image's partition UUIDs.
          "-drive if=none,id=otheros,format=qcow2,file=$OTHEROS_DISK"
          "-device ide-hd,bus=ahci.1,serial=otheros,drive=otheros"
          "-device qemu-xhci,id=xhci"
          "-drive if=none,id=usb,format=qcow2,file=$USB_DISK"
          "-device usb-storage,bus=xhci.0,serial=usb,drive=usb"
        ];
      };
      services.timesyncd.enable = lib.mkForce false;
      # The framework gives root an empty password; see the product's root.
      users.users.root.hashedPasswordFile = lib.mkForce null;

      environment.systemPackages = [
        pkgs.sshpass
        pkgs.efibootmgr
      ];
    };

  testScript =
    { nodes, ... }:
    let
      m = nodes.pod;
      # 0.5.2 changes k3s's data, then fails its health gate.
      unhealthy =
        { pkgs, ... }:
        {
          librepod.image.healthCheck = lib.mkForce (
            toString (
              pkgs.writeShellScript "image-e2e-unhealthy" ''
                until ${pkgs.k3s}/bin/k3s kubectl wait --for=condition=Ready nodes --all --timeout=10s; do sleep 5; done
                ${pkgs.k3s}/bin/k3s kubectl create configmap made-by-0-5-2 || true
                exit 1
              ''
            )
          );
        };
      releases = {
        "0.5.0" = m;
        "0.5.1" = m.system.build.release "0.5.1" [ ];
        "0.5.2" = m.system.build.release "0.5.2" [ unhealthy ];
        "0.5.3" = m.system.build.release "0.5.3" [ ];
      };
    in
    ''
      import json, os, subprocess, tempfile, time
      from test_driver.errors import RequestedAssertionFailed

      def boots():
          return pod.get_console_log().count("Linux version")

      def wait_boots(n, timeout=900):
          deadline = time.time() + timeout
          while boots() < n:
              if time.time() > deadline:
                  raise Exception(f"wanted {n} boots, saw {boots()}")
              time.sleep(5)

      def reconnect(timeout=300):  # to the shell of the last boot
          # Every boot's backdoor announces itself on the one shell socket, and
          # connect() stops at the first: after a few boots, one that's gone. So
          # once this boot's is up, drop them all and check the shell answers.
          deadline = time.time() + timeout
          while time.time() < deadline:
              if "connecting to host..." in pod.get_console_log().split("Linux version")[-1]:
                  time.sleep(2)  # its announcement follows at once
                  shell = pod.shell
                  assert shell
                  shell.setblocking(False)
                  try:
                      while shell.recv(4096):
                          pass
                  except BlockingIOError:
                      pass
                  finally:
                      shell.setblocking(True)
                  pod.connected = True
                  try:
                      pod.succeed("true")
                      return
                  except (BrokenPipeError, ValueError, RequestedAssertionFailed):
                      pass  # garbled by output still arriving: drop it, try again
              time.sleep(5)
          raise Exception("shell did not come back within timeout")

      def up_after(n, timeout=900):  # the shell of the n-th boot
          wait_boots(n, timeout)
          reconnect()
          pod.wait_for_unit("multi-user.target")

      def reboot_and_wait():
          n = boots() + 1
          try:
              pod.execute("systemctl reboot", check_return=False, timeout=30)
          except (BrokenPipeError, ValueError):
              pass
          up_after(n)

      disks = []
      def disk(backing=None, size=None):  # size: the backing file's, or 1G blank
          f = tempfile.NamedTemporaryFile(suffix=".qcow2")
          disks.append(f)
          args = ["-b", backing, "-F", "raw"] if backing else []
          size = [size] if size else [] if backing else ["1G"]
          subprocess.run(["${m.virtualisation.qemu.package}/bin/qemu-img", "create", "-f", "qcow2",
                          *args, f.name, *size], check=True)
          return f.name

      # One NVRAM: the pod boots by the entry the installer wrote.
      os.environ["NIX_EFI_VARS"] = os.path.join(tempfile.mkdtemp(), "efi-vars.fd")
      os.environ["OS_DISK"] = disk("${foreignDisk}", "24G")
      os.environ["DATA_DISK"] = disk("${foreignDisk}", "2G")  # a recycled disk
      os.environ["USB_DISK"] = disk()
      installer.start()
      server.start()  # before NIX_DISK_IMAGE points at the OS disk, below
      installer.wait_for_unit("multi-user.target")

      def dev(serial):  # kernel path of the disk with this serial
          return installer.succeed(f"lsblk -dnpo PATH,SERIAL | awk '$2==\"{serial}\" {{print $1}}'").strip()
      os_, data = dev("os"), dev("data")
      inst = "librepod-install --image ${m.system.build.releaseFiles}/librepod-vm_0.5.0.raw.zst --name pod-image --disk {disk} --data-disk {data} {flags}"

      with subtest("refusals: USB, mounted, a partition, held by device-mapper"):
          installer.fail(inst.format(disk=os_, data=dev("usb"), flags=""))
          installer.fail(inst.format(disk=dev("root"), data=data, flags=""))  # the installer's own
          installer.fail(inst.format(disk=os_ + "1", data=data, flags=""))
          # an old LVM the live system activated: in use, though nothing is mounted
          installer.succeed(f"dmsetup create held --table '0 8 linear {os_} 0'")
          out = installer.fail(inst.format(disk=os_, data=data, flags="") + " 2>&1")
          assert "in use" in out, out
          installer.succeed("dmsetup remove held")
          installer.fail("efibootmgr | grep LibrePod")

      with subtest("install; the data disk is ours"):
          out = installer.succeed(inst.format(disk=os_, data=data, flags=""))  # recycled disk: no flag needed
          code = out.strip().splitlines()[-1].split()[-1]  # "... setup code XXXX-XXXX-XXXX", the sticker's
          installer.succeed(f"mkdir -p /mnt && mount {data}p1 /mnt && touch /mnt/marker && umount /mnt")

      with subtest("existing data: refused without a flag, kept with --keep-data"):
          out = installer.fail(inst.format(disk=os_, data=data, flags="") + " 2>&1")
          assert "--keep-data" in out and "--wipe-data" in out, out
          # a reinstall keeps the sticker's code, typed as printed or not
          installer.succeed(inst.format(disk=os_, data=data, flags=f"--keep-data --setup-code {code.lower()}"))
      installer.shutdown()

      def serve(channel, repo):
          server.succeed(f"ln -sfn {repo} /srv/updates/{channel}")
      server.succeed("mkdir -p /srv/updates")
      serve("stable", "${repo releases."0.5.0"}")
      serve("beta", "${repo releases."0.5.3"}")

      os.environ["NIX_DISK_IMAGE"] = os.environ["OS_DISK"]
      os.environ["EXTRA_DISK"] = disk()
      os.environ["OTHERDATA_DISK"] = disk("${otherDataDisk}")
      os.environ["FOREIGN_DISK"] = disk("${foreignDisk}")
      os.environ["OTHEROS_DISK"] = disk("${m.system.build.image}/${m.image.filePath}")
      pod.start(allow_reboot=True)
      pod.wait_for_unit("multi-user.target")

      ssh = "sshpass -p {pw} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null {opts} librepod@localhost true"

      def disk_of(path):
          # serial of the disk holding the file system mounted at path
          src = pod.succeed(f"findmnt -fnvo SOURCE {path}").strip()
          return pod.succeed(f"lsblk -dno SERIAL /dev/$(lsblk -no PKNAME {src})").strip()

      def part_uuid(serial, label):
          # GPT UUID of the partition with this label on the disk with this serial
          disk = pod.succeed(f"lsblk -dnpo PATH,SERIAL | awk '$2==\"{serial}\" {{print $1}}'").strip()
          return pod.succeed(f"lsblk -nro PARTLABEL,PARTUUID {disk} | awk '$1==\"{label}\" {{print $2}}'").strip()

      def check_drives():
          serials = set(pod.succeed("lsblk -dno SERIAL").split())
          assert {"root", "data", "otherdata", "extra", "foreign", "otheros", "usb"} <= serials, serials
          for path in ["/", "/boot", "/nix/store"]:
              assert disk_of(path) == "root", (path, disk_of(path))
          assert disk_of("/mnt/k3s") == "data", disk_of("/mnt/k3s")
          # a fixed /dev/nvme0n1 name would have found the blank extra NVMe
          assert pod.succeed("lsblk -dno NAME,SERIAL | grep -w extra").startswith("nvme0n1")

      def wait_ready():
          pod.wait_until_succeeds(
              "k3s kubectl get node pod-image -o json"
              " | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'",
              timeout=600,
          )

      with subtest("hostname comes from /etc/hostname"):
          assert pod.succeed("hostname").strip() == "pod-image", pod.succeed("hostname")

      with subtest("the generic login: console only until a key is added; root locked"):
          assert pod.succeed("getent shadow root | cut -d: -f2").startswith("!")
          pod.wait_for_unit("sshd.service")
          pod.fail(ssh.format(pw="librepod", opts="-o PubkeyAuthentication=no"))
          # a power user adds a key
          key = open("${sshKeys.snakeOilPrivateKey}").read()
          pod.succeed(f"umask 077; cat > /root/key <<'EOF'\n{key}EOF")
          pod.succeed(
              "install -d -m 700 -o librepod -g users ~librepod/.ssh",
              "echo '${sshKeys.snakeOilPublicKey}' > ~librepod/.ssh/authorized_keys",
              "chown librepod:users ~librepod/.ssh/authorized_keys",
              "chmod 600 ~librepod/.ssh/authorized_keys",
          )
          pod.succeed(ssh.format(pw="librepod", opts="-i /root/key"))
          # and can copy files: scp needs sshd's sftp subsystem
          pod.succeed("sshpass -p librepod scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
                      " -i /root/key librepod@localhost:/etc/hostname /tmp/copy")
          assert pod.succeed("cat /tmp/copy").strip() == "pod-image"

      with subtest("extra NVMe, SATA and USB drives change nothing"):
          check_drives()

      with subtest("installed: root fills the disk, our entry booted, old data kept"):
          assert int(pod.succeed("df -B1 --output=size / | tail -1")) > 5 * 2**30
          assert "LibrePod" in pod.succeed("efibootmgr | grep \"Boot$(efibootmgr | sed -n 's/^BootCurrent: //p')\"")
          pod.succeed("test -e /mnt/k3s/marker")
          # fresh GUIDs: our ESP differs from the image copy's
          ours, copy = part_uuid("root", "librepod-esp"), part_uuid("otheros", "librepod-esp")
          assert ours and copy and ours != copy, (ours, copy)

      with subtest("PVs land on the data disk"):
          assert pod.succeed("findmnt -no PARTLABEL /mnt/k3s").strip() == "librepod-data"
          pod.succeed("findmnt /exports/k3s")

      with subtest("avahi is the only mDNS responder"):
          # <name>.local is how owners find the device; a second stack makes it unreliable
          responders = pod.succeed("ss -Hulpn 'sport = :5353'")
          assert "systemd-resolve" not in responders, responders

      with subtest("the published release: signed, this profile's files, this version"):
          server.wait_for_unit("nginx.service")
          out = pod.succeed("systemd-sysupdate --json=short list 0.5.0")
          v = json.loads(out)
          assert v["installed"] and v["available"], v

      with subtest("the k3s node is named after the device"):
          pod.wait_for_unit("k3s.service", timeout=600)
          wait_ready()
          assert pod.succeed("k3s kubectl get nodes -o name").split() == ["node/pod-image"]

      with subtest("the sticker's setup code reaches marketplace-ui"):
          assert pod.succeed("stat -c %a /var/lib/librepod/setup-code").strip() == "600"
          pod.wait_until_succeeds("k3s kubectl -n marketplace-ui get secret librepod-setup-code", timeout=300)
          got = pod.succeed("k3s kubectl -n marketplace-ui get secret librepod-setup-code"
                            " -o jsonpath='{.data.code}' | base64 -d").strip()
          assert got == code.replace("-", ""), (got, code)
          # and for a device without its sticker, the journal shows it with its link and a QR code
          journal = pod.succeed("journalctl -u librepod-setup-code -o cat")
          assert f"http://pod-image.local/#code={code}" in journal and "█" in journal, journal

      with subtest("a changed password, the host key and machine-id survive a reboot"):
          pod.succeed("echo librepod:new-pw | chpasswd")  # what onboarding will do
          ids = "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub; cat /etc/machine-id"
          before = pod.succeed(ids)
          reboot_and_wait()
          assert pod.succeed(ids) == before
          assert pod.succeed("hostname").strip() == "pod-image"
          check_drives()
          pod.wait_for_unit("sshd.service")
          pod.succeed(ssh.format(pw="new-pw", opts="-i /root/key"))
          pod.fail(ssh.format(pw="librepod", opts="-i /root/key"))

      with subtest("a missing data disk doesn't stop boot; NFS stays off"):
          pod.shutdown()
          os.environ["DATA_DISK"] = disk()  # blank: no partition with our UUID
          pod.start(allow_reboot=True)
          pod.wait_for_unit("multi-user.target")
          pod.wait_for_unit("sshd.service")
          # past the device timeout (~300 s here): the bind must not fall back to root's /mnt/k3s
          pod.wait_until_fails("systemctl list-jobs --no-legend | grep -E 'k3s.mount|nfs-server'", timeout=600)
          pod.fail("findmnt /mnt/k3s")
          pod.fail("findmnt /exports/k3s")
          pod.fail("systemctl is-active nfs-server.service")

      # ---- updates, through the real units ------------------------------------
      def version():
          return pod.succeed(". /etc/os-release; echo $IMAGE_VERSION").strip()

      def status():
          return json.loads(pod.succeed("librepod-update status"))

      def wait_status(cond, timeout=900):  # cond: jq, on the updater's status
          pod.wait_until_succeeds(f"librepod-update status | jq -e '{cond}'", timeout=timeout)
          return status()

      def wait_published(cond):  # the bridge's copy in the ConfigMap, within 2 min
          pod.wait_until_succeeds("k3s kubectl -n librepod-os get configmap librepod-os-update -o json"
                                  f" | jq -e '.data[\"status.json\"] | fromjson | {cond}'", timeout=120)

      def answer(key, value):  # what the Marketplace writes
          patch = json.dumps({"data": {key: json.dumps(value)}})
          pod.wait_until_succeeds("k3s kubectl -n librepod-os patch configmap librepod-os-update"
                                  f" --type merge -p '{patch}'", timeout=300)

      def installed():  # versions in the slots, a downloaded one too
          return json.loads(pod.succeed("systemd-sysupdate --offline --json=short list"))["all"]

      def window_zone():  # Etc/GMT-3 is UTC+3: the zone where the VM's clock reads 03:xx
          o = 3 - int(pod.succeed("date -u +%H"))
          if o < -12:
              o += 24
          return f"Etc/GMT{-o:+d}"

      def local_hour(zone):
          return int(pod.succeed(f"TZ={zone} date +%H"))

      with subtest("stable offers 0.5.1: downloaded and installed with k3s stopped, booted, blessed"):
          serve("stable", "${repo releases."0.5.1"}")
          pod.succeed("systemctl stop k3s")
          s = json.loads(pod.succeed("librepod-update check"))
          assert s["available"] == "0.5.1" and s["downloaded"], s
          n = boots() + 1
          pod.succeed("librepod-update install now")
          up_after(n)
          assert version() == "0.5.1"
          wait_ready()
          wait_status('.state == "done"')
          assert pod.succeed("/run/current-system/systemd/lib/systemd/systemd-bless-boot status").strip() == "good"
          pod.fail("test -e /var/lib/librepod/updates/k3s-db")

      with subtest("automatic in the night window, set through the ConfigMap: 0.5.2 fails, 0.5.1 is back with its k3s data"):
          pod.succeed("k3s kubectl create configmap made-by-0-5-1")
          serve("stable", "${repo releases."0.5.2"}")
          pod.succeed("librepod-update check")  # stands in for the 6-hourly check
          zone = window_zone()
          n = boots() + 3  # the install, then 0.5.2's two tries
          answer("settings.json", {"rev": 1, "channel": "stable", "auto": True, "timezone": zone})
          try:
              wait_status(f'.settings.auto and .settings.timezone == "{zone}"', timeout=300)
              # the timer's next run, without waiting up to 20 min for it
              pod.execute("systemctl start --no-block librepod-update.service", check_return=False, timeout=30)
          except (BrokenPipeError, ValueError):
              pass  # the tick that `auto on` started saw the window first, and rebooted into the install
          up_after(n, timeout=1800)
          assert version() == "0.5.1"
          s = wait_status('.state == "rolled-back"')
          assert s["failedVersions"] == ["0.5.2"], s
          assert "0.5.2" not in installed(), installed()  # vacuumed, so a retry downloads it again
          wait_ready()
          wait_published('.state == "rolled-back"')
          # k3s's data from before 0.5.2: what it made is gone
          pod.fail("k3s kubectl get configmap made-by-0-5-2")
          pod.succeed("k3s kubectl get configmap made-by-0-5-1")

      with subtest("not again automatically; the owner's install now retries it"):
          assert 2 <= local_hour(zone) < 5, local_hour(zone)  # still the night window, automatic on
          pod.succeed("systemctl start librepod-update.service")
          pod.fail("test -e /var/lib/librepod/updates/record.json")
          s = status()
          assert s["state"] == "rolled-back" and not s["downloaded"], s
          n = boots() + 3  # downloaded again, installed, 0.5.2's two tries
          answer("install.json", {"id": 1, "when": "now"})
          up_after(n, timeout=1800)
          assert version() == "0.5.1"
          s = wait_status('.state == "rolled-back"')
          assert s["failedVersions"] == ["0.5.2"], s
          assert "0.5.2" not in installed(), installed()

      with subtest("beta offers 0.5.3; stable doesn't, with beta's download in the slot"):
          pod.succeed("librepod-update auto off")
          pod.succeed("librepod-update channel beta")
          wait_status('.settings.channel == "beta" and .available == "0.5.3" and .downloaded')
          pod.succeed("librepod-update channel stable")
          # 0.5.2 failed here, so nothing downloads and 0.5.3 stays until the next download's vacuum
          wait_status('.settings.channel == "stable" and .available == "0.5.2" and (.downloaded | not)')
          assert "0.5.3" in installed(), installed()

      with subtest("a power cut after the snapshot: 0.5.1 again, interrupted, not failed; then it installs"):
          pod.succeed("librepod-update channel beta")
          wait_status('.available == "0.5.3" and .downloaded')
          # the download left from before went first, never installed
          pod.succeed("journalctl -b -u librepod-update.service -o cat | grep -F 'Removing old pending'")
          pod.succeed("touch /run/librepod-test-hold")
          pod.succeed("librepod-update install now")
          pod.wait_for_file("/run/librepod-test-hold.held", timeout=600)
          pod.crash()
          pod.start(allow_reboot=True)
          pod.wait_for_unit("multi-user.target")
          assert version() == "0.5.1"
          s = wait_status('.state == "failed"', timeout=300)
          assert "interrupted" in s["detail"] and "0.5.3" not in s["failedVersions"], s
          # why fallback decides by phase, not this: sysupdate 260 counts the download as installed
          pod.succeed("systemd-sysupdate pending")
          wait_ready()
          n = boots() + 1
          pod.succeed("librepod-update install now")
          up_after(n)
          assert version() == "0.5.3"
          wait_status('.state == "done"')

      used = os.stat("${m.system.build.image}/${m.image.baseName}.store.raw").st_blocks * 512
      print(f"image-e2e numbers: store slot {used / 2**20:.0f} MiB used of ${m.librepod.image.slotSize}")
      print("image-e2e: all scenarios passed")
    '';
}
