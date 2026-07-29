let nextNodeId = 1;

export function detectBrowserSupport({
  userAgent = "",
  vendor = "",
  hasDirectoryPicker = false,
} = {}) {
  const supportsDirectoryPicker = Boolean(hasDirectoryPicker);
  const hasSafariToken = /Safari\//i.test(userAgent);
  const isAlternateBrowser = /(Chrome|Chromium|CriOS|FxiOS|Edg|EdgiOS|OPR|Opera)\//i.test(
    userAgent,
  );
  const identifiesAsSafari =
    hasSafariToken && /Apple Computer/i.test(vendor) && !isAlternateBrowser;

  return {
    // Capability detection wins. A future Safari with the required picker must
    // remain usable even if its user-agent string still identifies as Safari.
    isSafari: identifiesAsSafari && !supportsDirectoryPicker,
    supportsDirectoryPicker,
    supportsLargeFolderScans: supportsDirectoryPicker,
  };
}

export function createNode({
  name,
  path,
  isDirectory,
  size = 0,
  lastModified = null,
  handle = null,
  file = null,
  parent = null,
}) {
  return {
    id: nextNodeId++,
    name,
    path,
    isDirectory,
    size,
    totalSize: size,
    lastModified,
    handle,
    file,
    parent,
    children: [],
    fileCount: isDirectory ? 0 : 1,
    folderCount: 0,
  };
}

export function finalizeTree(node) {
  if (!node.isDirectory) {
    node.totalSize = node.size;
    node.fileCount = 1;
    node.folderCount = 0;
    return node;
  }

  let totalSize = 0;
  let fileCount = 0;
  let folderCount = 0;
  for (const child of node.children) {
    finalizeTree(child);
    totalSize += child.totalSize;
    fileCount += child.fileCount;
    folderCount += child.folderCount + (child.isDirectory ? 1 : 0);
  }
  node.children.sort((a, b) => b.totalSize - a.totalSize || a.name.localeCompare(b.name));
  node.totalSize = totalSize;
  node.fileCount = fileCount;
  node.folderCount = folderCount;
  return node;
}

export function treeFromFileList(fileList) {
  const files = Array.from(fileList);
  const firstPath = files[0]?.webkitRelativePath || files[0]?.name || "Selected folder";
  const rootName = firstPath.split("/")[0] || "Selected folder";
  const root = createNode({ name: rootName, path: rootName, isDirectory: true });
  const directories = new Map([[rootName, root]]);

  for (const file of files) {
    const relativePath = file.webkitRelativePath || `${rootName}/${file.name}`;
    const parts = relativePath.split("/").filter(Boolean);
    let parent = root;
    let accumulated = rootName;

    for (let index = 1; index < parts.length - 1; index += 1) {
      accumulated += `/${parts[index]}`;
      let directory = directories.get(accumulated);
      if (!directory) {
        directory = createNode({
          name: parts[index],
          path: accumulated,
          isDirectory: true,
          parent,
        });
        parent.children.push(directory);
        directories.set(accumulated, directory);
      }
      parent = directory;
    }

    parent.children.push(
      createNode({
        name: parts.at(-1) || file.name,
        path: relativePath,
        isDirectory: false,
        size: file.size,
        lastModified: file.lastModified || null,
        file,
        parent,
      }),
    );
  }

  return finalizeTree(root);
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  if (bytes < 1024) return `${bytes} B`;
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / 1024 ** exponent;
  const digits = exponent >= 3 ? 2 : 1;
  return `${value.toFixed(digits)} ${units[exponent]}`;
}

export function findMatches(root, rawQuery, limit = 1000) {
  const query = rawQuery.trim().toLocaleLowerCase();
  if (!query) return [];
  const matches = [];
  const stack = [root];
  while (stack.length && matches.length < limit) {
    const node = stack.pop();
    if (node.name.toLocaleLowerCase().includes(query)) matches.push(node);
    if (node.isDirectory) {
      for (let index = node.children.length - 1; index >= 0; index -= 1) {
        stack.push(node.children[index]);
      }
    }
  }
  matches.sort((a, b) => {
    const aExact = a.name.toLocaleLowerCase() === query;
    const bExact = b.name.toLocaleLowerCase() === query;
    if (aExact !== bExact) return aExact ? -1 : 1;
    return b.totalSize - a.totalSize || a.path.localeCompare(b.path);
  });
  return matches;
}

const MIN_RECT_SIZE = 3;
const TITLE_HEIGHT = 18;
const BORDER = 1;

export function layoutTree(root, width, height) {
  const output = [];
  const items = root.children.filter((child) => child.totalSize > 0);
  layoutItems(items, { x: 0, y: 0, width, height }, 0, output);
  return output;
}

function layoutItems(items, rect, depth, output) {
  if (!items.length || rect.width < MIN_RECT_SIZE || rect.height < MIN_RECT_SIZE) return;

  if (items.length === 1) {
    const node = items[0];
    output.push({ node, rect, depth });
    if (node.isDirectory) {
      const inner = {
        x: rect.x + BORDER,
        y: rect.y + TITLE_HEIGHT,
        width: rect.width - BORDER * 2,
        height: rect.height - TITLE_HEIGHT - BORDER,
      };
      if (inner.width >= MIN_RECT_SIZE && inner.height >= MIN_RECT_SIZE) {
        layoutItems(
          node.children.filter((child) => child.totalSize > 0),
          inner,
          depth + 1,
          output,
        );
      }
    }
    return;
  }

  const first = [];
  const second = [];
  let firstSize = 0;
  let secondSize = 0;
  for (const item of items) {
    if (firstSize <= secondSize) {
      first.push(item);
      firstSize += item.totalSize;
    } else {
      second.push(item);
      secondSize += item.totalSize;
    }
  }

  const total = firstSize + secondSize;
  if (!total) return;
  const ratio = firstSize / total;
  let firstRect;
  let secondRect;
  if (rect.width >= rect.height) {
    const split = Math.round(rect.x + rect.width * ratio);
    firstRect = { x: rect.x, y: rect.y, width: split - rect.x, height: rect.height };
    secondRect = {
      x: split,
      y: rect.y,
      width: rect.x + rect.width - split,
      height: rect.height,
    };
  } else {
    const split = Math.round(rect.y + rect.height * ratio);
    firstRect = { x: rect.x, y: rect.y, width: rect.width, height: split - rect.y };
    secondRect = {
      x: rect.x,
      y: split,
      width: rect.width,
      height: rect.y + rect.height - split,
    };
  }
  layoutItems(first, firstRect, depth, output);
  layoutItems(second, secondRect, depth, output);
}

export function hitTest(point, displayNodes) {
  for (let index = displayNodes.length - 1; index >= 0; index -= 1) {
    const item = displayNodes[index];
    const { x, y, width, height } = item.rect;
    if (point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height) {
      return item;
    }
  }
  return null;
}
