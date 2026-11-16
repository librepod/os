# Device API: the OS and the Marketplace meet in one `Device` object — design

Status: draft, 2026-11-16. Replaces the update ConfigMap bridge
(`docs/updates.md`) and the setup-code Secret before either ships: neither is in
any release tag yet (`v0.5.0-rc.2` included).

## Why

The Marketplace UI should become the place where an owner manages an image
device: updates, reboot, power off, SSH keys, how the disks are doing. The OS
and the UI ship separately, and either can run without the other: a cluster
without LibrePod OS still gets a Marketplace, and a device without a
Marketplace still updates itself.

Today each feature gets its own path. Updates have a ConfigMap mailbox with its
own bridge script, timer, JSON checks in bash and RBAC
(`librepod-os/librepod-os-update`, `modules/image-updates/bridge.sh`). The
setup code is a Secret the OS writes into the app's namespace
(`marketplace-ui/librepod-setup-code`), which hard-codes an app name into the
OS. Reboot, power off and SSH keys would each add another script, key and Role.
The owner's complaint is that cost per feature, not the transport: the
Kubernetes API between the two is fine.

So: one OS-owned API, a `Device` custom resource, served by one agent on the
host. A new capability is one schema field plus one handler.

## Goals

- **One contract.** The OS's whole footprint in the cluster is one CRD and one
  `Device` object per node. No ConfigMaps, no Secrets, no app namespaces.
- **Cheap features.** Adding a capability is a field in the Go types (the CRD
  is generated) and a handler in the agent. No new unit, timer, mailbox key or
  Role.
- **No hard bonds.** The UI finds the OS through API discovery and hides OS
  features when it isn't there. The OS never names an app's namespace or
  service account.
- **Kubernetes enforces the split.** The UI writes `spec`, the agent writes
  `status` (a status subresource), and the API server validates the schema.
- **Transparent SSH access.** The key list in the UI is every key that can log
  in on the shipped config. A colleague who bakes a key in at install time
  shows up in the UI, and the owner can remove it.
- **v1 covers:** updates (all of today's bridge), reboot, power off, SSH keys,
  slow-changing status (version, disks), and the setup code as a hash.

## Non-goals

- **Library devices** (`lib.mkDevice`). They get no CRD and no agent, so the
  UI hides OS features there, as with no OS at all. Same rule as the updater.
- **Live CPU and RAM.** The UI reads them from k3s's bundled metrics-server
  (only traefik and local-storage are disabled), not through the agent.
- **Changing the `librepod` password** from the UI: `librepod-os-8ss.9`, its
  own design.
- **SMART data and backup age:** they need smartd and borgmatic first
  (`librepod-os-faq.8`, `librepod-os-eqi`).
- **Action objects with history** (a `DeviceAction` per reboot, like a Job).
  One-shot actions are fields with an id, as `install.json` is today.
- **Multi-node clusters.** Not built; v1 must not block them (below).

## Anti-goals

- **An owner needing SSH, kubectl or a console** for anything, recovery
  included (owner, 2026-11-16). LibrePod is for non-techy owners. SSH keys are
  for advanced users who know what they're doing, never a tool for routine
  control such as updates. The `kubectl` and console paths below exist for
  those users only; no owner flow depends on them.
- **A listening port on the host.** The agent is a Kubernetes client only.
- **The updater depending on k3s.** The agent is an adapter to the updater's
  CLI and files; the updater keeps working with k3s down.
- **The cluster as the source of truth.** A failed update restores k3s's
  datastore, and with it every `Device`. Truth lives on the host's disk; the
  `Device` is a mailbox and a mirror.
- **An action running twice.** A reboot that runs again after the reboot it
  caused is a boot loop.
- **A pod reaching the host without validation.** The threat is not the
  internet (the Marketplace is reached only on the LAN or over a VPN) but the
  third-party apps the Marketplace installs: the firewall is off, and any pod
  can reach any host port. That is why the transport stays the API server, with
  RBAC deciding who may write a `Device`.

## Approaches

| approach | trade-off | verdict |
| --- | --- | --- |
| ConfigMap mailbox per feature (today) | proven, but every feature costs a script, a key, JSON checks in bash and a Role; ownership of keys is a convention | the cost being removed |
| Node annotations | no CRD to ship; but strings only (JSON in strings, checked by hand again), no spec/status split, `patch nodes` also lets the writer taint or cordon the only node, and every write fans out to all node watchers | fine for a one-line fact, not for commands; rejected |
| HTTP/gRPC API on the host | request/response and live data; but a root-capable port that every pod can reach, plus its own auth | anti-goal; rejected |
| Extend `casdoor-sso-controller` (marketplace repo) | Go and controller-runtime already set up; but it is an unprivileged pod: host actions need privileged + hostPID + hostPath, Flux would update it apart from the OS it drives, and the OS would need the marketplace to manage itself | rejected; copy its toolchain instead |
| **`Device` CRD + Go agent on the host, in this repo** | one generated, validated contract; RBAC split by subresource; ships and rolls back with the image; costs a Go build in this repo | **chosen (owner, 2026-11-16)** |

## Design

### The `Device` object

Group `os.librepod.org`, version `v1alpha1`, kind `Device`, cluster-scoped
(like `Node`), short name `dev`. One object per node, named after the
Kubernetes Node name (k3s defaults it to the hostname; the Node name is the
key). The group follows the marketplace's `marketplace.librepod.org`.

```yaml
apiVersion: os.librepod.org/v1alpha1
kind: Device
metadata:
  name: pod
spec:                         # the UI writes it; the agent never does
  updates:                    # was settings.json
    rev: 3
    channel: stable           # stable | beta
    auto: false
    timezone: Europe/Minsk
  install:                    # was install.json
    id: 7
    when: tonight             # now | tonight
  power:
    id: 2
    action: reboot            # reboot | poweroff
  sshKeys:
    rev: 5
    keys:
      - ssh-ed25519 AAAAC3Nza... owner@laptop
status:                       # the agent writes it; the UI only reads
  updated: "2026-11-16T12:00:05Z"
  handled: { updates: 3, install: 7, power: 2, sshKeys: 5 }
  rejected: {}                # per section, the last rejected answer's reason
  update: { current: 0.6.0, available: null, state: up-to-date, ... }
  sshKeys:
    - ssh-ed25519 AAAAC3Nza... owner@laptop
  system:
    version: 0.6.0
    rootDisk: { sizeBytes: 250000000000, usedBytes: 12000000000 }
    dataDisk: { present: true, sizeBytes: 2000000000000, usedBytes: 410000000000 }
  setupCodeHash: "$2b$12$..."
```

- `spec` sections are independent. The UI merge-patches only the section it
  is answering, never the whole object.
- Every `spec` section is optional. An absent section changes nothing.
- `status.update` carries today's `status.json` fields unchanged (`current`,
  `available`, `downloaded`, `state`, `detail`, `installAt`, `settings`,
  `failedVersions`, `lastCheck`, `updated`; states as in `docs/updates.md`).
  `handled` moves up to `status.handled`.
