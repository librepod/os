# Device API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the update ConfigMap bridge and the setup-code Secret with one `Device` object (`os.librepod.org/v1alpha1`) served by a Go agent on the host, covering updates, reboot/power off, SSH keys, slow-changing status and the setup code.

**Architecture:** A controller-runtime program (`pkgs/librepod-os-agent`) runs as root on image devices, creates its own cluster-scoped `Device` named after the node, applies the owner's answers from `spec` once each (by `rev`/`id`, tracked on disk), and mirrors the host's truth into `status`. The CRD ships through k3s's auto-deploy directory. The updater keeps its CLI and files; the agent only calls it.

**Tech Stack:** Go 1.25 (`buildGo125Module`), controller-runtime v0.18.2 with `k8s.io/*` v0.30.x (the versions `casdoor-sso-controller` uses), `controller-gen` from nixpkgs `kubernetes-controller-tools`, `golang.org/x/crypto` (`bcrypt`, `ssh`), NixOS modules, bash stub checks, the `image-e2e` NixOS VM test.

**Spec:** `docs/superpowers/specs/2026-11-16-device-api-design.md`. Beads: epic `librepod-os-2q2`.

## Global Constraints

- Group `os.librepod.org`, version `v1alpha1`, kind `Device`, cluster-scoped, short name `dev`, status subresource; one object per node, named after the Kubernetes Node name (k3s defaults it to the hostname).
- The agent runs as root on image devices only (`imageModules`), with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`, and touches only `devices` (get, list, watch, create), `devices/status` (update, patch), `nodes` (get).
- No listening port: metrics `BindAddress: "0"`, no health probe address, no leader election.
- Agent state lives in `/var/lib/librepod/agent/` (root only, 0700).
- Handled once: a `spec` section is acted on once, and only when its `rev`/`id` is above `status.handled.<section>`; numbers are whole numbers from 1 to 999999999999999; never derived from `metadata.generation` or `resourceVersion`. A rejected answer still counts as handled, with its reason in `status.rejected.<section>`, cleared when that section's next answer is applied.
- The agent creates its `Device` with an empty `spec` and never writes `spec` after that.
- The agent writes `status` at least every 5 minutes (`status.updated`); the updater's status shows in the `Device` within a minute.
- With automatic updates off, nothing ever installs by itself.
- No owner action or recovery may require SSH, kubectl or a console.
- Big bang: no support for the bridge, its ConfigMap or the setup-code Secret anywhere.
- SSH keys: at most 32; each `<type> <base64 starting AAAA> [comment]`, no options.
- Setup code: `status.setupCodeHash` is bcrypt, cost 12, of the 12-character code, uppercase, without dashes.
- Binary built with `CGO_ENABLED=0` and `-s -w`.
- Shell scripts use `pkgs.writeShellApplication` with explicit `runtimeInputs` (CLAUDE.md).
- Commit steps run only when the owner has authorized commits for this run; otherwise stage and report. `docs/superpowers` is gitignored: plan and spec files need `git add -f`.
- `image-e2e` is local-only (KVM, ~1.5 h): tasks edit it, Task 9 runs it.

## Review Focus

1. **The agent restarts between deciding a reboot and rebooting.** Expect the id persisted before `systemctl reboot` runs, so the action never repeats (Task 5, `TestHandledPersistedBeforeExec`).
2. **The API server is unreachable at boot.** Expect the agent to change nothing on the host: no key file render, no heartbeat (Task 3 and Task 6, `TestGetErrorTouchesNothing`).
3. **Someone deletes the `Device`.** Expect it recreated with an empty `spec` and `status.handled` showing the numbers kept on disk (Task 3, `TestRecreatesDeletedDeviceKeepsHandled`).
4. **`status.json` is missing or garbage.** Expect `status.update` omitted and the rest of `status` still written (Task 4, `TestReadStatusMissingOrGarbage`).
5. **The key file was replaced by hand with a symlink.** Expect render to replace the link with a regular file and leave its target alone (Task 6, `TestRenderReplacesSymlink`).

---

### Task 1: SSH on image devices: keys only from `/etc/ssh/authorized_keys.d`, no root login

Bead `librepod-os-2q2.2`. Independent of the agent.

**Files:**
- Modify: `modules/identity/default.nix` (settings; header comment lines 12-16)
- Modify: `pkgs/librepod-install/install.sh:148-149` (final output)
- Modify: `flake.nix` (`image-profiles` and `mk-device` checks)
- Modify: `checks/installer-test.nix`
- Modify: `checks/image-e2e/default.nix` (subtest "without a key: no SSH, the console login works")

**Interfaces:**
- Produces: on image devices sshd reads keys only from `/etc/ssh/authorized_keys.d/%u` and refuses root. Task 6 relies on that file being the only key source.

- [ ] **Step 1: Add the eval assertions**

In `flake.nix`, `image-profiles` (next to the existing asserts on `c`):

```nix
assert !c.services.openssh.authorizedKeysInHomedir;
assert c.services.openssh.settings.PermitRootLogin == "no";
```

In `mk-device`: `assert (mk "lenovo-m710q").config.services.openssh.authorizedKeysInHomedir;` (library devices keep today's behaviour).

- [ ] **Step 2: Run them and see them fail**

Run: `nix build .#checks.x86_64-linux.image-profiles .#checks.x86_64-linux.mk-device`
Expected: FAIL, assertion in `image-profiles`.

- [ ] **Step 3: Implement in `modules/identity/default.nix`**

Set `services.openssh.authorizedKeysInHomedir = false;` and add `PermitRootLogin = lib.mkForce "no";` to the existing `services.openssh.settings`, with a one-line why (root's locked password doesn't stop key logins). In the header comment, the `authorized_keys.d/librepod` entry ends: "(installer, --ssh-key; later the Marketplace, through the OS agent); without it no SSH". Drop the console path to `~librepod/.ssh/authorized_keys`.

- [ ] **Step 4: Installer output**

After the "then open http://…" line in `install.sh`, print `==> no SSH key given: SSH stays off until a key is added in the Marketplace` when `--ssh-key` wasn't passed. In `checks/installer-test.nix`, assert that a run without `--ssh-key` prints `no SSH key given` and a run with one doesn't.

