{ ... }:
{
  name = "flux-operator";
  repo = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator";
  version = "0.58.0";
  # To update the hash:
  #   helm pull oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --version 0.58.0
  #   nix hash file --sri flux-operator-0.58.0.tgz
  hash = "sha256-/SsHlwe3alfpugkwEZxfxsr+9Caf0/8WKzn4DLR64B0=";
  targetNamespace = "flux-system";
  createNamespace = true;
  values = {
    installCRDs = true;
    # Reduce CPU limit from default 2000m to 1000m for resource-constrained environments
    resources.limits.cpu = "1000m";
  };
}