- `status.updated`: the agent's last write. It writes at least every 5
  minutes, so the UI can tell a silent agent ("not reporting since …").
- `status.rejected.<section>`: why the last answer above `handled` was
  rejected, such as `updates rev 4: the time zone is unknown` or
  `power id 3: an update is installing`. Cleared when that section's next
  answer is applied.

### Who may write what

- **The agent** runs as root on the host with k3s's kubeconfig
  (`/etc/rancher/k3s/k3s.yaml`, as the bridge does). It touches only `devices`
  (get, list, watch, create), `devices/status` (update, patch) and `nodes`
  (get). Staying inside that set is a rule, not just a habit: it is what lets
  per-node credentials replace the admin kubeconfig later without code changes.
- **The UI** ships its own ClusterRole in the marketplace repo: `devices` get,
  list, watch, patch; nothing on `devices/status`. The OS ships no RBAC for it
  and never names its service account.
- **Advanced users with `kubectl`** can `kubectl edit dev <node>`. It goes
  through the same handlers. It is not a recovery path for owners.

### Handled once, and rollback

Unchanged from the bridge (`docs/updates.md`, "Handled once"), applied to every
section:

- Each `spec` section carries a `rev` (desired state: `updates`, `sshKeys`) or
  an `id` (one-shot: `install`, `power`): a whole number from 1. The agent acts
  on a section once, and only when its number is above `status.handled.<section>`.
- The last handled numbers live on the host's disk, in the agent's state
  directory (`/var/lib/librepod/agent/`, root only). `status.handled` mirrors
  them. They are never derived from `metadata.generation` or
  `resourceVersion`: a datastore restore takes those back in time.
- After a rollback restores the datastore, `spec` can hold a lower number than
  `handled`. The agent ignores it; what the host runs stays as it was. The UI
  numbers its next answer max(its own last, `status.handled.<section>`) + 1,
  as today.
- The UI shows what `status` says the device runs (`status.update.settings`,
  `status.sshKeys`), never what `spec` asked for. After a rollback the two can
  differ, and `status` is the truth.
