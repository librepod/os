# Agent Instructions

## Build & Check Commands

```bash
# Enter dev shell (provides `just`)
nix-shell

# Run flake checks (evaluates module list for syntax/import errors)
nix flake check

# Build a specific NixOS config (requires a consumer flake)
nixos-rebuild build --flake .#<hostname>

# Format check (nixfmt)
nix fmt -- --check
```

## Architecture

### Flake Structure

- `flake.nix` — Exposes `nixosModules` (the module library), `lib.mkNixosConfig` (helper to create NixOS systems), and `checks` (smoke tests).
- Modules are listed individually in `nixosModules` — there is no auto-discovery.
- `lib.mkNixosConfig` injects `disko.nixosModules.disko` and passes `k3s-nixpkgs` via `specialArgs`.

### Module Conventions

- **Option-based modules** (`frpc`, `users`) define custom options under the `librepod.*` namespace and use `lib.mkIf cfg.enable` to conditionally enable config.
- **Direct-config modules** (`nfs`, `networking`, `ssh`, `nix`, `common`, `dns-server`) configure NixOS options directly with no custom option namespace — they activate on import.
- **Imports-based modules** (`duplicati`, `gobackup`, `gitolite`) are more complex, often defining multiple systemd services.

### Key Module Interactions

- **k3s** — Pinned to a specific nixpkgs commit via `k3s-nixpkgs` input; accepts `k3s-nixpkgs` via `specialArgs`. Imports `coredns.nix` which patches CoreDNS to forward `libre.pod`, `librepod.dev`, and `librepod.local` zones to the host's Unbound.
- **nfs** — Exports `/exports/k3s` (bind-mounted from `/mnt/k3s`) for K3S persistent volumes.
- **duplicati** — Uses a strategy pattern: `default.nix` imports either `per-pvc.nix` or `single.nix`. Has a `services.duplicati.k3sPostBackupReconcile` option supporting `argocd`, `snapshot`, or `fluxcd` reconciliation modes.
- **gobackup** — Self-packages GoBinary (`package.nix`), generates YAML config from NixOS options via `lib.generators.toYAML`, and creates per-model systemd services/timers.
- **gitolite** — Three chained systemd services: `gitolite-init` (keygen + setup) → `gitolite-user-setup` (SSH config + clone) → `gitolite-flux-k8s-secret` (provisions K8S secret for Flux).

### Device Profiles

Device profiles in `devices/` aggregate modules via `imports`. Each device provides `boot.nix` (bootloader/kernel), `hardware-configuration.nix` (generated), and `default.nix` (module composition). Some modules require explicit `import` with arguments (e.g., `k3s` and `common` need `{ inherit config pkgs lib; }`).

## Nix Style

- Uses `nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11"` (release channel, not unstable).
- All packages use `allowUnfree = false`.
- Scripts use `pkgs.writeShellApplication` with explicit `runtimeInputs` rather than `buildInputs` or ad-hoc PATH manipulation.
- `lib.mkDefault` is used for values that consumers should override (e.g., disk device in disko, hostname in networking).


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
