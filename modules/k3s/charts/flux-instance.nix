{ lib, ... }:
{
  name = "flux";
  repo = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance";
  version = "0.48.0";
  hash = "sha256-YASZtDWzmdmc1PwbNEj/1rE+csx/If9RDZosD+gj90o=";
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
      distribution = {
        version = "2.8.*";
      };
      cluster.size = "small";
      sync = {
        interval = "12h";
        kind = "OCIRepository";
        name = "librepod-bootstrap";
        path = "./clusters/librepod";
        ref = "latest"; # TODO: set to a fixed stable version of librepod-bootstrap artifact
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
