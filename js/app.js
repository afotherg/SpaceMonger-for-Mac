import {
  createNode,
  detectBrowserSupport,
  finalizeTree,
  findMatches,
  formatBytes,
  hitTest,
  layoutTree,
  treeFromFileList,
} from "./core.js?v=20260729-3";

const elements = {
  openFolder: document.querySelector("#open-folder"),
  welcomeOpen: document.querySelector("#welcome-open"),
  fallback: document.querySelector("#folder-fallback"),
  zoomOut: document.querySelector("#zoom-out"),
  goRoot: document.querySelector("#go-root"),
  breadcrumbs: document.querySelector("#breadcrumbs"),
  searchForm: document.querySelector("#search-form"),
  searchInput: document.querySelector("#search-input"),
  searchButton: document.querySelector("#search-button"),
  cancelScan: document.querySelector("#cancel-scan"),
  canvas: document.querySelector("#treemap"),
  visualizer: document.querySelector("#visualizer"),
  emptyState: document.querySelector("#empty-state"),
  scanState: document.querySelector("#scan-state"),
  scanFolderName: document.querySelector("#scan-folder-name"),
  scanProgress: document.querySelector("#scan-progress"),
  results: document.querySelector("#search-results"),
  resultHeading: document.querySelector("#result-heading"),
  resultList: document.querySelector("#result-list"),
  closeResults: document.querySelector("#close-results"),
  tooltip: document.querySelector("#tooltip"),
  statusPrimary: document.querySelector("#status-primary"),
  statusSecondary: document.querySelector("#status-secondary"),
  supportNote: document.querySelector("#support-note"),
  browserWarning: document.querySelector("#browser-warning"),
  toast: document.querySelector("#toast"),
};

const palette = ["#e55d57", "#f19a45", "#e3ce4d", "#55bd6b", "#42b6cf", "#5b82e6", "#a264df", "#db69ae"];
const state = {
  root: null,
  zoomStack: [],
  displayNodes: [],
  hovered: null,
  scanController: null,
  toastTimer: null,
};

const browserSupport = detectBrowserSupport({
  userAgent: navigator.userAgent,
  vendor: navigator.vendor,
  hasDirectoryPicker: "showDirectoryPicker" in window,
});
const supportsDirectoryPicker = browserSupport.supportsDirectoryPicker;

if (browserSupport.isSafari) {
  elements.browserWarning.hidden = false;
  elements.openFolder.disabled = true;
  elements.welcomeOpen.disabled = true;
  elements.welcomeOpen.textContent = "Open in Chrome or Edge";
  elements.supportNote.textContent =
    "Safari's upload-style folder picker is disabled here because it is not reliable for large scans.";
} else {
  elements.supportNote.textContent = supportsDirectoryPicker
    ? "Your browser supports direct folder access. You choose exactly what to share."
    : "Your browser will use a read-only folder snapshot. Chrome or Edge provides the best experience.";
}

function currentRoot() {
  return state.zoomStack.at(-1) || state.root;
}

async function chooseFolder() {
  if (state.scanController) return;
  if (browserSupport.isSafari) {
    showToast("Safari is not supported. Open this page in Chrome or Edge.");
    return;
  }
  if (!supportsDirectoryPicker) {
    elements.fallback.click();
    return;
  }

  try {
    const handle = await window.showDirectoryPicker({ mode: "read", id: "spacemonger-root" });
    await beginHandleScan(handle);
  } catch (error) {
    if (error?.name !== "AbortError") showToast(readableError(error));
  }
}

async function beginHandleScan(handle) {
  startScan(handle.name);
  const controller = state.scanController;
  try {
    const root = await scanDirectoryHandle(handle, controller.signal, updateScanProgress);
    if (!controller.signal.aborted) finishScan(root);
  } catch (error) {
    if (error?.name !== "AbortError") {
      resetAfterScan();
      showToast(readableError(error));
    }
  }
}

function startScan(name) {
  state.scanController?.abort();
  state.scanController = new AbortController();
  state.root = null;
  state.zoomStack = [];
  state.hovered = null;
  elements.emptyState.hidden = true;
  elements.results.hidden = true;
  elements.scanState.hidden = false;
  elements.scanFolderName.textContent = name;
  elements.scanProgress.textContent = "Starting scan";
  elements.cancelScan.hidden = false;
  elements.openFolder.disabled = true;
  elements.searchInput.disabled = true;
  elements.searchButton.disabled = true;
  elements.canvas.classList.remove("visible");
  updateNavigation();
}

