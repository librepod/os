{ lib, pkgs, ... }:

{
  environment.systemPackages = [ pkgs.casdoor-cli ];

  nixpkgs.overlays = [
    (final: _prev: {
      casdoor-cli = final.buildGoModule rec {
        pname = "casdoor-cli";
        version = "1.0.0";

        src = final.fetchFromGitHub {
          owner = "casdoor";
          repo = "casdoor-cli";
          rev = "50f997734e28f110a87a1a91047dd051969bdd2b";
          hash = "sha256-2CILtcEJoT0fxHNTMaaOXWRZgI/kQImtO5wqso2soHY=";
        };

        # Project ships a vendor/ directory — no separate vendor hash needed.
        vendorHash = null;

        ldflags = [ "-s" "-w" "-X main.version=${version}" ];

        meta = with lib; {
          description = "Official command-line interface for Casdoor IAM / SSO platform";
          homepage = "https://github.com/casdoor/casdoor-cli";
          license = licenses.asl20;
          mainProgram = "casdoor-cli";
          platforms = platforms.linux ++ platforms.darwin;
        };
      };
    })
  ];
}
