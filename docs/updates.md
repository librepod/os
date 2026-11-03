# OS updates: the ConfigMap contract

Each device has a ConfigMap `librepod-os/<hostname>`. The Marketplace writes
`spec.json`, and the device writes `status.json`.

The ConfigMap is only a mailbox. The device keeps its own record on disk
(`/var/lib/librepod`): the last request it handled, and the versions whose
trial failed. Deleting or re-creating the ConfigMap never starts an update.

## `spec.json` (Marketplace → device)

```json
{ "requestId": 7, "desiredVersion": "v0.4.0", "apply": "now" }
```

- `requestId`: an integer, starting at 1. Raise it for every new request,
  for example on each click on Update. The device acts on each `requestId`
  once, and ignores any `requestId` at or below the last one it handled.
- `desiredVersion`: a release tag, `vX.Y.Z`.
- `apply: "now"`: the owner asked. The device applies any tag at once,
  including a downgrade or a version that failed before.
- Without `apply: "now"` the update is unattended and needs
  `"policy": { "unattended": true, "window": "22:00-06:00" }` (device clock;
  the window may cross midnight). The device waits for the window, takes
  upgrades only, and never retries a version whose trial failed on it.

## `status.json` (device → Marketplace)

```json
{
  "observedRequestId": 7,
  "currentVersion": "v0.4.0",
  "state": "done",
  "lastTransition": "2026-11-03T12:00:00Z",
  "detail": "update to v0.4.0 verified healthy"
}
```

- `observedRequestId`: the last request the device handled. If it is below
  the spec's `requestId`, the request is still waiting: for its window, or
  for the next poll (every 5 minutes).
- `currentVersion`: the tag of the booted system. The node label
  `librepod.os/version` carries it too.
- `state` (the device writes it only when something happens, so a final
  state stays until the next request):

  | state         | meaning                                                   |
  | ------------- | --------------------------------------------------------- |
  | `building`    | building the requested version                            |
  | `verifying`   | rebooting into it once (a trial), health checks running   |
  | `done`        | the request is fulfilled (or the device was already on it) |
  | `rolled_back` | the trial boot failed; the device is back on the old version |
  | `failed`      | the build failed, or the trial boot could not be set up   |
  | `rejected`    | the request was refused; `detail` says why                |
  | `idle`        | a power cut stopped the update before its trial; cleared  |

## The trial boot

The device builds the new version beside the running one and boots it once.
The old version stays the boot default until the new one passes its health
checks (k3s, sshd, node Ready), so any failure — a panic, a hang, a power
cut, failed checks — lands back on the old version at the next boot.
`/etc/nixos` takes the new pin only once the update commits.
