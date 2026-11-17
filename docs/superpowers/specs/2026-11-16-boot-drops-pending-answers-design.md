# Pending power and install answers are dropped at the first run after a boot

GitHub #28, bead `librepod-os-bzk`. Contract: `docs/updates.md`.

## Why

A Restart, Power off or Install now can fire after a boot that nobody
connects with the click:

- **Late.** The agent is down, the UI still accepts clicks for 5–10 minutes,
  the owner pulls the plug; on the next boot the agent acts on the waiting `id`
  before the UI is even up.
- **Twice.** The agent unit is ordered `after = k3s.service`, so at shutdown it
  stops first while the k3s API still takes writes. An `id` written in that gap
  fires on the next boot.

The UI can't close this: anything it writes before a power cut is in the
datastore when the device boots, and the agent acts before marketplace-ui runs.

## Rule

At the agent's first run after a boot, a `spec.power` or `spec.install` whose
`id` is above `status.handled.<section>` is marked handled and not carried out.
`status.rejected.<section>` says `the device restarted before it could act`.
This applies to both `install` values, `now` and `tonight` (owner's call: one
rule; after days off, "tonight" is not the night the owner meant).

`spec.updates` and `spec.sshKeys` are settings, not actions, and are applied as
today.

An agent restart in the same boot behaves as today and acts on the waiting
answer: nothing booted in between, so it is still what the owner asked for.

## Goals, non-goals

- Goal: no power or install answer the agent has not yet acted on survives a
  boot. An install it already handed to the updater is the updater's (its
  request file persists; follow-up bead `librepod-os-3xd`).
- Non-goal: telling a click made before the boot from one made after it but
  before the agent's first run (the agent waits for k3s and the CRD). Both are
  dropped; the owner sees the reason and clicks again. A lost click beats a
  repeated one.
- Anti-goal: a new status field or new UI code. The existing "rejected counts
  as handled" path carries it.

## Approaches

1. **Boot ID in `state.json`, checked in `Reconcile` (chosen).** The agent
   keeps the last seen `/proc/sys/kernel/random/boot_id`. A different one at a
   run that has read the Device means a fresh boot. The rejections and the new
   boot ID are saved in one write, so a crash before that write leaves the old
   boot ID and the restarted agent drops the answer again.
2. Marker file in `/run` (tmpfs, empty after a boot). Same size, but splits the
   agent's state across two places. Rejected.
3. Drop at process start in `main.go`. Saving the boot ID before the drop is
   saved lets a crash in between turn into acting on the click. Rejected.

## Design

- `state.State` gains `BootID string` (`json:"bootID,omitempty"`). A state file
  without it (the first run of this agent version) counts as a fresh boot;
  that is right, since an image update always reboots.
- `controller.Reconciler` gains `BootID string`; `main.go` reads it from
  `/proc/sys/kernel/random/boot_id` (trimmed) and fails start-up if it can't.
- In `Reconcile`, after the Device is read (never on a read error) and before
  step 2: if `Store.S.BootID != r.BootID`, reject each of `spec.power.id` and
  `spec.install.id` that is `Fresh`, set `Store.S.BootID`, `Save` once. A
  `Save` error returns it, so the run is retried and nothing is acted on.
- The NotFound path (Device just created) returns before this; the requeued run
  sees an empty spec and only records the boot ID.
- Tests leave `BootID` empty on both sides, so existing tests are unchanged.

## Contract (`docs/updates.md`)

- `spec.power` and `spec.install`: an answer still waiting at the agent's
  first run after a boot is dropped, with the reason.
- "Handled once" rejection list: add `power` and `install`:
  `the device restarted before it could act`.

## Done when

- Test: pending `power` and `install` at the first run after a boot ID change
  are handled, `status.rejected` carries the reason, `Exec` and `Run` (install)
  are not called.
- Test: same boot ID, a pending `power` is still acted on.
- `go test ./...` and `nix flake check` pass.

## Left to the builder

Whether the drop lives in a small controller helper or inline in `Reconcile`.
