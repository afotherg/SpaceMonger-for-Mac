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

## Incremental Move to Trash

Moving an item to Trash is treated as a filesystem move, not an immediate deletion:

1. macOS moves the item using `FileManager.trashItem`.
2. macOS returns the actual destination URL. This matters because Trash locations
   can differ by volume and filenames may be changed to avoid collisions.
3. The item is removed from its original parent in the in-memory tree.
4. If the macOS Trash destination is inside the selected hierarchy, a relocated copy
   is added there as well.
5. Sizes and item counts are recalculated only for affected ancestors, and the
   treemap is laid out again without a full disk scan.

The item remains in the system Trash until the Trash is emptied. Changes made outside
the app, including emptying the Trash, are not currently reflected automatically and
require another scan.

## Building

Requirements:

- macOS 14 or newer
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

## Project Structure

```text
Package.swift
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
