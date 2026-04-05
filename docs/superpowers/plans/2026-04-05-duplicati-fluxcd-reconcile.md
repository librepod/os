# Duplicati FluxCD Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the multi-mode reconciliation system (argocd/snapshot/fluxcd) in the duplicati module with a single FluxCD-native approach, making fluxcd the default and only reconciliation mode.

**Architecture:** The duplicati module uses pre/post backup shell scripts invoked around Duplicati CLI runs. Pre-backup will suspend Flux Kustomizations and scale down PVC-using workloads. Post-backup will resume Flux Kustomizations (which triggers automatic reconciliation). The NixOS module layer removes the `k3sPostBackupReconcile` option and legacy `single.nix` strategy.

**Tech Stack:** NixOS module system, bash shell scripts, FluxCD CLI (`fluxcd` nixpkg), K3S/kubectl, Duplicati CLI.

**Spec:** `docs/superpowers/specs/2026-04-05-duplicati-fluxcd-reconcile-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `modules/duplicati/default.nix` | Modify | Entry point — imports per-pvc, enables Duplicati service. Remove reconcile option and strategy selection. |
| `modules/duplicati/per-pvc.nix` | Modify | Per-PVC backup strategy. Swap `argocd` -> `fluxcd` in runtimeInputs, remove env var exports. |
| `modules/duplicati/single.nix` | Delete | Legacy single-backup strategy. No longer needed. |
| `modules/duplicati/scripts/pre-backup.sh` | Rewrite | Suspend Flux, discover PVCs, scale down PVC-using deployments. |
| `modules/duplicati/scripts/post-backup.sh` | Rewrite | Resume Flux Kustomizations (triggers automatic reconciliation). |
| `modules/duplicati/scripts/backup-per-pvc.sh` | Unchanged | Orchestrates per-PVC backup runs. |
| `modules/k3s/default.nix` | Modify | Remove resolved FIXME comment. |

---

### Task 1: Rewrite pre-backup.sh

**Files:**
- Rewrite: `modules/duplicati/scripts/pre-backup.sh`

- [ ] **Step 1: Replace pre-backup.sh with FluxCD-only logic**

The new script removes all mode branching (`RECONCILE_MODE`, snapshot logic, ArgoCD logic) and replaces with:
1. Suspend all Flux Kustomizations
2. Discover PVCs with `storageClassName: nfs-client`
3. Scale down deployments using those PVCs
4. Wait for pods to terminate

Write the following to `modules/duplicati/scripts/pre-backup.sh`:

```bash
set -euo pipefail

# Pre-backup script for Duplicati with FluxCD integration
#
# This script prepares the cluster for a consistent backup by:
# 1. Suspending FluxCD Kustomization reconciliation
# 2. Scaling down deployments that use PVCs
# 3. Waiting for pods to terminate
#
# After backup completes, the post-backup script resumes Flux reconciliation,
# which restores all workloads to their desired Git state.

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
STORAGE_CLASS=nfs-client

# Logging functions for Duplicati integration
# Messages with these prefixes appear in Duplicati logs
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_info "Starting pre-backup script..."

# Step 1: Suspend FluxCD Kustomizations
# This prevents Flux from re-creating pods we're about to scale down
log_info "Suspending FluxCD Kustomizations..."
flux suspend kustomization --all --namespace flux-system || {
  log_error "Failed to suspend FluxCD Kustomizations"
  exit 1
}
log_info "FluxCD Kustomizations suspended"

# Step 2: Scale down deployments using PVCs
# Query PVCs from Kubernetes API to get correct PVC names
log_info "Scaling down deployments using PVCs..."

