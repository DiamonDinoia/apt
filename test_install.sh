#!/bin/bash
# End-to-end install of the built repository in a clean Debian sid container.
#
# test_repo.sh proves apt can read the index. This proves the packages work:
# the bootstrap package puts a usable source and key in place, apt verifies the
# signed index against that key, and every postinst downloads its payload, sees
# the hash match, and leaves the program on disk. A postinst that silently does
# nothing fails here and nowhere else. Passthrough packages are the named
# exception: the fork that builds them installs them in a container of its own.
#
# One container per package, never all of them at once. Installed together, a
# dependency one package declares satisfies another that forgot to, and the
# omission only surfaces on a user's machine. That is how the missing libc6-dev
# on gcc-17 survived a green run.
#
# Usage: ./test_install.sh [package ...]   (default: every package in the index)
#
# The repository must be signed, so a throwaway key is generated when GPG_KEY_ID
# is unset and the build is repeated with it.
set -uo pipefail

root=$(cd "$(dirname "$0")" && pwd)
repo=$root/out

engine=$(command -v podman || command -v docker) || {
  echo "FAIL  no podman or docker; this check cannot run"; exit 1; }

if [[ -z ${GPG_KEY_ID:-} ]]; then
  echo "==> GPG_KEY_ID unset, building with a throwaway key"
  gnupg=$(mktemp -d); chmod 700 "$gnupg"
  export GNUPGHOME=$gnupg
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-generate-key 'apt test <test@invalid>' rsa3072 sign never ||
    { echo "FAIL  key generation"; exit 1; }
  GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')
  export GPG_KEY_ID
  python3 "$root/build.py" >/dev/null || { echo "FAIL  build"; exit 1; }
fi

[[ -f $repo/InRelease ]] || { echo "FAIL  $repo is not signed"; exit 1; }

# The merged spec is the single test interface: wrapper shapes and `with`,
# bundle markers (install == "bundle"), defer groups and repos all read here.
spec=$(mktemp)
trap 'rm -f "$spec"; [ -n "${gnupg:-}" ] && rm -rf "$gnupg"' EXIT
python3 "$root/build.py" --dump-spec > "$spec"

