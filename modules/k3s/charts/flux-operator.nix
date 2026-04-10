{ ... }:
{
  name = "flux-operator";
  repo = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator";
  version = "0.43.0";
  hash = "sha256-Sv9BO/P/18V1Lu0mCbPpvNOxT7bUFSLNNKR2OEK/7bs=";
  targetNamespace = "flux-system";
  createNamespace = true;
  values = {
    installCRDs = true;
    # Reduce CPU limit from default 2000m to 1000m for resource-constrained environments
    resources.limits.cpu = "1000m";
  };
}
