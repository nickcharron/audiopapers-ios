#!/usr/bin/env bash
# Starts a release: bumps the version in project.yml, commits, and tags this repo (v<version>) and
# the audiopapers commit its core comes from (ios-<version>), and pushes both. Both repos have to
# be committed and in step with GitHub first, so the tags mark exactly what gets built. Then, on a
# Mac with both repos at those tags: xcodegen generate, and Product > Archive in Xcode.
#
#   scripts/release.sh 0.2
set -euo pipefail
version="${1:?Usage: scripts/release.sh <version, like 0.2>}"
cd "$(dirname "$0")/.."
core="${AUDIOPAPERS_REPO:-../audiopapers}"

for repo in . "$core"; do
    if [ -n "$(git -C "$repo" status --porcelain)" ]; then
        echo "$repo has uncommitted changes. Commit or stash them first." >&2
        exit 1
    fi
    git -C "$repo" fetch -q origin
    if [ "$(git -C "$repo" rev-parse HEAD)" != "$(git -C "$repo" rev-parse '@{u}')" ]; then
        echo "$repo isn't in step with GitHub. Pull or push first." >&2
        exit 1
    fi
done
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    echo "v$version already exists." >&2
    exit 1
fi
if git -C "$core" rev-parse -q --verify "refs/tags/ios-$version" >/dev/null; then
    echo "ios-$version already exists in $core." >&2
    exit 1
fi

build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"$/\1/p' project.yml)"
# Written to a copy and moved back, which works with both macOS's and Linux's sed.
sed -e "s/^\( *\)MARKETING_VERSION: \".*\"$/\1MARKETING_VERSION: \"$version\"/" \
    -e "s/^\( *\)CURRENT_PROJECT_VERSION: \"$build\"$/\1CURRENT_PROJECT_VERSION: \"$((build + 1))\"/" \
    project.yml > project.yml.new
mv project.yml.new project.yml

git commit -q -m "Release $version" project.yml
git tag -a "v$version" -m "iOS $version"
git -C "$core" tag -a "ios-$version" -m "The core in iOS $version"
git push -q origin HEAD "v$version"
git -C "$core" push -q origin "ios-$version"

echo "Tagged $version (core $(git -C "$core" rev-parse --short HEAD))."
echo "Now on a Mac, with both repos at those tags: xcodegen generate, then Product > Archive in Xcode."
