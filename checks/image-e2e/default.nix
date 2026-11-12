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
# Run locally (KVM): nix build .#image-e2e -L
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
          "-drive if=none,id=os,format=qcow2,file=$OS_DISK"
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

  nodes.pod =
    { pkgs, ... }:
    {
      imports = self.lib.imageModules;
      system.image.version = "1";
      librepod.image = {
        updateUrl = "https://updates.invalid/";
        pubring = pkgs.writeText "empty.pgp" "";
        healthCheck = "${pkgs.coreutils}/bin/true";
      };

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
      imageZst = hostPkgs.runCommand "image-e2e.raw.zst" {
        nativeBuildInputs = [ hostPkgs.zstd ];
      } "zstd -T0 -q ${m.system.build.image}/${m.image.filePath} -o $out";
    in
    ''
      import os, subprocess, tempfile, time

      def boots():
          return pod.get_console_log().count("Linux version")

      def wait_boots(n, timeout=900):
          deadline = time.time() + timeout
          while boots() < n:
              if time.time() > deadline:
                  raise Exception(f"wanted {n} boots, saw {boots()}")
              time.sleep(5)

      def reconnect(timeout=300):
          deadline = time.time() + timeout
          time.sleep(10)
          while time.time() < deadline:
              try:
                  pod.connected = False
                  pod.succeed("true")
                  return
              except (BrokenPipeError, ValueError):
                  time.sleep(5)
          raise Exception("shell did not come back within timeout")

      def reboot_and_wait():
          n = boots() + 1
          try:
              pod.execute("systemctl reboot", check_return=False, timeout=30)
          except (BrokenPipeError, ValueError):
              pass
          wait_boots(n)
          reconnect()
          pod.wait_for_unit("multi-user.target")

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
      os.environ["OS_DISK"] = disk("${foreignDisk}", "10G")
      os.environ["DATA_DISK"] = disk("${foreignDisk}", "2G")  # a recycled disk
      os.environ["USB_DISK"] = disk()
      installer.start()
      installer.wait_for_unit("multi-user.target")

      def dev(serial):  # kernel path of the disk with this serial
          return installer.succeed(f"lsblk -dnpo PATH,SERIAL | awk '$2==\"{serial}\" {{print $1}}'").strip()
      os_, data = dev("os"), dev("data")
      inst = "librepod-install --image ${imageZst} --name pod-image --disk {disk} --data-disk {data} {flags}"

      with subtest("refusals: USB, mounted, a partition"):
          installer.fail(inst.format(disk=os_, data=dev("usb"), flags=""))
          installer.fail(inst.format(disk=dev("root"), data=data, flags=""))  # the installer's own
          installer.fail(inst.format(disk=os_ + "1", data=data, flags=""))
          installer.fail("efibootmgr | grep LibrePod")

      with subtest("install; the data disk is ours"):
          installer.succeed(inst.format(disk=os_, data=data, flags=""))  # recycled disk: no flag needed
          installer.succeed(f"mkdir -p /mnt && mount {data}p1 /mnt && touch /mnt/marker && umount /mnt")

      with subtest("existing data: refused without a flag, kept with --keep-data"):
          out = installer.fail(inst.format(disk=os_, data=data, flags="") + " 2>&1")
          assert "--keep-data" in out and "--wipe-data" in out, out
          installer.succeed(inst.format(disk=os_, data=data, flags="--keep-data"))
      installer.shutdown()

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

      with subtest("the k3s node is named after the device"):
          pod.wait_for_unit("k3s.service", timeout=600)
          pod.wait_until_succeeds(
              "k3s kubectl get node pod-image -o json"
              " | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'",
              timeout=600,
          )
          assert pod.succeed("k3s kubectl get nodes -o name").split() == ["node/pod-image"]

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
          pod.fail("findmnt /mnt/k3s")
          pod.fail("findmnt /exports/k3s")
          pod.fail("systemctl is-active nfs-server.service")

      used = os.stat("${m.system.build.image}/${m.image.baseName}.store.raw").st_blocks * 512
      print(f"image-e2e numbers: store slot {used / 2**20:.0f} MiB used of ${m.librepod.image.slotSize}")
    '';
}