# Get all PVCs that are using the configured storage class
pvc_list=$(k3s kubectl get pvc -A -o json 2>/dev/null | jq -r "
  .items[] |
  select(.spec.storageClassName == \"$STORAGE_CLASS\") |
  \"\(.metadata.namespace) \(.metadata.name)\"
" || true)

if [ -n "$pvc_list" ]; then
  scaled_count=0

  while read -r pvc_namespace pvc_name; do
    [ -z "$pvc_namespace" ] && continue
    [ -z "$pvc_name" ] && continue

    # Find deployments using this PVC (match both name and namespace)
    deployments=$(k3s kubectl get deployments -A -o json 2>/dev/null | jq -r "
      .items[] |
      select(.metadata.namespace == \"$pvc_namespace\" and
             .spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == \"$pvc_name\") |
      \"\(.metadata.namespace) \(.metadata.name)\"
    " || true)

    if [ -n "$deployments" ]; then
      while read -r namespace name; do
        [ -z "$namespace" ] && continue
        [ -z "$name" ] && continue

        log_info "Scaling down: $namespace/$name (replicas -> 0)"
        if timeout 60 k3s kubectl scale deployment "$name" -n "$namespace" --replicas=0 2>/dev/null; then
          scaled_count=$((scaled_count + 1))

          # Wait for pods to terminate (with timeout)
          timeout 120 k3s kubectl wait --for=delete pods \
            -l "app.kubernetes.io/instance=$name" \
            -n "$namespace" --timeout=120s 2>/dev/null || true
        else
          log_error "Failed to scale down: $namespace/$name"
        fi
      done <<< "$deployments"
    fi
  done <<< "$pvc_list"

  log_info "Scaled down $scaled_count deployments"
else
  log_info "No PVCs found with $STORAGE_CLASS storage class"
fi

log_info "Pre-backup script completed successfully"
exit 0
```

- [ ] **Step 2: Commit**

```bash
git add modules/duplicati/scripts/pre-backup.sh
git commit -m "refactor(duplicati): rewrite pre-backup script for FluxCD"
```

---

### Task 2: Rewrite post-backup.sh

**Files:**
- Rewrite: `modules/duplicati/scripts/post-backup.sh`

- [ ] **Step 1: Replace post-backup.sh with FluxCD-only logic**

The new script is minimal — just resume Flux Kustomizations. `flux resume` waits for reconciliation to finish, so no separate reconcile step is needed.

Write the following to `modules/duplicati/scripts/post-backup.sh`:

```bash
set -euo pipefail

# Post-backup script for Duplicati with FluxCD integration
#
# This script resumes FluxCD Kustomization reconciliation after backup completes.
# Flux will detect any drift between Git state and cluster state, and restore
# all workloads to their desired replica counts.

# Configuration
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Logging functions for Duplicati integration
log_info() {
  echo "LOG:INFO $*"
}

log_error() {
  echo "LOG:ERROR $*" >&2
}

log_info "Starting post-backup script..."

# Resume FluxCD Kustomizations
# flux resume marks resources for reconciliation and waits for the apply to finish
log_info "Resuming FluxCD Kustomizations..."
flux resume kustomization --all --namespace flux-system || {
  log_error "Failed to resume FluxCD Kustomizations"
  exit 1
}

log_info "FluxCD Kustomizations resumed and reconciled"
log_info "Post-backup script completed successfully"
exit 0
```

- [ ] **Step 2: Commit**

```bash
git add modules/duplicati/scripts/post-backup.sh
git commit -m "refactor(duplicati): rewrite post-backup script for FluxCD"
```

---

### Task 3: Update default.nix — remove reconcile option and strategy selection

**Files:**
- Modify: `modules/duplicati/default.nix`

- [ ] **Step 1: Simplify default.nix**

Replace the entire file content with:

```nix
# Duplicati backup module with FluxCD integration
#
# This module enables Duplicati web UI for monitoring and provides:
# 1. Pre/post backup scripts that suspend/resume FluxCD and scale K8s deployments
# 2. A declarative systemd timer for automated nightly per-PVC backups
#
# Backup configuration is fully declarative - no web UI setup required.
# The web UI at http://<server>:8200 is available for viewing logs and manual operations.
#
# Scripts docs: https://docs.duplicati.com/detailed-descriptions/scripts

{ config, pkgs, lib, ... }:

{
  imports = [
    ./per-pvc.nix
  ];

  config = {
    # Enable base Duplicati service with web UI (for monitoring and manual operations)
    services.duplicati = {
      enable = lib.mkDefault true;
      interface = "any";  # Allow web UI access from network (default: 127.0.0.1)
      user = "root";
      # No parameters needed - backups are managed via systemd timer
      #
      # TODO: Find a way to opt-out from usage statistics
    };
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add modules/duplicati/default.nix
git commit -m "refactor(duplicati): remove reconcile option and strategy selection"
```

---

### Task 4: Update per-pvc.nix — swap argocd for fluxcd, remove env vars

**Files:**
- Modify: `modules/duplicati/per-pvc.nix`

- [ ] **Step 1: Update runtimeInputs and remove env var exports**

Make these specific changes to `modules/duplicati/per-pvc.nix`:

1. **Remove `cfg` binding** (line 25) — no longer needed since we removed the reconcile option:
   Change `let cfg = config.services.duplicati;` to just `let`

2. **Pre-backup script** (lines 28-36):
   - Change `runtimeInputs = with pkgs; [ k3s argocd jq coreutils ];` to `runtimeInputs = with pkgs; [ k3s fluxcd jq coreutils ];`
   - Remove the two `export` lines, keeping only `${builtins.readFile ./scripts/pre-backup.sh}`:
     ```nix
     preBackupScript = pkgs.writeShellApplication {
       name = "duplicati-pre-backup";
       runtimeInputs = with pkgs; [ k3s fluxcd jq coreutils ];
       text = builtins.readFile ./scripts/pre-backup.sh;
     };
     ```

3. **Post-backup script** (lines 38-46):
   - Change `runtimeInputs = with pkgs; [ k3s argocd jq coreutils ];` to `runtimeInputs = with pkgs; [ k3s fluxcd jq coreutils ];`
   - Remove the two `export` lines:
     ```nix
     postBackupScript = pkgs.writeShellApplication {
       name = "duplicati-post-backup";
       runtimeInputs = with pkgs; [ k3s fluxcd jq coreutils ];
       text = builtins.readFile ./scripts/post-backup.sh;
     };
     ```

4. **Per-PVC backup script** (lines 50-54):
   - Change `runtimeInputs = with pkgs; [ k3s argocd jq coreutils duplicati icu ];` to `runtimeInputs = with pkgs; [ k3s fluxcd jq coreutils duplicati icu ];`

- [ ] **Step 2: Commit**

```bash
git add modules/duplicati/per-pvc.nix
git commit -m "refactor(duplicati): swap argocd for fluxcd in runtimeInputs"
```

---

### Task 5: Delete single.nix

**Files:**
- Delete: `modules/duplicati/single.nix`

- [ ] **Step 1: Delete the legacy file**

```bash
git rm modules/duplicati/single.nix
git commit -m "refactor(duplicati): remove legacy single-backup strategy"
```

---

### Task 6: Clean up k3s FIXME comment

**Files:**
- Modify: `modules/k3s/default.nix:55-58`

- [ ] **Step 1: Remove the FIXME comment**

In `modules/k3s/default.nix`, remove line 58:
```
  # FIXME: Update duplicaty pre- and post- scripts to use flux for stop/start syncing
```

Keep lines 55-57 (the comments about what flux and jq are for) and line 59 (the `environment.systemPackages` line).

- [ ] **Step 2: Commit**

```bash
git add modules/k3s/default.nix
git commit -m "chore(k3s): remove resolved FIXME about duplicati flux integration"
```

---

### Task 7: Validate — run nix flake check

**Files:** None (validation only)

- [ ] **Step 1: Run flake check**

```bash
nix flake check
```

Expected: passes without errors. This validates that all NixOS module imports resolve, options are valid, and no syntax errors exist.

- [ ] **Step 2: Run format check**

```bash
nix fmt -- --check
```

Expected: passes without errors. All nix files are properly formatted.

- [ ] **Step 3: Commit any formatting fixes if needed**

If `nix fmt -- --check` reports issues, run `nix fmt` and commit the result.
