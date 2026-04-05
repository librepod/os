# Duplicati FluxCD Reconciliation Mode

## Context

The duplicati backup module (`modules/duplicati/`) currently supports three reconciliation modes via the `services.duplicati.k3sPostBackupReconcile` option: `argocd`, `snapshot`, and `fluxcd`. Only `argocd` and `snapshot` are implemented — `fluxcd` fails fast with an error. The project uses FluxCD as its GitOps controller (not ArgoCD), so the `fluxcd` mode should be the default and only mode.

## Decision

Replace the multi-mode reconciliation system with a single FluxCD-native approach. Remove the `k3sPostBackupReconcile` option, the `argocd` and `snapshot` modes, and the legacy `single.nix` backup strategy. Simplify the pre/post backup scripts to straight-line FluxCD logic.

## Files Changed

| File | Action |
|---|---|
| `modules/duplicati/default.nix` | Remove reconcile option, remove strategy selection, direct import of per-pvc, update comments |
| `modules/duplicati/per-pvc.nix` | Swap `argocd` -> `fluxcd` in runtimeInputs, remove env var exports |
| `modules/duplicati/single.nix` | Delete |
| `modules/duplicati/scripts/pre-backup.sh` | Remove mode branching, snapshot logic, ArgoCD logic. Flux-only flow |
| `modules/duplicati/scripts/post-backup.sh` | Remove mode branching, snapshot logic, ArgoCD logic. Flux-only flow |
| `modules/duplicati/scripts/backup-per-pvc.sh` | Unchanged |
| `modules/k3s/default.nix` | Remove resolved FIXME comment at line 58 |

## Pre-backup Script

Straight-line logic with no mode branching:

1. **Suspend Flux reconciliations** -- `flux suspend kustomization --all`
2. **Discover PVCs** with `storageClassName: nfs-client` (existing proven pattern)
3. **Scale down** deployments using those PVCs to 0 replicas
4. **Wait for pods to terminate** (120s timeout)

### Removed from pre-backup

- `RECONCILE_MODE` env var and all `if/elif` branching
- Snapshot file recording (`record_scale`, `SNAPSHOT_FILE`, `SNAPSHOT_DIR`)
- ArgoCD namespace scale-down loop
- `DUPLICATI_POST_BACKUP_RECONCILE` and `DUPLICATI_SCALE_SNAPSHOT_DIR` env vars

## Post-backup Script

Minimal Flux-native flow:

1. **Resume Flux reconciliations** -- `flux resume kustomization --all`
2. **Force reconciliation** -- `flux reconcile kustomization --all`

Flux restores all workloads from Git state. No explicit scale-up needed.

### Removed from post-backup

- `RECONCILE_MODE` env var and all `if/elif` branching
- Snapshot file reading and JSON parsing
- ArgoCD namespace scale-up logic and `ARGOCD_DEFAULT_REPLICAS` map
- `kubectl wait` for pod readiness

## NixOS Module Changes

### default.nix

- Remove `services.duplicati.k3sPostBackupReconcile` option (was lines 53-67)
- Remove strategy-selection comment block and conditional imports
- Replace with direct `imports = [ ./per-pvc.nix ];`
- Update header comment to reference FluxCD

### per-pvc.nix

- Remove `argocd` from `runtimeInputs`, add `fluxcd` in all three `writeShellApplication` blocks
- Remove `DUPLICATI_POST_BACKUP_RECONCILE` and `DUPLICATI_SCALE_SNAPSHOT_DIR` env var exports from pre/post script wrappers

### single.nix

- Delete the file entirely

### k3s/default.nix

- Remove the FIXME comment at line 58 (resolved by this change)

## Error Handling

- Post-backup script always runs -- Duplicati calls it via `--run-script-after` regardless of backup success or failure
- Flux always gets resumed -- no risk of stuck suspended state after a failed backup
- No trap/exit handler needed in pre-backup for this scenario
