import { request, action } from "./api";
import { escapeHtml, message } from "./ui";
interface Entry {
  name: string;
  kind: "directory" | "file" | "symlink" | "other";
}
interface Listing {
  root: string;
  path: string;
  entries: Entry[];
  truncated: boolean;
}
interface ConfigFile {
  path: string;
  content: string;
  revision: string;
  editable: boolean;
}
let listing: Listing | null = null;
let opened: ConfigFile | null = null;
let baseline = "";
let generation = 0;
let opening = 0;
let saving = false;
let host: HTMLElement;
const node = <T extends HTMLElement>(id: string) =>
  document.getElementById(id) as T;
const editor = () => node<HTMLTextAreaElement>("config-editor");
export function mountConfigBrowser(target: HTMLElement) {
  host = target;
  target.innerHTML = `<div class="workspace-title"><div><div class="eyebrow">~/ config / explorer</div><h1>Make yourself at home.</h1><p class="note">Browse your configuration. Review a diff before every save.</p></div><button class="button" id="config-refresh">Refresh folder</button></div>
    <div class="explorer"><aside class="file-pane" aria-label="Config files"><div class="file-toolbar"><button class="button" id="config-up" aria-label="Parent directory">↑</button><button class="button" id="config-root">Config root</button></div><p id="config-location" class="path-label">~/.config</p><label class="sr-only" for="config-filter">Filter this folder</label><input id="config-filter" class="input" type="search" placeholder="Filter this folder…"><div id="config-list" class="file-list"><p class="note">Open the config browser to discover files.</p></div></aside>
    <section class="editor-pane" aria-label="Config editor"><div class="editor-heading"><div><h2 id="editor-title">Select a text file</h2><p id="editor-meta" class="note">UTF-8 text · up to 256 KiB · backups on save</p></div><span id="editor-state" class="tag">NO FILE</span></div><label class="sr-only" for="config-editor">File contents</label><textarea id="config-editor" spellcheck="false" autocapitalize="off" autocomplete="off" disabled placeholder="Your configuration will appear here."></textarea><div class="editor-actions"><span class="note" id="editor-size"></span><button class="button" id="config-revert" disabled>Discard changes</button><button class="button primary" id="config-review" disabled>Review changes →</button></div></section></div>
    <p id="config-feedback" class="workspace-feedback" role="status" aria-live="polite"></p>
    <dialog id="diff-dialog" aria-labelledby="diff-title"><div class="dialog-heading"><div><div class="eyebrow">REVIEW BEFORE SAVING</div><h2 id="diff-title">Configuration changes</h2></div><button class="button" id="diff-close" aria-label="Close review">×</button></div><p class="note" id="diff-path"></p><p class="note">A private backup of the original is created before replacement. Some applications apply config changes immediately.</p><pre id="config-diff" class="diff" tabindex="0" aria-label="Changes to save"></pre><div class="dialog-actions"><button class="button" id="diff-cancel">Keep editing</button><button class="button primary" id="config-save">Save with backup</button></div></dialog>`;
  node("config-filter").addEventListener("input", renderList);
  node("config-root").addEventListener("click", () => void directory(""));
  node("config-up").addEventListener(
    "click",
    () => void directory(parent(listing?.path ?? "")),
  );
  node("config-refresh").addEventListener(
    "click",
    () => void directory(listing?.path ?? ""),
  );
  editor().addEventListener("input", changed);
  node("config-revert").addEventListener("click", () => {
    if (confirm("Discard your unsaved changes?")) {
      editor().value = baseline;
      changed();
    }
  });
  node("config-review").addEventListener("click", review);
  const dialog = node<HTMLDialogElement>("diff-dialog");
  for (const id of ["diff-close", "diff-cancel"])
    node(id).addEventListener("click", () => {
      if (!saving) dialog.close();
    });
  dialog.addEventListener("cancel", (event) => {
    if (saving) event.preventDefault();
  });
  node("config-save").addEventListener("click", () => void save());
  window.addEventListener("beforeunload", (event) => {
    if (dirty()) {
      event.preventDefault();
      event.returnValue = "";
    }
  });
}
const parent = (path: string) =>
  path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