function finishScan(root) {
  state.root = root;
  state.scanController = null;
  elements.scanState.hidden = true;
  elements.cancelScan.hidden = true;
  elements.openFolder.disabled = false;
  elements.searchInput.disabled = false;
  elements.searchButton.disabled = false;
  elements.canvas.classList.add("visible");
  updateNavigation();
  resizeAndDraw();
  updateStatus();
}

function resetAfterScan() {
  state.scanController = null;
  elements.scanState.hidden = true;
  elements.cancelScan.hidden = true;
  elements.openFolder.disabled = false;
  if (!state.root) elements.emptyState.hidden = false;
}

function cancelScan() {
  state.scanController?.abort();
  resetAfterScan();
  showToast("Scan cancelled");
}

async function scanDirectoryHandle(rootHandle, signal, onProgress) {
  const root = createNode({
    name: rootHandle.name,
    path: rootHandle.name,
    isDirectory: true,
    handle: rootHandle,
  });
  const stats = { files: 0, folders: 0, bytes: 0, unreadable: 0 };
  const directoryQueue = [{ handle: rootHandle, node: root }];
  const maxDirectories = 6;
  const maxFiles = 24;
  let activeDirectories = 0;
  let pendingDirectories = 1;
  let lastProgress = 0;
  const fileLimiter = createLimiter(maxFiles);

  return new Promise((resolve, reject) => {
    const abort = () => reject(new DOMException("Scan cancelled", "AbortError"));
    signal.addEventListener("abort", abort, { once: true });

    const report = () => {
      const now = performance.now();
      if (now - lastProgress > 80) {
        lastProgress = now;
        onProgress({ ...stats });
      }
    };

    const pump = () => {
      if (signal.aborted) return;
      while (activeDirectories < maxDirectories && directoryQueue.length) {
        const work = directoryQueue.shift();
        activeDirectories += 1;
        scanOneDirectory(work)
          .catch((error) => {
            if (error?.name === "AbortError") return;
            if (work.node === root) reject(error);
            else stats.unreadable += 1;
          })
          .finally(() => {
            activeDirectories -= 1;
            pendingDirectories -= 1;
            report();
            if (!signal.aborted && pendingDirectories === 0) {
              signal.removeEventListener("abort", abort);
              onProgress({ ...stats });
              resolve(finalizeTree(root));
            } else {
              pump();
            }
          });
      }
    };

    const scanOneDirectory = async ({ handle, node }) => {
      const fileTasks = [];
      for await (const [name, childHandle] of handle.entries()) {
        if (signal.aborted) throw new DOMException("Scan cancelled", "AbortError");
        const path = `${node.path}/${name}`;
        if (childHandle.kind === "directory") {
          const child = createNode({
            name,
            path,
            isDirectory: true,
            handle: childHandle,
            parent: node,
          });
          node.children.push(child);
          stats.folders += 1;
          pendingDirectories += 1;
          directoryQueue.push({ handle: childHandle, node: child });
          report();
          pump();
        } else {
          fileTasks.push(
            fileLimiter(async () => {
              if (signal.aborted) throw new DOMException("Scan cancelled", "AbortError");
              try {
                const file = await childHandle.getFile();
                node.children.push(
                  createNode({
                    name,
                    path,
                    isDirectory: false,
                    size: file.size,
                    lastModified: file.lastModified,
                    handle: childHandle,
                    parent: node,
                  }),
                );
                stats.files += 1;
                stats.bytes += file.size;
              } catch (error) {
                if (error?.name === "AbortError") throw error;
                stats.unreadable += 1;
              }
              report();
            }),
          );
        }
      }
      await Promise.all(fileTasks);
    };

    pump();
  });
}

