{ config, pkgs, machineConfig, ... }:
let
  createNewCerts = ''
    # Generate local certificate
    mkdir -p /exports/k3s/certs
    cd /exports/k3s/certs
    echo "Generating new ${machineConfig.domain} certificates..."
    mkcert -key-file ${machineConfig.domain}-key.pem -cert-file ${machineConfig.domain}-cert.pem ${machineConfig.domain} '*.${machineConfig.domain}'

    # Create Kubernetes TLS secret from newly created certs
    k3s kubectl delete secret ${machineConfig.domain}-tls \
      --ignore-not-found \
      -n kube-system
    k3s kubectl create secret tls ${machineConfig.domain}-tls \
      --key="${machineConfig.domain}-key.pem" \
      --cert="${machineConfig.domain}-cert.pem" \
      -n kube-system
  '';
in
{
  # This thing creates self signed certificates using mkcert for using with k3s Ingresses.
  systemd.services = {
    mkcert-create-certs = {
      description = "Generate selg-signed certificates using mkcert on startup";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      requires = [ ];
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        #!${pkgs.runtimeShell} -eu

        echo "Generating locally-trusted development certificates using mkcert..."

        export HOME=/root
        export PATH=${pkgs.lib.makeBinPath [ config.nix.package pkgs.mkcert pkgs.systemd pkgs.k3s]}:$PATH
        export NIX_PATH=nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix:/nix/var/nix/profiles/per-user/root/channels

        rootca=$(mkcert -CAROOT)/rootCA.pem

        if [ -f "$rootca" ]; then
          echo "rootCA.pem already exists. Exiting..."
          exit
        else
          # Create a new local CA
          mkcert -install
          mkdir -p /exports/k3s/certs
          cp $rootca /exports/k3s/certs
          # Create certificates issued by our just created CA
          ${createNewCerts}
        fi
      '';
    };

    mkcert-update-certs = {
      description = "Generates new certs whenever called";
      serviceConfig = {
        Type = "oneshot";
        User= "root";
      };
      script = ''
        #!${pkgs.runtimeShell} -eu

        export HOME=/root
        export PATH=${pkgs.lib.makeBinPath [ config.nix.package pkgs.mkcert pkgs.systemd pkgs.k3s]}:$PATH
        export NIX_PATH=nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix:/nix/var/nix/profiles/per-user/root/channels

        ${createNewCerts}
      '';
    };
  };

  systemd.timers."mkcert-update-certs" = {
    description = "Generates new certs once in a month";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
      Unit = "mkcert-update-certs.service";
    };
  };
}
