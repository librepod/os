# OS updates: the ConfigMap contract

An image device (one written by `librepod-install`) updates itself from its
channel, `stable` or `beta`, and needs no k3s for that. The Marketplace only
shows what the device reports and passes on the owner's answers. Library
devices (`lib.mkDevice`) have no updater: the owner bumps the flake pin and
runs `nixos-rebuild switch`.

The two meet in one ConfigMap, `librepod-os/librepod-os-update`, in the OS's
own namespace. A unit on the device, the bridge (`librepod-update-bridge`,
after k3s, every minute), creates the namespace and the ConfigMap if they are
missing, copies the updater's status into it and applies the owner's answers.
The Marketplace UI needs a Role in `librepod-os` that can get and patch that
ConfigMap.

It has three keys. Each side merge-patches only its own, and never applies the
whole ConfigMap:

| key             | written by | holds                                     |
| --------------- | ---------- | ----------------------------------------- |
| `status.json`   | device     | what the updater reports                  |
| `settings.json` | UI         | channel, automatic updates, time zone     |
| `install.json`  | UI         | the owner's click: install now or tonight |

Settings and the click are two keys, so a click right after onboarding cannot
overwrite the settings.

The ConfigMap is only a mailbox. The device keeps its settings, its status and
what it handled on disk (`/var/lib/librepod/updates`, root only), so deleting
or re-creating the ConfigMap never starts an update or replays an answer; the
bridge writes `status.json` back. The node label `librepod.os/version` is
gone: `current` carries the version.

## `status.json` (device → UI)

```json
{
  "current": "0.5.0",
  "available": "0.5.1",
  "downloaded": true,
  "state": "ready",
  "installAt": null,
  "settings": { "channel": "stable", "auto": false, "timezone": "Europe/Minsk" },
  "handled": { "settings": 3, "install": 7 },
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
- `handled`: the last `rev` of `settings.json` and the last `id` of
  `install.json` the bridge dealt with, `0` for none. The bridge adds it.

Until the updater has written its first status (a few minutes after boot), the
key holds only `handled`. While the update source can't be reached, the state
stays as it was, `detail` says so, and `lastCheck` doesn't move. An install the
owner asks for then, with nothing known to install, is dropped.

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
  `sshd` or `node-not-ready` (it never stayed healthy for 2 minutes),
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

## `settings.json` (UI → device)

```json
{ "rev": 3, "channel": "beta", "auto": true, "timezone": "Europe/Minsk" }
```

Onboarding writes it, and so does every later change, all four keys each time.

- `rev`: a whole number from 1 to 999999999999999, written as a plain integer
  (not `3.0` or `1e3`).
- `channel`: `stable` or `beta`. A new channel is checked at once.
- `auto`: `true` or `false`, a JSON boolean. On: every new version installs in
  the night window.
- `timezone`: an IANA zone the device's tzdata has, such as `Europe/Minsk`.
  Onboarding sends the browser's. The updater uses it for the night window
  only.

## `install.json` (UI → device)

```json
{ "id": 7, "when": "now" }
```

- `id`: as `rev`.
- `when`: `now` (install as soon as the download is there) or `tonight` (the
  next night window). It names no version. The owner's click also retries a
  version in `failedVersions`; automatic updates never do.

## Handled once

The bridge acts on a `rev` or `id` once, and only on one above the last it
handled (`status.handled`). Raise it for every new answer: the latest action
wins. Anything else is ignored: not a number, not a whole number from 1, or at
or below the last one handled.

A rollback restores k3s's datastore, this ConfigMap included, so `settings.json`
and `install.json` can go back to a lower `rev` or `id` while `status.handled`
stays higher. The UI numbers its next answer max(its own last, `handled.*`) + 1.

A `rev` or `id` that is above the last but fails validation is rejected, and
counts as handled:

- `settings.json`: `channel` is not `stable` or `beta`; `auto` is not `true` or
  `false`; `timezone` is not a zone the device knows. Nothing from that answer
  is applied.
- `install.json`: `when` is not `now` or `tonight`.

A rejection shows in `status.detail`, in place of the updater's own: `settings
rev 4 rejected: the time zone is unknown`, or `install id 8 rejected: when is
not now or tonight`. It stays until the updater's status moves on (`updated`
changes: a state change, or the next check). After that `handled` still shows
the answer was dealt with, and `settings` shows whether it was applied. Send a
corrected answer under a higher `rev` or `id`.

## The CLI

On the device, as root, with or without k3s. The bridge calls the same
commands, so a change made here shows in `status.settings`.

```
librepod-update status | check | install now|tonight | channel stable|beta | auto on|off | timezone ZONE
```

- `status`: refresh and print the updater's status (the bridge adds
  `handled`).
- `check`: check now, download what it finds, then print the status.
- `install now|tonight`: as `install.json`.
- `channel stable|beta`, `auto on|off`, `timezone ZONE`: as `settings.json`;
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
