{ pkgs, ... }:
{
  environment.variables = {
    EDITOR = "nvim";
  };

  programs.zsh = {
    enable = true;
    syntaxHighlighting.enable = true;
    interactiveShellInit = ''
      source ${pkgs.grml-zsh-config}/etc/zsh/zshrc
    '';
    promptInit = ""; # otherwise it'll override the grml prompt
  };

  environment.systemPackages = with pkgs; [
    dig
    gawk
    git
    gnumake
    iptables
    jq
    kitty
    kubernetes-helm
    neovim
    nftables
    yazi
  ];

  # NTP time sync.
  services.timesyncd.enable = true;

  # Always specify a system state version that matches the starting version of
  # Nixpkgs for that machine and never change it afterwards. In other words, even if
  # you upgrade Nixpkgs later on you would keep the state version the same.
  # Nixpkgs uses the state version to migrate your NixOS system because in order to
  # migrate your system each migration needs to know where your system started from.
  system.stateVersion = "21.11";
}
