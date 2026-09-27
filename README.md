# my-shell

Portable, idempotent setup script for a Linux (and macOS) developer workstation:
zsh + Powerlevel10k, vim, Nerd Fonts, the Kubernetes/OpenShift CLI set, and a
declarative manifest of dev tools.

```bash
./my-shell.sh --dry-run     # see what would happen
./my-shell.sh               # do it
```

---

## What it does

| Section   | What you get                                                                    |
|-----------|---------------------------------------------------------------------------------|
| `deps`    | the `deps` group of the manifest + `fontconfig`                                   |
| `fonts`   | MesloLGS NF and/or Hack Nerd Font, plus a rebuilt font cache                      |
| `zsh`     | `zsh`, Oh My Zsh, a starter `~/.zshrc`                                            |
| `plugins` | `zsh-autosuggestions`, `zsh-history-substring-search`, `zsh-syntax-highlighting`   |
| `theme`   | Powerlevel10k (or starship) + `~/.p10k.zsh`                                       |
| `k8s`     | `kubectl`, `oc`, `kubectx`, `kubens`, `stern` + completions and aliases           |
| `vim`     | `vim` + `~/.vimrc`                                                               |
| `git`     | safe global git defaults — **opt-in**                                             |
| `extras`  | tools from the manifest (`config_files/tools.conf`) — **opt-in**                 |
| `shell`   | `chsh` to the target shell — **opt-in**                                          |

Pick what runs:

```bash
./my-shell.sh --only=fonts,theme          # exactly these
./my-shell.sh --skip=fonts                # everything but these
./my-shell.sh --all                       # including git/extras/shell
```

## The tool manifest

The list of tools a new machine should end up with is **data, not code**. It lives
in [`config_files/tools.conf`](config_files/tools.conf), one tool per line:

```
id | group | method | arg | package mapping | note | probe
zoxide|daily|pkg|-|pacman=zoxide,apt=zoxide,dnf=zoxide,zypper=zoxide,apk=zoxide,brew=zoxide|cd that learns your habits|-
```

* `group` — what `--extras=<group>` selects: `deps daily k8s terminal secrets gui ai`.
  The `deps` group is special: the `deps` section installs it on every run without
  you asking for a profile, which is what makes the manifest the single place that
  says what a new machine needs.
* `method` — `pkg` (resolve the name), `npm`, `uv`, `cargo`, `official` (run an
  installer), or `none` (not a package: listed so the inventory stays complete,
  but a dedicated section installs it)
* `package mapping` — `manager=package` pairs; `-` means "not on this manager"
* `probe` — executables that count as "already installed", when it is not the id
  (Debian calls it `fdfind`, `btop`, `codium`)

`kubectl`, `oc`, `kubectx`, `kubens` and `stern` use `method=none`. They are not
packages anywhere: the `k8s` section downloads them, verifies their checksums
and pins their versions. They are in the manifest anyway so that one file lists
everything a machine ends up with, and so `--skip-tools` reaches them like any
other tool. Selecting them with `--tools` or `--extras` does nothing on its own —
keep the `k8s` section enabled.

The manifest is checked at the start of every run: a line with the wrong number
of fields, a repeated id, or a `probe` that is a sentence instead of a list of
executable names is reported and skipped. That last one matters more than it
looks — a `probe` is handed to the lookup as a command name, so a bad value makes
the script report a tool as installed when it is not.

A mapping that names a package the archive does not have is not treated as an
error. The script installs what it can, says which archive it looked in, and
carries on:

```
[ warn] helm: 'helm' is not in the debian 12 archive; take it from its own release page
```

Marking it `-` instead would be wrong: the next Debian release packages several
of them, and `-` would keep refusing. Trying is what self-corrects.

So a new workstation is a one-line diff, not a code change:

```bash
# a devops box
./my-shell.sh --extras=daily,k8s,terminal,secrets --aur

# individual tools
./my-shell.sh --extras --tools=zoxide,sops,lazygit

# drop the ones you already have your own way
./my-shell.sh --extras=daily --skip-tools=bat,eza

# --skip-tools also covers the binaries the k8s section downloads
./my-shell.sh --extras=k8s --skip-tools=kubectx,stern
```