- [ ] **Step 5: Extend the e2e subtest**

In "without a key: no SSH, the console login works", after the existing `pod.fail(by_key…)`:
- copy the test key into `~librepod/.ssh/authorized_keys` (owner `librepod`, 0600, dir 0700) and assert `pod.fail(by_key.format(user="librepod"))`;
- copy it to `/etc/ssh/authorized_keys.d/root` and assert `pod.fail(by_key.format(user="root"))`;
- remove both again.
(Task 6 later replaces the `rm` that opens this subtest.)

- [ ] **Step 6: Run the fast checks**

Run: `nix build .#checks.x86_64-linux.image-profiles .#checks.x86_64-linux.mk-device .#checks.x86_64-linux.installer-test && nix fmt -- --ci`
Expected: all build; formatting clean.

- [ ] **Step 7: Commit**

```bash
git add modules/identity/default.nix pkgs/librepod-install/install.sh flake.nix checks/installer-test.nix checks/image-e2e/default.nix
git commit -m "feat(identity): SSH keys only from authorized_keys.d, no root login on image devices"
```

---

### Task 2: The `Device` API types, the generated CRD, the Go package

Bead `librepod-os-2q2.1` (contract half).

**Files:**
- Create: `pkgs/librepod-os-agent/go.mod`, `go.sum`, `default.nix`
- Create: `pkgs/librepod-os-agent/api/v1alpha1/groupversion_info.go`, `device_types.go`, `zz_generated.deepcopy.go` (generated)
- Create: `pkgs/librepod-os-agent/crd/os.librepod.org_devices.yaml` (generated, committed)
- Test: `pkgs/librepod-os-agent/api/v1alpha1/crd_test.go`
- Modify: `flake.nix` (`packages.x86_64-linux.librepod-os-agent`; checks `os-agent`, `os-agent-generated`)

**Interfaces:**
- Produces, package `github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1`:
  - `GroupVersion = schema.GroupVersion{Group: "os.librepod.org", Version: "v1alpha1"}`, `AddToScheme`.
  - `Device{TypeMeta, ObjectMeta, Spec DeviceSpec, Status DeviceStatus}`, `DeviceList`.
  - `DeviceSpec{Updates *UpdatesSpec "updates"; Install *InstallSpec "install"; Power *PowerSpec "power"; SSHKeys *SSHKeysSpec "sshKeys"}`, all `omitempty`.
  - `UpdatesSpec{Rev int64 "rev"; Channel string "channel"; Auto bool "auto"; Timezone string "timezone"}`
  - `InstallSpec{ID int64 "id"; When string "when"}`, `PowerSpec{ID int64 "id"; Action string "action"}`, `SSHKeysSpec{Rev int64 "rev"; Keys []string "keys"}`
  - `DeviceStatus{Updated *metav1.Time "updated,omitempty"; Handled Handled "handled"; Rejected map[string]string "rejected,omitempty"; Update *apiextensionsv1.JSON "update,omitempty"; SSHKeys []string "sshKeys"; System *SystemStatus "system,omitempty"; SetupCodeHash string "setupCodeHash,omitempty"}`
  - `Handled{Updates int64 "updates"; Install int64 "install"; Power int64 "power"; SSHKeys int64 "sshKeys"}`
  - `SystemStatus{Version string "version"; RootDisk Disk "rootDisk"; DataDisk DataDisk "dataDisk"}`, `Disk{SizeBytes, UsedBytes int64}`, `DataDisk{Present bool "present"; SizeBytes, UsedBytes int64 omitempty}`
  - Package `librepod-os-agent` in `flake.nix`, with `.goModules` (vendor dir) used by later checks.

Plan decision: `status.update` is the updater's `status.json` as a raw JSON object (`apiextensionsv1.JSON`, `+kubebuilder:pruning:PreserveUnknownFields`, `+kubebuilder:validation:Type=object`), as `casdoor-sso-controller` does for its overrides. The updater stays the one owner of that schema.

- [ ] **Step 1: Write the failing CRD test**

`crd_test.go` reads `../../crd/os.librepod.org_devices.yaml` into `apiextensionsv1.CustomResourceDefinition` (`sigs.k8s.io/yaml`) and asserts, in `TestCRDContract`:
- `Spec.Group == "os.librepod.org"`, `Spec.Scope == Cluster`, `Spec.Names.Kind == "Device"`, `Spec.Names.ShortNames == ["dev"]`;
- one version `v1alpha1`, served and stored, with `Subresources.Status != nil`;
- `spec.updates.rev` and `spec.sshKeys.rev`, `spec.install.id`, `spec.power.id`: minimum 1, maximum 999999999999999;
- enums: `spec.updates.channel` = `stable, beta`; `spec.install.when` = `now, tonight`; `spec.power.action` = `reboot, poweroff`;
- `spec.updates.timezone`: pattern `^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$`, maxLength 64;
- `spec.sshKeys.keys`: maxItems 32, items pattern `^[a-z0-9@.-]+ AAAA[A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$`, items maxLength 8192;
- required fields: `updates` {rev, channel, auto, timezone}, `install` {id, when}, `power` {id, action}, `sshKeys` {rev, keys};
- `status.update` has `x-kubernetes-preserve-unknown-fields: true`.

- [ ] **Step 2: Run it to see it fail**

Run: `cd pkgs/librepod-os-agent && nix shell --inputs-from ../.. nixpkgs#go_1_25 -c go test ./api/...`
Expected: FAIL, CRD file missing.

- [ ] **Step 3: Write the types and generate**

`go mod init github.com/librepod/os/pkgs/librepod-os-agent`, `go 1.25.0`; `go get sigs.k8s.io/controller-runtime@v0.18.2 k8s.io/apiextensions-apiserver@v0.30.0 golang.org/x/crypto`, then `go mod tidy`. Write `groupversion_info.go` and `device_types.go` with the markers that produce the contract above (`+kubebuilder:resource:scope=Cluster,shortName=dev`, `+kubebuilder:subresource:status`, `+kubebuilder:validation:items:Pattern`, …). Generate:

