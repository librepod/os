{ pkgs, lib, ... }:
let
  dataDir = "/mnt/gitolite";
  adminKey = "${dataDir}/.ssh/gitolite-admin";
  adminUser = "nixos";

  # Seed file committed into cluster-config on first init.
  seedKustomization = pkgs.writeText "kustomization.yaml" ''
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources: []
  '';
in
{
  services.gitolite = {
    enable = true;
    dataDir = dataDir;
    # Not used — we generate the key at runtime and pass it to `gitolite setup`
    # ourselves.  The module requires a non-empty string.
    adminPubkey = "placeholder";
  };

  # Persistent dirs (StateDirectory only handles /var/lib).
  systemd.tmpfiles.rules = [
    "d ${dataDir}                0750 gitolite gitolite -"
    "d ${dataDir}/.gitolite      0750 gitolite gitolite -"
    "d ${dataDir}/.gitolite/logs 0750 gitolite gitolite -"
    "d ${dataDir}/.ssh           0700 gitolite gitolite -"
  ];

  # ── gitolite-init ──────────────────────────────────────────────────────
  # We mkForce the script because the upstream module hard-codes a
  # nix-store pubkey path, while we generate the keypair at runtime.
  # The logic mirrors upstream: rc management → first-time setup → upgrade.
  systemd.services.gitolite-init = {
    script = lib.mkForce ''
      set -euo pipefail

      # 1. Generate admin SSH keypair (first boot only).
      if [ ! -f "${adminKey}" ]; then
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "${adminKey}" -N "" -C "gitolite-admin"
      fi

      # 2. Bootstrap .gitolite.rc if missing.
      if [ ! -e "${dataDir}/.gitolite.rc" ]; then
        ${pkgs.gitolite}/bin/gitolite print-default-rc > "${dataDir}/.gitolite.rc"
      fi

      # 3. First-time gitolite init.
      if [ ! -d "${dataDir}/repositories" ]; then
        ${pkgs.gitolite}/bin/gitolite setup -pk "${adminKey}.pub"
      fi

      # 4. Declare cluster-config in gitolite.conf (via the working-tree that
      #    gitolite setup reads).  Without this, the admin key cannot access the
      #    repo even though it was the initial pubkey.
      ADMIN_CONF="${dataDir}/.gitolite/conf/gitolite.conf"
      if ! grep -q "repo cluster-config" "$ADMIN_CONF" 2>/dev/null; then
        printf '\nrepo cluster-config\n    RW+ = gitolite-admin\n' >> "$ADMIN_CONF"
      fi

      # 5. Refresh hooks, compile conf, create declared repos.
      ${pkgs.gitolite}/bin/gitolite setup

      # 6. Seed cluster-config with an empty kustomization.yaml (first boot).
      #    Pure plumbing — no hooks, no push, no shell escaping issues.
      CLUSTER_BARE="${dataDir}/repositories/cluster-config.git"
      if [ -d "$CLUSTER_BARE" ] && \
         ! GIT_DIR="$CLUSTER_BARE" ${pkgs.git}/bin/git rev-parse --verify refs/heads/main >/dev/null 2>&1; then
        blob=$(GIT_DIR="$CLUSTER_BARE" ${pkgs.git}/bin/git hash-object -w "${seedKustomization}")
        tree=$(printf "100644 blob %s\tkustomization.yaml\n" "$blob" \
          | GIT_DIR="$CLUSTER_BARE" ${pkgs.git}/bin/git mktree)
        commit=$(GIT_DIR="$CLUSTER_BARE" \
          GIT_AUTHOR_NAME=NixOS GIT_AUTHOR_EMAIL=nix@localhost \
          GIT_COMMITTER_NAME=NixOS GIT_COMMITTER_EMAIL=nix@localhost \
          ${pkgs.git}/bin/git commit-tree "$tree" -m "Initial cluster config")
        GIT_DIR="$CLUSTER_BARE" ${pkgs.git}/bin/git update-ref refs/heads/main "$commit"
      fi
    '';
  };

  # ── nixos user setup (SSH config + local clone) ────────────────────────
  # Runs as root after gitolite-init so the admin key already exists.
  systemd.services.gitolite-user-setup = {
    description = "Set up ${adminUser} SSH config and cluster-config clone";
    after = [ "gitolite-init.service" ];
    requires = [ "gitolite-init.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.git
      pkgs.openssh
      pkgs.util-linux
    ];
    script = ''
            set -euo pipefail
            home=/home/${adminUser}
            sshdir=$home/.ssh

            # Ensure .ssh dir and admin keypair copy.
            install -d -m 700 -o ${adminUser} -g users "$sshdir"
            install -m 600 -o ${adminUser} -g users "${adminKey}"     "$sshdir/gitolite-admin"
            install -m 644 -o ${adminUser} -g users "${adminKey}.pub" "$sshdir/gitolite-admin.pub"

            # Write SSH client config (idempotent).
            cfg=$sshdir/config
            if ! grep -q "Host gitolite" "$cfg" 2>/dev/null; then
              cat >> "$cfg" <<'EOF'

      Host gitolite
        HostName localhost
        User gitolite
        IdentityFile ~/.ssh/gitolite-admin
        StrictHostKeyChecking no
      EOF
              chown ${adminUser}:users "$cfg"
              chmod 600 "$cfg"
            fi

            # Clone cluster-config if not already present.
            repo=$home/cluster-config
            if [ ! -d "$repo/.git" ]; then
              rm -rf "$repo"
              runuser -u ${adminUser} -- git clone gitolite:cluster-config "$repo"
            fi
    '';
  };

  # ── Flux K8S secret ───────────────────────────────────────────────────
  systemd.services.gitolite-flux-k8s-secret = {
    description = "Provision gitolite admin key as Kubernetes Secret for Flux";
    after = [
      "gitolite-init.service"
      "k3s.service"
    ];
    requires = [ "gitolite-init.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.kubectl
      pkgs.gawk
    ];
    environment = {
      KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      # Wait for K3S API (up to 5 min).
      for i in $(seq 1 60); do
        kubectl get nodes >/dev/null 2>&1 && break
        [ "$i" -eq 60 ] && { echo "Timed out waiting for K3S API"; exit 1; }
        sleep 5
      done

      kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

      known_hosts=$(
        ${pkgs.openssh}/bin/ssh-keyscan -t ed25519 localhost 2>/dev/null \
          | awk '/^localhost[[:space:]]/ && $2 ~ /^ssh-/ { print "librepod.local", $2, $3 }'
      )

      kubectl create secret generic gitolite-flux-ssh \
        --namespace flux-system \
        --from-file=identity=${adminKey} \
        --from-file=identity.pub=${adminKey}.pub \
        --from-literal=known_hosts="$known_hosts" \
        --dry-run=client -o yaml | kubectl apply -f -
    '';
  };
}