A tool that cannot be installed on the current distribution is **reported and
skipped**, never fatal — the manifest's `note` column says why.

Nothing in the manifest needs `sudo` beyond the package manager, with one
exception: `npm install -g` writes to npm's global prefix, which is root-owned
on most distributions. The script checks that first and, rather than stopping
the run on a password prompt, prints the two commands to run yourself. The
`ai` group is never selected by a default profile anyway, because both `npm`
and `official` installers download and run third-party code.

## Supported distributions

Detection goes through `/etc/os-release` (`ID`, then `ID_LIKE`), with a fallback to
the legacy `/etc/*-release` files, and it can always be forced:

| Family             | Distributions                                                        | Manager   |
|--------------------|----------------------------------------------------------------------|-----------|
| `debian`           | Debian, Ubuntu, Mint, Pop!\_OS, Elementary, Kali, Parrot, Devuan, …   | `apt`     |
| `rhel`             | Fedora, RHEL, CentOS, Rocky, AlmaLinux, Oracle, Amazon Linux         | `dnf`/`yum`|
| `suse`             | openSUSE (Leap/Tumbleweed/MicroOS), SLES                             | `zypper`  |
| `arch`             | Arch, Manjaro, EndeavourOS, **CachyOS**, Garuda, Artix               | `pacman`  |
| `alpine`           | Alpine                                                              | `apk`     |
| `gentoo`           | Gentoo, Funtoo                                                      | `emerge`  |
| `void`             | Void                                                                | `xbps`    |
| `nixos`            | NixOS                                                               | `nix`     |
| `solus`            | Solus                                                               | `eopkg`   |
| `darwin`           | macOS                                                               | `brew`    |

Anything else: `--pkg-manager=<name>` (or a pull request adding the `case` arm in
`pkg_manager_for_id`). On a machine with no `bash` at all — Alpine, debootstrap
images — the POSIX preamble at the top of the file installs it first and then
re-executes itself.

Architectures: `x86_64`, `aarch64`, `armv7l`, `armv6l`, `i686`, `s390x`,
`ppc64le`, `riscv64`, `loongarch64`, plus Rosetta detection on macOS.

## Safety model

The previous version of this script destroyed user configuration. Concretely,
it deleted `~/.p10k.zsh` with `rm -f` and no prompt at all, `rm -rf`'d
`~/.oh-my-zsh`, ran the Oh My Zsh installer unconditionally — duplicating an
install that a distribution package already provides — and referenced a
`kube-ps1` plugin it never installed. It also could not be scripted: on a
non-TTY, `read -p` in its overwrite prompt returns nothing, so the `while true`
around it looped forever. Those are gone. The rules now are:

* **Nothing is overwritten silently.** For an existing dotfile you get
  `keep` / `backup` / `merge` / `cancel`. `--yes` and non-interactive runs pick
  `merge`, which is additive and safe.
* **Everything lands in a delimited block.** Every change to a dotfile is
  written between

  ```
  # >>> my-shell managed block >>>
  # <<< my-shell managed block <<<
  ```

  Re-running rewrites that block in place, so there are no duplicated
  completions or aliases. Delete the block to get your original file back.

  Inside the block, each contribution is tagged with the section that wrote it:

  ```
  # [my-shell:history] shell history tuning
  ```

  That tag is what makes the block repairable. A run that only re-runs one
  section rewrites that one part and leaves the others exactly where they were,
  and a part that has since become invalid gets fixed the next time its section
  runs. A block written by a version predating the tags is left untouched rather
  than guessed at, with the one `sed` command needed to remove it.
* **Package-owned files are never touched** (`dpkg -S`, `rpm -qf`, `pacman -Qo`).
* **Distribution shell configs are adopted, not replaced.** If your `~/.zshrc`
  sources something from `/usr/share` (CachyOS, Arch, Ubuntu, Fedora …), the
  script detects that — *including transitively*, since those files are often a
  one-liner pointing at a large config — and leaves the whole prompt alone. It
  only installs what is genuinely missing.