```bash
nix shell --inputs-from ../.. nixpkgs#go_1_25 nixpkgs#kubernetes-controller-tools -c sh -c \
  'controller-gen object paths=./api/... && controller-gen crd paths=./api/... output:crd:artifacts:config=crd'
```

- [ ] **Step 4: Run the test to see it pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Package and checks**

`default.nix`: `buildGo125Module { pname = "librepod-os-agent"; version = "0.1.0"; src = ./.; vendorHash = …; env.CGO_ENABLED = 0; ldflags = [ "-s" "-w" ]; meta.mainProgram = "librepod-os-agent"; }`. Get `vendorHash` from the first build with `lib.fakeHash`. In `flake.nix`: `packages.x86_64-linux.librepod-os-agent = callPackage ./pkgs/librepod-os-agent { };`, `checks.os-agent = self.packages.x86_64-linux.librepod-os-agent;` (its `go test` is the check), and `checks.os-agent-generated`: a `runCommand` with `go_1_25`, `kubernetes-controller-tools` and `diffutils` that copies the source, puts `${agent.goModules}` at `vendor`, runs the two `controller-gen` commands with `GOFLAGS=-mod=vendor`, and fails on `diff -ru` against the committed `api/` and `crd/`.

- [ ] **Step 6: Run the checks**

Run: `nix build .#checks.x86_64-linux.os-agent .#checks.x86_64-linux.os-agent-generated && nix fmt -- --ci`
Expected: both build.

- [ ] **Step 7: Commit**

```bash
git add pkgs/librepod-os-agent flake.nix
git commit -m "feat(os-agent): Device API types and generated CRD (os.librepod.org/v1alpha1)"
```

---

### Task 3: The agent runs: it creates its `Device`, keeps state, reports `status.system`

Bead `librepod-os-2q2.1` (agent half).

**Files:**
- Create: `pkgs/librepod-os-agent/main.go`
- Create: `pkgs/librepod-os-agent/internal/state/state.go`, `state_test.go`
- Create: `pkgs/librepod-os-agent/internal/system/system.go`, `system_test.go`
- Create: `pkgs/librepod-os-agent/internal/controller/reconciler.go`, `reconciler_test.go`
- Create: `modules/os-agent/default.nix`
- Modify: `flake.nix` (`nixosModules.os-agent`; `imageModules` after `image-updates`; `image-profiles` asserts)
- Modify: `checks/image-e2e/default.nix` (new subtest after "the k3s node is named after the device")
- Modify: `CLAUDE.md` (Key Module Interactions: one `os-agent` bullet)

**Interfaces:**
- Consumes: Task 2's `v1alpha1` types.
- Produces, package `internal/state`:
  - `type State struct { Handled v1alpha1.Handled "handled"; Rejected map[string]string "rejected,omitempty"; SSHKeys []string "sshKeys" }` (`SSHKeys` nil until adopted, Task 6).
  - `type Store struct { Path string; S State }`; `func Open(path string) (*Store, error)` (missing file → zero `State`); `func (s *Store) Save() error` (temp file, fsync, rename, fsync dir; mode 0600).
  - `func (s *State) Last(section string) int64`; `func (s *State) Accept(section string, n int64)` (sets handled, deletes `Rejected[section]`); `func (s *State) Reject(section string, n int64, why string)` (sets handled, `Rejected[section] = "<section> <rev|id> <n>: <why>"`: `rev` for `updates` and `sshKeys`, `id` for `install` and `power`). Sections: `updates`, `install`, `power`, `sshKeys`.
- Produces, package `internal/system`: `type Paths struct { OSRelease, Root, Data, MountInfo string }`; `func Read(p Paths) v1alpha1.SystemStatus` (version from `IMAGE_VERSION`, `unknown` when absent; `DataDisk.Present` iff `Data` is a mount point in `MountInfo`; sizes from `statfs`).
- Produces, package `internal/controller`:
  - `type Paths struct { StatusJSON, TZDir, AuthorizedKeys, Heartbeat string; System system.Paths }`
  - `type Reconciler struct { Client client.Client; Node string; Store *state.Store; Paths Paths; Run func(args ...string) error; Exec func(action string) error; SetupCodeHash string; Now func() time.Time }` (`Run`, `Exec` and `SetupCodeHash` are used from Tasks 4, 5 and 7).
  - `func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error)`; always `RequeueAfter: 30 * time.Second` on success.
  - `func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error`.
  - Heartbeat file `/var/lib/librepod/agent/status-written`, touched after each successful status write (Task 8 reads it).
- Produces, NixOS: `nixosModules.os-agent`; unit `librepod-os-agent.service`; manifest `services.k3s.manifests.librepod-device-crd`.

Reconcile order, fixed here so later tasks only fill in their step:
1. Get `Device/<Node>`. NotFound → create it (`metadata.name` only) and requeue. Any other error → return it, touching nothing.
2. *(Task 6: adopt SSH keys once.)*
3. *(Task 4: updates and install.)* *(Task 6: SSH keys answer, then render the key file.)*
4. Build `status` (handled and rejected from the store, `system`, *Task 4: update*, *Task 6: sshKeys*, *Task 7: setupCodeHash*). Write it with `Status().Patch(…, client.MergeFrom(orig))` when it differs from the live status, ignoring `updated` and the two `usedBytes`, or when `updated` is 4 minutes old or more. After a successful write, touch the heartbeat.
5. *(Task 5: power, last.)*

Plan decisions (the spec leaves both to the builder): controller tests use controller-runtime's fake client, not envtest, so they run in the Nix sandbox as the package's `checkPhase`; the API server's side (schema, RBAC) is proven in `image-e2e`. "Waits until the CRD is established" is done by exiting and letting systemd restart the agent every 10 s.

`main.go`: node name from `/proc/sys/kernel/hostname`; manager with metrics `BindAddress: "0"`, `HealthProbeBindAddress: "0"`, no leader election, and the cache limited to the own `Device` (`cache.ByObject` with `fields.OneTermEqualSelector("metadata.name", node)`). Before `mgr.Start`, an uncached client gets or creates the `Device`. On any error, including the CRD not being established yet, exit 1: systemd restarts the agent.