if [[ $# -gt 0 ]]; then
  want="$*"
else
  # Default: every advertiseable package EXCEPT compiler bundles (heavy
  # payloads; S4/S5 own their container tests).
  want=$(python3 -c "import json
s = json.load(open('$spec'))
bundles = {n for n, b in s['bundles'].items() if b.get('install') == 'bundle'}
names = [l.split()[1] for l in open('$repo/Packages') if l.startswith('Package: ')]
print(' '.join(n for n in names if n != 'diamondinoia-apt' and n not in bundles))")
fi
# Passthrough packages need a different container than the wrapper flow. Their
# fork already proved the heavy install (a desktop stack's worth of Depends);
# what it cannot prove is the path a user takes through this repository: index,
# pin, apt's acquire of a '+'-name asset, and any source packages spec['with']
# names, installed the way a user would install them, which is also what makes
# juno-drivers' juno-info and check-battery Depends resolvable here. Each line
# is "pkg extra extra...".
mapfile -t passthrough < <(python3 -c "import json
s = json.load(open('$spec'))
for n, w in s['wrappers'].items():
    if w.get('install') == 'passthrough':
        print(n, ' '.join(w.get('with', [])))")
ptnames=
for line in "${passthrough[@]}"; do ptnames="$ptnames ${line%% *}"; done
wrappers=
for pkg in $want; do
  case "$ptnames " in *" $pkg "*) ;; *) wrappers="$wrappers $pkg" ;; esac
done
echo "==> installing:$wrappers"

# The source the bootstrap package installs points at GitHub, which does not yet
# hold this build. Only the URI is rewritten; Signed-By stays, so apt still
# verifies the index against the key the bootstrap package installed.
# Which packages defer to the distribution is a property of the merged spec:
# every catalog compiler bundle (emitted today or pending its mirror row —
# the pin covers the name either way) plus any wrapper marked defer_to_debian.
# The list must stay non-vacuous over compiler names, or the glob-stanza check
# in the container proves nothing.
defer=$(python3 -c "import json
s = json.load(open('$spec'))
out = [n for n, b in sorted(s['bundles'].items())
       if b.get('pin') == 'defer' and ' (trunk family)' not in n]
out += [n for n, w in s['wrappers'].items() if w.get('defer_to_debian')]
print(' '.join(out))")
defer_n=$(wc -w <<<"$defer")
case " $defer " in *gcc-*|*clang-*) ;; *) echo "FAIL  defer list lost its compiler names"; exit 1;; esac
if [ "$defer_n" -lt 9 ]; then
  echo "FAIL  defer list covers $defer_n names, expected >= 9 compiler names"; exit 1
fi

# apt names a list file after the URI, with '_' escaped as %5f and '/' turned
# into '_', and inserts dists/<suite> for anything that is not a flat
# repository. Naming every file a source must produce catches a source that
# quietly loses one of its suites, which llvm has five of; grepping for the
# host cannot tell one suite from five.
indices() {           # $1: one repo name, or empty for every carried source
    python3 -c "import json, re, sys
want = sys.argv[1]
out = []
for name, r in json.load(open('$spec'))['repos'].items():
    if not ((name == want) if want else not r.get('separate')):
        continue
    for uri in r['uris'].split():
        path = re.sub(r'^https?://', '', uri).rstrip('/')
        path = path.replace('_', '%5f').replace('/', '_')
        for suite in r['suites'].split():
            out.append(path + ('_InRelease' if suite == '/'
                               else f'_dists_{suite}_InRelease'))
print(' '.join(out))" "$1"
}

echo "==> repository checks"
"$engine" run --rm -i -v "$repo:/repo:ro" -e "DEFER=$defer" -e "PT=$ptnames" \
    -e "INDICES=$(indices '')" debian:sid \
    bash -eo pipefail -s <<'SCRIPT'
rc=0
apt-get update -qq
apt-get install -y --no-install-recommends /repo/diamondinoia-apt_*.deb
apt-get install -y --no-install-recommends curl

test -s /etc/apt/keyrings/diamondinoia.gpg
grep '^Pin-Priority: 600' /etc/apt/preferences.d/diamondinoia >/dev/null

# Our own source names GitHub, which does not hold this build and whose index is
# signed by the published key rather than the one this build shipped. Pointing
# it at the local tree, exactly as the per-package containers do, puts it under
# the strict update below instead of leaving it a permanent warning.
sed -i 's|^URIs: .*|URIs: file:///repo/|' /etc/apt/sources.list.d/diamondinoia.sources

# The bootstrap also carries third-party sources. A key that no longer matches
# the repository signing it makes apt refuse that source, and Error-Mode=any is
# what turns apt's warning into a failure. The list file is the evidence that
# the source was fetched, not merely that the update as a whole survived.
apt-get update -qq -o APT::Update::Error-Mode=any
for f in $INDICES; do
    if [ -s "/var/lib/apt/lists/$f" ]; then
        echo "ok    ${f%_InRelease} verifies against the shipped key"
    else
        echo "FAIL  no index at /var/lib/apt/lists/$f"; rc=1
    fi
done

# Positive control for the loop above, on one source rather than all of them:
# the same strict update has to reject a source whose key is noise. tailscale
# is the cheapest to refetch. A loop that only ever sees good keys proves
# nothing. The key is restored and the source refetched, so the container is
# left in the state the checks after this one expect.
cp /etc/apt/keyrings/tailscale.gpg /tmp/key.bak
head -c 64 /dev/urandom > /etc/apt/keyrings/tailscale.gpg
rm -f /var/lib/apt/lists/pkgs.tailscale.com*
if apt-get update -qq -o APT::Update::Error-Mode=any >/dev/null 2>&1; then
    echo "FAIL  positive control: a corrupt tailscale key verified anyway"; rc=1
else
    echo "ok    positive control: a corrupt key is refused"
fi
cp /tmp/key.bak /etc/apt/keyrings/tailscale.gpg
apt-get update -qq -o APT::Update::Error-Mode=any

# A package that defers to the distribution has to sit in the 100 stanza. At
# 600 it outranks the archive and the handover never happens; named in neither
# list it drops to the -1 catch-all and stops being installable at all. The
# 100 stanza now covers the compiler namespace with globs (gcc-*, clang-*), so
# membership is a glob match, not a substring match. The post-publish test
# reads the same pin, but only after users could have it.
pin100=$(awk '/^Package: /{ p = substr($0, 10) }
              /^Pin-Priority: 100$/{ print p }' /etc/apt/preferences.d/diamondinoia)
for p in $DEFER; do
    hit=
    for tok in $pin100; do
        [[ $p == $tok ]] && { hit=1; break; }
    done
    [ -n "$hit" ] ||
        { echo "FAIL  $p defers to Debian but no 100-stanza token matches it"; exit 1; }
done
echo "ok    every defer name matches a 100-stanza token ($(wc -w <<<"$DEFER") names)"

# Positive control: the same reader applied to a pin file that puts those
# packages at 600 must come back empty, or the loop above proves nothing.
[ -z "$(awk '/^Package: /{ p = substr($0, 10) }
             /^Pin-Priority: 100$/{ print p }' <<<"Package: gcc-99 clang-99
Pin: release l=diamondinoia
Pin-Priority: 600")" ] ||
    { echo "FAIL  positive control: the reader found a 100 stanza in a 600 pin"; exit 1; }
echo "ok    positive control: a 600 pin yields no 100 stanza"
# Negative half of the control set: the glob reader must NOT match a name
# outside the compiler namespace, or containment is unverified.
for tok in $pin100; do
    [[ diamondinoia-apt == $tok ]] &&
        { echo "FAIL  positive control: the glob stanza swallows the bootstrap package"; exit 1; }
done
echo "ok    positive control: the glob stanza does not swallow other packages"

# A passthrough package competes on version alone, so it has to sit in the 500
# stanza and nowhere above it: at 600 it would shadow the original publisher,
# named in neither it would fall to the -1 catch-all and stop installing.
if [ -n "$PT" ]; then
    pin500=$(awk '/^Package: /{ p = substr($0, 10) }
                  /^Pin-Priority: 500$/{ print p }' /etc/apt/preferences.d/diamondinoia)
    pin600=$(awk '/^Package: /{ p = substr($0, 10) }
                  /^Pin-Priority: 600$/{ print p }' /etc/apt/preferences.d/diamondinoia)
    for p in $PT; do
        [[ " $pin500 " == *" $p "* ]] ||
            { echo "FAIL  $p is passthrough but not pinned at 500"; exit 1; }
        [[ " $pin600 " == *" $p "* ]] &&
            { echo "FAIL  $p is passthrough but also pinned at 600"; exit 1; }
    done
    echo "ok   $PT pinned at 500"
fi
# Positive control: a package whose pinned hash is wrong must refuse to install.
# Without it a passing run cannot be told apart from a postinst that checks
# nothing. The payload is local, so the control costs no download.
mkdir -p /tmp/bad/DEBIAN
cat > /tmp/bad/DEBIAN/postinst <<'CONTROL'
#!/bin/sh
set -e
[ "$1" = configure ] || exit 0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL 'file:///repo/Packages' -o "$tmp/payload"
echo '0000000000000000000000000000000000000000000000000000000000000000  '"$tmp/payload" | sha256sum -c - >/dev/null
CONTROL
chmod 755 /tmp/bad/DEBIAN/postinst
printf 'Package: hashcontrol\nVersion: 1\nArchitecture: all\nMaintainer: t <t@invalid>\nDescription: control\n' \
    > /tmp/bad/DEBIAN/control
dpkg-deb --build /tmp/bad /tmp/bad.deb >/dev/null
if dpkg -i /tmp/bad.deb >/dev/null 2>&1; then
    echo 'FAIL  positive control: a wrong hash installed anyway'; rc=1
else
    echo 'ok    positive control: wrong hash refused'
fi
exit $rc
SCRIPT
rc=$?

for pkg in $wrappers; do
  echo "==> $pkg"

  # From the merged spec rather than from the postinst, so a link the build
  # drops fails here, before publication, instead of only in the post-publish
  # tests. Compiler bundles pass this reader just like wrappers.
  links=$(python3 -c "import json
s = json.load(open('$spec'))
w = s['wrappers'].get('$pkg') or s['bundles'].get('$pkg', {})
print(' '.join(w.get('links', {})))")
  "$engine" run --rm -i -v "$repo:/repo:ro" -e "WANT=$pkg" -e "LINKS=$links" \
      -e "INDICES=$(indices "${pkg#diamondinoia-repo-}")" debian:sid \
      bash -eo pipefail -s <<'SCRIPT'
apt-get update -qq
apt-get install -y --no-install-recommends /repo/diamondinoia-apt_*.deb
sed -i 's|^URIs: .*|URIs: file:///repo/|' /etc/apt/sources.list.d/diamondinoia.sources

apt-get update -qq
apt-get install -y --no-install-recommends $WANT

rc=0
for pkg in $WANT; do
    if ! dpkg-query -W -f '${Status}' "$pkg" | grep -F 'install ok installed' >/dev/null; then
        printf 'FAIL  %-18s not configured\n' "$pkg"; rc=1; continue
    fi
    # What the package claims to install is read back out of its own postinst,
    # so the check follows the package rather than guessing from its name.
    script=$(dpkg-deb -I /repo/"$pkg"_*.deb postinst 2>/dev/null) || script=
    bin=$(sed -n 's|^chmod 0755 /usr/bin/\(.*\)$|\1|p' <<<"$script")

    if [ -s "/var/lib/$pkg.files" ]; then
        # The strongest of the three: every file the upstream .deb carried has
        # to be on disk, names with spaces included.
        missing=0
        while IFS= read -r f; do [ -e "$f" ] || missing=$((missing + 1)); done < "/var/lib/$pkg.files"
        if [ "$missing" -gt 0 ]; then
            printf 'FAIL  %-18s %s of %s files in the manifest are absent\n' \
                "$pkg" "$missing" "$(wc -l < "/var/lib/$pkg.files")"
            rc=1; continue
        fi
        what="$(wc -l < "/var/lib/$pkg.files") files"
    elif [ -n "$bin" ]; then
        if [ ! -x "/usr/bin/$bin" ]; then
            printf 'FAIL  %-18s /usr/bin/%s absent\n' "$pkg" "$bin"; rc=1; continue
        fi
        what="/usr/bin/$bin"
    elif src=$(dpkg -L "$pkg" | grep '^/etc/apt/sources.list.d/.*\.sources$'); then
        # A repository package installs no program, so the property to check is
        # that apt can fetch and verify the source it added with the key it
        # shipped. Error-Mode=any turns apt's warning about a failed source into
        # a failure, and the list file proves this source was the one fetched
        # rather than the update merely succeeding on the others.
        key=$(sed -n 's|^Signed-By: ||p' "$src")
        if [ ! -s "$key" ]; then
            printf 'FAIL  %-18s Signed-By names %s, which is not there\n' "$pkg" "$key"
            rc=1; continue
        fi
        if ! apt-get update -qq -o APT::Update::Error-Mode=any >/dev/null; then
            printf 'FAIL  %-18s apt-get update rejects the source it added\n' "$pkg"
            rc=1; continue
        fi
        for f in $INDICES; do
            [ -s "/var/lib/apt/lists/$f" ] && continue
            printf 'FAIL  %-18s no index at /var/lib/apt/lists/%s\n' "$pkg" "$f"
            rc=1
        done
        # Positive control: with the shipped key replaced by noise, the same
        # strict update has to reject this source. Only this source's index is
        # dropped, so apt refetches it and nothing else. Without the control a
        # green run cannot be told from a check that verifies nothing, which is
        # what a stale InRelease in the cache would give.
        cp "$key" /tmp/key.bak
        head -c 64 /dev/urandom > "$key"
        for f in $INDICES; do rm -f "/var/lib/apt/lists/$f"; done
        if apt-get update -qq -o APT::Update::Error-Mode=any >/dev/null 2>&1; then
            printf 'FAIL  %-18s positive control: a corrupt key verified anyway\n' "$pkg"
            rc=1
        fi
        cp /tmp/key.bak "$key"
        what="${INDICES%%_*} verified with $(basename "$key"), corrupt key refused"
    elif [ -d "/opt/$pkg" ]; then
        # A tree is only usable if the launcher symlink resolves into it.
        target=$(readlink -f "/usr/bin/$pkg" 2>/dev/null)
        case $target in
            /opt/$pkg/*) : ;;
            *) printf 'FAIL  %-18s /usr/bin/%s does not point into /opt/%s\n' \
                   "$pkg" "$pkg" "$pkg"; rc=1; continue ;;
        esac
        if [ ! -x "$target" ]; then
            printf 'FAIL  %-18s launcher %s is not executable\n' "$pkg" "$target"
            rc=1; continue
        fi
        what="$(du -sh "/opt/$pkg" | cut -f1) in /opt/$pkg -> ${target#/opt/$pkg/}"
    else
        printf 'FAIL  %-18s installed nothing\n' "$pkg"; rc=1; continue
    fi
    # Every link the package declares has to resolve to something that can run.
    for l in $LINKS; do
        t=$(readlink -f "/usr/bin/$l" 2>/dev/null) || t=
        if [ ! -x "$t" ]; then
            printf 'FAIL  %-18s link /usr/bin/%s resolves to nothing runnable\n' \
                "$pkg" "$l"; rc=1; continue 2
        fi
    done
    [ -z "$LINKS" ] || what="$what, $(wc -w <<<"$LINKS") links"

    printf 'ok    %-18s %s\n' "$pkg" "$what"
done

exit $rc
SCRIPT
  [ $? -eq 0 ] || rc=1
done

# Each passthrough package gets the user path: the same bootstrap, the extras
# the toml asks for (the repository's own source package, which is also what
# makes Juno's juno-info resolvable), then the package itself by name.
for line in ${passthrough[@]+"${passthrough[@]}"}; do
  pkg=${line%% *}
  case " $want " in *" $pkg "*) ;; *) continue ;; esac
  extras=${line#"$pkg"}; extras=${extras# }
  echo "==> $pkg"
  "$engine" run --rm -i -v "$repo:/repo:ro" -e "WANT=$pkg" -e "EXTRAS=$extras" \
      debian:sid bash -eo pipefail -s <<'SCRIPT'
# Passthrough packages are hardware metapackages: half their Depends live in
# contrib/non-free/non-free-firmware, which a stock sid image does not enable.
sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' \
    /etc/apt/sources.list.d/debian.sources
apt-get update -qq
apt-get install -y --no-install-recommends /repo/diamondinoia-apt_*.deb
sed -i 's|^URIs: .*|URIs: file:///repo/|' /etc/apt/sources.list.d/diamondinoia.sources
apt-get update -qq -o APT::Update::Error-Mode=any
for e in $EXTRAS; do
    apt-get install -y --no-install-recommends "$e"
    apt-get update -qq -o APT::Update::Error-Mode=any
done
apt-get install -y --no-install-recommends "$WANT"

rc=0
dpkg-query -W -f '${Status}' "$WANT" | grep -F 'install ok installed' >/dev/null ||
    { echo "FAIL  $WANT not configured"; exit 1; }
files=0; missing=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    files=$((files + 1))
    [ -e "$f" ] || missing=$((missing + 1))
done < <(dpkg -L "$WANT")
[ "$files" -gt 0 ] && [ "$missing" -eq 0 ] ||
    { echo "FAIL  $WANT: $missing of $files files absent"; rc=1; }
[ "$rc" -eq 0 ] && echo "ok    $WANT installed the way a user installs it, $files files"
exit $rc
SCRIPT
  [ $? -eq 0 ] || rc=1
done

echo "install_exit=$rc"
exit $rc
