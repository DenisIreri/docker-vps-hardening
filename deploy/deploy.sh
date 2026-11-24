#!/usr/bin/env bash
# Deploy a tagged release on the server, by hand.
#
#   ./deploy/deploy.sh v1.4.2
#
# - Pulls from private Git with a read-only deploy key (see docs/deploy-keys.md),
#   so a compromised server cannot push code back.
# - Deploys tags only, never a moving branch, so you always know what is running.
# - A person runs it. CI can build and test, but going live is a deliberate step.
# - Checks health afterwards and prints the command to roll back.

set -euo pipefail

TAG="${1:-}"
APP_DIR="${APP_DIR:-/opt/app}"
COMPOSE_DIR="${COMPOSE_DIR:-$APP_DIR/compose}"

if [[ -z "$TAG" ]]; then
  echo "Usage: HEALTH_URL=https://app.example.com/ $0 <tag>   e.g. $0 v1.4.2" >&2
  exit 2
fi
if [[ -z "${HEALTH_URL:-}" ]]; then
  echo "Set HEALTH_URL to a URL that returns 200 when the app is up." >&2
  exit 2
fi

cd "$APP_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree on the server has local changes. Refusing to deploy over them:" >&2
  git status --short >&2
  exit 1
fi

# What is running now: its tag if it has one, otherwise the commit.
previous="$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD)"
git fetch --tags --prune origin

# Tags, or an exact commit for rollbacks. Never a branch name: branches move.
if git show-ref -q --verify "refs/tags/$TAG"; then
  target="refs/tags/$TAG"
elif [[ "$TAG" =~ ^[0-9a-f]{7,40}$ ]] && git rev-parse -q --verify "$TAG^{commit}" >/dev/null; then
  target="$TAG"
else
  echo "$TAG is not a tag or commit on the remote." >&2
  exit 1
fi

echo "Deploying $TAG (currently running $previous)"
git -c advice.detachedHead=false checkout --detach "$target"

cd "$COMPOSE_DIR"
docker compose pull --quiet
docker compose up -d --build --remove-orphans

echo "Waiting for $HEALTH_URL ..."
for _ in $(seq 1 30); do
  if curl -fsSk --max-time 5 "$HEALTH_URL" >/dev/null; then
    echo "Healthy. $TAG is live."
    echo "Roll back with: $0 $previous"
    exit 0
  fi
  sleep 2
done

echo "Health check failed after 60 s. Roll back with: $0 $previous" >&2
exit 1
