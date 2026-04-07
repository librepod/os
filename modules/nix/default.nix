{ lib, pkgs, ... }:

{
  nix = {
    settings.auto-optimise-store = true;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    # Free up to 1GiB whenever there is less than 100MiB left.
    extraOptions = ''
        min-free = ${toString (100 * 1024 * 1024)}
        max-free = ${toString (1024 * 1024 * 1024)}
      # optional, useful when the builder has a faster internet connection than yours
      # builders-use-substitutes = true
    '';
    #
    # distributedBuilds = true;
    # buildMachines = [{
    #   hostName = "192.168.2.122";
    #   sshUser = "alex";
    #   sshKey = "/root/.ssh/id_ed25519";
    #   protocol = "ssh-ng";
    #   # if the builder supports building for multiple architectures,
    #   # replace the previous line by, e.g.,
    #   systems = [ "x86_64-linux" ];
    #   maxJobs = 1;
    #   speedFactor = 2;
    #   supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    #   mandatoryFeatures = [ ];
    # }];
  };

  nixpkgs.config = {
    allowUnfree = false;
  };
}
