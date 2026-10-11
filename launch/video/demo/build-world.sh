#!/usr/bin/env bash
# Rebuild the demo world from launch/video/demo/ so every take starts from the same state.
#   /Users/dev/shop, /Users/dev/blog       git repos with a short history
#   /work/monotask-home                     MONOTASK_HOME: agent-context.md + empty inbox/
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VIDEO="$(cd "$HERE/.." && pwd)"
DEV=/Users/dev
mkdir -p "$DEV"

commit() { git -c user.name=dev -c user.email=dev@example.com commit -q --date="$2" -m "$1"; }

# shop: 3 commits; the bug (redirect to "/") arrives in the second
rm -rf "$DEV/shop"; mkdir -p "$DEV/shop"; cd "$DEV/shop"; git init -q -b main
cp -r "$HERE/shop/." .
sed -i "s#location: '/',#location: '/dashboard',#" src/auth/callback.js
git add README.md package.json src/server.js src/dashboard.js src/auth/session.js src/auth/google.js src/auth/callback.js test/auth.test.js
GIT_COMMITTER_DATE="2026-09-28T10:02:00" commit "Google sign-in" "2026-09-28T10:02:00"
cp "$HERE/shop/src/auth/callback.js" src/auth/callback.js; git add src/auth/callback.js
GIT_COMMITTER_DATE="2026-10-06T16:40:00" commit "Set session cookie on sign-in" "2026-10-06T16:40:00"
git add src/email test/email-digest.test.js
GIT_COMMITTER_DATE="2026-10-09T11:15:00" commit "Batch order emails into a digest" "2026-10-09T11:15:00"

# blog: 2 commits
rm -rf "$DEV/blog"; mkdir -p "$DEV/blog"; cd "$DEV/blog"; git init -q -b main
cp -r "$HERE/blog/." .
git add README.md package.json build.js templates posts/2026-08-14-small-tools.md
GIT_COMMITTER_DATE="2026-08-14T09:00:00" commit "Static blog generator" "2026-08-14T09:00:00"
git add posts
GIT_COMMITTER_DATE="2026-09-02T09:00:00" commit "Post: one thing at a time" "2026-09-02T09:00:00"

# Monotask demo home
rm -rf /work/monotask-home; mkdir -p /work/monotask-home/inbox
cp "$VIDEO/fixtures/agent-context.md" /work/monotask-home/agent-context.md
cmp "$VIDEO/fixtures/agent-context.md" /work/monotask-home/agent-context.md
echo "world: ok"