- An answer above `handled` that the agent rejects still counts as handled,
  with the reason in `status.rejected`.

### The agent

- A Go controller-runtime program in this repo, packaged with `buildGoModule`
  and run by a systemd unit as root, `After=k3s.service`, restarting on
  failure. It lives in `imageModules` only.
- Toolchain copied from `casdoor-sso-controller` (marketplace repo): the same
  Go and controller-runtime versions, `controller-gen` to generate the CRD and
  deepcopy from the Go types, envtest for controller tests, the
  `api/v1alpha1` layout.
- The CRD reaches the cluster through k3s's auto-deploy directory
  (`services.k3s.manifests`), like the Flux charts. The agent waits until the
  CRD is established.
- At start, and whenever its object is missing, the agent creates its `Device`
  with an empty `spec`. It never writes `spec` after that.
- It watches its own `Device` (no polling for answers) and also reconciles at
  least every 5 minutes. Each reconcile reads the updater's status, the disks
  and the SSH keys, and writes `status`. The updater's status shows up in the
  `Device` within a minute, as with the bridge.
- It replaces `librepod-update-bridge` (service, timer, `bridge.sh`) and the
  namespace `librepod-os`.

### Updates

The bridge's behavior, unchanged, moved into the agent:

- `spec.updates` (rev, channel, auto, timezone) maps to `librepod-update
  channel|auto|timezone`, all four keys at once, as `settings.json` did.
  `channel` and `when` are enums in the CRD; `timezone` is checked against the
  device's tzdata by the agent, and rejected if unknown.
- `spec.install` (id, when) maps to `librepod-update install now|tonight`.
- `status.update` is the updater's `status.json`.
- The updater, its CLI, its files and its install window don't change. The
  agent rejects only what the bridge rejects and the CRD can't catch (an
  unknown time zone). An install with nothing available behaves as today: the
  updater checks, and reports `up-to-date` when the source has nothing newer.

### The health gate

A new version's health gate (`health.sh`) also requires the agent: its unit is
active and it has written `status.updated` during this boot. The gate's rule is
that a new version must be able to update away from itself. With automatic
updates off, the owner's click reaches the updater only through the agent, so
a release with a broken agent would strand those devices: the owner couldn't
install the fix. The failed check reads `agent` in `status.update.detail` after
the rollback, next to `k3s`, `sshd`, `node-not-ready` and `update-source`
(`docs/updates.md`).

The gate can't help when the control path breaks after a version has passed
it (an agent bug that shows up days later, a corrupt k3s datastore). A device
with automatic updates on heals with the next release. One with them off
stays as it is until the UI works again: with updates off, nothing ever
installs by itself (owner, 2026-11-16). Telling the owner about it (a host-side
heartbeat check and a notification channel) is deferred to its own bead.

### Power

- `spec.power` (id, action: `reboot` | `poweroff`) is a one-shot action.
- The agent writes the id as handled to disk (and `status.handled.power`)
  **before** it calls `systemctl reboot` or `systemctl poweroff`. If it crashed
  in between, the action is lost, never repeated: a lost click beats a boot
  loop.
- Refused while `status.update.state` is `installing`, which includes the new
  version's trial boot until its health gate passes: a reboot there spends a
  boot try and can roll the update back.

### SSH keys

The UI owns the whole list for the `librepod` user (owner, 2026-11-16).

- **Truth on disk:** the agent keeps the applied list in its state directory
  and renders `/etc/ssh/authorized_keys.d/librepod` from it (root-owned, 0644,
  atomic rename). The file stays on root, which updates never write.
- **Adoption:** on its first start, with no list of its own yet, the agent
  takes the keys the installer wrote to that file (`--ssh-key`). They appear in
  `status.sshKeys`, so the UI shows them from day one and can remove them.
- **Changes:** `spec.sshKeys` (rev, keys) replaces the whole list. An empty
  list removes every key: SSH becomes console-only, so the UI asks first.
- **Edits outside the UI are put back:** each reconcile renders the file from
  the agent's list, so a key added by hand disappears. The agent renders only
  after it has read its `Device`: with k3s down, an advanced user's console
  edit holds until the cluster is back.
- **Validation, in the CRD and again in the agent:** each entry is a bare
  public key, `<type> <base64> [comment]`, no options (`command=`, `from=`):
  the CRD pattern requires a key type first and base64 starting `AAAA` second.
  At most 32 keys. The agent parses each key (as the installer does with
  `ssh-keygen -l`, `pkgs/librepod-install/install.sh:55-70`) and rejects the
  whole answer if one fails. Adoption skips the comment and blank lines the
  installer allows.