function createLimiter(limit) {
  let active = 0;
  const queue = [];
  const runNext = () => {
    while (active < limit && queue.length) {
      const { task, resolve, reject } = queue.shift();
      active += 1;
      Promise.resolve()
        .then(task)
        .then(resolve, reject)
        .finally(() => {
          active -= 1;
          runNext();
        });
    }
  };
  return (task) =>
    new Promise((resolve, reject) => {
      queue.push({ task, resolve, reject });
      runNext();
    });
}

let progressFrame = 0;
function updateScanProgress(stats) {
  cancelAnimationFrame(progressFrame);
  progressFrame = requestAnimationFrame(() => {
    const inaccessible = stats.unreadable ? ` · ${stats.unreadable} inaccessible` : "";
    elements.scanProgress.textContent = `${stats.files.toLocaleString()} files · ${stats.folders.toLocaleString()} folders · ${formatBytes(stats.bytes)}${inaccessible}`;
  });
}

function updateNavigation() {
  elements.zoomOut.disabled = state.zoomStack.length === 0;
  elements.goRoot.disabled = state.zoomStack.length === 0;
  elements.breadcrumbs.replaceChildren();
  if (!state.root) return;

  const path = [state.root, ...state.zoomStack];
  path.forEach((node, index) => {
    if (index) {
      const separator = document.createElement("span");
      separator.className = "crumb-separator";
      separator.textContent = "/";
      elements.breadcrumbs.append(separator);
    }
    const button = document.createElement("button");
    button.type = "button";
    button.className = "crumb";
    button.textContent = node.name;
    button.title = node.path;
    button.setAttribute("aria-current", index === path.length - 1 ? "page" : "false");
    button.addEventListener("click", () => navigateToCrumb(index));
    elements.breadcrumbs.append(button);
  });
}

function navigateToCrumb(index) {
  state.zoomStack = state.zoomStack.slice(0, index);
  state.hovered = null;
  hideTooltip();
  closeResults();
  updateNavigation();
  resizeAndDraw();
  updateStatus();
}

function zoomOut() {
  if (!state.zoomStack.length) return;
  state.zoomStack.pop();
  state.hovered = null;
  updateNavigation();
  resizeAndDraw();
  updateStatus();
}

function goRoot() {
  if (!state.root) return;
  state.zoomStack = [];
  state.hovered = null;
  updateNavigation();
  resizeAndDraw();
  updateStatus();
}

function zoomTo(node) {
  if (!node?.isDirectory || node === currentRoot()) return;
  const path = [];
  let cursor = node;
  while (cursor && cursor !== state.root) {
    path.unshift(cursor);
    cursor = cursor.parent;
  }
  if (cursor !== state.root) return;
  state.zoomStack = path;
  state.hovered = null;
  closeResults();
  updateNavigation();
  resizeAndDraw();
  updateStatus();
}

function resizeAndDraw() {
  const root = currentRoot();
  if (!root) return;
  const rect = elements.canvas.getBoundingClientRect();
  if (!rect.width || !rect.height) return;
  const scale = Math.min(window.devicePixelRatio || 1, 2);
  elements.canvas.width = Math.round(rect.width * scale);
  elements.canvas.height = Math.round(rect.height * scale);
  const context = elements.canvas.getContext("2d");
  context.setTransform(scale, 0, 0, scale, 0, 0);
  state.displayNodes = layoutTree(root, rect.width, rect.height);
  drawTreemap(context, rect.width, rect.height);
}

function drawTreemap(context, width, height) {
  context.clearRect(0, 0, width, height);
  context.fillStyle = "#0c1018";
  context.fillRect(0, 0, width, height);
  for (const item of state.displayNodes) drawNode(context, item);
}

