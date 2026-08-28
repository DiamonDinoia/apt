#!/bin/bash
# Mirror the newest Compiler Explorer gcc-trunk nightly into this repository's
# `mirror` release, so the publisher is downloaded from exactly once per version
# and every install, test and rebuild pulls from GitHub instead.
#
# GCC is GPL and may be redistributed. Compiler Explorer pays for its own S3
# egress, which is the whole reason this file exists: the alternative pins their
# bucket in every package and spends their money on every install.
#
# Self-contained: creates the release on first run. Needs GH_TOKEN.
set -euo pipefail

repo=${GITHUB_REPOSITORY:-DiamonDinoia/apt}
bucket='https://s3.amazonaws.com/compiler-explorer'
keep=2

gh release view mirror --repo "$repo" >/dev/null 2>&1 ||
    gh release create mirror --repo "$repo" --title "payload mirror" --notes \
        "Upstream payloads re-hosted under a licence that permits it, so the
publisher is downloaded from once per version. Do not delete."

listing=$(curl -fsS "$bucket/?list-type=2&prefix=opt/gcc-trunk-")
# A truncated listing is ordered oldest-first, so the last key of one page
# would silently pin a stale build forever.
grep -F '<IsTruncated>true' <<<"$listing" >/dev/null &&
    { echo "FAIL  S3 listing truncated; paginate before trusting it"; exit 1; }

latest=$(grep -oE 'gcc-trunk-[0-9]{8}\.tar\.xz' <<<"$listing" | sort -u | tail -1)
[ -n "$latest" ] || { echo "FAIL  no gcc-trunk tarball in the listing"; exit 1; }

have=$(gh release view mirror --repo "$repo" --json assets -q '.assets[].name')

if grep -Fx "$latest" <<<"$have" >/dev/null; then
    echo "mirror already holds $latest, publisher not contacted"
else
    echo "fetching $latest from Compiler Explorer (the one download per version)"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "$bucket/opt/$latest" -o "$tmp/$latest"
    sha=$(sha256sum "$tmp/$latest" | cut -d' ' -f1)
    gh release upload mirror "$tmp/$latest" --repo "$repo"

    # GitHub hashes every asset on upload. build.py pins that digest without
    # downloading, so it has to equal the bytes that left here.
    got=$(gh release view mirror --repo "$repo" --json assets \
          -q ".assets[] | select(.name == \"$latest\") | .digest")
    [ "$got" = "sha256:$sha" ] ||
        { echo "FAIL  GitHub reports $got, local bytes are sha256:$sha"; exit 1; }
    echo "mirrored $latest ($sha)"
fi

# Keep the newest few, so an install that resolved the previous nightly a moment
# ago still finds its payload.
gh release view mirror --repo "$repo" --json assets -q '.assets[].name' |
    grep -E '^gcc-trunk-[0-9]{8}\.tar\.xz$' | sort | head -n "-$keep" |
while read -r old; do
    gh release delete-asset mirror "$old" --repo "$repo" -y
    echo "pruned $old"
done
