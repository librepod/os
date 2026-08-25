{ lib, ... }:
{
  name = "flux";
  repo = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance";
  version = "0.58.0";
  # To update the hash:
  #   helm pull oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance --version 0.58.0
  #   nix hash file --sri flux-instance-0.58.0.tgz
  hash = "sha256-CIRABpwUJWFxEsBUcLwUmshvbSaFrpoC4pmYghnQ+4A=";
  targetNamespace = "flux-system";
  createNamespace = true;
  extraDeploy = [
    ./cosign-pub-secret.yaml
  ];
  # See default values here: https://fluxoperator.dev/docs/charts/flux-instance/
  # mkDefault allows device configs to override the entire values attrset.
  # Needed because types.attrs in nixpkgs k3s autoDeployCharts uses shallow merge (//).
  values = lib.mkDefault {
    instance = {
      cluster.size = "small";
      sync = {
        interval = "12h";
        kind = "OCIRepository";
        name = "librepod-bootstrap";
        path = "./clusters/librepod";
        ref = "v0.1.0";
        url = "oci://ghcr.io/librepod/marketplace/bootstrap";
      };
      kustomize = {
        patches = [
          {
            patch = ''
              - op: add
                path: /spec/verify
                value:
                  provider: cosign
                  secretRef:
                    name: cosign-pub
            '';
            target.kind = "OCIRepository";
            target.name = "librepod-bootstrap";
          }
        ];
      };
    };
  };
}