* **Plugins are reused, not re-cloned.** If the distribution already ships a
  plugin it is sourced from there; only what is missing is fetched, into a
  user-owned directory that needs no `sudo`.
* **No full system upgrade** unless you pass `--upgrade`. On Arch in particular
  `pacman -Sy` followed by `pacman -S` is a partial upgrade and breaks the
  system, so the refresh is skipped by default.
* **Downloads are checksum-verified** (`kubectl`, `kubectx`, `kubens`, `stern`).
  The OpenShift mirror publishes no checksum for `oc`; that is called out.
* **`--dry-run` changes nothing.** It never writes, including inside existing
  managed blocks. It also predicts privilege escalation correctly: a directory
  that does not exist yet but whose parent is writable is reported without
  `sudo`, because that is what the real run would do.

## Reporting and exit status

The run always goes to the end. A download that cannot complete, a font archive
that comes back truncated, a `chsh` that needs a password you are not there to
type — none of these abandon the setup half-finished. They are reported, and the
summary marks which sections were affected:

```
  fonts      done
  k8s        finished with 1 problem(s)
[ fail] 2 step(s) did not complete; the run finished anyway
```

**The exit status is non-zero if any step did not complete**, so a provisioning
pipeline or a dotfile installer that runs this can tell the difference between
"everything is configured" and "the script did not crash". A step that was not
needed — a tool already present, a font family already installed — is a `[ skip]`
and counts for nothing.

Two categories are deliberately *not* fatal, because aborting would be worse than
the problem: a font or a login-shell change that needs `sudo` prints the exact
command to run yourself, and a download failure prints the URL. Both still count
as problems in the exit status.

A message that says what went wrong is worth more than one that says it failed.
The two that come up most often are called out by name:

* **GitHub rate limits.** Resolving "the latest release" uses the GitHub API,
  which allows 60 unauthenticated requests an hour *per IP* — and every machine
  behind the same NAT shares that budget. When it runs out the script says so and
  names the flag that skips the lookup, instead of failing with a generic message
  that sends you looking for a network problem that does not exist. One answer is
  cached per repository per run, so installing both nerd fonts costs one request
  and not two.
* **A command that is not installed.** `chsh`, for instance, is in `util-linux` on
  Debian, `shadow` on Alpine and `shadow-utils` on RHEL. "run `sudo chsh`
  yourself" is useless advice when `chsh` is not there, so the script names the
  package that provides it.

## Notes and deliberate choices

* **`kube-ps1` is opt-in (`--kube-ps1`) and off by default.** Powerlevel10k has a
  native `kubecontext` segment, and the bundled `config_files/p10k.zsh` already
  enables it. `kube-ps1` works by rewriting `$PROMPT`, which fights with p10k.
* **Plugins are sourced explicitly** from the managed block rather than through
  the `plugins=(...)` array. `zsh-syntax-highlighting` must be sourced last, and
  this works whether Oh My Zsh comes from a tarball or from a distribution
  package.
* **`~/.p10k.zsh` is never clobbered** unless you pass `--replace-p10k`; an
  existing one is left alone so `p10k configure` stays authoritative. A backup is
  taken before any replacement.
* **The prompt is checked for what it needs.** The bundled `config_files/p10k.zsh`
  shows the git status, which comes from `vcs_info`. Most distributions build
  that into `zsh`; Alpine ships it as a separate `zsh-vcs` package. Without it the
  prompt still appears and prints `vcs_info: function definition file not found`
  on every redraw, which most people read as part of the theme. The `theme`
  section checks for it and says so once. The check looks for the function file
  rather than running `zmodload zsh/vcs_info`, because on Alpine it is autoloaded
  and is not a loadable module at all.
* **`ca-certificates` is a base requirement**, not a nicety. Every download here
  is over HTTPS, and `debian:bookworm-slim` ships without a trust store — the
  symptom is `server certificate verification failed` from git and curl exit 77
  from the font archives, which reads like a network problem. It is in the
  manifest's `deps` group, and curl exit 77 is reported as what it is.
