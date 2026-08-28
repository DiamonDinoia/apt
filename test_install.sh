#!/bin/bash
# End-to-end install of the built repository in a clean Debian sid container.
#
# test_repo.sh proves apt can read the index. This proves the packages work:
# the bootstrap package puts a usable source and key in place, apt verifies the
# signed index against that key, and every postinst downloads its payload, sees
# the hash match, and leaves the program on disk. A postinst that silently does
# nothing fails here and nowhere else.
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
  trap 'rm -rf "$gnupg"' EXIT
  export GNUPGHOME=$gnupg
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-generate-key 'apt test <test@invalid>' rsa3072 sign never ||
    { echo "FAIL  key generation"; exit 1; }
  GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')
  export GPG_KEY_ID
  python3 "$root/build.py" >/dev/null || { echo "FAIL  build"; exit 1; }
fi

[[ -f $repo/InRelease ]] || { echo "FAIL  $repo is not signed"; exit 1; }

if [[ $# -gt 0 ]]; then
  want="$*"
else
  want=$(awk '/^Package: /{if ($2 != "diamondinoia-apt") printf "%s ", $2}' "$repo/Packages")
fi
echo "==> installing: $want"

# The source the bootstrap package installs points at GitHub, which does not yet
# hold this build. Only the URI is rewritten; Signed-By stays, so apt still
# verifies the index against the key the bootstrap package installed.
"$engine" run --rm -i -v "$repo:/repo:ro" -e "WANT=$want" debian:sid \
    bash -eo pipefail -s <<'SCRIPT'
apt-get update -qq
apt-get install -y --no-install-recommends /repo/diamondinoia-apt_*.deb

test -s /etc/apt/keyrings/diamondinoia.gpg
grep '^Pin-Priority: 600' /etc/apt/preferences.d/diamondinoia >/dev/null
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
    script=$(dpkg-deb -I /repo/"$pkg"_*.deb postinst)
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
    printf 'ok    %-18s %s\n' "$pkg" "$what"
done

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
status=$?
echo "install_exit=$status"
exit $status
