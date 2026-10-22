# Maintaining this repository

## Build and publish pipeline

`nightly.yml` runs on cron `17 4 * * *`, on dispatch, and on pushes to main:

1. `python3 mirror.py sync --max 4` rotates new trunk nightlies into the
   `mirror` release.
2. The runner commits the rewritten `mirror-manifest.json` back to main.
3. `python3 build.py` builds `out/`: the debs, `Packages`, `Release`, and with
   `GPG_KEY_ID` set also `InRelease`, `Release.gpg` and `KEY.gpg`.
4. `./test_repo.sh`, then `./test_install.sh`.
5. The publish step uploads changed assets to the `repo` release and deletes
   assets no longer in the index.
6. `./test_gcc17.sh` runs the published-path battery.

The validate workflows run the container suites out of band:
`validate-compilers.yml` (`test_compilers.sh`, sharded matrix),
`validate-failure-modes.yml` (`test_failure_modes.sh`),
`validate-precedence.yml` (`test_precedence.sh`). `bulk-sync.yml` backfills the
mirror and commits the manifest in chunks.

## Machine files

One writer per file; edit the writer, never the file:

    catalog.json          catalog.py
    mirror-manifest.json  mirror.py
    exceptions.json       test_compilers.sh ("cutoff"),
                          test_failure_modes.sh ("relr")

`build.py` merges those with `packages.toml`; `build.py --dump-spec` prints the
merged spec, the single interface every test reads.

## Add a package

Append a block to `packages.toml`. `install` picks the shape:

    deb          download a .deb and unpack it into /
    member       download an archive, place one executable in /usr/bin
    tree         unpack into /opt/<name>, symlink the launcher into /usr/bin,
                 write a desktop entry
    passthrough  serve a fork-built .deb bit-identical, keeping its maintainer
                 scripts

The version resolves from a GitHub release (`repo` + `asset`), a JSON feed
(`json` + `json_path` + `version_re`), a text page (`text` + `text_re`), or a
redirect target (`url` + `version_re`). `defer_to_debian = true` moves the name
from the 600 pin to 100. `icon`, `desktop_name` and `desktop_categories` cover
GUI applications. Compiler payloads are never entries: one bundle per
`catalog.json` entry, derived by `build.py`.

## Signing key

The workflow expects a `GPG_PRIVATE_KEY` secret holding an ASCII-armoured
private key used for nothing else:

    gpg --batch --quick-generate-key 'DiamonDinoia apt <mbarbone@flatironinstitute.org>' rsa4096 sign never
    gpg --armor --export-secret-keys <key-id> | gh secret set GPG_PRIVATE_KEY --repo DiamonDinoia/apt

`GPG_KEY_ID` is the id of the imported key. Without it `build.py` leaves the
index unsigned and skips the bootstrap package. The public half is published
as `KEY.gpg`, so it is never committed.

## The pin

The bootstrap package installs `/etc/apt/preferences.d/diamondinoia`:

    Package: *
    Pin: release l=diamondinoia
    Pin-Priority: -1

    Package: act clion diamondinoia-apt diamondinoia-repo-cuda
     diamondinoia-repo-juno difftastic discord galaxybudsclient ghostty
     intel-sde lazygit lua-language-server stylua watchexec zed zoom
    Pin: release l=diamondinoia
    Pin-Priority: 600

    Package: clevo-keyboard-dkms clevofan-dkms diamondinoia-wallpapers ec-sys-dkms
     juno-drivers-diamon juno-kde-fancontrol
    Pin: release l=diamondinoia
    Pin-Priority: 500

    Package: gcc-* clang-*
    Pin: release l=diamondinoia
    Pin-Priority: 100

The -1 catch-all vetoes anything no stanza claims. 600 covers the wrappers and
repo packages, 500 the fork-built passthrough packages, and 100 the compiler
namespace, which defers to the distribution. The bootstrap's version tracks
the files it ships, so a changed pin or key offers an upgrade.

## Third-party sources

The bootstrap package also installs these third-party apt sources with the keys
that verify them:

    brave  github-cli  google-cloud-cli  llvm  nvidia-container-toolkit
    onlyoffice  tailscale  vscode  yazi

Every key is fetched at build time and checked against a SHA-256 in
`packages.toml`; a rotated key fails the build, not the install. Two are
hardware-specific and ship as their own packages:
`diamondinoia-repo-cuda` (NVIDIA's debian13 repository; the old debian12 key
self-certifies with SHA-1 and sqv rejects it) and `diamondinoia-repo-juno`.
Machines carrying hand-added copies can drop them:

    sudo rm /etc/apt/sources.list.d/cuda-debian12-x86_64.sources
    sudo rm /etc/apt/sources.list.d/juno-debian.sources /etc/apt/keyrings/juno.gpg

## The Compiler Explorer mirror

