#!/usr/bin/env bash
# LibrePod image installer — run from a live USB booted through UEFI. Writes
# the appliance image to the OS disk, grows root, writes the device's name and
# data disk to it, sets up the data disk and an optional backup disk, and
# registers the boot entry.
# Design: docs/superpowers/specs/2026-11-11-ab-image-updates-design.md (phase 3)
set -euo pipefail

usage() {
  echo "usage: librepod-install --image FILE --name NAME [--disk /dev/nvme0n1]"
  echo "                        [--data-disk /dev/sda] [--keep-data | --wipe-data]"
  echo "                        [--backup-disk /dev/sdb] [--keep-backup | --wipe-backup]"
  echo "                        [--setup-code XXXX-XXXX-XXXX]  (keep a printed sticker's)"
  echo "                        [--ssh-key FILE]  (public keys for SSH as librepod, the only"
  echo "                                           SSH login; a reinstall needs it again)"
  exit 1
}
die() { echo "$*" >&2; exit 1; }

IMAGE="" NAME="" DISK="/dev/nvme0n1" DATA_DISK="/dev/sda" DATA="" SETUP_CODE="" SSH_KEY=""
BACKUP_DISK="" BACKUP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) [ $# -ge 2 ] || usage; IMAGE="$2"; shift 2;;
    --name) [ $# -ge 2 ] || usage; NAME="$2"; shift 2;;
    --disk) [ $# -ge 2 ] || usage; DISK="$2"; shift 2;;
    --data-disk) [ $# -ge 2 ] || usage; DATA_DISK="$2"; shift 2;;
    # Empty would mean "no backup disk": an unset variable must not drop it.
    --backup-disk) [ $# -ge 2 ] && [ -n "$2" ] || usage; BACKUP_DISK="$2"; shift 2;;
    # Empty would mean "mint one": an unset variable must not orphan a sticker.
    --setup-code) [ $# -ge 2 ] && [ -n "$2" ] || usage; SETUP_CODE="$2"; shift 2;;
    --ssh-key) [ $# -ge 2 ] && [ -n "$2" ] || usage; SSH_KEY="$2"; shift 2;;
    --keep-data|--wipe-data) [ -z "$DATA" ] || die "pass --keep-data or --wipe-data, not both"; DATA="${1#--}"; shift;;
    --keep-backup|--wipe-backup) [ -z "$BACKUP" ] || die "pass --keep-backup or --wipe-backup, not both"; BACKUP="${1#--}"; shift;;
    *) usage;;
  esac
done
[ -n "$IMAGE" ] && [ -n "$NAME" ] || usage
[ -z "$BACKUP" ] || [ -n "$BACKUP_DISK" ] || die "--$BACKUP needs --backup-disk"

