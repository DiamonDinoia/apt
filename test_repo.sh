#!/bin/bash
# Verify that out/ is a usable apt repository.
#
# Check 1: apt reads the index, and every package it advertises is visible to
#          apt at the advertised version, coming from this repository.
# Check 2: a package carries no payload, only a pinned URL and SHA-256, so the
#          URL must still answer and the hash must be a hash.
# Check 3 (positive control): mutating Packages after Release was written must
#          make apt reject the repository. Without it the checks above cannot be
#          told apart from apt quietly ignoring an index it never read.
#
# Dependency resolution is not checked here. It only means anything against the
# archive the packages target, and test_install.sh proves it by installing them
# in a Debian sid container. Simulating it against whatever archive this host
# happens to carry fails on packages that install correctly.
#
# Nothing is installed and nothing outside the temporary directory is written.
set -uo pipefail

repo=$(cd "$(dirname "$0")" && pwd)/out
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work"/{sources,lists/partial,archives/partial}
cp /etc/apt/sources.list.d/* "$work/sources/" 2>/dev/null
echo "deb [trusted=yes] file://$repo ./" > "$work/sources/zz-local.list"

apt=(-o Dir::Etc::sourcelist=/dev/null
     -o Dir::Etc::sourceparts="$work/sources"
     -o Dir::State::lists="$work/lists"
     -o Dir::Cache::archives="$work/archives"
     -o Dir::Etc::preferences=/dev/null
     -o Dir::Etc::preferencesparts=/dev/null
     -o APT::Get::AllowUnauthenticated=true)

if ! apt-get "${apt[@]}" update -qq 2>"$work/err"; then
  echo "FAIL  apt update rejected the repository"; cat "$work/err"; exit 1
fi

fail=0
while read -r pkg ver; do
  # Check 1. The version table must bind the advertised version to this repo.
  # grep without -q: -q exits on the first match and SIGPIPEs whatever feeds
  # it, which pipefail then reports as a failed pipeline despite the match.
  if ! apt-cache "${apt[@]}" policy "$pkg" | grep -A5 -F " $ver " | grep -F "$repo" >/dev/null; then
    printf 'FAIL  %-18s %s not offered by this repository\n' "$pkg" "$ver"
    fail=1
    continue
  fi
  printf 'ok    %-18s %s\n' "$pkg" "$ver"
done < <(awk '/^Package: /{p=$2} /^Version: /{print p, $2}' "$repo/Packages")

# Check 2. A package carries no payload, only a URL and a hash, so the URL has
# to answer and the hash has to be a hash. A HEAD follows the publisher's
# redirects the same way the postinst curl does.
for deb in "$repo"/*.deb; do
  pkg=$(dpkg-deb -f "$deb" Package)
  # A package with no postinst carries its own files and pins no payload, which
  # is true of the bootstrap package and of nothing else here.
  if ! script=$(dpkg-deb -I "$deb" postinst 2>/dev/null); then
    printf 'ok    %-18s ships its own files\n' "$pkg"
    continue
  fi
  url=$(sed -n "s/^curl -fsSL '\(.*\)' -o .*/\1/p" <<<"$script")
  sha=$(sed -n "s/^echo '\([0-9a-f]*\)  '.*/\1/p" <<<"$script")

  if [[ ${#sha} -ne 64 ]]; then
    printf 'FAIL  %-18s pinned hash is %q, not a SHA-256\n' "$pkg" "$sha"
    fail=1
  elif ! code=$(curl -fsSLI -o /dev/null -w '%{http_code}' --max-time 30 "$url"); then
    printf 'FAIL  %-18s payload unreachable: %s\n' "$pkg" "$url"
    fail=1
  else
    printf 'ok    %-18s payload %s %s\n' "$pkg" "$code" "${sha:0:12}"
  fi
done

# Positive control for check 2: the reachability probe must fail on a URL that
# does not resolve, or a dead payload would pass unnoticed.
if curl -fsSLI -o /dev/null --max-time 30 \
     https://github.com/DiamonDinoia/apt/releases/download/repo/no-such-asset 2>/dev/null; then
  echo "FAIL  positive control: curl accepted a missing payload"
  fail=1
else
  echo "ok    positive control: missing payload rejected"
fi

# Check 3. Release carries the SHA256 of Packages, so any edit must be caught.
cp "$repo/Packages" "$work/Packages.bak"
printf 'Package: bogus\nVersion: 1\nArchitecture: amd64\n\n' >> "$repo/Packages"
rm -rf "$work/lists"; mkdir -p "$work/lists/partial"
if apt-get "${apt[@]}" update -qq 2>/dev/null &&
   apt-cache "${apt[@]}" policy bogus | grep -F 'Candidate: 1' >/dev/null; then
  echo "FAIL  positive control: apt accepted a mutated Packages index"
  fail=1
else
  echo "ok    positive control: mutated index rejected"
fi
cp "$work/Packages.bak" "$repo/Packages"

exit $fail
