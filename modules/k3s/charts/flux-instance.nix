{ ... }:
{
  name = "flux";
  repo = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance";
  version = "0.43.0";
  hash = "sha256-ytO60lUy9Eurxi2H9jlnmFJH5XAlbZx7BvZfJlClyPo=";
  targetNamespace = "flux-system";
  createNamespace = true;
  # Use inline Nix instead of file path to avoid fromYaml call which requires yq-go (Linux-only)
  # This fixes cross-platform evaluation on Darwin
  extraDeploy = [
    {
      apiVersion = "v1";
      kind = "Secret";
      metadata = {
        name = "cosign-pub";
        namespace = "flux-system";
      };
      type = "Opaque";
      stringData = {
        "cosign.pub" = ''
          -----BEGIN PUBLIC KEY-----
          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEkAgu26dkUj9UcO0zoEpli4CD8B0p
          k+YPa1RlIz625eldAwx56argKN0jqdy82pfGor3qZBA++QWwlUrHH9VK7A==
          -----END PUBLIC KEY-----
        '';
      };
    }
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
