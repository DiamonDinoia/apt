# apt

A flat Debian repository, rebuilt nightly from upstream releases. It puts tools
that ship only as a GitHub release artifact under `apt` control, and replaces
third-party repositories that either lag upstream or are run by somebody other
than the vendor.

Nothing upstream is redistributed, with one deliberate exception below. Every
package is a few kilobytes of maintainer script: `postinst` downloads the file
from the publisher and checks it against a SHA-256 pinned when the package was
built. Thirteen packages and the signed index come to under 35 kB.

That is what makes proprietary software packageable here. Discord, Zoom and
CLion forbid redistribution, and none of their bytes pass through this
repository. It is the same shape Debian itself uses for
`ttf-mscorefonts-installer`. It also removes the reason to care how large an
upstream artifact is.

The index and the packages are published as assets of a single GitHub release
tagged `repo`.

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

    Package: diamondinoia-apt diamondinoia-repo-cuda diamondinoia-repo-juno act
     lazygit stylua galaxybudsclient ghostty discord zoom clion zed watchexec
     difftastic lua-language-server
    Pin: release l=diamondinoia
    Pin-Priority: 600

    Package: gcc-17
    Pin: release l=diamondinoia
    Pin-Priority: 100

The pin matches the `Release` label rather than `github.com`, so it holds
whatever the repository is served from and never claims every package hosted on
GitHub.

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

The third stanza is for a package that only fills a gap until Debian fills it.
At 100 it installs while Debian has no package of that name, and loses to
Debian's own 500 the day Debian ships one, whatever the two versions are. A
package left out of both lists would fall to the `-1` default and never install
at all, so the low stanza is what makes deferring possible.

The bootstrap package's version tracks the signing key. Rotating the key offers
an upgrade that replaces the keyring, instead of leaving users with an index
they cannot verify.

## Add a package

Append a block to `packages.toml`. `install` picks one of three shapes.

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
fails rather than leaving a tree nothing can start. A tree that ships a
toolchain names further commands in `links` (`{ "g++-17" = "bin/g++" }`);
each one is checked at install so a target upstream dropped fails loudly
instead of dangling.

Any shape resolves its version one of three ways: a GitHub release (`repo` plus
an `asset` regex), a JSON feed (`json` plus `json_path` and `version_re`), or a
URL that redirects to a versioned path (`url` plus `version_re`). GitHub tags
have a leading `v` stripped. Adding `tag` reads a fixed release instead of the
latest one; there several versions coexist as assets, so `version_re` extracts
the version from the asset name and the greatest one is current. A `version_re`
with two capture groups joins them with `~`, which makes a pre-release version
that sorts below every real release of the same major.

Add `defer_to_debian = true` for a package that carries a name Debian will
eventually use itself. It moves out of the 600 pin into the 100 one, so Debian
wins the moment it publishes that name.

Add `icon`, `desktop_name` and `desktop_categories` for a GUI application. A
`tree` package's `icon` is a path inside the payload; a `member` package has
nowhere to put one, so it names a stock icon.

## How it works

`build.py` resolves every package's current upstream version and its SHA-256.
GitHub publishes a `digest` field on every release asset and JetBrains publishes
a `.sha256` beside each tarball, so those packages are never downloaded at all.
Only Discord and Zoom, which publish no checksum, are fetched once per upstream
version to be hashed, along with every `.deb` payload, whose own `Depends` can
be read no other way. A payload that is fetched and also carries a published
digest has the two compared, so a checksum that disagrees with the bytes fails
the build. The payload is cached and never enters a package. `build.py` then
generates `Packages`, `Packages.gz` and `Release` and signs them
into `InRelease` and `Release.gpg`.

`test_repo.sh` runs before anything is published. It points a throwaway `apt`
configuration at the built repository plus the host's real sources, then checks
that every advertised package resolves at its advertised version from this
repository, that every pinned payload URL still answers, and that every pinned
hash is a SHA-256. Two positive controls back those checks: a `Packages` mutated
after `Release` was signed must be rejected, and a missing payload URL must fail
the probe. Dependency resolution is deliberately not simulated here, because it
only means anything against the archive the packages target.

`test_install.sh` runs the real thing in a clean `debian:sid` container. It
installs the bootstrap package, points the source at the freshly built
repository, and installs every package with signature verification left on. Each
one has to end up configured with its payload on disk, which is the only check
that catches a `postinst` that runs and does nothing. Its positive control
installs a package whose pinned hash is wrong and fails the run if `dpkg`
accepts it. Give it package names to test a subset; with none it tests all of
them, which downloads a few gigabytes.

`test_gcc17.sh` runs after publishing rather than before it, because it checks
the repository as a user meets it: it installs the bootstrap package in a
`debian:sid` container, installs `gcc-17` from the published index, compiles and
runs a C++ and a Fortran program, and then simulates Debian shipping its own
`gcc-17` to confirm the handover. A rejected invalid program proves the
successful compiles are not vacuous.

The publish step uploads everything and deletes assets for versions no longer in
the index. Only the current version of each package is served, which is all
`apt` needs.

## The exception: gcc-17

`gcc-17` is Compiler Explorer's nightly build of GCC master. Compiler
Explorer pays for its own S3 egress, so pointing every install at their bucket
would spend their money. GCC is GPL and may be redistributed, so `mirror.sh`
downloads each new nightly from them exactly once and re-publishes it as an
asset of the `mirror` release here; the package pins the GitHub URL, and no
install or test ever reaches their bucket. The 4e8-byte tarball is what costs
them, and it moves once per version. The one bucket listing per workflow run,
which is how a new version is noticed, is unavoidable and negligible. The exact source commit of every
build is embedded in `gcc-17 --version`. The newest two versions are kept.

