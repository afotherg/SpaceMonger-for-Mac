# SpaceMonger for Mac

SpaceMonger for Mac is a native SwiftUI disk-usage visualizer for macOS. Select a
folder and the app scans its contents, then displays files and directories as a
treemap: the larger a rectangle is, the more disk space that item occupies.

The app works best with as much screen space as possible.

## Features

- Fast, parallel directory scanning using bulk filesystem metadata reads and a
  bounded worker pool.
- Treemap visualization based on allocated size rather than only logical file size.
- Click-to-zoom directory navigation, Zoom Out, Root, and clickable breadcrumbs.
- Hover details showing the full path, modification date, and human-readable size.
- Case-insensitive filename and directory-name search. Exact matches appear first,
  followed by the largest matches.
- Single-click search results: folders open directly, while files open their
  containing folder.
- Finder actions for revealing or explicitly opening an item.
- Move to Trash without rescanning the complete selected hierarchy.

<img width="1432" height="946" alt="Space Monger Cached Files" src="https://github.com/user-attachments/assets/44498ec5-c9c0-49c8-97b6-f21927010c3a" />


## Downloading and Running
On the right hand side of the github page, click on Releases, and download the .zip file

Unzip the file, and copy the "SpaceMonger for Mac" file to your Applications folder.

New releases produced by the signing workflow are Developer ID signed and notarized
by Apple. Open the app normally; macOS may show its standard first-open confirmation
and ask for permission to access protected folders such as Documents or Downloads.

Older releases (including v0.9.6) are ad-hoc signed and may require **System Settings
→ Privacy & Security → Open Anyway**. Download a signed release when available to
avoid that workaround.

## Building

Requirements:

- macOS 12 Monterey or newer
- Swift 5.9 or newer
- Xcode command-line tools

Build and run the debug version:

```sh
swift build
swift run "SpaceMonger for Mac"
```

Build the optimized release version:

```sh
swift build -c release
".build/release/SpaceMonger for Mac"
```

Create a universal macOS app bundle and ZIP locally:

```sh
Scripts/package-app.sh v1.0.0
open "dist/SpaceMonger for Mac.app"
```

## Creating a Release

Releases are created on demand with GitHub Actions:

1. Open **Actions** in GitHub and select **Create Release**.
2. Choose **Run workflow**.
3. Enter a new semantic version tag such as `v1.0.0` and optionally mark it as a
   pre-release.

The workflow builds a Universal 2 app for Intel and Apple silicon, signs it with a
Developer ID Application certificate, submits it to Apple for notarization, and
staples the accepted ticket before publishing the ZIP. A failed signing or
notarization step prevents publication.

For Mac App Store packaging and submission, see [the App Store guide](Docs/APP_STORE.md).

Before the first signed release, configure the five Apple Actions secrets described
in [the release setup guide](Docs/RELEASING.md).

## Project Structure

```text
Package.swift
Assets/
├── AppIcon.png            1024-pixel source artwork
└── AppIcon.icns           macOS application icon bundle
Sources/SpaceMonger/
├── ContentView.swift       Main interface, search, navigation, and actions
├── FileNode.swift          In-memory filesystem tree and cached totals
├── FolderScanner.swift     Parallel filesystem scanner
├── TreeMapLayout.swift     Treemap layout algorithm and hit testing
├── TreeMapView.swift       SwiftUI Canvas rendering
└── SpaceMongerApp.swift    Application entry point and window setup
```

## Origins and Acknowledgements

This project is a macOS reimplementation inspired by Sean Werkema's original
[SpaceMonger 1.x source code](https://github.com/seanofw/spacemonger1). The original
Windows application established the treemap concept, navigation model, and core disk
usage experience adapted here. That source is distributed under the MIT License and
is copyright © 1998–2020 Sean Werkema.

Scanner optimization work was informed in part by ideas demonstrated in
[okturan/dirwiz](https://github.com/okturan/dirwiz), particularly bulk filesystem
metadata access and bounded parallel scanning.

The initial macOS implementation was created by Claude. Subsequent polishing and
feature development—including faster scanning, clickable breadcrumbs, search,
interface refinements, and incremental Trash updates—were completed by ChatGPT Codex.
