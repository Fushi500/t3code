# Personal fork flow

`personal/main` is upstream T3 Code at a nightly tag plus Darius's own
commits. It replaces `fork/integration-0.1.7`, which had to be rebuilt by hand
for every nightly.

## How it works

1. **One branch for own features.** Every personal change is one commit on
   `personal/main`, listed in `personal/features.tsv` with its exact subject
   and a check.
2. **Rebase on nightly.** `personal/update.sh` fetches `upstream`, takes the
   newest `v*-nightly.*` tag and rebases `personal/main` onto it. A conflict
   aborts the rebase, leaves the branch as it was and tells Cârcel.
3. **Tests and checks.** It runs the tests of the personal features, builds
   the desktop app and the CLI, signs the app with the Apple Development
   identity (so the macOS keychain grant survives updates), and runs every
   check in `features.tsv` against the build. A personal commit that vanished
   in the rebase, or a failed check, stops it.
4. **Install, only when asked.** `--install` (or `--install-only` for the last
   build) waits until no thread runs, moves the current app to
   `~/.t3/app-backups/<time>/`, installs the new one, points `~/.local/bin/t3`
   at the new CLI, starts the app and checks the server answers. If it does
   not, it puts the old app back.

The build has no `app-update.yml`, so the app never replaces itself with a
plain upstream nightly. Updates come only from this script.

## Commands

```sh
cd ~/worktrees/t3code-personal
personal/update.sh                 # rebase, test, build, check. Changes nothing installed.
personal/update.sh --push          # same, then push personal/main
personal/update.sh --install-only  # install the last good build (restarts T3)
```

## Add a feature

1. Commit it on `personal/main` (or cherry-pick it there).
2. Add a line to `features.tsv`: id, the commit subject, a shell check
   (`$T3` is the new CLI, `$APP` the new app, `$ROOT` the repo).
3. Run `personal/update.sh`.

## Needs

Xcode command line tools, Rust (`~/.cargo/bin`), pnpm. The script downloads the
official Node build once, because Homebrew's Node cannot make the CLI binary.
