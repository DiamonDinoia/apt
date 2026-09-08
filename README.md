# apt

A flat Debian repository, rebuilt nightly from upstream releases. It puts tools
that ship only as a GitHub release artifact under `apt` control, and replaces
third-party repositories that either lag upstream or are run by somebody other
than the vendor.

Two package classes live here. Wrappers redistribute nothing: each one is a few
kilobytes of maintainer script whose `postinst` downloads the file from the
publisher and checks it against a SHA-256 pinned when the package was built.
Compiler bundles do redistribute: the Compiler Explorer payloads are GPL, and
they are mirrored once onto this repository's own `mirror` release because
pointing every install at Compiler Explorer's S3 bucket would spend their
egress money. Those two classes are the whole of what this repository serves.

Nothing else upstream is redistributed, with the two exceptions given their own
sections at the bottom. The wrapper shape is what makes proprietary software
packageable here: Discord, Zoom and CLion forbid redistribution, and none of
their bytes pass through this repository. It is the same shape Debian itself
uses for `ttf-mscorefonts-installer`. It also removes the reason to care how
large an upstream artifact is.

The index and the packages are published as assets of one GitHub release
tagged `repo`; the mirrored payloads ride a second release tagged `mirror`,
and no install or test ever reaches the Compiler Explorer bucket.

## Use it

One package installs the key, the source and the pin. Its file name carries a
version that moves, so take the name from the index rather than typing it:

    base=https://github.com/DiamonDinoia/apt/releases/download/repo
    deb=$(curl -fsSL $base/Packages | sed -n 's/^Filename: \(diamondinoia-apt_.*\)$/\1/p')
    curl -fsSLO "$base/$deb"
    sudo apt-get install ./"$deb"
    sudo apt-get update

The pin it installs confines this repository to the packages it is meant to
provide, so it can never shadow Debian:

    Package: *
    Pin: release l=diamondinoia
    Pin-Priority: -1

    Package: act clion diamondinoia-apt diamondinoia-repo-cuda
     diamondinoia-repo-juno difftastic discord galaxybudsclient ghostty
     intel-sde lazygit lua-language-server stylua watchexec zed zoom
    Pin: release l=diamondinoia
    Pin-Priority: 600

    Package: clevo-keyboard-dkms juno-drivers-diamon juno-kde-fancontrol
    Pin: release l=diamondinoia
    Pin-Priority: 500

    Package: gcc-* clang-*
    Pin: release l=diamondinoia
    Pin-Priority: 100

The pin matches the `Release` label rather than `github.com`, so it holds
whatever the repository is served from and never claims every package hosted on
GitHub.

The stanzas in order: the catch-all at -1 vetoes anything the lists miss. 600
is the wrappers and repo packages. 500 is the fork-built packages, which
version-compete with the original publisher at the archive's own level. 100 is
the compiler namespace, spelled as the two globs that cover every bundle:
those packages defer to the distribution on purpose, and the defer story has
its own section below. A package left out of every list would fall to the -1
default and never install at all, so a name only ever installs because one
stanza claims it.

The bootstrap package's version tracks the files it ships, so a changed pin or
key offers an upgrade that carries the change to installed machines.

## Other people's repositories

The bootstrap package also installs these third-party apt sources with the keys
that verify them:

    brave  github-cli  google-cloud-cli  llvm  nvidia-container-toolkit
    onlyoffice  tailscale  vscode  yazi

A machine that wants this repository at all wants a current llvm and `gh`.

Two are hardware, so they are packages of their own and install nothing else:

    sudo apt-get install diamondinoia-repo-cuda    # NVIDIA CUDA
    sudo apt-get install diamondinoia-repo-juno    # Juno Computers

Every key is fetched while the package is built, checked against a SHA-256 in
`packages.toml`, and written into the package. A vendor that rotates or
replaces a key fails the build rather than the install, and no install needs
network before apt runs. The files land in `/etc`, so they are conffiles: an
edit survives an upgrade, and removing the package leaves them until purge.

`diamondinoia-repo-cuda` points at NVIDIA's `debian13` repository. The
`debian12` key `A4B469963BF863CC` self-certifies with SHA-1, which sequoia's
`sqv` rejects from 2026-02-01, so on a stock Debian 13 that source fails every
`apt-get update`. It verifies only where a local
`/etc/crypto-policies/back-ends/sequoia.config` re-enables SHA-1, and that
override weakens signature checking for every apt source, not only NVIDIA's.
A machine carrying the old source can drop it:

    sudo rm /etc/apt/sources.list.d/cuda-debian12-x86_64.sources

