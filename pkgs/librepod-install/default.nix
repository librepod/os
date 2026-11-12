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
    systemd # udevadm
  ];
  text = builtins.readFile ./install.sh;
}