* **Backups** go to `${XDG_STATE_HOME:-~/.local/state}/my-shell/backups/`
  (`--backup-dir` to change). `/etc/passwd` is backed up before `chsh`.
* **Binaries** go to `/usr/local/bin` when it is writable, otherwise to
  `~/.local/bin` so the script works without `sudo` at all. Because that
  directory may not be on your `PATH` yet, the script looks for its own previous
  installs there too — otherwise the second run would not recognise them and
  would download everything again.
* **`oc` is not refreshed automatically.** The OpenShift mirror serves a single
  rolling `latest` tarball with no version index and no checksum, so there is no
  way to tell whether the installed client is current. It is left alone if
  present, and the summary says how to force a refresh.
* **`--aur` is opt-in.** AUR packages are built from a PKGBUILD, which is
  arbitrary code executed as root. No helper (`paru`, `yay`, `pikaur`, `trizen`)
  is ever used unless you ask for it.
* **git defaults never override an existing value** — they only fill in keys you
  have not set.

## Useful options

```
-n, --dry-run            print what would happen, change nothing
-y, --yes                non-interactive
-v, --verbose            extra diagnostics
    --no-color           disable ANSI colours
-h, --help               this text
    --version            print the version and exit
    --only=a,b / --skip=a,b / --all
    --prompt=powerlevel10k|starship|none
    --fonts=both|meslo|hack|none       --font-dir=DIR   --font-version=vX.Y.Z
    --shell=zsh|bash|fish              target shell for completions and chsh
    --kube-ps1                         opt in to kube-ps1 anyway
    --replace-p10k                     overwrite ~/.p10k.zsh with the repo version
    --git                              safe git defaults
    --extras[=daily,k8s,terminal,secrets,gui,ai]
    --tools=zoxide,sops,lazygit        specific manifest tools
    --skip-tools=bat,eza               drop tools from the selection
    --extra=pkg1,pkg2                  raw package names, not in the manifest
    --aur                             allow AUR installs via paru/yay/pikaur/trizen
    --upgrade                          allow a full system upgrade
    --set-default-shell                change the login shell without asking
    --kubectl-version=V --kubectx-version=V --stern-version=V
    --pkg-manager=NAME
```

`--extras` with no value is shorthand for `--extras=daily`.

## Examples

```bash
# first look, change nothing
./my-shell.sh --dry-run

# a devops box: prompt, k8s tooling, git defaults, no fonts
./my-shell.sh --only=theme,k8s,git

# everything except a full system upgrade
./my-shell.sh --all --skip=shell

# Debian laptop, no sudo needed (user-writable font and bin dirs)
./my-shell.sh --font-dir="$HOME/.local/share/fonts" --only=deps,fonts,k8s

# a full devops workstation, tools from the manifest
./my-shell.sh --extras=daily,k8s,terminal,secrets --aur
```

## After it finishes

```bash
sed -n '/my-shell/,$p' ~/.zshrc   # review exactly what was added
p10k configure                    # regenerate the prompt config
```

## Files

```
my-shell.sh              the script (POSIX preamble + bash body)
config_files/p10k.zsh    Powerlevel10k configuration
config_files/zshrc-omz   starter .zshrc, only used when none exists
config_files/vimrc       vim configuration
config_files/tools.conf  the tool manifest: groups, per-distro names, install method
```

`config_files/zshrc-omz` and `config_files/vimrc` are only installed when the
corresponding file does not exist, or when you explicitly choose `backup`.

## Development

The script is `shellcheck`-clean at `style` severity:

```bash
shellcheck my-shell.sh
bash -n my-shell.sh
```

Both are worth running in CI; `.shellcheckrc` tells shellcheck that the file is
a `sh`/`bash` polyglot.

`config_files/tools.conf` is plain data, so it can be checked on its own:

```bash
# every entry has the same number of fields, no duplicate ids
awk -F'|' '!/^#/ && NF && NF != 7 {print NR": "NF" fields"}' config_files/tools.conf
grep -vE '^#|^$' config_files/tools.conf | cut -d'|' -f1 | sort | uniq -d
```