function drawNode(context, item) {
  const { node, rect, depth } = item;
  const isHovered = state.hovered?.node === node;
  const color = palette[depth % palette.length];
  const { x, y, width, height } = rect;
  if (width < 1 || height < 1) return;

  if (node.isDirectory) {
    const shade = 22 + (depth % 5) * 7;
    context.fillStyle = `rgb(${shade} ${shade + 5} ${shade + 12})`;
    context.fillRect(x, y, width, height);
    if (height >= 18) {
      context.globalAlpha = isHovered ? 1 : 0.88;
      context.fillStyle = color;
      context.fillRect(x, y, width, 18);
      context.globalAlpha = 1;
      if (width >= 34) drawLabel(context, node.name, x + 5, y + 12.5, width - 9, true);
    }
    context.strokeStyle = isHovered ? "rgba(255,255,255,.95)" : "rgba(0,0,0,.55)";
    context.lineWidth = isHovered ? 2 : 1;
    context.strokeRect(x + 0.5, y + 0.5, Math.max(0, width - 1), Math.max(0, height - 1));
  } else {
    context.globalAlpha = isHovered ? 1 : 0.84;
    context.fillStyle = color;
    context.fillRect(x, y, width, height);
    context.globalAlpha = 1;
    context.strokeStyle = "rgba(0,0,0,.32)";
    context.lineWidth = 1;
    context.strokeRect(x + 0.5, y + 0.5, Math.max(0, width - 1), Math.max(0, height - 1));
    if (width >= 38 && height >= 15) drawLabel(context, node.name, x + 5, y + 12.5, width - 9, false);
  }
}

function drawLabel(context, text, x, y, maxWidth, directory) {
  context.save();
  context.beginPath();
  context.rect(x - 1, y - 12, maxWidth + 1, 16);
  context.clip();
  context.font = `${directory ? "600" : "500"} 10px ui-sans-serif, system-ui, sans-serif`;
  context.fillStyle = directory ? "rgba(255,255,255,.94)" : "rgba(7,12,20,.78)";
  context.textBaseline = "alphabetic";
  context.fillText(text, x, y, maxWidth);
  context.restore();
}

function canvasPoint(event) {
  const rect = elements.canvas.getBoundingClientRect();
  return { x: event.clientX - rect.left, y: event.clientY - rect.top };
}

function handlePointerMove(event) {
  const item = hitTest(canvasPoint(event), state.displayNodes);
  if (state.hovered?.node === item?.node) {
    if (item) positionTooltip(event);
    return;
  }
  state.hovered = item;
  const context = elements.canvas.getContext("2d");
  const rect = elements.canvas.getBoundingClientRect();
  drawTreemap(context, rect.width, rect.height);
  if (item) showTooltip(item.node, event);
  else hideTooltip();
  updateStatus();
  elements.canvas.style.cursor = item?.node.isDirectory ? "pointer" : "default";
}

function handleCanvasClick(event) {
  const item = hitTest(canvasPoint(event), state.displayNodes);
  if (item?.node.isDirectory) zoomTo(item.node);
}

function showTooltip(node, event) {
  elements.tooltip.replaceChildren();
  const name = document.createElement("strong");
  name.textContent = node.name;
  const size = document.createElement("span");
  size.textContent = formatBytes(node.totalSize);
  const hint = document.createElement("small");
  hint.textContent = node.isDirectory ? "Click to zoom in" : "Logical file size";
  elements.tooltip.append(name, size, hint);
  elements.tooltip.hidden = false;
  positionTooltip(event);
}

function positionTooltip(event) {
  const bounds = elements.visualizer.getBoundingClientRect();
  const tooltipBounds = elements.tooltip.getBoundingClientRect();
  let left = event.clientX - bounds.left + 14;
  let top = event.clientY - bounds.top + 14;
  if (left + tooltipBounds.width > bounds.width - 8) left -= tooltipBounds.width + 28;
  if (top + tooltipBounds.height > bounds.height - 8) top -= tooltipBounds.height + 28;
  elements.tooltip.style.transform = `translate(${Math.max(8, left)}px, ${Math.max(8, top)}px)`;
}

function hideTooltip() {
  elements.tooltip.hidden = true;
}

function updateStatus() {
  const root = currentRoot();
  const node = state.hovered?.node;
  if (node) {
    elements.statusPrimary.textContent = node.path;
    const date = node.lastModified ? ` · modified ${new Date(node.lastModified).toLocaleDateString()}` : "";
    elements.statusSecondary.textContent = `${node.isDirectory ? `${node.fileCount.toLocaleString()} files · ` : ""}${formatBytes(node.totalSize)}${date}`;
  } else if (root) {
    elements.statusPrimary.textContent = `${root.fileCount.toLocaleString()} files · ${root.folderCount.toLocaleString()} folders`;
    elements.statusSecondary.textContent = `${formatBytes(root.totalSize)} logical size`;
  }
}

