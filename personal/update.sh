#!/usr/bin/env bash
# Keep Darius's own T3 Code features on top of upstream nightly.
#
#   personal/update.sh                 rebase on the newest nightly tag, test, build, check
#   personal/update.sh --install       same, then install once no thread is running
#   personal/update.sh --install-only  install the last build, no rebase or build
#   personal/update.sh --tag <tag>     use this upstream tag instead of the newest nightly
#   personal/update.sh --push          also push personal/main (force-with-lease) after a good build
#
# Run it from the personal/main worktree on the Mac. Exit codes: 0 ok,
# 2 rebase conflict (branch left as it was), 3 a test or feature check failed,
# 4 install refused or failed (old app kept). See personal/README.md.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
BRANCH=personal/main
BUILDS="${T3_FORK_BUILDS:-$HOME/.t3/fork-builds}"
APP_NAME="T3 Code (Nightly).app"
INSTALLED_APP="/Applications/$APP_NAME"
NODE_VERSION="${T3_FORK_NODE_VERSION:-v26.12.1}"
LOG_PREFIX="[t3-fork]"
INSTALL=0 INSTALL_ONLY=0 PUSH=0 TAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --install-only) INSTALL_ONLY=1 ;;
    --push) PUSH=1 ;;
    --tag) TAG="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "$LOG_PREFIX unknown option $1" >&2; exit 64 ;;
  esac
  shift
done

say() { echo "$LOG_PREFIX $*"; }
notify() { [ -x "$HOME/.carcel/notify-carcel" ] && "$HOME/.carcel/notify-carcel" "T3 fork: $*" >/dev/null 2>&1 || true; }

# ---------- install ----------
running_threads() {
  # Runs that are still working, read-only from T3's own database.
  sqlite3 -readonly "file:$HOME/.t3/userdata/statev2.sqlite?mode=ro" \
    "select count(*) from orchestration_v2_projection_runs where status in ('running','starting','preparing');" 2>/dev/null || echo 999
}