`mirror.py` moves `catalog.json` payloads onto the `mirror` release and records
sha256, size and a per-payload analysis into `mirror-manifest.json` at mirror
time. Stables are immutable: a size or ETag change upstream is an alarm and
`mirror.py check` exits 1 naming it. Trunk nightlies rotate: a dated payload is
deleted only when the published index was fetched and verified, no package
names the payload, it is at least 14 days old, and it is not the newest dated
asset of its class in its family (renamed payloads and raw dated leftovers
each protect their own newest). A family whose keys cannot be listed is
skipped for pruning; assets that never finished uploading are corrupt
leftovers and are still removed.

Bundle names use Debian's spelling where Debian has one. Versions are
`<series>~ce<upstream>-R` for stables and `<major>~trunk<date>` for nightlies,
both below every version shape the archive spells, which is proven with
`dpkg --compare-versions` against the recorded corpus. Majors are probed from
the payload, so the day trunk becomes 18 that upload probes 18 and is named
for it. Bundle `Depends` come from the recorded NEEDED-soname union, plus
`libc6-dev` always and `libxml2` when the payload ships gcobol.

### The gcc-17 partition

`gcc-17` installs to `/opt/gcc-17` and puts 27 commands on `PATH` under
Debian's own `-17` names:

    gcc-17     g++-17        cpp-17         gfortran-17
    gccgo-17   gdc-17        gm2-17         gcobol-17
    gccrs-17   ga68-17
    gcc-ar-17  gcc-nm-17     gcc-ranlib-17
    gcov-17    gcov-dump-17  gcov-tool-17   lto-dump-17
    gnat-17    gnatbind-17   gnatchop-17    gnatclean-17  gnatkr-17
    gnatlink-17  gnatls-17   gnatmake-17    gnatname-17   gnatprep-17

The payload's 73 bin/ names partition into those 27 names (26 links plus the
`gcc-17` launcher) and 46 excluded names. 27 are the bundled binutils and
gprofng, which the driver finds itself. 15 are `x86_64-linux-gnu-` aliases of
drivers already linked, spelled without a version, so linking them would have
to invent a name no current Debian `gcc-NN` ships. One is `c++`, which Debian
gives no `-NN` spelling. One is `gcobc`, a shell script that finds `gcobol`
through `$0`, so a `/usr/bin/gcobc-17` symlink retargets that lookup at a
binary that exists nowhere. The last two are `go` and `gofmt`, built against
the payload's own `libgo` with no loader path. `build.py --selftest`
re-derives this partition from the committed manifest row and refuses any
other accounting.

## Known-broken installs

Two era gcc bundles refuse to install at all: Debian's `libstdc++6` declares a
versioned `Breaks` on them and `libstdc++6` cannot be removed. The rows live in
`exceptions.json` under `cutoff.install_refusals` and the matrix asserts them
in both directions:

    gcc-4.4  gcc-4.5

A glob spanning several series of one unversioned-analog family (`gcc-*-avr`,
`gcc-*-arm-none-eabi`) cannot resolve, because the series conflict on their
shared unversioned name; install one series by name.

## Failure classes

The failure classes are loud by design, and a suite proves the exact text
rather than the intent. A major or asset that disappears from under a pinned
spec stops the build with `no asset matches ...; have: ...`, which
`test_failure_modes.sh` drives through a mutated listing. A payload whose
bytes disagree with the pinned hash dies at the package's hash gate
(`did not match`), and a tarball truncated past the hash dies in extraction
with no partial tree left behind; both arms are `test_failure_modes.sh`.
A series-wide glob over an unversioned-analog cross family aborts apt with
`Reached two conflicting assignments`, asserted verbatim by
`test_compilers.sh`.

## Test suites

- `test_repo.sh` runs before anything is published: a throwaway apt
  configuration against the built repository, index/payload/hash probes, the
  pin-policy coverage probe, the offline bundle-rule selftest, and the
  documentation checks that diff this file and `README.md` against the machine
  files. Positive controls back every class.
- `test_install.sh` installs every wrapper and passthrough package alone in a
  clean `debian:sid` container; package names as arguments test a subset.
- `test_compilers.sh` is the compiler matrix over the catalog, sharded
  deterministically, in `debian:sid` and `debian:trixie` containers: install by
  name=version, linker and `ldd` sweeps, `exceptions.json` asserted in both
  directions, compile smoke tests.
- `test_precedence.sh` proves distro precedence against the live archive:
  per-name classification, handover swaps in both directions, and a
  pin-flip-to-600 control.
- `test_failure_modes.sh` carries the failure-mode arms the other suites do
  not duplicate: the mutated listing, truncated tarballs, the mirror
  ghost-asset control, the version-order gate, and the RELR measurements
  recorded into `exceptions.json`.
- `test_gcc17.sh` runs after publishing: released bootstrap install, upgrade
  of a stale pinned install, `gcc-17` from the published index, and the
  payload's compile battery.
