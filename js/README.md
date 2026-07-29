# SpaceMonger Web

A dependency-free browser edition of SpaceMonger. It recursively scans a folder
chosen by the user and renders its contents as an interactive treemap.

The published app is available at <https://spacemonger.fothergill.com>.

## Run locally

The app uses JavaScript modules, so serve this directory over HTTP rather than
opening `index.html` directly:

```sh
cd js
python3 -m http.server 8080
```

Then open <http://localhost:8080> in Chrome or Edge. `localhost` counts as a
secure context for the File System Access API.

## Browser behavior

- Chromium browsers use `showDirectoryPicker()` for direct, read-only folder
  access.
- Safari is detected and blocked because it does not provide incremental local
  directory access. Its upload-style folder picker must prepare the entire
  selection before the app can process it and is not reliable for large scans.
- Other non-Chromium browsers fall back to `<input webkitdirectory>`, which
  provides a read-only snapshot of the selected files and omits empty
  directories.
- Sizes are logical file sizes. Browsers do not expose allocated disk size,
  inode/hard-link identity, volume capacity, mount points, Finder integration,
  or the macOS Trash.
- Files are inspected locally and are never uploaded.

## Shortcuts

- Command/Ctrl-O: choose a folder
- Command/Ctrl-[: zoom out
- `/`: focus search
- Escape: close search results, then return to the root