const join = (path: string, name: string) => (path ? `${path}/${name}` : name);
function status(text: string, error = false) {
  node("config-feedback").textContent = text;
  node("config-feedback").classList.toggle("error", error);
}
export async function showConfigs(path?: string) {
  if (!host) return;
  if (path === undefined) {
    if (!listing && generation === 0) await directory("");
    return;
  }
  const folder = parent(path);
  await directory(folder);
  const entry = listing?.entries.find(
    (entry) => join(listing!.path, entry.name) === path,
  );
  if (entry?.kind === "directory") await directory(path);
  else if (entry?.kind === "file") await file(path);
  else if (entry)
    status("Symlinks and special files are listed but cannot be opened.", true);
}
async function directory(path: string) {
  const token = ++generation;
  node("config-list").innerHTML = '<p class="note">Reading directory…</p>';
  try {
    const result = await request<Listing>(
      `config/list?path=${encodeURIComponent(path)}`,
    );
    if (token !== generation) return;
    listing = result;
    node("config-location").textContent = join(result.root, result.path);
    node<HTMLInputElement>("config-filter").value = "";
    node<HTMLButtonElement>("config-up").disabled = !path;
    renderList();
    status(
      result.truncated
        ? "Directory listing limited to 1,024 entries."
        : `${result.entries.length} entries. Links are not followed; files stay within your config directory.`,
    );
  } catch (error) {
    if (token === generation) {
      node("config-list").innerHTML =
        '<p class="note">Could not open this directory. Use Config root to return.</p>';
      status(message(error), true);
    }
  }
}
function renderList() {
  if (!listing) return;
  const term = node<HTMLInputElement>("config-filter").value.toLowerCase();
  const matches = listing.entries.filter((entry) =>
    entry.name.toLowerCase().includes(term),
  );
  node("config-list").replaceChildren();
  for (const entry of matches) {
    const button = document.createElement("button");
    button.className = "file-entry";
    button.innerHTML = `<span class="entry-symbol" aria-hidden="true">${entry.kind === "directory" ? "▸" : entry.kind === "file" ? "≡" : "↗"}</span><span>${escapeHtml(entry.name)}</span><small>${entry.kind === "directory" ? "dir" : entry.kind === "file" ? "file" : entry.kind}</small>`;
    button.disabled = entry.kind !== "directory" && entry.kind !== "file";
    button.title = button.disabled
      ? "Links and special files are not followed"
      : entry.name;
    const path = join(listing.path, entry.name);
    button.classList.toggle("selected", opened?.path === path);
    button.addEventListener("click", () =>
      entry.kind === "directory" ? void directory(path) : void file(path),
    );
    node("config-list").append(button);
  }
  if (!matches.length)
    node("config-list").innerHTML = '<p class="note">No entries match.</p>';
}
function dirty() {
  return !!opened && editor().value !== baseline;
}
async function file(path: string) {
  if (
    saving ||
    (dirty() && !confirm("Discard unsaved changes and open another file?"))
  )
    return;
  const token = ++opening;
  editor().disabled = true;
  node<HTMLButtonElement>("config-review").disabled = true;
  node<HTMLButtonElement>("config-revert").disabled = true;
  status("Reading file…");
  try {
    const result = await request<ConfigFile>(
      `config/file?path=${encodeURIComponent(path)}`,
    );
    if (token !== opening) return;
    opened = result;
    editor().value = result.content;
    baseline = editor().value;
    editor().disabled = false;
    editor().readOnly = !result.editable;
    node("editor-title").textContent = result.path;
    node("editor-meta").textContent = result.editable
      ? "Review changes to save. A backup is created automatically."
      : "Read-only file or multiple hard links. You can view and copy its contents.";
    changed();
    renderList();
    status(`Opened ${result.path}`);
  } catch (error) {
    if (token === opening) status(message(error), true);
  } finally {
    if (token === opening) {
      editor().disabled = !opened;
      changed();
    }
  }
}
function changed() {
  const hasChanges = dirty();
  node("editor-state").textContent = !opened
    ? "NO FILE"
    : !opened.editable
      ? "READ ONLY"
      : hasChanges
        ? "UNSAVED"
        : "SAVED";
  node("editor-state").classList.toggle("peach", hasChanges);
  node<HTMLButtonElement>("config-review").disabled =
    !hasChanges || !opened?.editable || saving;
  node<HTMLButtonElement>("config-revert").disabled = !hasChanges || saving;
  node("editor-size").textContent =
    `${new TextEncoder().encode(editor().value).length.toLocaleString()} bytes`;
}
function editedContent() {
  const crlf =
    opened!.content.includes("\r\n") &&
    !opened!.content.replaceAll("\r\n", "").includes("\n");
  return crlf ? editor().value.replaceAll("\n", "\r\n") : editor().value;
}
let reviewed = "";
function review() {
  if (!opened || !dirty()) return;
  reviewed = editedContent();
  if (new TextEncoder().encode(reviewed).length > 256 * 1024) {
    status("File exceeds the 256 KiB editor limit.", true);
    return;
  }
  node("diff-path").textContent = opened.path;
  const oldLines = opened.content.replaceAll("\r\n", "\n").split("\n");
  const newLines = reviewed.replaceAll("\r\n", "\n").split("\n");
  let prefix = 0;
  while (
    prefix < oldLines.length &&
    prefix < newLines.length &&
    oldLines[prefix] === newLines[prefix]
  )
    prefix++;
  let suffix = 0;
  while (
    suffix < oldLines.length - prefix &&
    suffix < newLines.length - prefix &&
    oldLines.at(-1 - suffix) === newLines.at(-1 - suffix)
  )
    suffix++;
  const lines: [string, string][] = [];
  for (const line of oldLines.slice(Math.max(0, prefix - 3), prefix))
    lines.push([" ", line]);
  for (const line of oldLines.slice(prefix, oldLines.length - suffix))
    lines.push(["-", line]);
  for (const line of newLines.slice(prefix, newLines.length - suffix))
    lines.push(["+", line]);
  for (const line of oldLines.slice(
    oldLines.length - suffix,
    oldLines.length - suffix + 3,
  ))
    lines.push([" ", line]);
  node("config-diff").innerHTML =
    `<span class="diff-context">@@ from line ${Math.max(1, prefix - 2)} @@</span>\n` +
    lines
      .map(
        ([sign, line]) =>
          `<span class="${sign === "+" ? "diff-add" : sign === "-" ? "diff-remove" : "diff-context"}">${sign} ${escapeHtml(line)}</span>`,
      )
      .join("\n") +
    (!reviewed.endsWith("\n")
      ? '\n<span class="diff-context">\\ No newline at end of new file</span>'
      : "");
  node<HTMLDialogElement>("diff-dialog").showModal();
}
async function save() {
  if (!opened || saving) return;
  saving = true;
  for (const id of ["config-save", "diff-close", "diff-cancel"])
    node<HTMLButtonElement>(id).disabled = true;
  const path = opened.path;
  try {
    const result = await action<{ backup: string; revision: string }>(
      "config/save",
      { path, content: reviewed, revision: opened.revision },
    );
    opened = { ...opened, content: reviewed, revision: result.revision };
    editor().value = reviewed;
    baseline = editor().value;
    node<HTMLDialogElement>("diff-dialog").close();
    status(`Saved ${path}. Original backed up to ${result.backup}`);
  } catch (error) {
    node<HTMLDialogElement>("diff-dialog").close();
    status(message(error), true);
  } finally {
    saving = false;
    for (const id of ["config-save", "diff-close", "diff-cancel"])
      node<HTMLButtonElement>(id).disabled = false;
    changed();
  }
}