function performSearch(event) {
  event?.preventDefault();
  if (!state.root) return;
  const query = elements.searchInput.value.trim();
  if (!query) {
    closeResults();
    return;
  }
  const matches = findMatches(state.root, query);
  elements.resultHeading.textContent = `${matches.length.toLocaleString()} ${matches.length === 1 ? "match" : "matches"} for “${query}”`;
  elements.resultList.replaceChildren();
  if (!matches.length) {
    const empty = document.createElement("p");
    empty.className = "no-results";
    empty.textContent = "No file or folder names matched your search.";
    elements.resultList.append(empty);
  } else {
    const fragment = document.createDocumentFragment();
    for (const node of matches) fragment.append(createResultRow(node));
    elements.resultList.append(fragment);
  }
  elements.results.hidden = false;
  elements.canvas.setAttribute("aria-hidden", "true");
}

function createResultRow(node) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "result-row";
  button.addEventListener("click", () => zoomTo(node.isDirectory ? node : node.parent));

  const icon = document.createElement("span");
  icon.className = `result-icon ${node.isDirectory ? "folder" : "file"}`;
  icon.textContent = node.isDirectory ? "▰" : "▪";
  icon.setAttribute("aria-hidden", "true");
  const copy = document.createElement("span");
  copy.className = "result-copy";
  const name = document.createElement("strong");
  name.textContent = node.name;
  const path = document.createElement("small");
  path.textContent = node.path;
  copy.append(name, path);
  const size = document.createElement("span");
  size.className = "result-size";
  size.textContent = formatBytes(node.totalSize);
  button.append(icon, copy, size);
  return button;
}

function closeResults() {
  elements.results.hidden = true;
  elements.canvas.removeAttribute("aria-hidden");
}

function showToast(message) {
  clearTimeout(state.toastTimer);
  elements.toast.textContent = message;
  elements.toast.hidden = false;
  state.toastTimer = setTimeout(() => {
    elements.toast.hidden = true;
  }, 5000);
}

function readableError(error) {
  if (error?.name === "NotAllowedError") return "Folder access was not granted.";
  if (error?.message) return `Could not scan this folder: ${error.message}`;
  return "Could not scan this folder.";
}

elements.openFolder.addEventListener("click", chooseFolder);
elements.welcomeOpen.addEventListener("click", chooseFolder);
elements.cancelScan.addEventListener("click", cancelScan);
elements.zoomOut.addEventListener("click", zoomOut);
elements.goRoot.addEventListener("click", goRoot);
elements.searchForm.addEventListener("submit", performSearch);
elements.closeResults.addEventListener("click", closeResults);
elements.canvas.addEventListener("pointermove", handlePointerMove);
elements.canvas.addEventListener("pointerleave", () => {
  state.hovered = null;
  hideTooltip();
  if (state.root) {
    const context = elements.canvas.getContext("2d");
    const rect = elements.canvas.getBoundingClientRect();
    drawTreemap(context, rect.width, rect.height);
    updateStatus();
  }
});
elements.canvas.addEventListener("click", handleCanvasClick);
elements.fallback.addEventListener("change", () => {
  if (!elements.fallback.files?.length) return;
  const name = elements.fallback.files[0].webkitRelativePath.split("/")[0] || "Selected folder";
  startScan(name);
  requestAnimationFrame(() => {
    try {
      const root = treeFromFileList(elements.fallback.files);
      finishScan(root);
    } catch (error) {
      resetAfterScan();
      showToast(readableError(error));
    } finally {
      elements.fallback.value = "";
    }
  });
});

elements.searchInput.addEventListener("input", () => {
  if (!elements.searchInput.value.trim()) closeResults();
});

window.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key === "o") {
    event.preventDefault();
    chooseFolder();
  } else if ((event.metaKey || event.ctrlKey) && event.key === "[") {
    event.preventDefault();
    zoomOut();
  } else if (event.key === "Escape") {
    if (!elements.results.hidden) closeResults();
    else goRoot();
  } else if (event.key === "/" && document.activeElement !== elements.searchInput && state.root) {
    event.preventDefault();
    elements.searchInput.focus();
  }
});

new ResizeObserver(() => {
  if (state.root && elements.results.hidden) resizeAndDraw();
}).observe(elements.visualizer);
