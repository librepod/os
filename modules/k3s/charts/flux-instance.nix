{ ... }:
{
  name = "flux";
  repo = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance";
  version = "0.43.0";
  hash = "sha256-ytO60lUy9Eurxi2H9jlnmFJH5XAlbZx7BvZfJlClyPo=";
  targetNamespace = "flux-system";
  createNamespace = true;
  extraDeploy = [
    ./cosign-pub-secret.yaml
  ];
  # See default values here: https://fluxoperator.dev/docs/charts/flux-instance/
  values = {
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
      # -- Kustomize patches https://fluxoperator.dev/docs/crd/fluxinstance/#kustomize-patches
      # @schema item: string; uniqueItems: true; itemEnum:
      # [source-controller,kustomize-controller,helm-controller,notification-controller,image-reflector-controller,image-automation-controller,source-watcher]
      # components = [
      #   "helm-controller"
      #   "kustomize-controller"
      #   "notification-controller"
      #   "source-controller"
      #   "source-watcher"
      # ];
    };
  };
}