A machine that already carries Juno's repository by hand can likewise drop its
copy in favour of the pinned one this package installs:

    sudo rm /etc/apt/sources.list.d/juno-debian.sources /etc/apt/keyrings/juno.gpg

The second exception section below covers the Juno source: the packages the
forks build are released here bit-identical.

## Add a package

Append a block to `packages.toml`. `install` picks one of four shapes.

`install = "deb"` downloads an upstream `.deb` and unpacks it into `/`. The
package's `Depends` is read off that `.deb` at build time, which is why a
`.deb` payload is always fetched. Always the right choice when upstream ships
a `.deb`.

`install = "member"` downloads a release tarball or zip and puts one executable
in `/usr/bin`. `member` names the path inside the archive; `binary` names the
command when it differs from the package name, as `difft` does.

`install = "tree"` downloads an archive, unpacks the application into
`/opt/<name>`, symlinks the first `launcher` that exists into `/usr/bin` and
writes a desktop entry. One wrapping directory is stripped; set `strip = 0` or
`strip = 2` for an archive that differs. If no `launcher` exists the install
fails rather than leaving a tree nothing can start. A tree that needs more
commands on `PATH` names them in `links` — `intel-sde` carries
`{ sde = "sde64" }`, putting the `sde` name on the 64-bit driver the tree
ships as `sde64`. Each target is checked at install, so a path upstream
dropped fails loudly instead of dangling.