- **No other way in on image devices** (`modules/identity`):
  - `services.openssh.authorizedKeysInHomedir = false`, so sshd stops reading
    `~librepod/.ssh/authorized_keys`. The file the agent renders becomes the
    only key source.
  - `PermitRootLogin = "no"` (`modules/ssh` sets `yes`). Root's password is
    locked, but a lock doesn't stop key logins. `librepod` has sudo.
  - Someone with root can still open a new way in. Making that tamper-evident
    is dm-verity and Secure Boot (`librepod-os-8ss.7`), not this design.

This hardening doesn't need the agent and can ship first, but it closes the
console path the identity comment documents today (`modules/identity/default.nix:15-16`).
A device installed without `--ssh-key` then has no SSH until the owner adds a
key in the UI.

### Status

Slow-changing facts only; nothing that changes every few seconds goes in a
`Device`:

- `system.version`: the booted image version.
- `system.rootDisk`, `system.dataDisk`: size and use. `dataDisk.present` is
  false when the `librepod-data` partition isn't mounted at `/mnt/k3s`.
- The last boot's result is `status.update.state` (`rolled-back`, with the
  check that failed in `detail`).

### Setup code

The setup code is typed by the owner, not shown: it proves you were there at
install, so nobody else on the LAN claims a new device first. It never changes;
reset-onboarding goes back to it (`librepod-os-rks`).

- `status.setupCodeHash`: a bcrypt hash (cost 12) of the 12-character code,
  uppercase, without dashes. The UI strips dashes and spaces, uppercases, and
  compares. The raw code never leaves the host.
- Absent when `/var/lib/librepod/setup-code` doesn't exist. Without an OS, the
  UI keeps minting and logging its own code, as today.
- `librepod-setup-code` stops creating the `marketplace-ui` namespace and the
  Secret. It keeps logging the code with its `#code=` link and QR code for the
  console, and no longer needs k3s.
- The code has about 59 bits (12 characters out of 31). With bcrypt, guessing
  it offline from the hash isn't practical, so `get` on `devices` is not a
  secret-level permission.

### Discovery and degrading

- The UI checks API discovery for `os.librepod.org/v1alpha1` `devices`:
  - **No group:** no LibrePod OS. The OS features stay hidden.
  - **Group, no `Device` yet:** the agent is starting.
  - **`status.updated` older than ~10 minutes:** the agent isn't reporting.
- The UI lists `Device` objects; it never guesses a name.

### Versioning

- `v1alpha1` until the UI ships against it, then `v1beta1`.
- Once the UI ships, changes are additive: new optional fields only, no renames
  or removals without a new version. A device with automatic updates off can
  stay on an old image for months, so the UI must handle an older `Device`
  (missing fields) and the agent an older CRD (its new fields pruned).

### What goes away

