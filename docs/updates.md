# OS updates: the Device contract

An image device (one written by `librepod-install`) updates itself from its
channel, `stable` or `beta`, and needs no k3s for that. The Marketplace only
shows what the device reports and passes on the owner's answers. Library
devices (`lib.mkDevice`) have no updater: the owner bumps the flake pin and
runs `nixos-rebuild switch`.

The two meet in one cluster-scoped object per device, `Device`
(`os.librepod.org/v1alpha1`, short name `dev`), named after the Kubernetes Node.
The OS agent (`librepod-os-agent`, on the device, after k3s) creates it with an
empty `spec`, and never writes `spec` after that. The CRD ships with the OS
(k3s's auto-deploy directory). **Discovery:** no `os.librepod.org` group means
no OS features.

- `spec`: the owner's answers, written by the Marketplace UI.
- `status`: what the device reports, written only by the agent. The agent
  writes it at least every 5 minutes (`status.updated`); the updater's status
  shows in it within a minute.

The UI's ClusterRole: `devices` get, list, watch and patch, and nothing on
`devices/status`.

The `Device` is only a mailbox. The device keeps what it handled on disk
(`/var/lib/librepod/agent`, root only), so deleting or re-creating the `Device`
never starts an update or replays an answer: the agent re-creates it with an
empty `spec` and `status.handled` as it was.

## `status` (device → UI)

| field               | holds                                                                  |
| ------------------- | ---------------------------------------------------------------------- |
| `updated`           | when the agent last wrote `status`                                     |
| `handled`           | `{updates, install, power, sshKeys}`: the last `rev` or `id` acted on, `0` for none |
| `rejected`          | per section, why the last answer was refused; cleared when that section's next answer is applied |
| `update`            | the updater's status, below                                            |
| `system`            | `version`, `rootDisk`, `dataDisk` (`present`, sizes in bytes)          |
| `sshKeys`           | the public keys that can log in, below                                 |
| `setupCodeHash`     | bcrypt of the setup code, below                                        |

### `status.update`

```json
{
  "current": "0.5.0",
  "available": "0.5.1",
  "downloaded": true,
  "state": "ready",
  "installAt": null,
  "settings": { "channel": "stable", "auto": false, "timezone": "Europe/Minsk" },
  "failedVersions": [],
  "lastCheck": "2026-11-13T12:00:00Z",
  "updated": "2026-11-13T12:00:05Z",
  "detail": "0.5.1 is ready to install"
}
```

- `current`: the booted version, plain `X.Y.Z`.
- `available`: the newest version on the channel when it is above `current`,
  else `null`. A device never moves to a lower version.
- `downloaded`: `available` is already on the device, so installing is a
  reboot.
- `state`, `detail`: below. `detail` is for people.
- `installAt`: while `state` is `scheduled`, when the install starts, in the
  owner's time zone with an offset (`2026-11-14T02:00:00+03:00`). Otherwise
  `null`.
- `settings`: what the device runs with now, whoever changed it (the UI or the
  CLI). Until onboarding sets them: `stable`, `false`, `UTC`.
- `failedVersions`: versions that failed here. Automatic updates skip them;
  the owner can still install one, so the UI can show an `available` that is
  in the list as "failed, try again".
- `lastCheck`: the last successful check, UTC (`2026-11-13T12:00:00Z`, as is
  `updated`), or `null` before the first.
- `updated`: when any other field of the updater's status last changed, UTC.
  A check moves it, through `lastCheck`.

The updater owns this schema; the agent copies its `status.json` verbatim, and
leaves `update` out until the updater has written one (a few minutes after
boot). While the update source can't be reached, the state stays as it was,
`detail` says so, and `lastCheck` doesn't move. An install the owner asks for
then, with nothing known to install, is dropped.

### States

| state         | meaning                                                                |
| ------------- | ---------------------------------------------------------------------- |
| `up-to-date`  | nothing newer than `current` on the channel                            |
| `downloading` | `available` is being downloaded; a check starts it at once             |
| `ready`       | downloaded, waiting for the owner's answer                             |
| `scheduled`   | installs in the night window, at `installAt`                           |
| `installing`  | stopping k3s, copying its data, writing the version, rebooting; it stays through the new version's first boot, until that version passes its health gate |
| `done`        | the new version passed its health gate; `detail` says `updated to X`   |
| `rolled-back` | the new version failed its health gate, and the old one is back        |
| `failed`      | the install did not happen (below); the old version still runs         |

- The night window is 02:00-05:00 in `settings.timezone`; 05:00 is out.
- A newer version's download replaces an older one. An install takes the
  newest version when it starts, not the one the owner saw.
- `scheduled` is for an `available` the owner asked to install `tonight`, or
  for any `available` that is not in `failedVersions` while `settings.auto` is
  on. A `tonight` with nothing to install is dropped when the window comes.
- `done`, `rolled-back` and `failed` stay until the next install starts or a
  check finds a version that is not in `failedVersions`. A check that finds
  nothing new leaves them. An install the owner asked for goes to
  `up-to-date` when the source has nothing newer.
- `rolled-back`: the version is now in `failedVersions`, and k3s's data is as
  it was before the install. `detail` names the check that failed last: `k3s`,
  `sshd`, `node-not-ready` or `agent` (the OS agent did not report during the
  new version's first boot; the check never stayed healthy for 2 minutes),
  `update-source` (healthy, but the channel's signed `SHA256SUMS` could not be
  fetched and verified, so the new version could not update itself), or `did
  not finish` (a panic, a hang or a power cut).
- `failed`, with `detail` saying which: the download did not finish; the
  install stopped (k3s runs again, and the version is in `failedVersions`); a
  power cut interrupted it before the new version was written (nothing
  changed, and the version is not in the list); k3s's data could not be
  restored; or the record of the install in flight was unreadable.
- A download that did not finish is tried again at the next check (at boot,
  every 6 hours, `check`, or a new channel) or when the owner asks to install.
  Until then the state stays `failed`. A newer version downloads as usual.

### `status.setupCodeHash`

The sticker's setup code as a bcrypt hash (cost 12). The UI normalizes what the
owner typed (uppercase, no dashes or spaces: `7kqm-x3rt-9vhc` becomes
`7KQMX3RT9VHC`) and compares it with the hash. The field is absent on a device
without a code: the Marketplace then mints and logs its own. The code itself is
never in the cluster.

## `spec` (UI → device)

Four sections. Write a whole section each time, never part of one.

```yaml
spec:
  updates: { rev: 3, channel: beta, auto: true, timezone: Europe/Minsk }
  install: { id: 7, when: now }
```

### `spec.updates`

Onboarding writes it, and so does every later change, all four fields each time.

- `rev`: a whole number from 1 to 999999999999999.
- `channel`: `stable` or `beta`. A new channel is checked at once.
- `auto`: on, every new version installs in the night window.
- `timezone`: an IANA zone the device's tzdata has, such as `Europe/Minsk`.
  Onboarding sends the browser's. The updater uses it for the night window
  only.

### `spec.install`

- `id`: as `rev`.
- `when`: `now` (install as soon as the download is there) or `tonight` (the
  next night window). It names no version. The owner's click also retries a
  version in `failedVersions`; automatic updates never do. With automatic
  updates off, nothing installs by itself.

### `spec.power`

```yaml
spec:
  power: { id: 1, action: reboot }
```

- `id`: as `rev`.
- `action`: `reboot` or `poweroff`.
- Refused while an update is installing: `status.rejected.power` says
  `an update is installing`, and the answer counts as handled.
- The agent saves the `id` before it acts, so a restart in between never
  repeats it. A lost click beats a repeated one: if the device did not go down,
  send a new `id`.

### `spec.sshKeys`

```yaml
spec:
  sshKeys: { rev: 2, keys: ["ssh-ed25519 AAAA... me@laptop"] }
```

The whole list, each time: the keys that can log in as `librepod` over SSH
(root never can). An empty list means no SSH. At most 32 keys, each
`<type> <base64 starting AAAA> [comment]` on one line, with no options. One bad
key rejects the whole answer: `status.rejected.sshKeys` says `key 2 is not a
public key (key type first, no options)`, counting from 1.

The agent adopts the installer's keys (`--ssh-key`) once, at its first run,
and from then on the UI's list is the truth: the agent puts the file sshd reads
(`/etc/ssh/authorized_keys.d/librepod`) back within a minute if it was edited
by hand. `status.sshKeys` is the list now in force (the adopted one until the
first answer).

## Handled once

The agent acts on a section once, and only when its `rev` or `id` is above
`status.handled.<section>`. Raise it for every new answer: the latest action
wins. Anything else is ignored. The agent keeps the numbers on disk, so they
are never derived from `metadata.generation` or `resourceVersion`.

A rollback restores k3s's datastore, the `Device` included, so `spec` can go
back to a lower `rev` or `id` while `status.handled` stays higher; the agent
changes nothing for it. The UI numbers its next answer max(its own last,
`status.handled.<section>`) + 1.

A `rev` or `id` that is above the last but fails validation is rejected, and
counts as handled, with the reason in `status.rejected.<section>`:

- `updates`: `the time zone is unknown` (the schema refuses a bad channel).
  Nothing from that answer is applied.
- `install`: `when is not now or tonight`.

For example `updates rev 4: the time zone is unknown`. Send a corrected answer
under a higher number.

## The CLI

On the device, as root, with or without k3s. The agent calls the same
commands, so a change made here shows in `status.settings`.

```
librepod-update status | check | install now|tonight | channel stable|beta | auto on|off | timezone ZONE
```

- `status`: refresh and print the updater's status.
- `check`: check now, download what it finds, then print the status.
- `install now|tonight`: as `spec.install`.
- `channel stable|beta`, `auto on|off`, `timezone ZONE`: as `spec.updates`;
  `ZONE` is a name such as `Europe/Minsk`.

## The install

A version is downloaded into the spare slot as soon as it is found. To install
it, the updater records what it is doing, stops k3s, copies k3s's datastore,
writes the version as the next boot entry and reboots. The new version boots
with a limited number of tries. Its health gate (k3s and sshd active, the node
Ready, all of it stable for 2 minutes, then the channel's signed `SHA256SUMS`
fetched and verified) decides within 15 minutes. If it passes, the boot is
blessed and the status moves to `done`. If it fails, the old version boots
again, and before k3s starts, a fallback unit puts the datastore back.
