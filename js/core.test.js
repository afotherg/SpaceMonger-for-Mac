import assert from "node:assert/strict";
import test from "node:test";

import {
  detectBrowserSupport,
  findMatches,
  formatBytes,
  layoutTree,
  treeFromFileList,
} from "./core.js";

const files = [
  { name: "movie.mov", webkitRelativePath: "Example/Media/movie.mov", size: 900, lastModified: 10 },
  { name: "notes.txt", webkitRelativePath: "Example/notes.txt", size: 100, lastModified: 20 },
  { name: "photo.jpg", webkitRelativePath: "Example/Media/photo.jpg", size: 500, lastModified: 30 },
];

test("builds and aggregates a folder snapshot", () => {
  const root = treeFromFileList(files);
  assert.equal(root.name, "Example");
  assert.equal(root.totalSize, 1500);
  assert.equal(root.fileCount, 3);
  assert.equal(root.folderCount, 1);
  assert.equal(root.children[0].name, "Media");
  assert.equal(root.children[0].totalSize, 1400);
});

test("search orders exact matches before partial matches", () => {
  const root = treeFromFileList(files);
  const matches = findMatches(root, "notes.txt");
  assert.equal(matches[0].name, "notes.txt");
  assert.equal(matches[0].path, "Example/notes.txt");
});

test("treemap produces bounded rectangles", () => {
  const root = treeFromFileList(files);
  const nodes = layoutTree(root, 800, 500);
  assert.ok(nodes.length >= 2);
  for (const { rect } of nodes) {
    assert.ok(rect.x >= 0 && rect.y >= 0);
    assert.ok(rect.x + rect.width <= 800);
    assert.ok(rect.y + rect.height <= 500);
  }
});

test("formats binary byte units", () => {
  assert.equal(formatBytes(512), "512 B");
  assert.equal(formatBytes(1536), "1.5 KB");
  assert.equal(formatBytes(1024 ** 3), "1.00 GB");
});

test("detects desktop Safari without misclassifying Chromium browsers", () => {
  const safari = detectBrowserSupport({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.5 Safari/605.1.15",
    vendor: "Apple Computer, Inc.",
    hasDirectoryPicker: false,
  });
  assert.equal(safari.isSafari, true);
  assert.equal(safari.supportsLargeFolderScans, false);

  const chrome = detectBrowserSupport({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36",
    vendor: "Google Inc.",
    hasDirectoryPicker: true,
  });
  assert.equal(chrome.isSafari, false);
  assert.equal(chrome.supportsLargeFolderScans, true);

  const futureSafari = detectBrowserSupport({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/620.1 Version/20.0 Safari/620.1",
    vendor: "Apple Computer, Inc.",
    hasDirectoryPicker: true,
  });
  assert.equal(futureSafari.isSafari, false);
  assert.equal(futureSafari.supportsLargeFolderScans, true);
});
