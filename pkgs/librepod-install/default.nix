{
  writeShellApplication,
  coreutils,
  util-linux,
  gptfdisk,
  zstd,
  e2fsprogs,
  efibootmgr,
  gnugrep,
  gawk,
  openssh,
  systemd,
}:

writeShellApplication {
  name = "librepod-install";
  runtimeInputs = [
    coreutils
    util-linux
    gptfdisk
    zstd
    e2fsprogs
    efibootmgr
    gnugrep
    gawk
    openssh # ssh-keygen
    systemd # udevadm
  ];
  text = builtins.readFile ./install.sh;
}
