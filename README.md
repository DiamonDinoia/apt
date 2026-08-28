# apt

A flat Debian repository, rebuilt nightly from upstream releases. It puts tools
that ship only as a GitHub release artifact under `apt` control, and replaces
third-party repositories that either lag upstream or are run by somebody other
than the vendor.

Nothing upstream is redistributed. Every package is a few kilobytes of
maintainer script: `postinst` downloads the file from the publisher and checks
it against a SHA-256 pinned when the package was built. Twelve packages and the
signed index come to 31 kB.

That is what makes proprietary software packageable here. Discord, Zoom and
CLion forbid redistribution, and none of their bytes pass through this
repository. It is the same shape Debian itself uses for
`ttf-mscorefonts-installer`. It also removes the reason to care how large an
upstream artifact is.

The index and the packages are published as assets of a single GitHub release
tagged `repo`.

## Use it

One package installs the key, the source and the pin:

    curl -fsSLO https://github.com/DiamonDinoia/apt/releases/download/repo/diamondinoia-apt_1.0+939a3a3d_all.deb
    sudo apt-get install ./diamondinoia-apt_*.deb
    sudo apt-get update

The pin it installs confines this repository to the packages it is meant to
provide, so it can never shadow Debian:

    Package: *
    Pin: release l=diamondinoia
    Pin-Priority: -1

    Package: diamondinoia-apt act lazygit stylua galaxybudsclient ghostty
     discord zoom clion zed watchexec difftastic lua-language-server
    Pin: release l=diamondinoia
    Pin-Priority: 600

The pin matches the `Release` label rather than `github.com`, so it holds
whatever the repository is served from and never claims every package hosted on
GitHub.

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
writes a desktop entry. One wrapping directory is stripped; set `strip = 0` for
an archive that has none. If no `launcher` exists the install fails rather than
leaving a tree nothing can start.

Any shape resolves its version one of three ways: a GitHub release (`repo` plus
an `asset` regex), a JSON feed (`json` plus `json_path` and `version_re`), or a
URL that redirects to a versioned path (`url` plus `version_re`). GitHub tags
have a leading `v` stripped.

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

The publish step uploads everything and deletes assets for versions no longer in
the index. Only the current version of each package is served, which is all
`apt` needs.

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