# Every check before the first write.
# Hostname and k8s node name.
[[ "$NAME" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid name: $NAME (a-z, 0-9, -)"
# The claim code for marketplace-ui's setup wizard (the sticker's): kept from
# --setup-code or minted here. Alphabet and length as in its setup-code.ts.
ALPHABET=ABCDEFGHJKMNPQRSTUVWXYZ23456789
if [ -z "$SETUP_CODE" ]; then
  # No reader closing early: `tr </dev/urandom | head` dies of SIGPIPE under pipefail.
  SETUP_CODE="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$ALPHABET")"
  SETUP_CODE="${SETUP_CODE:0:12}"
fi
SETUP_CODE="${SETUP_CODE^^}" SETUP_CODE="${SETUP_CODE//[- ]/}"
[[ "$SETUP_CODE" =~ ^[$ALPHABET]{12}$ ]] || die "invalid setup code: 12 of $ALPHABET, dashes optional"
[ -f "$IMAGE" ] || die "$IMAGE: no such file"
# A whole disk image has a GPT header in its second sector and its last one:
# a store slot or a truncated download doesn't. zstd -f passes .raw through.
img() { zstd -dcf -- "$IMAGE" 2>/dev/null || true; } # || true: SIGPIPE from head
FIRST=$(img | head -c 520 | tail -c 8 | tr -d '\0')
LAST=$(img | tail -c 512 | head -c 8 | tr -d '\0')
[ "$FIRST $LAST" = "EFI PART EFI PART" ] || die "$IMAGE is not a whole disk image (.raw or .raw.zst)"
# Line by line: ssh-keygen -lf passes a file with one good key, a private key,
# and known_hosts lines. The key data (base64, always AAAA…) must be the second
# field, after the key type: sshd reads anything before the type as options and
# refuses a known_hosts host field there, so options are not accepted either.
if [ -n "$SSH_KEY" ]; then
  [ -f "$SSH_KEY" ] && [ -r "$SSH_KEY" ] || die "--ssh-key $SSH_KEY: no such file"
  n=0 keys=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r _ blob _ <<< "$line"
    { [[ "$blob" == AAAA* ]] && ssh-keygen -lf - <<< "$line" >/dev/null 2>&1; } \
      || die "--ssh-key $SSH_KEY: line $n is not a public key (key type first, no options)"
    keys=$((keys + 1))
  done < "$SSH_KEY"
  [ "$keys" -gt 0 ] || die "--ssh-key $SSH_KEY: no public key in it"
fi
for d in "$DISK" "$DATA_DISK" ${BACKUP_DISK:+"$BACKUP_DISK"}; do
  [ -b "$d" ] || die "$d is not a block device"
  [ "$(lsblk -dnro TYPE "$d")" = disk ] || die "$d is not a whole disk"
  [ "$(lsblk -dnro TRAN "$d")" != usb ] && [ "$(lsblk -dnro RM "$d")" = 0 ] \
    || die "$d is a USB or removable drive"
  [ -z "$(lsblk -nro MOUNTPOINTS "$d" | tr -d '[:space:]')" ] || die "$d has a mounted partition"
  [ -z "$(lsblk -nro TYPE "$d" | grep -vxE 'disk|part' || true)" ] \
    || die "$d is in use (LVM, RAID or encryption): stop it first, e.g. vgchange -an"
done
[ -z "$(realpath "$DISK" "$DATA_DISK" ${BACKUP_DISK:+"$BACKUP_DISK"} | sort | uniq -d)" ] \
  || die "--disk, --data-disk and --backup-disk must be different disks"
[ -d /sys/firmware/efi/efivars ] || die "not booted through UEFI: the boot entry can't be written"
# A disk may hold only its own role's LibrePod partition, and formats it only
# when told: a swapped or mistyped disk is refused before its data or backups
# are lost. Prints the partition UUID to record: the kept one's, or a new one.
claim() { # disk, role (os, data or backup), --keep-/--wipe- choice
  local role n uuid=""
  for role in data backup; do
    n=$(lsblk -nro PARTLABEL "$1" | grep -cx "librepod-$role" || true)
    if [ "$role" != "$2" ]; then
      [ "$n" = 0 ] || die "$1 holds LibrePod $role, so it can't be the $2 disk: check the disk flags (to reuse it, wipe it first)"
    elif [ "$3" = "keep-$role" ]; then
      [ "$n" = 1 ] || die "--keep-$role: $1 has $n librepod-$role partitions, not 1"
      uuid=$(lsblk -nro PARTLABEL,PARTUUID "$1" | awk -v l="librepod-$role" '$1 == l { print $2 }')
      [ -n "$uuid" ] || die "--keep-$role: no PARTUUID for the librepod-$role partition on $1"
    elif [ -z "$3" ]; then
      [ "$n" = 0 ] || die "$1 holds LibrePod $role: pass --keep-$role or --wipe-$role"
    fi
  done
  [ "$2" = os ] || echo "${uuid:-$(cat /proc/sys/kernel/random/uuid)}"
}
claim "$DISK" os ""
# die exits claim's subshell; the failed assignment then stops the script.
DATA_UUID=$(claim "$DATA_DISK" data "$DATA")
BACKUP_UUID=""
if [ -n "$BACKUP_DISK" ]; then
  BACKUP_UUID=$(claim "$BACKUP_DISK" backup "$BACKUP")
else
  # Left out, a backup disk the device has would drop off root unnoticed.
  HELD=$(lsblk -nrpo PARTLABEL,PKNAME | awk '$1 == "librepod-backup" { printf " %s", $2 }')
  [ -z "$HELD" ] || die "LibrePod backups on$HELD: pass --backup-disk with --keep-backup or --wipe-backup (to drop the disk, wipe it first)"
fi

echo "==> writing $IMAGE to $DISK"
wipefs -aq "$DISK"
zstd -dcf -- "$IMAGE" | dd of="$DISK" bs=4M conv=fsync status=none
# The backup GPT moves to the end of the disk; fresh GUIDs, so a copy of the
# image on another drive is never taken for this one.
sgdisk -e -G "$DISK" >/dev/null
partx -u "$DISK"
udevadm settle

part() { # "<path> <number>" of the one partition on DISK labelled $1
  lsblk -nrpo PATH,PARTLABEL,PARTN "$DISK" \
    | awk -v l="$1" '$2 == l { n++; p = $1 " " $3 } END { if (n == 1) print p }'
}
read -r ROOT ROOT_N <<< "$(part librepod-root)"
read -r _ ESP_N <<< "$(part librepod-esp)"
[ -n "$ROOT_N" ] && [ -n "$ESP_N" ] || die "$DISK: no single librepod-root and librepod-esp after writing"

echo "==> growing root to the end of $DISK"
echo ', +' | sfdisk -q -N "$ROOT_N" --no-reread "$DISK"
partx -u "$DISK"
udevadm settle
e2fsck -fp "$ROOT" || [ $? -le 1 ] # 1: errors corrected
resize2fs "$ROOT"

provision() { # disk, role (data or backup), --keep-/--wipe- choice, partition UUID
  if [ "$3" = "keep-$2" ]; then
    echo "==> keeping the $2 on $1"
    return
  fi
  echo "==> formatting $1 as the $2 disk"
  wipefs -aq "$1"
  sgdisk -Z "$1" >/dev/null
  sgdisk -n1:0:0 -t1:8300 -u1:"$4" "$1" >/dev/null
  partx -u "$1"
  udevadm settle
  # -F: always format; stale signatures must not skip it
  mkfs.ext4 -qF "$(lsblk -nrpo PATH,PARTN "$1" | awk '$2 == 1 { print $1 }')"
  # Labelled last: an interrupted format leaves nothing to keep.
  sgdisk -c1:"librepod-$2" "$1" >/dev/null
}
provision "$DATA_DISK" data "$DATA" "$DATA_UUID"
[ -z "$BACKUP_DISK" ] || provision "$BACKUP_DISK" backup "$BACKUP" "$BACKUP_UUID"

echo "==> writing $NAME${SSH_KEY:+, its SSH key}, its data${BACKUP_DISK:+ and backup} disk(s) and setup code to root"
MNT=$(mktemp -d)
mount "$ROOT" "$MNT"
umask 022 # sshd's StrictModes refuses keys under a group-writable /etc or /etc/ssh
mkdir -p "$MNT/etc/librepod"
echo "$NAME" > "$MNT/etc/hostname"
echo "$DATA_UUID" > "$MNT/etc/librepod/data-partuuid"
[ -z "$BACKUP_DISK" ] || echo "$BACKUP_UUID" > "$MNT/etc/librepod/backup-partuuid"
install -d -m 700 "$MNT/var/lib/librepod"
(umask 077 && echo "$SETUP_CODE" > "$MNT/var/lib/librepod/setup-code")
if [ -n "$SSH_KEY" ]; then
  # Root's, 0644 in a 0755 directory: sshd's StrictModes. No CRs from Windows.
  install -d -m 755 "$MNT/etc/ssh/authorized_keys.d"
  tr -d '\r' < "$SSH_KEY" > "$MNT/etc/ssh/authorized_keys.d/librepod"
fi
umount "$MNT"

echo "==> boot entry LibrePod, first in BootOrder"
efibootmgr -q --create --disk "$DISK" --part "$ESP_N" --label LibrePod --loader '\EFI\BOOT\BOOTX64.EFI'

if [ -z "$SSH_KEY" ]; then
  echo "==> no SSH key given: SSH stays off until a key is added in the Marketplace"
fi

echo "==> installed $NAME: os $DISK, data $DATA_DISK${BACKUP_DISK:+, backup $BACKUP_DISK}. Reboot when ready."
echo "==> then open http://$NAME.local, setup code ${SETUP_CODE:0:4}-${SETUP_CODE:4:4}-${SETUP_CODE:8:4}"
