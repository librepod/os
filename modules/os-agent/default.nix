# The OS agent: serves the Device API (os.librepod.org/v1alpha1) on image
# devices. The Marketplace writes Device.spec, the agent applies each answer
# once and writes Device.status. Design:
# docs/superpowers/specs/2026-11-16-device-api-design.md, contract: docs/updates.md
{
  config,
  lib,
  pkgs,
  ...
}:
{
  systemd.tmpfiles.rules = [ "d /var/lib/librepod/agent 0700 root root -" ];

  # k3s applies it from its auto-deploy directory; the agent waits (by
  # exiting and being restarted) until the CRD is established.
  services.k3s.manifests.librepod-device-crd.source =
    ../../pkgs/librepod-os-agent/crd/os.librepod.org_devices.yaml;

  systemd.services.librepod-os-agent = {
    description = "LibrePod OS agent (Device API)";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s.service" ];
    unitConfig.StartLimitIntervalSec = 0;
    environment = {
      KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      TZDIR = "${pkgs.tzdata}/share/zoneinfo";
    };
    path = [
      config.systemd.package
      config.librepod.updates.cli
    ];
    serviceConfig = {
      ExecStart = lib.getExe (pkgs.callPackage ../../pkgs/librepod-os-agent { });
      Restart = "always";
      RestartSec = "10s";
    };
  };
}
