# Namespace-level backup opt-out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** borgmatic skips every nfs-client PVC whose Namespace has `backup.libre.pod/disabled=true`, both when backing up and when scaling down before the backup.

**Architecture:** One jq filter, `modules/borgmatic/scripts/backup-pvcs.jq`, reads `kubectl get ns,pvc -A -o json` and prints the PVCs to back up. `generate-sources.sh` and `pre-backup.sh` both pipe through it. A flake check runs the filter on sample JSON.

**Tech Stack:** Nix flake checks (`pkgs.runCommand`), jq, bash via `pkgs.writeShellApplication`.

**Spec:** `docs/superpowers/specs/2026-11-19-namespace-backup-opt-out-design.md`

## Global Constraints

- Label `backup.libre.pod/disabled`, which counts only with the value exactly `"true"`. Storage class `nfs-client`. Both live only in `backup-pvcs.jq`.
- A namespace label always wins: a PVC inside a disabled namespace can't opt back in.
- Keep the scripts' `2>/dev/null … || true` around the kubectl/jq pipeline, so that when k3s is down there are no PVCs and the script still exits 0.
- `writeShellApplication` runs shellcheck: no unused variables.
- Flakes only see files git tracks: `git add` new files before any `nix build`.
- Don't touch `modules/duplicati/` or `post-backup.sh`.
- This repo uses the conservative profile: run the commit steps only once the user has approved committing.

## Review Focus

- A disabled namespace whose name is a prefix of an enabled one (`sandboxes` vs `sandboxes-archive`): only the exact name is skipped. The sample data covers this in Task 1.
- A Namespace or PVC with no `labels` key: treated as not disabled, with no jq error. Covered in Task 1.
- k3s down: kubectl writes nothing to stdout, so the filter gets empty input, prints nothing and exits 0. Covered in Task 1.
- An unbound PVC: its line ends with an empty `volumeName`. `generate-sources` skips it, and in `pre-backup` the `read` swallows it into `_`. Covered in Task 1 (filter output) and Task 2 (`read` change).
- `kubectl get ns,pvc -A -o json` must return a single `List` whose items carry `.kind`. Checked on a real k3s in Task 1, Step 1.

---

### Task 1: Shared PVC filter and its check

**Files:**
- Create: `modules/borgmatic/scripts/backup-pvcs.jq`
- Create: `checks/borgmatic-pvcs/input.json`, `checks/borgmatic-pvcs/expected.txt`
- Modify: `flake.nix` (add the check after `installed-device`, ~line 389)

**Interfaces:**
- Produces: `backup-pvcs.jq`, used as `jq -r -f backup-pvcs.jq`. Stdin is `kubectl get ns,pvc -A -o json`. Stdout has one line per PVC to back up: `"<namespace> <name> <volumeName or empty>"`, in input order.

- [ ] **Step 1: Confirm the kubectl output shape on a dev device (needs the user or a device with k3s)**

Run on the device: `k3s kubectl get ns,pvc -A -o json | jq -c '[.kind, (.items | map(.kind) | unique)]'`
Expected: `["List",["Namespace","PersistentVolumeClaim"]]`. If you get anything else, stop and report it, because the design depends on this shape.

- [ ] **Step 2: Write the sample data**

`checks/borgmatic-pvcs/input.json` is a `{"kind":"List","items":[…]}` holding these items, with only the fields shown:

| kind | name | namespace | labels | storageClassName | volumeName |
|---|---|---|---|---|---|
| Namespace | media | | *(no `labels` key)* | | |
| Namespace | sandboxes | | `disabled: "true"` | | |
| Namespace | sandboxes-archive | | *(no `labels` key)* | | |
| Namespace | tools | | `disabled: "false"` | | |
| PersistentVolumeClaim | photos | media | *(none)* | nfs-client | pv-photos |
| PersistentVolumeClaim | cache | media | `disabled: "true"` | nfs-client | pv-cache |
| PersistentVolumeClaim | scratch | media | *(none)* | local-path | pv-scratch |
| PersistentVolumeClaim | pending | media | *(none)* | nfs-client | *(absent)* |
| PersistentVolumeClaim | step-1 | sandboxes | *(none)* | nfs-client | pv-step-1 |
| PersistentVolumeClaim | logs | sandboxes-archive | *(none)* | nfs-client | pv-logs |
| PersistentVolumeClaim | db | tools | *(none)* | nfs-client | pv-db |

(In the table, `disabled` stands for the full label key `backup.libre.pod/disabled`.)

`checks/borgmatic-pvcs/expected.txt`:
```
media photos pv-photos
media pending
sandboxes-archive logs pv-logs
tools db pv-db
```

- [ ] **Step 3: Register the check in `flake.nix`**

```nix
          # Which PVCs borgmatic backs up and scales down (one filter for both scripts).
          borgmatic-pvcs =
            let
              filter = ./modules/borgmatic/scripts/backup-pvcs.jq;
            in
            pkgs.runCommand "borgmatic-pvcs" { nativeBuildInputs = [ pkgs.jq ]; } ''
              # -Z: an unbound PVC's line ends with an empty volumeName
              jq -r -f ${filter} ${./checks/borgmatic-pvcs/input.json} | diff -u -Z ${./checks/borgmatic-pvcs/expected.txt} -
              # k3s down: empty input, no output
              [ -z "$(jq -r -f ${filter} < /dev/null)" ]
              touch $out
            '';
```

