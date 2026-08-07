# Open With Obsidian

Open Markdown files in Obsidian from Finder on macOS, including files that are
outside an existing Obsidian vault. Files already inside a registered vault are
opened directly. External files are represented by temporary symlinks in a
ScratchVault; the original files are never moved or modified.

## Upstream and customizations

This project is a customized derivative of
[`ZndrrMr/open-with-obsidian`](https://github.com/ZndrrMr/open-with-obsidian),
which provides the original Finder-to-Obsidian workflow and ScratchVault
concept. The upstream project is released under the MIT License.

This repository is maintained for my macOS setup and is not an official
upstream release. Custom work includes:

- a flat `src/` repository layout;
- a native Swift wrapper with universal `arm64` and `x86_64` builds;
- safe vault registry, locking, atomic sidecar writes, and installer
  validation;
- a bundled CommonJS Obsidian cleanup plugin; and
- five-second grace-period cleanup after a ScratchVault tab closes.

Please retain this attribution and the MIT license when redistributing this
derivative work.

## Quick start

This is the simplest local installation path and does not require Xcode:

```bash
brew install duti
npm install
OPEN_WITH_OBSIDIAN_USE_PREBUILT=1 \
  ./scripts/setup-open-with-obsidian.sh
./scripts/install-open-with-obsidian.sh
open /Applications/OpenWithObsidian.app
duti -s com.openwithobsidian.app md all
duti -s com.openwithobsidian.app markdown all
```

After installation, double-click any `.md` file in Finder. If Obsidian asks
for permission to load **Open With Obsidian — Scratch Cleanup**, enable it.
Restart Obsidian once if the ScratchVault does not open on the first attempt.

For a source build with Xcode, use the commands in
[Build and install](#build-and-install).

## Requirements

- macOS 13 or newer
- Obsidian Desktop
- Xcode 15.2 or a compatible Xcode only for source builds
- `duti` for Launch Services association
- Node.js and npm for plugin bundling and tests

## Build and install

From the repository root:

```bash
npm install
./scripts/setup-open-with-obsidian.sh
./scripts/install-open-with-obsidian.sh
```

The setup script builds the Swift wrapper, bundles the cleanup plugin, and
installs the ScratchVault template. It uses `./Xcode.app` or
`/Applications/Xcode-15.2.app` when available.

To package using the verified prebuilt universal executable without Xcode:

```bash
OPEN_WITH_OBSIDIAN_USE_PREBUILT=1 \
  ./scripts/setup-open-with-obsidian.sh
```

To select another Xcode installation:

```bash
OPEN_WITH_OBSIDIAN_DEVELOPER_DIR=/Applications/Xcode-15.2.app/Contents/Developer \
  ./scripts/setup-open-with-obsidian.sh
```

The safe installer keeps a timestamped backup of an existing app bundle rather
than merging files into it.

## Configure Finder

Register the installed application and make it the default Markdown handler:

```bash
open /Applications/OpenWithObsidian.app
brew install duti
duti -s com.openwithobsidian.app md all
duti -s com.openwithobsidian.app markdown all
duti -x md
duti -x markdown
```

The final two commands should report `OpenWithObsidian` and
`/Applications/OpenWithObsidian.app`. Restart Finder if it continues using the
old application association.

The ScratchVault is stored at:

```text
~/Library/Application Support/OpenWithObsidian/ScratchVault
```

The first external-file open may require restarting Obsidian so it loads the
newly registered vault and the bundled **Open With Obsidian — Scratch Cleanup**
plugin. Enable the plugin when Obsidian asks to trust it.

## Readiness check

Confirm the installation is working end to end:

1. Create or choose a Markdown file outside any Obsidian vault.
2. Double-click it in Finder.
3. Confirm it opens in Obsidian without changing the original file.
4. Confirm a temporary entry appears under the ScratchVault path.
5. Close the Obsidian tab.
6. Wait five seconds and confirm the temporary entry is removed.

If Finder opens the old application, rerun the two `duti -s` commands and
restart Finder. If cleanup does not run, open Obsidian Settings → Community
plugins and enable the Scratch Cleanup plugin.

## Cleanup behavior

The cleanup plugin is installed only in the ScratchVault. It:

- removes temporary entries when no Obsidian leaf references them;
- waits five seconds before removing a valid closed entry, protecting delayed
  Finder-to-Obsidian opens;
- removes missing directories, invalid sidecars, and broken symlink entries;
- never deletes the canonical external source file; and
- exposes the command `Clean stale scratch entries` in Obsidian.

## Development checks

Run the complete local test and validation commands:

```bash
npm test
npm run check
npm audit --omit=dev
```

`npm test` runs the JavaScript cleanup tests and native Swift tests.
`npm run check` validates JavaScript and shell syntax and rebuilds the bundled
plugin. The plugin source is under `src/`; the native wrapper source and tests
are under `src/swift/`.

## Repository layout

```text
src/
├── main.js                         # cleanup plugin entry point
├── reconcile.js                    # safe stale-entry detection
├── cleanup.js                      # hash-entry deletion
├── manifest.json                   # Obsidian plugin metadata
├── OpenWithObsidian                # verified prebuilt wrapper
├── OpenWithObsidian.plist          # macOS bundle metadata
├── swift/                          # native Swift wrapper and tests
└── scratch-vault-template/          # bundled ScratchVault configuration
scripts/                            # build, install, and verification scripts
tests/                              # JavaScript cleanup tests
```

## Security notes

The wrapper operates only on the selected file and the application-owned
ScratchVault. It uses canonical paths, validates vault directories, writes
sidecars atomically, and deletes only validated hash-named temporary entries.
The app is ad-hoc signed for local use. Developer ID signing, notarization,
and a physical Finder double-click acceptance run remain release tasks.