- [ ] **Step 1: Write the failing tests**

`state_test.go`: `TestOpenMissingIsZero`, `TestSaveOpenRoundTrip`, `TestSaveLeavesNoTempFilesAndMode0600`, `TestAcceptClearsRejected`, `TestRejectFormats` (expects `Rejected["updates"] == "updates rev 4: the time zone is unknown"`).
`system_test.go`: `TestReadVersion` (`IMAGE_VERSION="0.6.0"` gives `0.6.0`, a missing file gives `unknown`), `TestDataDiskAbsent` (mountinfo fixture without the data path gives `Present == false`), `TestDataDiskPresent` (fixture listing `t.TempDir()` gives `Present == true` and `SizeBytes > 0`).
`reconciler_test.go`, with the controller-runtime fake client and `WithStatusSubresource(&v1alpha1.Device{})`:
- `TestCreatesDeviceWhenMissing`: after Reconcile, `Device/pod-image` exists and its spec is empty.
- `TestRecreatesDeletedDeviceKeepsHandled`: store with `Handled.Install = 7`, no object; two Reconciles give `status.handled.install == 7`.
- `TestStatusWrittenAndHeartbeatTouched`: `status.updated` is set, `status.system.version == "0.6.0"`, and the heartbeat mtime is at or after the test's start.
- `TestUsageOnlyChangeWaitsFourMinutes`: with an injected `Now`, a second Reconcile at +1 min with different used bytes doesn't change `resourceVersion`; at +4 min 1 s it does.
- `TestNeverWritesSpec`: the spec the test set is unchanged after Reconcile.
- `TestGetErrorTouchesNothing`: an interceptor fails `Get`; Reconcile returns the error, and no heartbeat file exists.

- [ ] **Step 2: Run them to see them fail**

Run: `cd pkgs/librepod-os-agent && nix shell --inputs-from ../.. nixpkgs#go_1_25 -c go test ./...`
Expected: FAIL (undefined: `state.Open`, `system.Read`, `controller.Reconciler`).

- [ ] **Step 3: Implement `internal/state`, `internal/system`, `internal/controller`, `main.go`**

As in Interfaces and the reconcile order above. `Now` defaults to `time.Now`.

- [ ] **Step 4: Run the tests to see them pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: The NixOS module and the flake**

`modules/os-agent/default.nix`:
- `systemd.tmpfiles.rules = [ "d /var/lib/librepod/agent 0700 root root -" ]`.
- `services.k3s.manifests.librepod-device-crd.source = ../../pkgs/librepod-os-agent/crd/os.librepod.org_devices.yaml`.
- `systemd.services.librepod-os-agent`: `wantedBy = [ "multi-user.target" ]`, `after = [ "k3s.service" ]`, `unitConfig.StartLimitIntervalSec = 0`, `environment = { KUBECONFIG = "/etc/rancher/k3s/k3s.yaml"; TZDIR = "${pkgs.tzdata}/share/zoneinfo"; }`, `path = [ config.systemd.package ]`, and `serviceConfig = { ExecStart = lib.getExe (pkgs.callPackage ../../pkgs/librepod-os-agent { }); Restart = "always"; RestartSec = "10s"; }`.

Header comment: what it serves, and a link to the spec.

`flake.nix`: `nixosModules.os-agent = ./modules/os-agent;`, added to `imageModules` after `self.nixosModules.image-updates`. In `image-profiles`: `assert c.systemd.services ? librepod-os-agent; assert c.services.k3s.manifests ? librepod-device-crd;`.

- [ ] **Step 6: The e2e subtest**

Subtest "the agent creates the Device; only the UI's role writes its spec":
- wait until `k3s kubectl get dev pod-image -o json | jq -e '.status.updated and .status.system.version == "0.5.0" and .status.system.dataDisk.present'`, with timeout 300;
- apply a ServiceAccount `ui` (namespace `default`), a ClusterRole with `devices` get/list/watch/patch, and a binding;
- as `--as=system:serviceaccount:default:ui`, `patch dev pod-image --type merge -p '{"metadata":{"labels":{"e2e":"1"}}}'` succeeds, and `patch dev pod-image --subresource=status --type merge -p '{"status":{"handled":{"power":9}}}'` fails;
- as admin, each of these patches fails: power `action: halt`; updates `channel: nightly`; an `sshKeys` entry starting `command="x" ssh-ed25519 AAAA…`; 33 keys.

- [ ] **Step 7: `CLAUDE.md`**

One bullet under Key Module Interactions:
- **os-agent:** `librepod-os-agent` (Go, `pkgs/librepod-os-agent`) serves `Device` (`os.librepod.org/v1alpha1`, CRD via `services.k3s.manifests`) on image devices: the Marketplace writes `spec`, the agent writes `status`. Contract: `docs/updates.md`.

- [ ] **Step 8: Run the checks**

Run: `nix build .#checks.x86_64-linux.os-agent .#checks.x86_64-linux.image-profiles && nix fmt -- --ci`
Expected: both build.

- [ ] **Step 9: Commit**

```bash
git add pkgs/librepod-os-agent modules/os-agent flake.nix checks/image-e2e/default.nix CLAUDE.md
git commit -m "feat(os-agent): the agent creates its Device and reports system status"
```

---

### Task 4: Updates through the `Device`; the bridge goes

Bead `librepod-os-2q2.3`.

**Files:**
- Create: `pkgs/librepod-os-agent/internal/updates/updates.go`, `updates_test.go`
- Modify: `pkgs/librepod-os-agent/internal/controller/reconciler.go`, `reconciler_test.go`; `main.go` (`Run`)
- Modify: `modules/image-updates/default.nix` (option `librepod.updates.cli`; drop the bridge service, timer and `bridgeInputs`; header comment)
- Modify: `modules/image-updates/scripts.nix` (drop `bridge`), `modules/image-updates/common.sh` (header comment)
- Delete: `modules/image-updates/bridge.sh`, `checks/image-bridge-test.nix`
- Modify: `flake.nix` (drop the `image-bridge-test` check; assert `!(c.systemd.services ? librepod-update-bridge)`)
- Modify: `modules/os-agent/default.nix` (`path` gains `config.librepod.updates.cli`)
- Modify: `docs/updates.md` (rewritten as the `Device` contract), `README.md:138`
- Modify: `checks/image-e2e/default.nix` (`answer`, `wait_published`, the subtest title)

