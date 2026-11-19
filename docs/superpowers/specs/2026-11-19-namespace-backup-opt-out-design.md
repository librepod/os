# Namespace-level backup opt-out (issue #33)

## Why

The only way to skip borgmatic backup today is to label each PVC with
`backup.libre.pod/disabled=true`. When a controller creates PVCs at runtime,
the app's manifests have nothing to label. The factory8 sandboxes are the
case in point: a worker creates one 10Gi PVC per SDLC step in
`factory8-sandboxes`, and those PVCs accumulate. That data shouldn't be
backed up, and the sandbox workloads shouldn't be scaled down for the backup.

## Goals

- A PVC is skipped if the PVC **or its Namespace** has
  `backup.libre.pod/disabled=true`.
- `generate-sources.sh` (what gets backed up) and `pre-backup.sh` (what gets
  scaled down) always agree on that set.

## Non-goals

- Opting a single PVC back in when its namespace is disabled. The namespace
  label always wins.
- Excluding a disabled namespace's HelmReleases or Kustomizations from the
  Flux suspend/resume. Suspending Flux doesn't stop running pods.
- `modules/duplicati` (decommissioned) and `post-backup.sh` (it replays the
  state file and has no PVC logic).
- Labeling `factory8-sandboxes`. The marketplace repo does that.

## Constraints

- The scripts hide kubectl errors (`|| true`) so that a stopped k3s just
  means no backup. Two separate kubectl calls (PVCs, then namespaces) could
  disagree: a failed namespace fetch would leave an empty skip list without
  any error, and every sandbox PVC would be backed up and scaled down.
  A single `get ns,pvc` call narrows that gap but doesn't close it: kubectl
  still prints the types that succeeded and exits 1. So a non-zero exit
  from kubectl means no PVCs that run (logged), which is what a stopped k3s
  already means. Partial output is never used.
- `writeShellApplication` runs shellcheck, so an unused variable breaks the
  build.

## Approaches

- **A. Change each script in place.** Each script fetches namespaces and
  PVCs with one `kubectl get ns,pvc -A -o json` call and applies its own
  filter. About 4 lines per script. Still two copies, still no test.
- **B. One shared filter plus a flake check. Chosen.** Same single fetch, but
  one jq file is the only place that defines which PVCs get backed up. Both
  scripts use it, and a flake check runs it against sample JSON. The scripts
  can't drift apart, and the logic is tested without a k3s VM. Costs about
  30 more lines than A.

## Design

1. **`modules/borgmatic/scripts/backup-pvcs.jq`** (new). Input: the output
   of `kubectl get ns,pvc -A -o json` (a `List` whose items carry `.kind`).
   Output: one `namespace name volumeName` line per PVC to back up.
   - Collect the names of Namespaces whose label is `"true"`.
   - Keep PersistentVolumeClaims with `storageClassName == "nfs-client"`
     whose own label isn't `"true"` and whose namespace isn't in that list.
   - `volumeName` is `""` when unbound, as today (generate-sources skips
     those).
   - The label and the storage class are written into this file, so it is
     the only place that defines what gets backed up.
2. **`default.nix`**: prepend `PVC_FILTER=${./scripts/backup-pvcs.jq}` to
   the `text` of the generate-sources and pre-backup scripts.
3. **`generate-sources.sh`**: replace its `get pvc` + inline jq with
   `k3s kubectl get ns,pvc -A -o json | jq -r -f "$PVC_FILTER"`, keeping the
   existing `2>/dev/null … || true`. Drop the variables that are no longer
   used (`SKIP_LABEL`, `STORAGE_CLASS`).
4. **`pre-backup.sh`**: the same replacement, reading the lines with
   `read -r pvc_namespace pvc_name _`. Drop `SKIP_LABEL`.
5. **Flake check `borgmatic-pvc-filter`**: a `runCommand` that runs the
   filter against `checks/borgmatic-pvcs.json` and diffs the output against
   the expected lines. Sample cases: an ordinary PVC (kept), a labeled PVC
   (skipped), a PVC in a labeled namespace (skipped), a PVC in a namespace
   labeled `"false"` (kept), a PVC with another storage class (skipped), an
   unbound PVC (kept, empty volumeName).
6. **Docs**: update the header comments in `default.nix` and
   `generate-sources.sh`, and add
   `kubectl label ns <namespace> backup.libre.pod/disabled=true` next to the
   PVC example.

## Left to the builder

- Run `kubectl get ns,pvc -A -o json` once on a real k3s (any dev device)
  to confirm it returns a single `List` with `.kind` on every item, before
  relying on it.
- Exact jq style and the sample's layout.
