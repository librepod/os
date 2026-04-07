# GoBackup package - fetch pre-built binary from GitHub releases
#
{
  lib,
  stdenv,
  fetchurl,
  ...
}:

stdenv.mkDerivation {
  pname = "gobackup";
  version = "3.0.0";

  src = fetchurl {
    url = "https://github.com/gobackup/gobackup/releases/download/v3.0.0/gobackup-linux-amd64.tar.gz";
    # TODO: Replace with actual sha256 from nix-prefetch-url
    hash = "sha256-sOvYj4lzFBxh/atCIXJTH+JIVT6UMb/4FK5sVsWSzHU=";
  };

  sourceRoot = ".";

  installPhase = ''
    install -Dm755 gobackup $out/bin/gobackup
  '';

  meta = with lib; {
    description = "CLI tool for backup your databases, files to cloud storages";
    homepage = "https://github.com/gobackup/gobackup";
    license = licenses.mit;
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
  };
}