**Interfaces:**
- Consumes: `state.Store`, `Reconciler.Run`.
- Produces, package `internal/updates`:
  - `func Apply(spec v1alpha1.DeviceSpec, st *state.Store, run func(args ...string) error, tzdir string) error`. It handles `Updates`, then `Install`, and saves the store after each section's decision. If `run` fails, that section's number is not recorded and the error comes back, but a section already recorded stays recorded.
  - `func ReadStatus(path string) *apiextensionsv1.JSON` (nil when the file is missing, isn't JSON, or isn't an object).
  - `func Installing(path string) bool` (`state == "installing"`).
- Produces, NixOS: `options.librepod.updates.cli` (package, `readOnly`, `internal`), set to the updater.

Mapping, carried over from `bridge.sh` unchanged:
- `updates` runs `channel <c>`, then `auto on|off`, then `timezone <z>`, all three.
- `install` runs `install <when>`.
- A time zone that fails the shape check `^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$`, or isn't a regular file under `tzdir`, is rejected with `the time zone is unknown`.
- An install with nothing available is passed through as today.

- [ ] **Step 1: Write the failing tests (ported from `image-bridge-test.nix`)**

`updates_test.go`, with a recording `run` stub and `tzdir` set to `${tzdata}` (`TZDIR` from the environment, falling back to `/etc/zoneinfo`):
- `TestSettingsOncePerRev`: rev 3 `{beta, true, Europe/Minsk}` produces exactly `[channel beta] [auto on] [timezone Europe/Minsk]`, and handled is 3. Again: no calls. Rev 2: no calls, handled stays 3.
- `TestInstallOncePerID`: id 7 `now` produces `[install now]`; again: no calls.
- `TestUnknownZoneRejected`: each of `../../etc/shadow`, `Europe/Minsk; reboot` and `Mars/Olympus` produces no calls, handled equal to its rev, and `Rejected["updates"] == "updates rev <n>: the time zone is unknown"`.
- `TestCLIFailureNotRecorded`: `run` fails on `channel`; handled stays where it was and the error comes back. The next Apply with a working `run` records it.
- `TestSettingsKeptWhenInstallFails`: rev 31 and id 9, `run` failing on `install`: the state file on disk has `updates 31`, `install 8`.
- `TestAppliedAnswerClearsRejection`.
- `TestReadStatusMissingOrGarbage`: missing, `garbage` and `[1]` each give nil; a valid object gives the same JSON.
- `TestInstalling`.

`reconciler_test.go`:
- `TestStatusUpdateMirrorsStatusJSON`.
- `TestRestoredSpecBelowHandledChangesNothing`: store at updates 2, spec rev 1. No calls, and `status.handled.updates == 2`.

- [ ] **Step 2: Run them to see them fail**

Run: `cd pkgs/librepod-os-agent && TZDIR=$(nix build --inputs-from ../.. nixpkgs#tzdata --print-out-paths --no-link)/share/zoneinfo nix shell --inputs-from ../.. nixpkgs#go_1_25 -c go test ./...`
Expected: FAIL (undefined: `updates.Apply`).

- [ ] **Step 3: Implement `internal/updates`, then wire it in**

The reconciler calls `updates.Apply` at step 3 and sets `status.update = updates.ReadStatus(Paths.StatusJSON)` in step 4. `main.go` sets `Run` to `exec.Command("librepod-update", args...)`, with the combined output logged. In `default.nix`, the package's `checkPhase` gets `TZDIR` pointing at `${tzdata}/share/zoneinfo` (add `tzdata` to the arguments).

- [ ] **Step 4: Run the tests to see them pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Remove the bridge, expose the CLI**

Make these changes:
- Delete `bridge.sh` and `checks/image-bridge-test.nix`.
- Drop `bridge` from `scripts.nix`.
- Drop the `librepod-update-bridge` service and timer, and `bridgeInputs`, from `modules/image-updates/default.nix`.
- Add `options.librepod.updates.cli` there, which moves the existing attributes under `config`.
- In `modules/os-agent/default.nix`, add `config.librepod.updates.cli` to `path`.
- In `flake.nix`, remove `image-bridge-test` and add the assert.
- Fix the comments that name the bridge (`common.sh`, `default.nix` headers).

- [ ] **Step 6: Rewrite `docs/updates.md` and `README.md:138`**

The contract is now the `Device`:
- `spec.updates` replaces `settings.json`, `spec.install` replaces `install.json`, and `status.update` replaces `status.json`.
- `status.handled` and `status.rejected.<section>` replace the bridge's `handled` and its `detail` override.
- The UI ClusterRole is `devices` get, list, watch and patch, with nothing on `devices/status`.
- Discovery: no `os.librepod.org` group means no OS features.
- The numbering rule stays: max(own last, `status.handled.<section>`) + 1.
- The states, install and CLI sections stay.

README: one line pointing to the `Device` contract.

- [ ] **Step 7: The e2e helpers**

- `answer(section, value)` patches `k3s kubectl patch dev pod-image --type merge -p {"spec": {section: value}}`, retried up to 300 s.
- `wait_published(cond)` waits on `k3s kubectl get dev pod-image -o json | jq -e '.status.update | <cond>'`, up to 120 s.
- The call sites become `answer("updates", {...})` and `answer("install", {...})`.
- The title "set through the ConfigMap" becomes "set through the Device".
- Move both helpers up next to `wait_ready()`: Tasks 5 and 6 call `answer` from subtests that run before the update ones.
- At the start of "beta offers 0.5.3…" (the channel is set to beta through the CLI there), add the spec's rollback proof: `answer("updates", {"rev": 1, "channel": "stable", "auto": True, "timezone": "UTC"})`, where rev 1 is already handled. Then sleep 60 s and assert `status().settings.channel == "beta"` and `.status.handled.updates == 1`.

- [ ] **Step 8: Run the checks**

