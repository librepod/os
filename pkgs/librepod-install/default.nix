{
  writeShellApplication,
  curl,
  jq,
  disko,
  nixos-install-tools,
}:

writeShellApplication {
  name = "librepod-install";
  runtimeInputs = [
    curl
    jq
    disko
    nixos-install-tools
  ];
  text = builtins.readFile ./install.sh;
}
