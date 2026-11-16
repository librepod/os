# The OS agent: serves the Device API (os.librepod.org/v1alpha1) on image
# devices. Its go test run is the package's check.
{ buildGo125Module }:
buildGo125Module {
  pname = "librepod-os-agent";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-0kw9Gp7p2/kHrA2SvpAV+rA3IgynVbP6rLwF2Xi7nY4=";
  env.CGO_ENABLED = 0;
  ldflags = [
    "-s"
    "-w"
  ];
  meta.mainProgram = "librepod-os-agent";
}