Run: `nix build .#checks.x86_64-linux.os-agent .#checks.x86_64-linux.image-profiles .#checks.x86_64-linux.image-updater-test .#checks.x86_64-linux.image-health-test && nix fmt -- --ci`
Expected: all build; `nix flake check --no-build` shows no `image-bridge-test`.

- [ ] **Step 9: Commit**

```bash
git add -A pkgs/librepod-os-agent modules/image-updates modules/os-agent flake.nix docs/updates.md README.md checks/image-e2e/default.nix checks/image-bridge-test.nix
git commit -m "feat(os-agent): updates through the Device; remove the ConfigMap bridge"
```

---

### Task 5: Reboot and power off

Bead `librepod-os-2q2.4`.

**Files:**
- Create: `pkgs/librepod-os-agent/internal/power/power.go`, `power_test.go`
- Modify: `internal/controller/reconciler.go`; `main.go` (`Exec`)
- Modify: `docs/updates.md` (a `spec.power` section)
- Modify: `checks/image-e2e/default.nix` (new subtest after Task 3's)

**Interfaces:**
- Consumes: `state.Store`, `updates.Installing`, `Reconciler.Exec`.
- Produces: `func power.Apply(spec *v1alpha1.PowerSpec, st *state.Store, installing bool, publish func() error, exec func(action string) error) error`.
  - Not fresh: nothing happens.
  - `installing`: rejected with `an update is installing`, then saved.
  - Otherwise, in this order: Accept, Save (on failure, return the error and don't exec), `publish()` (best effort, error logged), then `exec(action)`.

- [ ] **Step 1: Write the failing tests**

- `TestRebootOnce`: id 1 `reboot` execs once with `"reboot"`; the same spec again doesn't exec.
- `TestPoweroff`.
- `TestRefusedWhileInstalling`: no exec, and `Rejected["power"] == "power id 3: an update is installing"`.
- `TestHandledPersistedBeforeExec`: the `exec` stub opens the store file from disk and asserts `handled.power == id`.
- `TestSaveFailureNoExec`: the store path is in a read-only directory; Apply returns an error and exec isn't called.

- [ ] **Step 2: Run them to see them fail**

Run: `cd pkgs/librepod-os-agent && nix shell --inputs-from ../.. nixpkgs#go_1_25 -c go test ./internal/power/...`
Expected: FAIL (undefined: `power.Apply`).

- [ ] **Step 3: Implement and wire in**

The reconciler calls `power.Apply` at step 5, with `installing = updates.Installing(Paths.StatusJSON)`, and `publish` re-running step 4's status write. `main.go` sets `Exec` to `exec.Command("systemctl", action)`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `… go test ./...`. Expected: PASS.

- [ ] **Step 5: The e2e subtest "a reboot from the Device happens once"**

1. Set `n = boots() + 1`, then `answer("power", {"id": 1, "action": "reboot"})`.
2. `up_after(n)`, `wait_ready()`.
3. Wait until `status.handled.power == 1` and `status.updated` is newer than the boot.
4. Sleep 60 s, then assert `boots() == n`.

The spec's "refused while installing" proof is the unit test `TestRefusedWhileInstalling`. Catching the updater mid-install in the VM would need a timing hook the e2e doesn't have.

- [ ] **Step 6: Docs**

In `docs/updates.md`, add `spec.power`: id, action, refused while installing, and that a lost click beats a repeated one.

- [ ] **Step 7: Run the checks, then commit**

Run: `nix build .#checks.x86_64-linux.os-agent && nix fmt -- --ci`. Expected: builds.

```bash
git add pkgs/librepod-os-agent docs/updates.md checks/image-e2e/default.nix
git commit -m "feat(os-agent): reboot and power off as one-shot actions"
```

---

### Task 6: SSH keys: the UI owns the whole list

Bead `librepod-os-2q2.5`. Needs Task 1.

**Files:**
- Create: `pkgs/librepod-os-agent/internal/sshkeys/sshkeys.go`, `sshkeys_test.go`
- Modify: `internal/controller/reconciler.go`, `reconciler_test.go`
- Modify: `docs/updates.md` (`spec.sshKeys`, `status.sshKeys`)
- Modify: `checks/image-e2e/default.nix` (new subtest; "without a key" opens via the `Device`)

**Interfaces:**
- Consumes: `state.Store` (`S.SSHKeys`), `Paths.AuthorizedKeys` (`/etc/ssh/authorized_keys.d/librepod`).
- Produces, package `internal/sshkeys`:
  - `func Validate(keys []string) error`: the first bad key gives `key <i> is not a public key (key type first, no options)`, 1-based. A key is good when `ssh.ParseAuthorizedKey` succeeds with no options and nothing left over, and its second field starts with `AAAA`.
  - `func Adopt(path string) ([]string, error)`: lines of the installer's file, skipping blank lines, `#` lines and lines that fail `Validate`. A missing file gives `[]string{}`.
  - `func Apply(spec *v1alpha1.SSHKeysSpec, st *state.Store) error`: if fresh and valid, Accept and set `S.SSHKeys = keys`; if invalid, Reject with Validate's text (`sshKeys rev 5: key 2 is not …`). Either way, Save.
  - `func Render(path string, keys []string) error`: content is one key per line, each ending in a newline. It writes only when the content differs, as a temp file renamed over the path (mode 0644, owner root), creating the directory with 0755 if needed.

Reconciler: step 2 adopts when `S.SSHKeys == nil`, then saves. Step 3 runs `sshkeys.Apply`, then `sshkeys.Render(Paths.AuthorizedKeys, S.SSHKeys)`; both come after a successful Get. Step 4 sets `status.sshKeys = S.SSHKeys`.

- [ ] **Step 1: Write the failing tests**

- `TestValidate`: accepts ed25519, ECDSA, RSA and `sk-ssh-ed25519@openssh.com` keys, with and without a comment. Rejects `command="x" ssh-ed25519 AAAA…`, `from="1.2.3.4" ssh-…`, `host ssh-ed25519 AAAA…` (a known_hosts line), `junk`, and a key containing `\r`.
- `TestAdoptSkipsCommentsAndBlank`, `TestAdoptMissingFileIsEmpty`.
- `TestApplyReplacesList`.
- `TestApplyRejectsWholeAnswer`: three keys, the second bad. The list is unchanged and `Rejected["sshKeys"] == "sshKeys rev 5: key 2 is not a public key (key type first, no options)"`.
- `TestApplyEmptyListRemovesAll`.
- `TestRenderRewritesHandEdit`, `TestRenderMode0644`.
- `TestRenderReplacesSymlink`: the path is a symlink to another file. Afterwards the path is a regular file and the target is unchanged.

`reconciler_test.go`: extend `TestGetErrorTouchesNothing`. The key file's content and mtime are unchanged.

- [ ] **Step 2: Run them to see them fail**

Run: `cd pkgs/librepod-os-agent && nix shell --inputs-from ../.. nixpkgs#go_1_25 -c go test ./internal/sshkeys/... ./internal/controller/...`
Expected: FAIL (undefined: `sshkeys.Validate`).

- [ ] **Step 3: Implement and wire in**

As above.

- [ ] **Step 4: Run the tests to see them pass**

Run: `… go test ./...`. Expected: PASS.

- [ ] **Step 5: The e2e changes**

New subtest "SSH keys: the installer's key shows; the Device's list replaces it; a hand edit is put back", after Task 5's:
1. Wait until `status.sshKeys` equals `[<snakeOil public key>]`.
2. `ssh-keygen -t ed25519 -N '' -f /root/k2`.
3. `answer("sshKeys", {"rev": 1, "keys": [snakeOil, k2.pub]})`; wait until the file has exactly those two lines.
4. `echo junk >> /etc/ssh/authorized_keys.d/librepod`; wait (timeout 120 s) until it has exactly the two keys again.
5. `by_key` still logs in.

In "without a key: no SSH, the console login works", replace `rm /etc/ssh/authorized_keys.d/librepod` with `answer("sshKeys", {"rev": 2, "keys": []})`, then wait until the file is empty. Task 1's assertions stay.

- [ ] **Step 6: Docs, checks, commit**

In `docs/updates.md`, add `spec.sshKeys` (the whole list, an empty list means no SSH, validation rules) and `status.sshKeys`.

Run: `nix build .#checks.x86_64-linux.os-agent && nix fmt -- --ci`. Expected: builds.

```bash
git add pkgs/librepod-os-agent docs/updates.md checks/image-e2e/default.nix
git commit -m "feat(os-agent): SSH keys from the Device; the UI owns the whole list"
```

---

### Task 7: Setup code as a bcrypt hash; the Secret goes

Bead `librepod-os-2q2.6`.

**Files:**
- Create: `pkgs/librepod-os-agent/internal/setupcode/setupcode.go`, `setupcode_test.go`
- Modify: `main.go` (hash once at start into `Reconciler.SetupCodeHash`), `internal/controller/reconciler.go` (step 4)
- Modify: `modules/onboarding/default.nix`, `modules/onboarding/publish-setup-code.sh`, `checks/onboarding-test.nix`
- Modify: `modules/identity/default.nix` (setup-code comment line), `CLAUDE.md` (onboarding bullet)
- Modify: `docs/updates.md` (`status.setupCodeHash`)
- Modify: `checks/image-e2e/default.nix` (subtest "the sticker's setup code reaches marketplace-ui"; `extraPythonPackages = p: [ p.bcrypt ];`)

**Interfaces:**
- Produces, package `internal/setupcode`:
  - `func Normalize(s string) string`: drops `-`, spaces and newlines, then uppercases.
  - `func Hash(path string) (string, error)`: `""` when the file is missing, otherwise `bcrypt.GenerateFromPassword(Normalize(content), 12)`.
- Reconciler step 4 sets `status.setupCodeHash = r.SetupCodeHash`.

- [ ] **Step 1: Write the failing tests**

- `TestHashVerifies`: with the file `7KQMX3RT9VHC\n`, `bcrypt.CompareHashAndPassword(h, "7KQMX3RT9VHC")` returns nil and `bcrypt.Cost(h) == 12`.
- `TestHashNormalizes`: with the file `7kqm-x3rt-9vhc`, the hash verifies `7KQMX3RT9VHC`.
- `TestHashRejectsOther`.
- `TestHashMissingFileEmpty`.

In `checks/onboarding-test.nix`, scenario 1 keeps its log assertions and replaces the Secret assertion with `[ ! -s "$CALLS_LOG" ]`: kubectl is never called.

- [ ] **Step 2: Run them to see them fail**

Run: `cd pkgs/librepod-os-agent && nix shell --inputs-from ../.. nixpkgs#go_1_25 -c go test ./internal/setupcode/... ; nix build .#checks.x86_64-linux.onboarding-test`
Expected: Go FAIL (undefined: `setupcode.Hash`); onboarding-test FAIL (kubectl called).

- [ ] **Step 3: Implement**

- **Agent:** `internal/setupcode`, plus the `main.go` and reconciler wiring.
- **`publish-setup-code.sh`:** delete the k3s wait and both kubectl lines, and update its header comment to say it logs the code for the console.
- **`modules/onboarding/default.nix`:**
  - drop `after = [ "k3s.service" ]`, `KUBECONFIG`, and `k3s` from `runtimeInputs`
  - set the description to "Log the device setup code for the console"
  - update the header comment to say the OS agent publishes the code's hash in the `Device`
- **`modules/identity`:** the setup-code comment says the OS agent publishes the hash.
- **`CLAUDE.md`:** rewrite the onboarding bullet. The code is logged, with its `#code=` link and a QR code. The agent publishes its bcrypt hash in `Device.status.setupCodeHash`. No Secret. With no file, marketplace-ui mints and logs a code.

- [ ] **Step 4: Run the tests to see them pass**

Run: same as Step 2. Expected: PASS, and `onboarding-test` builds.

- [ ] **Step 5: The e2e subtest**

Rename it to "the sticker's setup code is published as a hash". Keep the 0600 mode assertion and the journal assertion. In place of the Secret:
1. Wait until `.status.setupCodeHash` is non-empty.
2. In the test driver, assert `bcrypt.checkpw(code.replace("-", "").encode(), h.encode())` and `not bcrypt.checkpw(b"AAAAAAAAAAAA", h.encode())`.
3. `pod.succeed("! k3s kubectl get secrets -A -o name | grep -q librepod-setup-code")` and `pod.fail("k3s kubectl get namespace marketplace-ui")`. The second holds because the VM has no network for Flux to deploy the marketplace; drop it if that changes.

- [ ] **Step 6: Docs, checks, commit**

In `docs/updates.md`, add `status.setupCodeHash`: how the UI normalizes and compares the typed code, and that the field is absent without a code.

Run: `nix build .#checks.x86_64-linux.os-agent .#checks.x86_64-linux.onboarding-test && nix fmt -- --ci`. Expected: builds.

```bash
git add pkgs/librepod-os-agent modules/onboarding modules/identity/default.nix checks/onboarding-test.nix checks/image-e2e/default.nix docs/updates.md CLAUDE.md
git commit -m "feat(os-agent): setup code as a bcrypt hash in the Device; drop the Secret"
```

---

### Task 8: The health gate requires the agent

Bead `librepod-os-2q2.7`.

**Files:**
- Modify: `modules/image-updates/health.sh` (`failing_check`)
- Modify: `checks/image-health-test.nix`
- Modify: `docs/updates.md` (the `rolled-back` reasons gain `agent`)

**Interfaces:**
- Consumes: the heartbeat `/var/lib/librepod/agent/status-written` (Task 3) and the unit `librepod-os-agent`.
- Produces: the reason `agent` in the install record, after `k3s`, `sshd` and `node-not-ready` in check order.

- [ ] **Step 1: Write the failing scenarios**

In `image-health-test.nix`:
- Export `LIBREPOD_AGENT_HEARTBEAT=$T/heartbeat` and `LIBREPOD_BOOT_TIME=$(date +%s)`.
- `fresh()` touches the heartbeat. Healthy runs still pass.

New scenarios:
- `fresh; touch $STUBS/down-librepod-os-agent; expect not $H; expect [ "$(reason)" = agent ]; expect not called curl`
- `fresh; touch -d @$((LIBREPOD_BOOT_TIME - 10)) $T/heartbeat; expect not $H; expect [ "$(reason)" = agent ]`
- `fresh; rm $T/heartbeat; expect not $H; expect [ "$(reason)" = agent ]`
- `fresh; touch $STUBS/down-k3s $STUBS/down-librepod-os-agent; expect not $H; expect [ "$(reason)" = k3s ]`

- [ ] **Step 2: Run it to see it fail**

Run: `nix build .#checks.x86_64-linux.image-health-test`
Expected: FAIL at the first new scenario.

- [ ] **Step 3: Implement in `health.sh`**

- Add `AGENT_HEARTBEAT="${LIBREPOD_AGENT_HEARTBEAT:-/var/lib/librepod/agent/status-written}"`.
- Add `BOOT_TIME="${LIBREPOD_BOOT_TIME:-$(sed -n 's/^btime //p' /proc/stat)}"` (`gnused` is already in the scripts' `runtimeInputs`).
- In `failing_check`, after the node check, return `agent` when `systemctl is-active --quiet librepod-os-agent` fails, or when the heartbeat's mtime (`stat -c %Y`, missing counts as 0) is below `BOOT_TIME`.

- [ ] **Step 4: Run it to see it pass**

Run: same as Step 2. Expected: builds, "image-health scenarios passed".

- [ ] **Step 5: Docs, commit**

In `docs/updates.md`, add `agent` to the `rolled-back` reasons: the OS agent didn't report during the new version's first boot.

```bash
git add modules/image-updates checks/image-health-test.nix docs/updates.md
git commit -m "feat(image-updates): a new version's health gate requires the OS agent"
```

---

### Task 9: Docs, full verification

Bead `librepod-os-2q2.11`, and the proof for the whole epic.

**Files:**
- Modify: `docs/superpowers/specs/2026-11-11-ab-image-updates-design.md:467` (the anti-goal's reason)
- Modify: `CLAUDE.md` (drop the `coredns.nix` sentence from the k3s bullet)

- [ ] **Step 1: The two doc fixes**

The anti-goal becomes: "Anything a pod writes reaching the host unvalidated: the Marketplace installs third-party apps, and any pod can reach the host." `CLAUDE.md`'s k3s bullet keeps the pin and `specialArgs` and loses the CoreDNS sentence (no `modules/k3s/coredns.nix` exists).

- [ ] **Step 2: All fast checks**

Run: `nix flake check && nix fmt -- --ci`
Expected: passes, with no `image-bridge-test` among the checks.

- [ ] **Step 3: The VM test**

Run: `nix build .#image-e2e -L` (KVM, about 1.5 h or more)
Expected: "image-e2e: all scenarios passed". Fix and re-run until it passes, and note the store slot size it prints next to the previous run's, since the agent adds to every update download.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git add -f docs/superpowers/specs/2026-11-11-ab-image-updates-design.md
git commit -m "docs: fix stale anti-goal and CoreDNS notes"
```

---

### Task 10: Release: pin the marketplace bootstrap that speaks `Device`

Bead `librepod-os-2q2.9`. **Blocked** until bead `librepod-os-2q2.8` (marketplace repo) has a tagged release. Ask the owner for the tag; don't guess it.

**Files:**
- Modify: `modules/k3s/charts/flux-instance.nix` (`ref`)

- [ ] **Step 1: Bump `ref`**

Set `ref` from `0.11.0` to the marketplace tag the owner names.

- [ ] **Step 2: Check**

Run: `nix build .#checks.x86_64-linux.image-profiles && nix fmt -- --ci`. Expected: builds.

- [ ] **Step 3: Owner's device**

The owner updates their own device to this build and checks, from the UI alone:
- onboarding takes the sticker's code
- the update notice and install now/tonight work
- reboot works
- the SSH key list matches the device

Record the result on bead `librepod-os-2q2.9`.

- [ ] **Step 4: Commit**

```bash
git add modules/k3s/charts/flux-instance.nix
git commit -m "feat(k3s): pin the marketplace bootstrap that speaks Device"
```
