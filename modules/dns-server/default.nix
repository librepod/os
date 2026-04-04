{ config, lib, pkgs, ... }:

{
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];

  systemd.services.unbound.preStart =
    let
      ip = "${pkgs.iproute2}/bin/ip";
      awk = "${pkgs.gawk}/bin/awk";
    in
    ''
      set -euo pipefail

      # Pick the primary IPv4 used for outbound traffic (works well for multi-NIC too).
      host_ip="$(${ip} -4 route get 1.1.1.1 2>/dev/null | ${awk} '{for (i=1; i<=NF; i++) if ($i=="src") { print $(i+1); exit }}' || true)"

      # Fallbacks
      if [ -z "$host_ip" ] && command -v hostname >/dev/null 2>&1; then
        host_ip="$(hostname -I 2>/dev/null | ${awk} '{print $1}' || true)"
      fi
      if [ -z "$host_ip" ]; then
        host_ip="127.0.0.1"
      fi

      install -d -m 0755 /var/lib/unbound
      cat > /var/lib/unbound/librepod-local.conf <<EOF
# Answer any name inside libre.pod (e.g. foo.libre.pod) with the same A record.
local-zone: "libre.pod." redirect
local-data: "libre.pod. 3600 IN A $host_ip"

# Development domain - same behavior, separate namespace to avoid collisions.
local-zone: "librepod.dev." redirect
local-data: "librepod.dev. 3600 IN A $host_ip"

# mDNS hostname for cluster-internal access (e.g., Flux gitolite SSH).
local-zone: "librepod.local." redirect
local-data: "librepod.local. 3600 IN A $host_ip"
EOF
      chmod 0644 /var/lib/unbound/librepod-local.conf
    '';

  services.unbound = {
    enable = true;
    settings = {
      include = [ "/var/lib/unbound/librepod-local.conf" ];
      server = {
        # When only using Unbound as DNS, make sure to replace 127.0.0.1 with your ip address
        # When using Unbound in combination with pi-hole or Adguard, leave 127.0.0.1, and point Adguard to 127.0.0.1:PORT
        # Bind on loopback (for local resolvers) and all interfaces (for LAN clients).
        interface = [ "127.0.0.1" "0.0.0.0" "::1" "::0" ];
        port = 53;
        # access-control = [ "0.0.0.0/0 allow" ];
        access-control = [
          "127.0.0.0/8 allow"
          "::1 allow"
          # Safe defaults for typical homelab networks; tighten/expand as needed.
          "10.0.0.0/8 allow"
          "172.16.0.0/12 allow"
          "192.168.0.0/16 allow"
        ];
        # Based on recommended settings in https://docs.pi-hole.net/guides/dns/unbound/#configure-unbound
        harden-glue = true;
        harden-dnssec-stripped = true;
        use-caps-for-id = false;
        prefetch = true;
        edns-buffer-size = 1232;

        # Custom settings
        hide-identity = true;
        hide-version = true;
      };
      # forward-zone = [
      #   # Example config with quad9
      #   {
      #     name = ".";
      #     forward-addr = [
      #       "9.9.9.9#dns.quad9.net"
      #       "149.112.112.112#dns.quad9.net"
      #     ];
      #     forward-tls-upstream = true;  # Protected DNS
      #   }
      # ];
    };
  };
}
