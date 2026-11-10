# { lib, ... }:
# {
#   disko.devices = {
#     disk = {
#       main = {
#         device = "/dev/nvme0n1";
#         type = "disk";
#         content = {
#           type = "gpt";
#           partitions = {
#             ESP = {
#               type = "EF00";
#               size = "500M";
#               content = {
#                 type = "filesystem";
#                 format = "vfat";
#                 mountpoint = "/boot";
#               };
#             };
#             root = {
#               size = "100%";
#               content = {
#                 type = "filesystem";
#                 format = "ext4";
#                 mountpoint = "/";
#               };
#             };
#           };
#         };
#       };
#     };
#   };
# }
#
# Example to create a bios compatible gpt partition
#
# Appliance layout: TWO disks by product contract — OS (disk.main, everything
# the system is) + data (disk.data, everything the user ever keeps). PVs and
# app data live at /mnt/k3s: the nfs module bind-mounts it to /exports/k3s,
# which the marketplace's nfs-provisioner hands to PVCs. Both disks are
# wiped at install; the installer records the concrete devices in the
# device-owned install.nix (--disk / --data-disk).
{ lib, ... }:
{
  disko.devices = {
    disk.main = {
      device = lib.mkDefault "/dev/nvme0n1";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            name = "boot";
            size = "1M";
            type = "EF02";
          };
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            name = "root";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "pool";
            };
          };
        };
      };
    };
    disk.data = {
      device = lib.mkDefault "/dev/sda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          data = {
            name = "data";
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/mnt/k3s";
              mountOptions = [ "defaults" ];
            };
          };
        };
      };
    };
    lvm_vg = {
      pool = {
        type = "lvm_vg";
        lvs = {
          root = {
            size = "100%FREE";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [
                "defaults"
              ];
            };
          };
        };
      };
    };
  };
}
