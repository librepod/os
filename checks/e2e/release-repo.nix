# checks/e2e/release-repo.nix — local stand-in for github:librepod/os releases.
# Three tags from the real flake source; flake.lock inputs are rewritten to
# store paths so the VM evaluates fully offline. Generated per-run; throwaway.
{
  self,
  hostPkgs,
}:

hostPkgs.runCommand "librepod-os-releases"
  {
    nativeBuildInputs = with hostPkgs; [
      git
      nix
      jq
    ];
  }
  ''
    set -euo pipefail
    export NIX_CONFIG="experimental-features = nix-command flakes"
    # Sandbox HOME (/homeless-shelter) is not writable; keep git's global
    # config OUTSIDE the repo so it never lands in the output.
    export HOME="$PWD/.git-home"
    mkdir -p "$HOME"
    git config --global --add safe.directory '*'   # sandbox ownership mismatch
    cp -r --no-preserve=mode ${self} repo
    # Worktree checkouts copy a .git gitdir-pointer file into the store; it
    # points outside the sandbox and breaks git init.
    rm -rf repo/.git
    cd repo

    # Lock inputs → store paths (VM has no network; github refs would hang).
    # narHash via `nix hash path` so path nodes satisfy pure lock checks.
    jq \
      --arg nixpkgs "${self.inputs.nixpkgs}" --arg nixpkgs_h "$(nix hash path ${self.inputs.nixpkgs})" \
      --arg k3s "${self.inputs.k3s-nixpkgs}" --arg k3s_h "$(nix hash path ${self.inputs.k3s-nixpkgs})" \
      --arg disko "${self.inputs.disko}" --arg disko_h "$(nix hash path ${self.inputs.disko})" \
      --arg tf "${self.inputs.treefmt-nix}" --arg tf_h "$(nix hash path ${self.inputs.treefmt-nix})" \
      '.nodes.nixpkgs.locked = {type:"path",path:$nixpkgs,narHash:$nixpkgs_h}
       | .nodes["k3s-nixpkgs"].locked = {type:"path",path:$k3s,narHash:$k3s_h}
       | .nodes.disko.locked = {type:"path",path:$disko,narHash:$disko_h}
       | .nodes["treefmt-nix"].locked = {type:"path",path:$tf,narHash:$tf_h}' \
      flake.lock > flake.lock.tmp
    mv flake.lock.tmp flake.lock

    git init -q
    git config user.email e2e@librepod
    git config user.name e2e
    git add -A
    git commit -qm baseline

    # One commit per release; the marker module rides mkDevice's module list
    # (anchor: the hostname line in flake.nix's mkDevice — keep in sync).
    mark() {  # tag, marker-text, extra-module ("" for none)
      local extra=""
      [ -n "$3" ] && extra="\n              $3"
      sed -i "s|{ networking.hostName = name; }|{ networking.hostName = name; }\n              { environment.etc.\"release-marker\".text = \"$2\"; }$extra|" flake.nix
      git commit -aqm "$1"
      git tag "$1"
    }
    mark v0.3.5 "v0.3.5" ""
    mark v0.4.0 "v0.4.0" ""
    mark v9.9.9 "v9.9.9" "{ services.k3s.enable = nixpkgs.lib.mkForce false; }"

    mkdir -p $out
    cp -r ./. $out/
  ''
