# apt

A flat Debian repository for amd64, rebuilt nightly from upstream releases and
published as assets of the `repo` GitHub release. Each wrapper package is a few
kilobytes of maintainer script whose `postinst` downloads the payload from the
publisher and checks it against a SHA-256 pinned at build time. Two classes
redistribute bytes. The compiler bundles mirror the GPL Compiler Explorer
payloads onto the `mirror` release. The fork-built debs marked below are served
bit-identical, because their maintainer scripts are the package.

## Contents

Compiler bundles under Debian's own names (`gcc-16`, `clang-19`, the cross
variants). Binaries a bundle produces may need the matching runtime, because
that lives in the payload rather than in Debian. Either pass
`-Wl,-rpath,/opt/gcc-17/lib64` or link the runtime statically with
`-static-libstdc++`.

The wrappers and the fork-built debs:

- `act`: run GitHub Actions locally
- `lazygit`: terminal UI for git commands
- `stylua`: Lua code formatter
- `galaxybudsclient`: manager for Samsung Galaxy Buds
- `ghostty`: GPU-accelerated terminal emulator
- `discord`: voice and text chat client
- `zoom`: video conferencing client
- `clion`: JetBrains C and C++ IDE
- `zed`: multiplayer code editor
- `watchexec`: run commands when files change
- `difftastic`: structural diff that understands syntax
- `lua-language-server`: language server for Lua
- `intel-sde`: Intel Software Development Emulator
- `juno-drivers-diamon`: Juno laptop drivers, forked build (installs together
  with `diamondinoia-repo-juno`)
- `clevo-keyboard-dkms`: Clevo keyboard/backlight driver (dkms), forked build
- `juno-kde-fancontrol`: fan control for Juno (Clevo) laptops
- `ec-sys-dkms`: ec_sys embedded-controller debugfs module (dkms), forked build
- `clevofan-dkms`: Clevo EC fan-control module (dkms), forked build
- `diamondinoia-repo-cuda`: apt source for NVIDIA's CUDA repository
- `diamondinoia-repo-juno`: apt source for Juno Computers' repository

## Install

One package installs the key, the source and the pin file:

    base=https://github.com/DiamonDinoia/apt/releases/download/repo
    deb=$(curl -fsSL $base/Packages | sed -n 's/^Filename: \(diamondinoia-apt_.*\)$/\1/p')
    curl -fsSLO "$base/$deb"
    sudo apt-get install ./"$deb"
    sudo apt-get update

The pin file sets a priority for each package this repository serves: 600
for the wrapper and repository packages, which then win over Debian's
default 500; 500 for passthrough packages, which compete with the original
package on version; 100 for compiler-namespace packages; -1 for every other
package, which apt then refuses to install from this repository. The same
package also adds the apt sources and
keys of nine third-party repositories: brave, github-cli, google-cloud-cli,
llvm, nvidia-container-toolkit, onlyoffice, tailscale, vscode and yazi. The
pin file does not cover those sources; they stay at apt's default priority
and can shadow Debian. Install anything from the list by name, for example
`sudo apt-get install lazygit`. Juno laptops also install
`diamondinoia-repo-juno` before `juno-drivers-diamon`:

    sudo apt-get install diamondinoia-repo-juno

A package downloads its payload during `postinst`, not during `apt`'s own
download phase, so an install needs working network at configure time.

Maintainer documentation lives in [doc/maintaining.md](doc/maintaining.md).