It installs to `/opt/gcc-17` and puts 28 commands on `PATH` under Debian's own
`-17` names, never shadowing Debian's default compiler.

It depends on `libc6-dev`, the same as Debian's own `gcc-NN`: the payload
carries a compiler, not a C library, so without the system headers it cannot
preprocess `<cstdio>`, let alone link. Declaring that is not optional. A machine
that happens to have `build-essential` hides the omission, which is exactly how
it survived a green CI run.

It also depends on `libxml2`, which the nine `libgcobol` objects link against.
Nothing in `gcobol-17 --version` touches it, so the omission only appeared when
a container with no `libxml2` tried to link a COBOL program and `ld` reported
`undefined reference to xmlCtxtGetLastError@LIBXML2_2.6.0`. `test_gcc17.sh` now
runs `ldd` over every executable and every shared object under `/opt/gcc-17`
and fails on anything reported `not found`.

Six files are the exception, and they are the test's positive control: `go`,
`gofmt` and the four binaries `gccgo` runs for cgo, `buildid`, `cgo`,
`test2json` and `vet`, are built against the payload's own `libgo.so.25` with
no rpath to it. They are permanently unresolvable, so the sweep asserts it
still finds exactly six. The practical consequence is that `gccgo-17` compiles
pure Go, which the test checks, but not Go that imports `"C"`.

It needs nothing else. The payload bundles its own binutils, so `as`, `ld`,
`ar`, `nm`, `objdump`, `readelf`, `strip` and `gprofng` come from
`/opt/gcc-17/bin` and there is no dependency on Debian's `binutils`. Measured,
not assumed: a container with `libc6-dev` and no `binutils` links and runs a
C++ binary.

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

The list comes from `packages.toml`, and `test_gcc17.sh` reads it from there
and runs every entry, so a tool a future payload drops fails CI rather than
becoming a dangling symlink. The reverse direction is checked too: the 73
executables in the payload's `bin` are 28 linked ones plus 45 excluded for a
stated reason, and a name in neither set fails the test, so a front end a
future payload adds cannot go unnoticed. Beyond starting them it compiles and runs a
program in each language that can be compiled today, C, C++, Fortran, Ada, D,
Modula-2, Go and COBOL, each summing 1 to 100. `gccrs` still answers `gccrs is
not yet able to compile Rust code properly`, so it and `ga68` are started but
not exercised.

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

Binaries it produces may need the matching runtime, because that lives in the
payload rather than in Debian. Either pass `-Wl,-rpath,/opt/gcc-17/lib64` or
link the runtime statically with `-static-libstdc++`. `test_gcc17.sh` compiles
and runs a C++ program the static way and a Fortran program the rpath way, so
both forms in this paragraph are checked rather than assumed.

The name and the commands are Debian's, on purpose. The version is
`17~trunkYYYYMMDD`, and `~` sorts below a plain digit, so this package stays
below the two forms Debian has used for a `gcc-NN` package, `17.1.0-1` and
`17-<date>-1`, both measured with `dpkg --compare-versions`. Debian's real
`gcc-17` then replaces this one on a plain `apt upgrade` the day it reaches
unstable, with nothing to uninstall by hand.

The claim is that narrow on purpose. After a `~` the rest is compared as text,
so `17~exp1-1` and `17~rc1-1` both sort *above* `17~trunk20260828`. Debian has
never numbered a `gcc-NN` upload that way, but if it did, the handover would
need `apt install gcc-17=<version>` once by hand. No version string avoids
this: anything sorting below `17~exp` also sorts below the nightlies already
installed, which would stop those machines receiving any further nightly.

Handover happens from unstable, not from experimental. Debian's experimental
`Release` carries `NotAutomatic: yes` and no `ButAutomaticUpgrades`, so apt
gives it priority 1, below the 100 this package holds. A `gcc-17` that only
ever reaches experimental therefore does not displace the nightly, which is
also what a user who enabled experimental should expect.

Both halves are needed. `apt` will not downgrade across priorities, so a higher
pin on Debian's side does not by itself displace a nightly whose version is
higher; the version has to sort below Debian's as well. `test_gcc17.sh` checks
the handover in a container against a second repository standing in for Debian,
and its control raises the pin to 600 with nothing else changed to show the pin
is what decides.

### Moving to gcc-18

The bump is deliberately manual, once per GCC release cycle. The major is
written into the `asset` regex rather than derived from the payload, so the
spring that trunk becomes 18, the nightly stops with

    gcc-17: no asset matches '^gcc-17-trunk[0-9]{8}\.tar\.xz$'; have: gcc-18-trunk20270415.tar.xz

That failure names the new major and is the whole reminder mechanism. To act on
it, rename the `[gcc-17]` block to `[gcc-18]` and change `17` to `18` in
`asset`, `version_re` and `links`. Nothing else moves.

Deriving the name from the payload instead would be automatic but wrong in two
ways. A package that renames itself has no upgrade path in `apt`, so anyone
holding the old name would silently stop receiving updates. And publishing GCC
18 under the name `gcc-17` would leave Debian's real `gcc-17`, when it arrives,
looking like the newer version of a compiler it is older than.

The failure is loud rather than silent because `mirror.sh` reads the major out
of the payload's `lib/gcc/<target>/<version>/` path and puts it in the asset
name, so the name can never disagree with the compiler inside it.

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

A pinned hash is only as current as the last nightly run. If a publisher
replaces an artifact in place under a URL that does not name its version, the
next install fails the checksum until the next build. That is the intended
failure: a payload that does not match what was signed is refused, never
installed.
