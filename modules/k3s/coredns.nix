{ config, pkgs, lib, k3s-nixpkgs ? null, ... }:
let
  # Import k3s from a specific nixpkgs commit for version control
  # This allows you to pin k3s independently of your main nixpkgs channel
  customK3s = if k3s-nixpkgs != null then
    (import k3s-nixpkgs {
      inherit (pkgs.stdenv) system;
      config.allowUnfree = false;
    }).k3s
  else
    pkgs.k3s;
in
{
  # Make CoreDNS resolve libre.pod, librepod.dev, and librepod.local inside the
  # cluster by forwarding those zones to the host's Unbound instance over TCP.
  #
  # We do this at runtime (systemd oneshot) so it works with DHCP hosts and doesn't
  # require hardcoding the node IP into a manifest.
  config = lib.mkIf config.services.k3s.enable {
    systemd.services.coredns-librepod-zone = {
    description = "Configure CoreDNS stub zones for librepod domains";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s.service" "network-online.target" ];
    wants = [ "k3s.service" "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script =
      let
        ip = "${pkgs.iproute2}/bin/ip";
        awk = "${pkgs.gawk}/bin/awk";
        k3s = "${customK3s}/bin/k3s";
      in
      ''
        set -euo pipefail

        # Wait briefly for the apiserver to be ready.
        for _ in $(seq 1 60); do
          if ${k3s} kubectl get --raw=/readyz >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done

        host_ip="$(${ip} -4 route get 1.1.1.1 2>/dev/null | ${awk} '{for (i=1; i<=NF; i++) if ($i=="src") { print $(i+1); exit }}' || true)"
        if [ -z "$host_ip" ]; then
          echo "Could not determine host IPv4; skipping CoreDNS librepod zones" >&2
          exit 0
        fi

        cat <<EOF | ${k3s} kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  libre-pod.server: |
    libre.pod:53 {
        errors
        cache 30
        forward . $host_ip {
            force_tcp
        }
    }
    librepod.dev:53 {
        errors
        cache 30
        forward . $host_ip {
            force_tcp
        }
    }
    librepod.local:53 {
        errors
        cache 30
        forward . $host_ip {
            force_tcp
        }
    }
EOF

        # Ensure CoreDNS notices changes if it doesn't hot-reload.
        ${k3s} kubectl -n kube-system rollout restart deployment coredns >/dev/null 2>&1 || true
      '';
  };
  };
}