install_build() {
  local state="$BUILDS/last-build.env"
  [ -f "$state" ] || { say "no build to install ($state missing)"; exit 4; }
  # shellcheck disable=SC1090
  . "$state"
  [ -d "$BUILT_APP" ] && [ -x "$BUILT_CLI" ] || { say "build files are gone"; exit 4; }

  local deadline=$(( $(date +%s) + ${T3_FORK_WAIT_SECONDS:-43200} ))
  while [ "$(running_threads)" != "0" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "threads kept running; not installing"; notify "build $VERSION ready, install skipped because threads kept running"; exit 4
    fi
    sleep 60
  done

  local stamp backup pid
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$HOME/.t3/app-backups/$stamp"
  mkdir -p "$backup"
  cp -p "$HOME/.local/bin/t3" "$backup/t3-shim"

  # Quit the app and wait on its own PID, checked against its full path.
  pid="$(pgrep -x "${APP_NAME%.app}" | head -1 || true)"
  if [ -n "$pid" ] && ! ps -p "$pid" -o command= | grep -qF "$INSTALLED_APP/Contents/MacOS/"; then pid=""; fi
  say "quitting T3 Code${pid:+ (pid $pid)}"
  osascript -e "quit app \"${APP_NAME%.app}\"" >/dev/null 2>&1 || true
  if [ -n "$pid" ]; then
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then say "T3 Code did not quit; nothing changed"; exit 4; fi
  fi

  say "installing $VERSION; the old app moves to $backup"
  local staged="/Applications/.t3-fork-staged.app"
  ditto "$BUILT_APP" "$staged"
  [ -d "$INSTALLED_APP" ] && mv "$INSTALLED_APP" "$backup/$APP_NAME"
  mv "$staged" "$INSTALLED_APP"

  cat >"$HOME/.local/bin/t3" <<SHIM
#!/bin/sh
# Fork build of the t3 CLI ($BRANCH, $COMMIT) on $UPSTREAM_TAG.
# Installed by personal/update.sh on $stamp. Roll back: cp "$backup/t3-shim" ~/.local/bin/t3
export T3CODE_CLI_PATH='$HOME/.local/bin/t3'
export T3CODE_HOME="\${T3CODE_HOME:-$HOME/.t3}"
exec '$BUILT_CLI' "\$@"
SHIM
  chmod +x "$HOME/.local/bin/t3"

  say "starting T3 Code"
  open -a "$INSTALLED_APP"
  for _ in $(seq 1 90); do
    if "$HOME/.local/bin/t3" thread list --project "$HOME/.t3/scratch" >/dev/null 2>&1; then
      say "installed $VERSION; server answers. Old app kept in $backup"
      notify "installed $VERSION ($COMMIT). Old app kept in $backup"
      return 0
    fi
    sleep 2
  done
  say "server did not answer in 3 minutes; rolling back"
  osascript -e "quit app \"${APP_NAME%.app}\"" >/dev/null 2>&1 || true
  sleep 10
  mv "$INSTALLED_APP" "$backup/failed-$APP_NAME"
  mv "$backup/$APP_NAME" "$INSTALLED_APP"
  cp -p "$backup/t3-shim" "$HOME/.local/bin/t3"
  open -a "$INSTALLED_APP"
  notify "install of $VERSION failed, rolled back. Logs in $BUILDS"
  exit 4
}

if [ "$INSTALL_ONLY" = 1 ]; then install_build; exit 0; fi

# ---------- rebase ----------
[ "$(git branch --show-current)" = "$BRANCH" ] || { say "run this on $BRANCH"; exit 64; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { say "worktree has changes; commit or stash first"; exit 64; }

git fetch -q upstream --tags
git fetch -q origin
if [ -z "$TAG" ]; then
  TAG="$(git tag --list 'v*-nightly.*' --sort=-creatordate | head -1)"
fi
say "upstream tag $TAG"
BEFORE="$(git rev-parse HEAD)"
if git merge-base --is-ancestor "$TAG" HEAD; then
  say "already on $TAG"
else
  if ! git rebase -q "$TAG"; then
    git rebase --abort || true
    git reset -q --hard "$BEFORE"
    say "rebase on $TAG hit a conflict; $BRANCH is unchanged"
    notify "rebase on $TAG has a conflict, branch left at ${BEFORE:0:10}. Run personal/update.sh by hand."
    exit 2
  fi
fi
COMMIT="$(git rev-parse --short HEAD)"

# Every personal commit must still be there after the rebase.
missing=0
# Read the log once: piping it into grep -q kills git log early, and pipefail
# then reports a found commit as missing.
subjects="$(git log --format=%s "$TAG..HEAD")"
while IFS=$'\t' read -r id subject _check || [ -n "$id" ]; do
  case "$id" in ''|\#*) continue ;; esac
  if ! grep -qxF "$subject" <<<"$subjects"; then
    say "MISSING after rebase: $id ($subject)"; missing=1
  fi
done <personal/features.tsv
if [ "$missing" = 1 ]; then
  git reset -q --hard "$BEFORE"; notify "a personal commit vanished in the rebase on $TAG"; exit 3
fi

# ---------- test ----------
export PATH="$ROOT/node_modules/.bin:$HOME/.cargo/bin:$PATH"
pnpm install --frozen-lockfile --silent
( cd apps/server && vp test run src/cli/thread.test.ts src/mcp/toolkits/project/handlers.test.ts ) || { notify "tests failed on $TAG"; exit 3; }
( cd packages/client-runtime && vp test run src/state/threadRelationships.test.ts ) || { notify "tests failed on $TAG"; exit 3; }
( cd packages/provider-opencode && vp test run --config ../../vite.config.ts src/server/status.test.ts ) || { notify "tests failed on $TAG"; exit 3; }

# ---------- build ----------
VERSION="${TAG#v}"
OUT="$BUILDS/${VERSION##*.}-$COMMIT"
mkdir -p "$OUT"
# Node from Homebrew has single-executable builds turned off; the CLI needs the official one.
NODE_DIR="$BUILDS/node-official/node-$NODE_VERSION-darwin-arm64"
if [ ! -x "$NODE_DIR/bin/node" ]; then
  mkdir -p "$BUILDS/node-official"
  ( cd "$BUILDS/node-official"
    curl -fsSLO "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-arm64.tar.gz"
    curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" | grep "node-$NODE_VERSION-darwin-arm64.tar.gz" | shasum -a 256 -c
    tar xzf "node-$NODE_VERSION-darwin-arm64.tar.gz" )
fi

restore_versions() { git checkout -q -- apps/server/package.json apps/desktop/package.json apps/web/package.json packages/contracts/package.json; }
trap restore_versions EXIT
node scripts/update-release-package-versions.ts "$VERSION" >/dev/null
say "building the desktop app"
node scripts/build-desktop-artifact.ts --platform mac --target dir --arch arm64 \
  --build-version "$VERSION" --output-dir "$OUT/desktop" >"$OUT/desktop.log" 2>&1 \
  || { say "desktop build failed, see $OUT/desktop.log"; notify "desktop build failed on $TAG"; exit 3; }
BUILT_APP="$OUT/desktop/mac-arm64/$APP_NAME"
say "building the CLI"
PATH="$NODE_DIR/bin:$PATH" node apps/server/scripts/cli.ts build-exe >"$OUT/cli.log" 2>&1 \
  || { say "CLI build failed, see $OUT/cli.log"; exit 3; }
PATH="$NODE_DIR/bin:$PATH" node scripts/build-cli-archive.ts --platform mac --arch arm64 \
  --version "$VERSION-fork.$COMMIT" --output-dir "$OUT/cli" \
  --resource-monitor-dir "$BUILT_APP/Contents/Resources/resource-monitor" >>"$OUT/cli.log" 2>&1 \
  || { say "CLI archive failed, see $OUT/cli.log"; exit 3; }
restore_versions
trap - EXIT
mkdir -p "$HOME/.t3/fork-cli"
tar xzf "$OUT/cli/t3-$VERSION-fork.$COMMIT-darwin-arm64.tar.gz" -C "$HOME/.t3/fork-cli"
BUILT_CLI="$HOME/.t3/fork-cli/t3-$VERSION-fork.$COMMIT-darwin-arm64/t3"

# Sign with a stable identity so macOS keeps the keychain grant across updates.
IDENTITY="${T3_FORK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$BUILT_APP" >/dev/null 2>&1
  codesign --verify --deep --strict "$BUILT_APP"
else
  say "no signing identity; the app stays ad-hoc signed and macOS will ask for keychain access after each update"
fi

# ---------- feature checks ----------
T3="$BUILT_CLI" APP="$BUILT_APP"
export T3 APP ROOT
failed=0
while IFS=$'\t' read -r id _subject check || [ -n "$id" ]; do
  case "$id" in ''|\#*) continue ;; esac
  if bash -c "$check"; then say "ok   $id"; else say "FAIL $id"; failed=1; fi
done <personal/features.tsv
[ "$failed" = 0 ] || { notify "feature check failed on $TAG, see the log"; exit 3; }

cat >"$BUILDS/last-build.env" <<STATE
VERSION='$VERSION'
UPSTREAM_TAG='$TAG'
COMMIT='$COMMIT'
BUILT_APP='$BUILT_APP'
BUILT_CLI='$BUILT_CLI'
STATE
say "build $VERSION-fork.$COMMIT ready"

if [ "$PUSH" = 1 ]; then git push -q --force-with-lease origin "$BRANCH"; say "pushed $BRANCH"; fi
if [ "$INSTALL" = 1 ]; then install_build; fi
