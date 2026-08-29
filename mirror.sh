#!/bin/bash
# Mirror the newest Compiler Explorer gcc-trunk nightly into this repository's
# `mirror` release, so the 4e8-byte tarball is downloaded from the publisher
# exactly once per version and every install, test and rebuild pulls from GitHub
# instead. Noticing a new version still costs one bucket listing per run.
#
# GCC is GPL and may be redistributed. Compiler Explorer pays for its own S3
# egress, which is the whole reason this file exists: the alternative pins their
# bucket in every package and spends their money on every install.
#
# The asset is renamed to carry the major that the tarball actually contains,
# because the package is named for that major and has to defer to the
# distribution's own package of the same name once one exists.
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

# The listing is one long line, so it is split on the tag before matching.
# tr and sed both exit 0 on no match, which lets an empty listing reach the
# diagnostic below rather than aborting on grep's exit status under pipefail.
latest=$(tr '<' '\n' <<<"$listing" |
         sed -nE 's|^Key>opt/(gcc-trunk-[0-9]{8}\.tar\.xz)$|\1|p' | sort -u | tail -1)
[ -n "$latest" ] || { echo "FAIL  no gcc-trunk tarball in the listing"; exit 1; }
date=${latest//[!0-9]/}

have=$(gh release view mirror --repo "$repo" --json assets -q '.assets[].name')

# Matched on the date alone, because the major is only known after the bytes
# are here and re-downloading a build already mirrored is the one thing this
# script exists to avoid.
if grep -qE "^gcc-[0-9]+-trunk${date}\.tar\.xz$" <<<"$have"; then
    echo "mirror already holds the $date build, publisher not contacted"
else
    echo "fetching $latest from Compiler Explorer (the one download per version)"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "$bucket/opt/$latest" -o "$tmp/$latest"

    # `lib/gcc/<target>/<version>/` is fixed by GCC's own install layout, so
    # the major is read from the payload rather than assumed from the calendar.
    major=$(tar -tJf "$tmp/$latest" |
            sed -nE 's|.*lib/gcc/[^/]+/([0-9]+)\..*|\1|p' | sort -u)
    case $major in
        [0-9]*) [ "$(wc -l <<<"$major")" -eq 1 ] || major= ;;
        *) major= ;;
    esac
    [ -n "$major" ] ||
        { echo "FAIL  no single gcc major under lib/gcc/ in $latest"; exit 1; }

    name="gcc-${major}-trunk${date}.tar.xz"
    mv "$tmp/$latest" "$tmp/$name"
    sha=$(sha256sum "$tmp/$name" | cut -d' ' -f1)
    gh release upload mirror "$tmp/$name" --repo "$repo"

    # GitHub hashes every asset on upload. build.py pins that digest without
    # downloading, so it has to equal the bytes that left here.
    got=$(gh release view mirror --repo "$repo" --json assets \
          -q ".assets[] | select(.name == \"$name\") | .digest")
    [ "$got" = "sha256:$sha" ] ||
        { echo "FAIL  GitHub reports $got, local bytes are sha256:$sha"; exit 1; }
    echo "mirrored $name ($sha)"
fi

# Keep the newest few, so an install that resolved the previous nightly a moment
# ago still finds its payload. Filtering happens in bash rather than through a
# `grep` in a pipeline: with `pipefail`, a `grep` that correctly matches nothing
# fails the whole script, and silencing that with `|| true` would also hide a
# real error from `gh`.
mapfile -t assets < <(gh release view mirror --repo "$repo" --json assets -q '.assets[].name')

drop=()
dated=()
for a in "${assets[@]}"; do
    if [[ $a =~ ^gcc-trunk-[0-9]{8}\.tar\.xz$ ]]; then
        drop+=("$a")                        # pre-rename; nothing resolves it
    elif [[ $a =~ ^gcc-[0-9]+-trunk([0-9]{8})\.tar\.xz$ ]]; then
        dated+=("${BASH_REMATCH[1]} $a")
    fi
done

if [ "${#dated[@]}" -gt "$keep" ]; then
    mapfile -t sorted < <(printf '%s\n' "${dated[@]}" | sort)
    for ((i = 0; i < ${#sorted[@]} - keep; i++)); do drop+=("${sorted[i]#* }"); done
fi

for old in ${drop[@]+"${drop[@]}"}; do
    gh release delete-asset mirror "$old" --repo "$repo" -y
    echo "pruned $old"
done
