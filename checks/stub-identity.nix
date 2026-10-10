# Minimal identity for the mk-device eval check. Real identity.nix files add
# users' hashed passwords, ssh keys, frpc config — never hardware.
# Note: no module imports here — mkDevice already provides the base stack
# (importing librepod.nixosModules from a check duplicates option
# declarations across flake-source copies).
{ ... }:
{
  librepod.users = {
    root.hashedPassword = "$6$rounds=4096$stub$stubhash";
    librepod.hashedPassword = "$6$rounds=4096$stub$stubhash";
  };
}