`install = "passthrough"` is for a `.deb` this project forks and builds itself.
The payload is the package: the three shapes above unpack or extract and lose
the deb's own maintainer scripts, so instead the asset the fork's CI published
is served bit-identical. The build fetches it, fails unless the hash matches
the digest the release reported, and fails unless the deb's own `Package:` and
`Version:` match what the asset name promised. `tag`, `asset` and `version_re`
name the release; `with` lists packages `test_install.sh` installs first
(typically this repository's own source package), so the container walks the
same path a user walks.

Compiler payloads are never a `packages.toml` entry: `catalog.py` classifies
the Compiler Explorer bucket into `catalog.json`, and `build.py` emits one
bundle per entry. The `[gcc-17]` block that pre-dated the catalog is gone; its
rules — naming, version, links, exclusion classes — are now derived per payload
from the mirror's recorded analysis.

Any wrapper resolves its version one of four ways: a GitHub release (`repo`
plus an `asset` regex), a JSON feed (`json` plus `json_path` and
`version_re`), a small text page (`text` plus `text_re`, whose named groups
drive the `url` and `version` templates — `intel-sde`'s oracle is an AUR
PKGBUILD, Intel's own pages being bot-blocked), or a URL that redirects to a
versioned path (`url` plus `version_re`). GitHub tags have a leading `v`
stripped. Adding `tag` reads a fixed release instead of the latest one; there
several versions coexist as assets, so `version_re` extracts the version from
the asset name and the greatest one is current, order compared with `dpkg
--compare-versions`. A `version_re` with two capture groups joins them with
`~`, which makes a pre-release version that sorts below every real release of
the same major.

Add `defer_to_debian = true` for a package that carries a name Debian will
eventually use itself. It moves out of the 600 pin into the 100 one, so Debian
wins the moment it publishes that name. The compiler bundles get that
treatment by construction, with a deferring version beside it; the section
below spells out why both halves are needed.

Add `icon`, `desktop_name` and `desktop_categories` for a GUI application. A
`tree` package's `icon` is a path inside the payload; a `member` package has
nowhere to put one, so it names a stock icon.

## How it works

`build.py` merges four inputs into one resolved spec — `packages.toml`, the
hand-written wrappers and repos; `catalog.json`, the bucket classification
`catalog.py` alone writes; `mirror-manifest.json`, the mirror rows
`mirror.py` alone writes (payload sha256/size plus a per-payload analysis
recorded once, at mirror time); and `exceptions.json`, the measured
known-broken rows, curated with one writer per section. The same spec, printed
by `build.py --dump-spec`, is the single interface every test below reads.

For each wrapper, `build.py` resolves the current upstream version and its
SHA-256. GitHub publishes a `digest` field on every release asset and JetBrains
publishes a `.sha256` beside each tarball, so those packages are never
downloaded at all. Only Discord and Zoom, which publish no checksum, are
fetched once per upstream version to be hashed, along with every `.deb`
payload, whose own `Depends` can be read no other way. A payload that is
fetched and also carries a published digest has the two compared, so a checksum
that disagrees with the bytes fails the build. The payload is cached and never
enters a package. `build.py` then generates `Packages`, `Packages.gz` and
`Release` and signs them into `InRelease` and `Release.gpg`.

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

Then the suites, in the order they run:

`test_repo.sh` runs before anything is published. It points a throwaway `apt`
configuration at the built repository plus the host's real sources, then checks
that every advertised package resolves at its advertised version from this
repository, that every pinned payload URL still answers, and that every pinned
hash is a SHA-256. It also runs the defer-coverage probe over every emitted
bundle name under the shipped pin, the offline bundle-rule selftest, and a
block of documentation checks that diff this README against the machine files
its claims come from. Positive controls back every class: a `Packages` mutated
after `Release` was signed must be rejected, a missing payload URL must fail
the probe, and each documentation check re-runs over a mutated copy and must
refuse it. Dependency resolution is deliberately not simulated here, because
it only means anything against the archive the packages target.

`test_install.sh` runs the real thing in a clean `debian:sid` container. It
installs the bootstrap package, points the source at the freshly built
repository, and installs every wrapper package with signature verification
left on. Passthrough packages walk the path a user walks: the bootstrap, any
packages their spec's `with` names, then a real `apt-get install` — their
fork's CI has already proven the heavy install; this proves the repository
serves them correctly. Each one has to end up configured with its payload on
disk, which is the only check that catches a `postinst` that runs and does
nothing. Its positive control installs a package whose pinned hash is wrong
and fails the run if `dpkg` accepts it. Give it package names to test a
subset; with none it tests all of them, which downloads a few gigabytes.
Compiler bundles are not its job: their container coverage belongs to the two
suites below.

`test_compilers.sh` is the compiler matrix: every bundle the mirror covers,
sharded deterministically over the sorted catalog keys, in clean `debian:sid`
and `debian:trixie` containers. Install by `name=version`, launcher and links
answer, an `ldd` sweep of the whole payload resolves against what the package
declares, and the measured exceptions in `exceptions.json` are asserted both
directions — an exception that unexpectedly resolves fails as hard as a
surprise `not found`. On sid it additionally compiles and runs C/C++ per entry
level, verifies a cross-produced object against the payload's expected arch
with the payload's own binutils, and runs the install-UX legs the defer
section describes.

`test_precedence.sh` is the distro-precedence proof, on both baselines: every
emitted name is classified by live archive probes, the handover swap runs in
both directions over three representative regimes with exact remove/keep
assertions, and a control that flips the pin to 600 must flip every outcome.
The compiler section's defer claims are this suite's claims.

`test_failure_modes.sh` carries the failure-mode deltas the other suites do
not duplicate: the truncated-tarball arms above, the mutated listing, the
ghost-asset control for the mirror, the version-order gate driven against the
real inventory, and the RELR measurements recorded into `exceptions.json`.
Every control asserts a specific expected failure, and the suite fails if any
control is stubbed.

`test_gcc17.sh` runs after publishing rather than before it, because it checks
the repository as a user meets it: it installs the released bootstrap package,
watches `apt upgrade` carry a stale pinned install to the current one, installs
`gcc-17` from the published index, and runs the payload's compile battery. Its
distro-precedence half moved into `test_precedence.sh`; what remains unique
here is the published path and the battery, neither reproducible offline.

The publish step uploads everything and deletes assets for versions no longer
in the index. Only the current version of each package is served, which is all
`apt` needs.

## The exception: the Compiler Explorer mirror

The first redistribution exception. Compiler Explorer builds GCC and Clang for
every supported series and ships them as payload tarballs; GCC is GPL and may
be redistributed, and Compiler Explorer pays for its own S3 egress, so
re-publishing once from their bucket and pointing every install at the copy is
the only neighbourly shape. `mirror.py` does the copy: one pass per payload,
stream-only analysis, everything recorded into `mirror-manifest.json` at mirror
time and never recomputed per build.

The mirror carries two payload classes with opposite drift rules. Stables are
immutable: 222 catalog payloads (the latest point release of every in-scope
series, native and cross) are mirrored once, and a later size or ETag change
upstream is an alarm — `mirror.py check` exits 1 naming it and nothing
re-mirrors or self-heals a stable. Nightlies rotate: 9 trunk families (native
`gcc`/`clang` and seven cross) keep exactly the newest two dated assets per
family, a new date re-records the row without alarm, and rows orphaned by an
outside rotation are reaped rather than alarmed, because for this class a
vanished asset is the design, not drift. That is 238 mirrored payloads,
roughly 46 GiB.

Each catalog entry and each trunk family's newest row becomes one bundle deb:
231 emitted today. A bundle's postinst fetches the payload from the `mirror`
release and checks it against the sha256 the manifest recorded, then stages the
tree and renames it onto `/opt/<name>` atomically.

### Names, versions, and how a bundle defers

Bundle names are the Debian ones wherever Debian has them — `gcc-16`,
`clang-19`, `gcc-16-aarch64-linux-gnu` — so a script written against the
distribution spelling keeps working. Stable versions spell
`<series>~ce<upstream>-R`: `~ce` sorts below every version shape Debian uses
for that series (true point releases, date snapshots, the epoch-carrying
spellings clang has shipped, backports), and
`build.py` proves each emitted version against the catalog's recorded
per-suite corpus with `dpkg --compare-versions`, failing the build on a
violation. Nightlies keep `<major>~trunk<date>`, which sits below the same
corpus forms. Two sorts of names exist beside the Debian-shaped ones:
families Debian ships only unversioned (`gcc-avr` — spelled here `gcc-13-avr`),
and families with no Debian analog at all (`gcc-12-vax`, `gcc-7-k1`). All of
them carry the same `~ce` discipline.

Deferring then works in two regimes, and both rest on the same mechanism: the
glob stanza pins every bundle at 100 while the version sorts below anything
the archive can spell. Where Debian ships the name today, apt resolves the
distribution's package — `apt install gcc-16` never touches this repository's
one. Where only this repository ships the name, the bundle installs at 100 and
fills the gap until Debian starts shipping the name, after which an upgrade
swaps the bundle out in one transaction. `apt` will not downgrade across priorities,
so neither half alone suffices: a higher pin on Debian's side does not displace
an installed package whose version is higher, and a low version without the
pin would still win on the 500 a new Debian upload carries. Both halves are
always shipped together.

`test_precedence.sh` proves it end-to-end on `debian:sid` and `debian:trixie`,
against the live archive as oracle: every emitted name is probed for which side
resolves it; then the handover swap runs both directions over three
representatives that share the mechanism — native `gcc-16` with its real split
chain, epoch-spelled `clang-19`, and the cross `gcc-16-aarch64-linux-gnu` —
with exact remove/keep sets asserted per leg, and a pin-flip-to-600 control
that must reverse every outcome or the regime assertions prove nothing.

Install UX follows from the same rules, and `test_compilers.sh` asserts it on
the real built repository rather than describing it. Installing any emitted
name on its own resolves cleanly; under the wide globs `gcc-*` / `clang-*`
this repository's bundles lawfully join the solution set where only this
repository ships a name, and apt never reports one of its versions as a
conflict party there. The exception is the
unversioned-analog families: every series of one claims the same unversioned
Debian name (`gcc-13-avr` and `gcc-16-avr` both carry `Provides/Conflicts:
gcc-avr`), so the series install together no better than their Debian shapes
would, and a glob like `gcc-*-avr` aborts with `Reached two conflicting
assignments` — the exact text `test_compilers.sh` asserts, with each family
member resolving alone as its control arm. Install one series by name and it
asks nothing further of the user.

### gcc-17 as the instance

`gcc-17` is the head of the `gcc-trunk` nightly family: the deb version pins
the nightly's date (`17~trunk` followed by it), and the family machinery below
is what made the name follow the payload's probed major. It installs to
`/opt/gcc-17` and puts 28 commands on `PATH` under Debian's own `-17` names,
never shadowing Debian's default compiler.

Every front end and tool the payload ships is linked, spelled the way Debian
spells it, so a script written against `gcc-17` keeps working after the
distribution takes the name over:

    gcc-17     g++-17        cpp-17         gfortran-17
    gccgo-17   gdc-17        gm2-17         gcobol-17     gcobc-17
    gccrs-17   ga68-17
    gcc-ar-17  gcc-nm-17     gcc-ranlib-17
    gcov-17    gcov-dump-17  gcov-tool-17   lto-dump-17
    gnat-17    gnatbind-17   gnatchop-17    gnatclean-17  gnatkr-17
    gnatlink-17  gnatls-17   gnatmake-17    gnatname-17   gnatprep-17

The link table is derived from the mirror's recorded bin/ inventory, not
spelled out by hand: the payload's 73 bin/ names partition into the 27 links
above plus the `gcc-17` launcher itself, and 45 excluded names each carrying a
stated class, so a front end a future payload adds or drops fails the build
instead of going unnoticed. `build.py --selftest` re-derives this partition
from the committed manifest row and refuses any other accounting; the same
28/45 numbers are what the README check pins.

The 45 that are not linked fall into four classes. 27 are the bundled binutils
and gprofng: the driver finds them itself, and `dpkg -L` shows Debian's
`gcc-13` through `gcc-16` put none of them in `PATH` either. 15 are
`x86_64-linux-gnu-` aliases of drivers already linked; the payload spells them
without a version, so linking them would have to invent
`x86_64-linux-gnu-gcc-17`, a name no current Debian `gcc-NN` ships. `gcc-12`
did ship eight such names; `gcc-13` onwards ship none, so following the current
convention means leaving them out. One is `c++`, which Debian gives no `-NN`
spelling. The last two are `go` and `gofmt`, Go programs built against the
payload's own `libgo`, which exit 127 with `error while loading shared
libraries` unless the loader is pointed at `/opt/gcc-17/lib64`, and this
package sets no loader path.

A bundle's `Depends` come from the recorded analysis, not from a hand list: the
union of NEEDED sonames across the payload's host executables, mapped through
the era-aware soname table, plus two rules. Every compiler bundle declares
`libc6-dev`, because a compiler without the system C headers cannot preprocess
`<cstdio>`, let alone link — a dependency whose absence once survived a green
CI run on a machine that happened to carry `build-essential`. And any payload
shipping `gcobol` declares `libxml2`, because the payload's `libgcobol` objects
link it unversioned and no `--version` call touches it; the omission surfaced
only when a container without `libxml2` linked a COBOL program and `ld`
answered `undefined reference to xmlCtxtGetLastError@LIBXML2_2.6.0`. The
corresponding sweeps now run over the whole payload: `test_gcc17.sh` runs
`ldd` over every executable and shared object of `gcc-17` and
`test_compilers.sh` does the same per bundle, failing on anything `not found`
that no exception row covers.

Six files are the accepted exception, and they are the sweep's positive
control: `go`, `gofmt` and the four binaries `gccgo` runs for cgo — `buildid`,
`cgo`, `test2json` and `vet` — are built against the payload's own
`libgo.so.25` with no rpath to it. They are permanently unresolvable, so the
sweep asserts it still finds exactly six. The practical consequence is that
`gccgo-17` compiles pure Go, which the battery checks, but not Go that imports
`"C"`.

Nothing else is needed. The payload bundles its own binutils — the recorded
analysis proves `as`, `ld` and `ar` ship in the payload's `bin`, so no bundle
of this family depends on Debian's `binutils`. Measured, not assumed: a
container with `libc6-dev` and no `binutils` links and runs a C++ binary.

Binaries a bundle produces may need the matching runtime, because that lives in
the payload rather than in Debian. Either pass `-Wl,-rpath,/opt/gcc-17/lib64`
or link the runtime statically with `-static-libstdc++`. `test_gcc17.sh`
compiles and runs a C++ program the static way and a Fortran program the rpath
way, plus Ada, D, Modula-2, Go and COBOL batteries, so every form in this
paragraph is checked rather than assumed. `gccrs` still answers `gccrs is not
yet able to compile Rust code properly`, so it and `ga68` are started but not
exercised.

### Rotation, majors, and retention

Major bumps are per-class affairs, and neither class surprises. A stable can never bump:
its series is its name, it is mirrored once, and any upstream byte drift raises
the stable alarm above. A nightly family bumps in stride: the major is probed
out of each payload (`lib/gcc/<target>/<version>/` for GCC, `lib/clang/<major>/`
for Clang) and the asset is renamed to match, so the name can never lie about
the compiler inside it. The day GCC's master becomes 18, that night's upload
probes 18, the rotate keeps the newest two dated assets of the family, and the
emitted bundle's name and version follow the probe — `gcc-17` stops being
offered while the name's installed copies simply keep running, since apt has
no rename, and `gcc-18` is the name that now tracks trunk. Keep-two is the
whole retention for nightlies; stables are never pruned, because the series
they mirror does not rotate.

## The exception: juno-drivers-diamon

The second redistribution exception. `juno-drivers-diamon` is Juno Computers'
driver package as maintained in
[DiamonDinoia/juno-drivers-debian](https://github.com/DiamonDinoia/juno-drivers-debian),
a fork that carries local fixes on top of Juno's packaging. The fork's CI
builds the `.deb`, installs it in a clean `debian:sid` container (starting from
Juno's own packages, to prove the swap), and publishes it as an asset of its
`builds` release. The same shape covers the fork-built `clevo-keyboard-dkms`
payload and the fan-control package from
[DiamonDinoia/juno-kde-fancontrol](https://github.com/DiamonDinoia/juno-kde-fancontrol).

The wrapper shapes would drop the maintainer scripts that do the real work, so
this package serves that `.deb` itself, bit-identical: `packages.toml` resolves
the newest asset on the release, and the build stops unless the bytes hash to
the digest GitHub reported and the deb's own `Package:`/`Version:` match. Only
the packages the forks build are released this way; Juno's unmodified packages
(`juno-info`, the wallpapers and so on) keep coming from Juno's repository,
which `diamondinoia-repo-juno` adds.

The fork versions its builds `0.5.48.2+diamonN`, which sorts above Juno's
`0.5.48~debian`, so at the archive's own 500 pin the fork wins on version
alone. If a Juno release ever lands before the fork rebuilds, that release
becomes visible and installable rather than shadowed — and the daily workflow
in the fork watches Juno's changelog and opens an issue, which is the signal
to rebase and bump the diamon suffix.

The package Provides/Conflicts/Replaces `juno-drivers`, `juno-drivers-local`
and `juno-grub`, so every earlier layout swaps out. `juno-info` and
`check-battery`, which only Juno publishes, sit in its `Depends`, so the
install is

    sudo apt-get install diamondinoia-repo-juno
    sudo apt-get install juno-drivers-diamon

and `test_install.sh` walks exactly that path in a container. The version
jumps, `+localN` → `0.5.48.1+diamonN` → merge, are recorded in the fork's
changelog; the `.1` bump existed because `+diamon1` alone would have sorted
below the then-installed `+local1`.

## Signing key

The workflow expects a `GPG_PRIVATE_KEY` secret holding an ASCII-armoured
private key used for nothing else:

    gpg --batch --quick-generate-key 'DiamonDinoia apt <mbarbone@flatironinstitute.org>' rsa4096 sign never
    gpg --armor --export-secret-keys <key-id> | gh secret set GPG_PRIVATE_KEY --repo DiamonDinoia/apt

The public half is published as `KEY.gpg`, so it is never committed.

## Limits

`amd64` only. One version per package.

The payload is downloaded during `postinst`, not during `apt`'s own download
phase, so an install needs working network at configure time.
`apt-get --download-only` fetches nothing usable, and an offline install fails.

A wrapper's pinned hash is only as current as the last nightly run. If a
publisher replaces an artifact in place under a URL that does not name its
version, the next install fails the checksum until the next build. That is the
intended failure: a payload that does not match what was signed is refused,
never installed. A bundle's payload cannot drift this way — the mirrored bytes
are frozen and the manifest's sha256 is what the postinst checks; drift of a
stable is a mirror alarm, and nightly rotation is the mirror's own bookkeeping.

Two era gcc bundles refuse to install at all, and the refusal is the defer
scheme working as designed: Debian's `libstdc++6` declares a versioned
`Breaks` on them at revisions any below-everything spelling always falls
inside, and `libstdc++6` cannot be removed. The rows live in
`exceptions.json` under `cutoff.install_refusals` and the matrix asserts them
in both directions:

    gcc-4.4  gcc-4.5

A glob spanning several series of one unversioned-analog family
(`gcc-*-avr`, `gcc-*-arm-none-eabi`) cannot resolve, by design: the series
conflict on their shared unversioned name. Install the series wanted by name.
The wide `gcc-*` / `clang-*` globs are unaffected and safe.
