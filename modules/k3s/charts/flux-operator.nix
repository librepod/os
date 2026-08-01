{ ... }:
{
  name = "flux-operator";
  repo = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator";
  version = "0.57.0";
  hash = "sha256-NBmhU5grQV1c2lLAJAGDdjrb0GKcTLM/KhKytpKGG3Q=";
  targetNamespace = "flux-system";
  createNamespace = true;
  values = {
    installCRDs = true;
    # Reduce CPU limit from default 2000m to 1000m for resource-constrained environments
    resources.limits.cpu = "1000m";
  };
}
