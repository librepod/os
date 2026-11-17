# Boot Drops Pending Answers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At the agent's first run after a boot, a `spec.power` or `spec.install` still waiting is marked handled and rejected, not carried out.

**Architecture:** The agent keeps the last seen kernel boot ID in `state.json`. `Reconcile`, once it has read the Device, compares it with the current boot ID; on a change it rejects the waiting power and install ids through the existing `State.Reject` path and saves the rejections and the new boot ID in one write.

**Tech Stack:** Go 1.25, controller-runtime fake client (`reconciler_test.go`'s `newEnv`).

**Spec:** `docs/superpowers/specs/2026-11-16-boot-drops-pending-answers-design.md`. Bead `librepod-os-bzk`, GitHub #28.

## Global Constraints

- Rejection reason, exact: `the device restarted before it could act` (so `status.rejected.power` reads `power id 5: the device restarted before it could act`).
- Both `install` values (`now`, `tonight`) are dropped. `spec.updates` and `spec.sshKeys` are untouched.
- Only an id that is `Fresh` (above `handled`, within 1..999999999999999) is dropped.
- The rejections and the new boot ID go to disk in one `Store.Save()`; a save error returns from `Reconcile` before anything acts.
- Never drop or record anything when the Device read fails.
- Boot ID source: `/proc/sys/kernel/random/boot_id`, whitespace-trimmed.
- No new status fields, no CRD change, no new dependencies.
- Commit only when the owner authorizes it for this run; otherwise stage and report. `docs/superpowers` is gitignored: plan and spec need `git add -f`.

## Review Focus

1. Owner clicks again after the drop, same boot → the new id is acted on and the rejection clears (Task 1, last phase of `TestBootDropsWaitingPowerAndInstall`).
2. `state.json` can't be written during the drop → `Reconcile` returns the error, nothing is executed (Task 1, `TestBootDropSaveFailureActsOnNothing`).
3. Device read fails at the first run after a boot → boot ID not recorded, so the next good run still drops (Task 1, extend `TestLiveReadErrorTouchesNothing`).
4. Ids not above `handled` at boot (already handled before shutdown, or restored by a rollback) → no rejection written, an earlier rejection text kept (Task 1, `TestBootChangeKeepsHandledAnswers`).
5. First run of this agent version: `state.json` has no `bootID` → treated as a fresh boot (Task 1, `TestBootDropSaveFailureActsOnNothing` and `TestBootChangeKeepsHandledAnswers` start from an empty stored boot ID).

---

### Task 1: Agent drops waiting power and install answers after a boot

**Files:**
- Modify: `pkgs/librepod-os-agent/internal/state/state.go` (`State` struct)
- Modify: `pkgs/librepod-os-agent/internal/controller/reconciler.go` (`Reconciler` struct; `Reconcile` between step 1 and step 2)
- Modify: `pkgs/librepod-os-agent/main.go` (`run`, where `controller.Reconciler` is built)
- Test: `pkgs/librepod-os-agent/internal/controller/reconciler_test.go`

**Interfaces:**
- Produces: `state.State.BootID string` with tag `json:"bootID,omitempty"`; `controller.Reconciler.BootID string` (the current boot; tests leave it `""`, so existing tests see no boot change); `func (r *Reconciler) dropAfterBoot(spec v1alpha1.DeviceSpec) error` in `reconciler.go`.

- [ ] **Step 1: Write the failing tests** in `reconciler_test.go` (import `state` is already there)

`TestBootDropsWaitingPowerAndInstall`:
- spec `Power{ID: 5, Action: "poweroff"}`, `Install{ID: 4, When: "now"}`; `e.r.Store.S.BootID = "boot-1"`, `e.r.BootID = "boot-2"`; record `Exec` actions in `acts` and `Run` calls in `calls`.
- Reconcile twice. Assert `len(acts) == 0`, `len(calls) == 0`, `Status.Handled.Power == 5`, `Status.Handled.Install == 4`,
  `Status.Rejected["power"] == "power id 5: the device restarted before it could act"`,
  `Status.Rejected["install"] == "install id 4: the device restarted before it could act"`.
- `st, _ := state.Open(e.r.Store.Path)`; assert `st.S.BootID == "boot-2"` (persisted).
- Then set the Device's `spec.power` to `{ID: 6, Action: "reboot"}` via `e.c.Update`, reconcile once. Assert `acts == ["reboot"]` and `Status.Rejected["power"] == ""`.

`TestSameBootStillActsOnWaitingPower` (the issue's restart case):
- spec `Power{ID: 5, Action: "reboot"}`; `e.r.Store.S.BootID = "boot-1"`, `e.r.Store.Save()`, then replace `e.r.Store` with `state.Open(same path)` (agent restart); `e.r.BootID = "boot-1"`.
- Reconcile. Assert `acts == ["reboot"]`, `Status.Rejected["power"] == ""`.

`TestBootDropSaveFailureActsOnNothing`:
- spec `Power{ID: 5, Action: "reboot"}`; stored boot ID left `""`, `e.r.BootID = "boot-2"`; `e.r.Store.Path = filepath.Join(e.dir, "os-release", "state.json")` (a file in the way, so `MkdirAll` fails).
- Call `e.r.Reconcile` directly. Assert it returns a non-nil error and `len(acts) == 0`.

`TestBootChangeKeepsHandledAnswers`:
- spec `Power{ID: 5, Action: "reboot"}`; `e.r.Store.S.Handled.Power = 5`, `e.r.Store.S.Rejected = map[string]string{"power": "power id 5: an update is installing"}`; stored boot ID `""`, `e.r.BootID = "boot-2"`.
- Reconcile. Assert `len(acts) == 0`, `Status.Rejected["power"] == "power id 5: an update is installing"`, `e.r.Store.S.BootID == "boot-2"`.

Extend `TestLiveReadErrorTouchesNothing`: set `e.r.BootID = "boot-2"` before the call; after it, assert `e.r.Store.S.BootID == ""`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd pkgs/librepod-os-agent && go test ./internal/controller/`
Expected: build failure, `e.r.Store.S.BootID undefined` / `e.r.BootID undefined`.

- [ ] **Step 3: Implement**

- `state.go`: add `BootID` to `State` with a one-line comment (the kernel boot ID of the last run that read the Device).
- `reconciler.go`: add `BootID string` to `Reconciler`; add `dropAfterBoot`: no-op when `r.Store.S.BootID == r.BootID`; otherwise `Reject` each of `spec.Power.ID` and `spec.Install.ID` that is non-nil and `Fresh`, with the exact reason, set `r.Store.S.BootID = r.BootID`, and return `r.Store.Save()`. Call it right after the Device read succeeds (after `if err != nil { return ... }`, before step 2), returning `ctrl.Result{}, err` on error. One comment line on why: an answer that outlived a boot is no longer the owner's click.
- `main.go`: read `/proc/sys/kernel/random/boot_id` next to the hostname read, return the error if it fails, pass `strings.TrimSpace` of it as `BootID` in the `controller.Reconciler` literal.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd pkgs/librepod-os-agent && go test ./... && gofmt -l . && go vet ./...`
Expected: every package `ok`, `gofmt -l` prints nothing, `go vet` prints nothing.

- [ ] **Step 5: Commit** (only when authorized; otherwise `git add` and report)

```bash
git add pkgs/librepod-os-agent
git commit -m "feat(os-agent): drop power and install answers still waiting after a boot (#28)"
```

### Task 2: Contract text and full checks

**Files:**
- Modify: `docs/updates.md` (`### spec.install`, `### spec.power`, `## Handled once`)

**Interfaces:**
- Consumes: the rejection reason from Global Constraints; behavior from Task 1.

- [ ] **Step 1: Edit `docs/updates.md`**

- `### spec.install`, new last paragraph: `An answer still waiting at the agent's first run after a boot (now or tonight) is dropped: status.rejected.install says the device restarted before it could act, and it counts as handled. A click made while the agent was down never reboots the device later.` (code-format the field and the reason as the file does).
- `### spec.power`, new bullet after the `an update is installing` one: `An answer still waiting at the agent's first run after a boot is dropped the same way: status.rejected.power says the device restarted before it could act. The boot already happened: a reboot is done, and a power off was overruled by whoever switched the device back on. An agent restart without a boot still acts on it.`
- `## Handled once`, after the `install` bullet of the validation list and before the example: `A power or install answer still waiting at the agent's first run after a boot is rejected the same way: the device restarted before it could act.`

- [ ] **Step 2: Run the full checks**

Run: `cd pkgs/librepod-os-agent && go test ./... && cd ../.. && nix flake check`
Expected: all Go packages `ok`; `nix flake check` exits 0 (no Nix files change, so `vendorHash` and `nix fmt -- --ci` are unaffected).

- [ ] **Step 3: Commit** (only when authorized; otherwise stage and report)

```bash
git add docs/updates.md
git add -f docs/superpowers/specs/2026-11-16-boot-drops-pending-answers-design.md docs/superpowers/plans/2026-11-16-boot-drops-pending-answers.md
git commit -m "docs(updates): power and install answers waiting at boot are dropped (#28)"
```

- [ ] **Step 4: Close the bead** — `bd close librepod-os-bzk`