- [ ] **Step 4: Run the check and make sure it fails**

Run: `git add checks/borgmatic-pvcs && nix build .#checks.x86_64-linux.borgmatic-pvcs`
Expected: an evaluation error saying `modules/borgmatic/scripts/backup-pvcs.jq` does not exist.

- [ ] **Step 5: Write `modules/borgmatic/scripts/backup-pvcs.jq`**

Start with a one-line header comment giving the input and output (the Interfaces line above). Collect the names of `Namespace` items whose label is `"true"` into an array. Then emit the `PersistentVolumeClaim` items with `storageClassName == "nfs-client"`, own label not `"true"`, and namespace not in the array. Test membership with exact equality (`IN($skip[])`), never with string `contains`/`test`. The output line format is `"\(.metadata.namespace) \(.metadata.name) \(.spec.volumeName // "")"`.

- [ ] **Step 6: Run the check and make sure it passes**

Run: `git add modules/borgmatic/scripts/backup-pvcs.jq && nix build .#checks.x86_64-linux.borgmatic-pvcs`
Expected: exits 0 with no diff output.

- [ ] **Step 7: Format check**

Run: `nix fmt -- --ci`
Expected: exits 0.

- [ ] **Step 8: Commit (only with the user's approval)**

```bash
git add flake.nix checks/borgmatic-pvcs modules/borgmatic/scripts/backup-pvcs.jq
git commit -m "feat(borgmatic): shared PVC filter honoring namespace-level backup.libre.pod/disabled"
```

### Task 2: Both scripts use the filter

**Files:**
- Modify: `modules/borgmatic/default.nix:1-33` (header comment), `:74`, `:85` (script `text`)
- Modify: `modules/borgmatic/scripts/generate-sources.sh:3-13, 17-18, 33-39`
- Modify: `modules/borgmatic/scripts/pre-backup.sh:16-17, 66-74, 79, 120`

**Interfaces:**
- Consumes: `backup-pvcs.jq` from Task 1. Its path reaches each script as the shell variable `PVC_FILTER`.

- [ ] **Step 1: Pass the filter path into both scripts**

In `default.nix`, for `generateSourcesScript` and `preBackupScript` only:
`text = "PVC_FILTER=${./scripts/backup-pvcs.jq}\n" + builtins.readFile ./scripts/<script>.sh;`

- [ ] **Step 2: `generate-sources.sh`**

Replace the `pvc_list=$(…)` query with
`pvc_list=$(k3s kubectl get ns,pvc -A -o json 2>/dev/null | jq -r -f "$PVC_FILTER" 2>/dev/null || true)`.
Delete `STORAGE_CLASS` and `SKIP_LABEL`. In the header comment, say a PVC is skipped when it or its namespace has the label, and point to `backup-pvcs.jq`.

- [ ] **Step 3: `pre-backup.sh`**

Make the same `pvc_list` replacement and change the loop to `while read -r pvc_namespace pvc_name _; do`. Delete `STORAGE_CLASS` and `SKIP_LABEL`. Change the empty-list log line to `log_info "No PVCs to back up"`. In the Step 3 comment, mention that PVCs in disabled namespaces are skipped too.

- [ ] **Step 4: `default.nix` header comment**

Line 4: change it to "label a PVC or its Namespace `backup.libre.pod/disabled=true` to skip". Line 23: change "labeled PVCs" to "PVCs to back up (see `scripts/backup-pvcs.jq`)". Under "To skip a PVC from backup", add:
```
# To skip every PVC in a namespace (e.g. PVCs a controller creates at runtime):
#   kubectl label ns <namespace> backup.libre.pod/disabled=true
```

- [ ] **Step 5: Build the scripts (this runs shellcheck)**

Run:
```bash
nix build --impure --no-link --print-out-paths --expr '
let
  f = builtins.getFlake (toString ./.);
  inherit (f.inputs.nixpkgs) lib;
  sys = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ f.nixosModules.borgmatic { boot.isContainer = true; system.stateVersion = "25.11"; } ];
  };
in
sys.pkgs.linkFarmFromDrvs "borgmatic-scripts"
  (builtins.filter (p: lib.hasPrefix "borgmatic-" (p.name or "")) sys.config.environment.systemPackages)'
```
Expected: prints `/nix/store/…-borgmatic-scripts`.

- [ ] **Step 6: No old filter left**

Run: `grep -n 'SKIP_LABEL\|STORAGE_CLASS\|get pvc -A' modules/borgmatic/scripts/*.sh`
Expected: no output.

- [ ] **Step 7: Check and format**

Run: `nix build .#checks.x86_64-linux.borgmatic-pvcs && nix fmt -- --ci`
Expected: both exit 0.

- [ ] **Step 8: Try it on a dev device (needs the user)**

Deploy the branch to a dev device and label a test namespace that has an nfs-client PVC. Then run `sudo borgmatic-generate-sources`. It only rewrites `/run/borgmatic/sources.yaml`, and it's safe to run by hand. Don't run `borgmatic-pre-backup` by hand: it suspends Flux and scales workloads down.
Expected: no `Including PVC <test-ns>/…` line, and that namespace's paths are missing from `/run/borgmatic/sources.yaml`.

- [ ] **Step 9: Commit (only with the user's approval)**

```bash
git add modules/borgmatic
git commit -m "feat(borgmatic): skip PVCs in namespaces labeled backup.libre.pod/disabled (#33)"
```