- `librepod-update-bridge`: unit, timer, `bridge.sh`, the `librepod-os`
  namespace and ConfigMap, `checks/image-bridge-test.nix` (its cases move to
  the agent's test).
- `docs/updates.md` becomes the `Device` contract for the UI side; the
  updater's states and install rules stay in it.
- The setup-code Secret and its namespace creation (`modules/onboarding`).
- `librepod-os-rks.5` and `librepod-os-8ss.18` are superseded.

### Multi-node (not built; v1 must not block it)

Speculated with the owner on 2026-11-16, for a future "add a LibrePod node":

- **What fits as is.** One `Device` per node, named after the Node, served by
  its own agent. A device that joins another cluster recreates its `Device`
  there from its disk. Joining is a one-shot action on the new device's own
  `Device`:
  - The existing cluster's UI mints a short-lived k3s bootstrap token through
    the API.
  - The owner pastes it into the new device's UI.
  - The new device's agent writes the k3s settings to disk and restarts k3s
    as an agent of the existing cluster. Its own cluster is thrown away.
- **What v1 does now:** names each `Device` after the Node, and keeps the
  agent inside the RBAC set above.
- **What a multi-node phase adds:** per-node credentials for the agents
  (workers have no admin kubeconfig), and a `ValidatingAdmissionPolicy` that
  lets a node write only the `Device` named after it. Optionally an
  ownerReference to the Node, so removing a node removes its `Device`.
- **What breaks elsewhere:**
  - CRD skew: only servers auto-deploy the CRD, so the server's version wins.
    Servers update first.
  - The updater's datastore snapshot and rollback assume one node is the whole
    cluster.
  - Every node installs in the same night window. They need one-at-a-time
    installs with a Lease and a drain.
  - Storage: the nfs-provisioner mounts `127.0.0.1:/exports/k3s`, so a volume
    lives on one node.
  - A second server, for HA, means moving from SQLite to etcd.

## Proof

A NixOS VM check over the image stack, with k3s (the existing
`checks/image-*` style):

1. On boot, the CRD is established and the agent creates `Device/<node>`.
   `status.system`, `status.update` and `status.updated` are filled in.
2. A UI-like client limited to the UI's ClusterRole can patch `spec`, but is
   refused on `devices/status`. The API server refuses a bad enum, a key with
   options, and 33 keys.
3. Updates: every case `checks/image-bridge-test.nix` covers today passes
   against `spec.updates` and `spec.install`: applied once, rejected with a
   reason, ignored at or below `handled`.
4. Power: `spec.power` reboot reboots the VM exactly once; after the reboot,
   `status.handled.power` holds the id and no second reboot follows. Refused
   while the state is `installing`.
5. SSH keys: installer keys show in `status.sshKeys`. A new list replaces the
   file. A hand edit is put back on the next reconcile. With
   `authorizedKeysInHomedir = false`, a key in `~librepod/.ssh` doesn't log in,
   and root can't log in with a key.
6. Setup code: `status.setupCodeHash` verifies the code with bcrypt and rejects
   another; no Secret and no `marketplace-ui` namespace exist.
7. Rollback: restore an older datastore copy (spec numbers below `handled`).
   The agent changes nothing on the host, and `status` shows the host's truth.

## Our calls (for review)

- **Cluster-scoped, named after the Node**, like `Node` itself, so the OS needs
  no namespace.
- **The agent never writes `spec`.** Installer keys reach the UI through
  `status.sshKeys`, and the UI edits from `status`. That matches Kubernetes
  practice and keeps one rollback rule (`handled`) for every section, instead
  of the "rewrite spec from disk after a rollback" special case discussed
  earlier.
- **bcrypt for the setup code**, over argon2id: the UI verifies it in plain JS
  (`bcryptjs`) with no native module, and 59 bits behind cost 12 is out of
  reach.
- **Power is refused during `installing`**, trial boot included.
- **The health gate requires the agent**, from the gate's own rule that a
  new version must be able to update away from itself.
- **A lost power click beats a repeated one:** handled is persisted before the
  action.
- **Edits to the key file are reverted only after a successful read of the
  `Device`**, which keeps the console break-glass path when k3s is down.
- **`status.rejected` per section**, replacing the bridge's habit of
  overwriting the updater's `detail`.
- **Up to 32 SSH keys.**

## Left to the builder

- Package layout and names (`pkgs/librepod-os-agent` or similar), and whether
  the generated CRD YAML is committed (casdoor's way, with a check that it is
  current) or generated at build time.
- Running envtest in the Nix sandbox, or keeping controller tests outside
  `nix flake check` and relying on the VM check.
- How the agent sees the updater's status change in time (inotify on
  `status.json`, or reading it every 30 s): within a minute is the bar.
- Binary size: build with `CGO_ENABLED=0` and `-s -w`. The store slot is 8G
  but every MiB is downloaded on every update (`modules/onboarding` already
  avoids `pkgs.kubectl` for 60 MiB).
- Exact field names inside `status.system`.

## Risks

- **Big bang, OS and UI together.** There are no live devices besides the
  owner's own (owner, 2026-11-16), so there's no transition period: no support
  for the bridge or the Secret on either side, and v0.5.0 can ship before or
  after this lands. The marketplace side (the ClusterRole, a `Device` client,
  the hash check, the update, power and SSH key screens) is built in step in
  the marketplace repo. The OS release that ships the agent waits for that
  marketplace release and bumps the bootstrap pin
  (`modules/k3s/charts/flux-instance.nix`, `ref`), as `librepod-os-rks.4` did
  for the Secret. Otherwise the UI on a new device mints its own code, and the
  sticker's code doesn't work.
- **`patch devices` is root.** Writing `spec.sshKeys` lets you log in as
  `librepod`, and `librepod` has sudo with the generic password `librepod`
  until `librepod-os-8ss.9` lets the owner change it. So only the UI gets that
  permission. The UI's service account is already about cluster-admin through
  Flux (it creates HelmReleases), and cluster-admin is root on the node anyway,
  so this adds no new tier, but it should be written down as one.
- **SSH lockout.** After the hardening, a device installed without `--ssh-key`
  has no SSH until the UI adds a key. That is intended, but the installer's
  output should say so.
- **A Go toolchain in an all-Nix-and-bash repo:** a vendor hash to bump with
  dependency updates, and a review surface the shell scripts didn't have.
