import { mountConfigBrowser, showConfigs } from "./config-browser";
import { mountControls, showControls } from "./controls";
import "./style.css";
import {
  request,
  type SystemInfo,
  type MemoryInfo,
  type CpuInfo,
  type DotfilesInfo,
} from "./api";

const icons: Record<string, string> = {
  system:
    '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8m-4-4v4"/>',
  kernel: '<path d="m8 5-6 7 6 7m8-14 6 7-6 7m-2-16-4 18"/>',
  cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 1v5m6-5v5M9 18v5m6-5v5M1 9h5m-5 6h5m12-6h5m-5 6h5"/><rect x="9" y="9" width="6" height="6"/>',
  memory:
    '<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10v4m4-4v4m4-4v4m4-4v4M6 18v3m4-3v3m4-3v3m4-3v3"/>',
  uptime: '<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>',
  shell: '<path d="m4 6 6 6-6 6m9 0h7"/>',
  hypr: '<path d="M4 3v18M20 3v18M4 12h16m-8-9v18"/>',
  dotfiles:
    '<circle cx="6" cy="5" r="3"/><circle cx="6" cy="19" r="3"/><circle cx="18" cy="5" r="3"/><path d="M6 8v8m12-8v2a4 4 0 0 1-4 4H6"/>',
  refresh:
    '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6 7a7 7 0 0 1 12-2l2 3M4 16l2 3a7 7 0 0 0 12-2"/>',
};
const icon = (name: string) =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name]}</svg>`;
const cards = [
  ["system", "System", "01"],
  ["kernel", "Kernel", "02"],
  ["cpu", "Processor", "03"],
  ["memory", "Memory", "04"],
  ["uptime", "Uptime", "05"],
  ["shell", "Shell", "06"],
  ["hypr", "Hyprland", "07"],
  ["dotfiles", "Config", "08"],
];
document.querySelector<HTMLDivElement>("#app")!.innerHTML = `
  <div class="topline"><span>PERSONAL SYSTEM INTERFACE</span><span>LINUX / LOCAL ONLY</span></div>
  <header class="header"><a class="brand" href="/" aria-label="RiceHub home"><span class="brand-icon">${icon("shell")}</span><span><span class="wordmark">RICEHUB<span class="cursor">_</span></span><span class="subtitle">local control center</span></span></a>
    <div class="connection" id="connection"><span class="dot"></span><span id="connection-text">connecting</span><span class="connection-address">127.0.0.1</span></div>
  </header>
  <nav class="workspace-nav" aria-label="Workspace"><a href="#overview" data-page="overview" aria-current="page">01 / Overview</a><a href="#configs" data-page="configs">02 / Config files</a><a href="#controls" data-page="controls">03 / Controls</a></nav>
  <main>
    <div id="page-overview">
    <section class="intro" aria-labelledby="overview-title"><div><div class="eyebrow"><span class="green">~/</span> workspace / overview</div><h1 id="overview-title">Your machine. <span>Your rules.</span></h1><p>A little clarity for the system you made your own.</p></div>
      <button id="refresh" class="button">${icon("refresh")}<span>Refresh</span></button>
    </section>
    <div class="section-label"><span><span class="green">●</span> SYSTEM SNAPSHOT</span><span id="updated">reading system…</span></div>
    <section class="grid" aria-label="System information">${cards
      .map(
        ([id, title, number]) => `
      <article class="card ${id}" id="card-${id}" aria-labelledby="title-${id}"><div class="card-heading"><h2 id="title-${id}"><span class="card-icon">${icon(id)}</span>${title}</h2><span class="card-number">${number}</span></div><div id="data-${id}" class="card-data" aria-busy="true"><p class="loading">Reading ${title.toLowerCase()}…</p></div>${id === "hypr" ? `<button class="button reload" id="reload" disabled>${icon("refresh")} Reload configuration <span class="arrow">↗</span></button>` : ""}</article>`,
      )
      .join("")}
    </section>
    <div class="feedback" id="feedback" role="status" aria-live="polite">${icon("shell")}<span>Ready when you are. Everything stays on this machine.</span></div>
    </div><div id="page-configs" hidden></div><div id="page-controls" hidden></div>
  </main>
  <footer><span><span class="green">ricehub</span> <span class="muted">/</span> built for your corner of Linux</span><span>ZIG <span class="muted">+</span> TYPESCRIPT <span class="footer-mark">✳</span></span></footer>`;
const el = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id) as T;
const escape = (value: unknown) =>
  String(value).replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        char
      ]!,
  );
const text = (value: unknown) =>
  value == null || value === "" ? "Unavailable" : escape(value);
const metric = (value: unknown, className = "") =>
  `<div class="metric ${className}">${text(value)}</div>`;
const note = (value: unknown) => `<p class="note">${text(value)}</p>`;
const tag = (value: unknown, color = "") =>
  `<span class="tag ${color}">${text(value)}</span>`;
function render(id: string, html: string) {
  const target = el(`data-${id}`);
  target.innerHTML = html;
  target.setAttribute("aria-busy", "false");
  el(`card-${id}`).classList.remove("failed");
}
function fail(ids: string[], error: unknown) {
  const message = error instanceof Error ? error.message : "Request failed";
  for (const id of ids) {
    render(id, metric("Unavailable", "small") + note(message));
    el(`card-${id}`).classList.add("failed");
  }
}
let hyprlandAvailable = false;
let reloading = false;
function system(data: SystemInfo) {
  render(
    "system",
    metric(data.os) +
      `<div class="details"><span>hostname</span><strong>${text(data.hostname)}</strong></div>` +
      `<div class="tags">${tag(data.desktop)}${tag(data.session_type, "blue")}</div>`,
  );
  render(
    "kernel",
    metric(data.kernel, "small mono") +
      note("Linux kernel release") +
      `<div class="card-bottom">${tag("KERNEL", "purple")}<span class="source">/proc/sys/kernel</span></div>`,
  );
  const seconds = data.uptime_seconds;
  const days = seconds == null ? null : Math.floor(seconds / 86400);
  const hours = seconds == null ? null : Math.floor(seconds / 3600) % 24;
  const minutes = seconds == null ? null : Math.floor(seconds / 60) % 60;
  render(
    "uptime",
    seconds == null
      ? metric(null)
      : `<div class="time-metric"><span>${days}<small>d</small></span><span>${hours}<small>h</small></span><span>${minutes}<small>m</small></span></div>`,
  );
  el("data-uptime").insertAdjacentHTML(
    "beforeend",
    note("Time since last boot") +
      `<div class="card-bottom">${tag(seconds == null ? "UNAVAILABLE" : "RUNNING", seconds == null ? "" : "green")}</div>`,
  );
  render(
    "shell",
    metric(data.shell?.split("/").pop(), "shell-name") +
      note(data.shell) +
      `<div class="card-bottom"><span class="source">$SHELL · inherited environment</span></div>`,
  );
  hyprlandAvailable = data.hyprland_available;
  el<HTMLButtonElement>("reload").disabled = !hyprlandAvailable || reloading;
  render(
    "hypr",
    `<div class="hypr-status">${metric(hyprlandAvailable ? "Session detected" : "Not detected", "small")}${tag(hyprlandAvailable ? "AVAILABLE" : "INACTIVE", hyprlandAvailable ? "green" : "")}</div>` +
      note(
        hyprlandAvailable
          ? "Apply your latest Hyprland configuration."
          : "Reload is available in a Hyprland session. Other Linux desktops work here too.",
      ),
  );
}
const gib = (value: number | null) =>
  value == null ? "Unavailable" : (value / 1024 ** 3).toFixed(1);
function memory(data: MemoryInfo) {
  const percent =
    data.total_bytes && data.used_bytes != null
      ? Math.max(0, Math.min(100, (data.used_bytes / data.total_bytes) * 100))
      : null;
  render(
    "memory",
    `<div class="memory-values">${metric(data.used_bytes == null ? null : gib(data.used_bytes))}<span>${data.total_bytes == null ? "" : `/ ${gib(data.total_bytes)} GiB`}</span><strong>${percent == null ? "—" : `${Math.round(percent)}%`}</strong></div><div class="memory-bar" ${percent == null ? "" : `role="meter" aria-label="RAM used" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(percent)}"`}><span style="width:${percent ?? 0}%"></span></div><div class="memory-legend"><span><i></i> Used RAM</span><span>${data.available_bytes == null ? "Available RAM unknown" : `${gib(data.available_bytes)} GiB available`}</span></div>`,
  );
}
function cpu(data: CpuInfo) {
  render(
    "cpu",
    metric(data.model, "small") +
      `<div class="core-strip" aria-hidden="true">${Array.from({ length: Math.min(data.logical_cores ?? 0, 48) }, () => "<span></span>").join("")}</div><div class="card-bottom">${tag(data.logical_cores == null ? "CORE COUNT UNKNOWN" : `${data.logical_cores} LOGICAL CORES`, "peach")}<span class="source">/proc/cpuinfo</span></div>`,
  );
}
function dotfiles(data: DotfilesInfo) {
  if (!data.available) {
    render(
      "dotfiles",
      metric("Unavailable", "small") +
        note(data.path) +
        note(data.error_message),
    );
    return;
  }
  const names = data.entries
    .map(
      (name) =>
        `<button class="tag config-open" data-config="${escape(name)}">${text(name)} ↗</button>`,
    )
    .join("");
  render(
    "dotfiles",
    `<div class="hypr-status">${metric(`${data.entries.length}${data.truncated ? "+" : ""} config entries`, "small")}${tag("DISCOVERED", "green")}</div>` +
      note(data.path) +
      `<div class="config-entries" tabindex="0" role="region" aria-label="Discovered configuration entries">${names || note("This directory is empty.")}</div>` +
      (data.git_available
        ? `<div class="details"><span>${text(data.branch === "HEAD" ? "Detached HEAD" : data.branch)}</span><strong>${data.dirty ? `${data.changed_files} changed entries` : "Git working tree clean"}</strong></div>`
        : "") +
      (data.git_error ? note(`Optional Git status: ${data.git_error}`) : "") +
      (data.truncated ? note("Showing the first 512 entries discovered.") : ""),
  );
}
function feedback(message: string, error = false) {
  el("feedback").classList.toggle("error", error);
  el("feedback").innerHTML = `${icon("shell")}<span>${escape(message)}</span>`;
}
let refreshing = false;
async function refresh() {
  if (refreshing) return;
  refreshing = true;
  const button = el<HTMLButtonElement>("refresh");
  button.disabled = true;
  button.classList.add("spinning");
  el("updated").textContent = "reading system…";
  const results = await Promise.all([
    load<SystemInfo>(
      "system",
      ["system", "kernel", "uptime", "shell", "hypr"],
      system,
    ),
    load<CpuInfo>("cpu", ["cpu"], cpu),
    load<MemoryInfo>("memory", ["memory"], memory),
    load<DotfilesInfo>("dotfiles", ["dotfiles"], dotfiles),
  ]);
  const passed = results.filter(Boolean).length;
  el("connection").classList.toggle("offline", passed !== 4);
  el("connection-text").textContent =
    passed === 4
      ? "localhost connected"
      : passed
        ? "partially connected"
        : "backend offline";
  el("updated").textContent =
    `${passed === 4 ? "updated" : `${passed}/4 endpoints · checked`} ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}`;
  feedback(
    passed === 4
      ? "Snapshot refreshed. Reading directly from your machine."
      : `${4 - passed} endpoint(s) unavailable. Check the backend and refresh to retry.`,
    passed !== 4,
  );
  button.disabled = false;
  button.classList.remove("spinning");
  refreshing = false;
}
async function load<T>(
  endpoint: string,
  ids: string[],
  callback: (data: T) => void,
): Promise<boolean> {
  try {
    callback(await request<T>(endpoint));
    return true;
  } catch (error) {
    fail(ids, error);
    if (endpoint === "system") {
      hyprlandAvailable = false;
      el<HTMLButtonElement>("reload").disabled = true;
    }
    return false;
  }
}
el("refresh").addEventListener("click", () => void refresh());
el("reload").addEventListener("click", async () => {
  if (reloading || !hyprlandAvailable) return;
  reloading = true;
  el<HTMLButtonElement>("reload").disabled = true;
  feedback("Reloading Hyprland configuration…");
  try {
    const result = await request<{ message: string }>("hypr/reload", true);
    feedback(result.message);
  } catch (error) {
    feedback(error instanceof Error ? error.message : "Reload failed", true);
  } finally {
    reloading = false;
    el<HTMLButtonElement>("reload").disabled = !hyprlandAvailable;
  }
});
void refresh();

mountConfigBrowser(el("page-configs"));
mountControls(el("page-controls"));
function navigate() {
  const current = ["configs", "controls"].includes(location.hash.slice(1))
    ? location.hash.slice(1)
    : "overview";
  for (const page of ["overview", "configs", "controls"])
    el(`page-${page}`).hidden = current !== page;
  document
    .querySelectorAll<HTMLAnchorElement>("[data-page]")
    .forEach((link) => {
      if (link.dataset.page === current)
        link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });
  if (current === "configs") void showConfigs();
  if (current === "controls") void showControls();
}
window.addEventListener("hashchange", navigate);
el("data-dotfiles").addEventListener("click", (event) => {
  const button = (event.target as HTMLElement).closest<HTMLButtonElement>(
    "[data-config]",
  );
  if (!button) return;
  location.hash = "configs";
  void showConfigs(button.dataset.config!);
});
navigate();
