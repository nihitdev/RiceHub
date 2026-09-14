import { request, action } from "./api";
import { escapeHtml as esc, message } from "./ui";
interface Audio {
  tool: string;
  volume: number;
  muted: boolean;
}
interface Brightness {
  device: string;
  value: number;
}
interface Service {
  unit: string;
  active: string;
  sub: string;
  description: string;
  controllable: boolean;
}
interface Updates {
  manager: string;
  packages: string[];
  source: string;
  can_check: boolean;
  can_apply: boolean;
  command: string[];
  terminal_running: boolean;
  terminal_exit_code: number | null;
}
let host: HTMLElement;
let services: Service[] = [];
let loaded = false;
let refreshing = false;
const node = <T extends HTMLElement>(id: string) =>
  document.getElementById(id) as T;
function feedback(value: string, error = false) {
  node("controls-feedback").textContent = value;
  node("controls-feedback").classList.toggle("error", error);
}
export function mountControls(target: HTMLElement) {
  host = target;
  target.innerHTML = `<div class="workspace-title"><div><div class="eyebrow">~/ system / controls</div><h1>A few useful switches.</h1><p class="note">Local controls, detected from the tools installed on your machine.</p></div><button class="button" id="controls-refresh">Refresh controls</button></div>
    <div class="controls-grid"><section class="control-panel"><div class="panel-heading"><h2>Audio</h2><span class="tag blue">OUTPUT</span></div><div id="audio-control"><p class="note">Waiting to read audio…</p></div></section><section class="control-panel"><div class="panel-heading"><h2>Brightness</h2><span class="tag peach">BACKLIGHT</span></div><div id="brightness-control"><p class="note">Waiting to read brightness…</p></div></section>
    <section class="control-panel service-panel"><div class="panel-heading"><h2>User services</h2><span class="tag purple">SYSTEMD --USER</span></div><label class="sr-only" for="service-filter">Filter user services</label><input id="service-filter" type="search" class="input" placeholder="Find a service…"><div id="services-control" class="service-list"><p class="note">Waiting to read services…</p></div></section>
    <section class="control-panel updates-panel"><div class="panel-heading"><h2>Package updates</h2><span id="package-manager" class="tag green">DETECTING</span></div><div id="updates-control"><p class="note">Waiting to check the local package cache…</p></div></section></div>
    <p class="workspace-feedback" id="controls-feedback" role="status" aria-live="polite"></p>`;
  node("controls-refresh").addEventListener(
    "click",
    () => void refreshControls(),
  );
  node("service-filter").addEventListener("input", renderServices);
}
export async function showControls() {
  if (!loaded) await refreshControls();
}
async function load<T>(id: string, path: string, render: (value: T) => void) {
  try {
    render(await request<T>(`controls/${path}`));
  } catch (error) {
    node(id).innerHTML =
      `<p class="control-unavailable">Unavailable</p><p class="note">${esc(message(error))}</p>`;
    if (id === "updates-control") {
      const retry = document.createElement("button");
      retry.className = "button";
      retry.textContent = "Check updates";
      retry.onclick = () =>
        void operate(
          retry,
          () => action<Updates>("controls/updates/check", {}, 70_000),
          renderUpdates,
        );
      node(id).append(retry);
    }
  }
}
async function refreshControls() {
  if (refreshing || !host) return;
  refreshing = true;
  node<HTMLButtonElement>("controls-refresh").disabled = true;
  await Promise.all([
    load<Audio>("audio-control", "audio", renderAudio),
    load<Brightness>("brightness-control", "brightness", renderBrightness),
    load<{ services: Service[] }>("services-control", "services", (value) => {
      services = value.services;
      renderServices();
    }),
    load<Updates>("updates-control", "updates", renderUpdates),
  ]);
  loaded = true;
  refreshing = false;
  node<HTMLButtonElement>("controls-refresh").disabled = false;
}
async function operate<T>(
  button: HTMLButtonElement,
  job: () => Promise<T>,
  complete: (result: T) => void,
) {
  if (button.disabled) return;
  button.disabled = true;
  try {
    complete(await job());
  } catch (error) {
    feedback(message(error), true);
  } finally {
    if (button.isConnected && !button.dataset.keepDisabled)
      button.disabled = false;
  }
}
function renderAudio(value: Audio) {
  node("audio-control").innerHTML =
    `<div class="control-value">${value.volume}<small>%</small> <span class="tag ${value.muted ? "peach" : "green"}">${value.muted ? "MUTED" : "UNMUTED"}</span></div><p class="note">Default output · ${esc(value.tool)}</p><div class="range-control"><label for="audio-range">Volume <output id="audio-output">${Math.min(value.volume, 100)}%</output></label><input type="range" id="audio-range" min="0" max="100" value="${Math.min(value.volume, 100)}"></div><div class="control-actions"><button class="button" id="audio-mute">${value.muted ? "Unmute" : "Mute"}</button><button class="button primary" id="audio-apply">Apply volume</button></div>`;
  node("audio-range").addEventListener("input", () => {
    node("audio-output").textContent =
      `${node<HTMLInputElement>("audio-range").value}%`;
  });
  node<HTMLButtonElement>("audio-apply").onclick = (event) =>
    void operate(
      event.currentTarget as HTMLButtonElement,
      () =>
        action<Audio>("controls/audio", {
          action: "volume",
          value: Number(node<HTMLInputElement>("audio-range").value),
        }),
      (result) => {
        renderAudio(result);
        feedback("Output volume updated.");
      },
    );
  node<HTMLButtonElement>("audio-mute").onclick = (event) =>
    void operate(
      event.currentTarget as HTMLButtonElement,
      () =>
        action<Audio>("controls/audio", {
          action: "mute",
          value: value.muted ? 0 : 1,
        }),
      (result) => {
        renderAudio(result);
        feedback(result.muted ? "Output muted." : "Output unmuted.");
      },
    );
}
function renderBrightness(value: Brightness) {
  node("brightness-control").innerHTML =
    `<div class="control-value peach">${value.value}<small>%</small></div><p class="note">${esc(value.device)}</p><div class="range-control"><label for="brightness-range">Brightness <output id="brightness-output">${value.value}%</output></label><input type="range" id="brightness-range" min="1" max="100" value="${Math.max(1, value.value)}"></div><div class="control-actions"><span class="note">1–100% · backlight devices</span><button class="button primary" id="brightness-apply">Apply brightness</button></div>`;
  node("brightness-range").addEventListener("input", () => {
    node("brightness-output").textContent =
      `${node<HTMLInputElement>("brightness-range").value}%`;
  });
  node<HTMLButtonElement>("brightness-apply").onclick = (event) =>
    void operate(
      event.currentTarget as HTMLButtonElement,
      () =>
        action<Brightness>("controls/brightness", {
          value: Number(node<HTMLInputElement>("brightness-range").value),
        }),
      (result) => {
        renderBrightness(result);
        feedback("Backlight brightness updated.");
      },
    );
}
function renderServices() {
  const term = node<HTMLInputElement>("service-filter").value.toLowerCase();
  const matches = services.filter((service) =>
    `${service.unit} ${service.description}`.toLowerCase().includes(term),
  );
  node("services-control").replaceChildren();
  for (const service of matches) {
    const row = document.createElement("div");
    row.className = "service-row";
    row.innerHTML = `<div><strong>${esc(service.unit)}</strong><p class="note">${esc(service.description)}</p><span class="tag ${service.active === "active" ? "green" : service.active === "failed" ? "peach" : ""}">${esc(service.active)} / ${esc(service.sub)}</span>${!service.controllable ? '<span class="note"> · read-only</span>' : ""}</div><div class="service-actions"></div>`;
    if (service.controllable)
      for (const command of ["start", "stop", "restart"]) {
        const button = document.createElement("button");
        button.className = "button";
        button.textContent = command;
        button.setAttribute("aria-label", `${command} ${service.unit}`);
        button.disabled =
          (command === "start" && service.active === "active") ||
          (command === "stop" && service.active === "inactive");
        button.onclick = () => {
          if (
            !confirm(
              `${command[0].toUpperCase() + command.slice(1)} ${service.unit}?`,
            )
          )
            return;
          void operate(
            button,
            () =>
              action<{ message: string }>("controls/services", {
                unit: service.unit,
                action: command,
              }),
            (result) => {
              feedback(result.message);
              void load<{ services: Service[] }>(
                "services-control",
                "services",
                (data) => {
                  services = data.services;
                  renderServices();
                },
              );
            },
          );
        };
        row.querySelector(".service-actions")!.append(button);
      }
    node("services-control").append(row);
  }
  if (!matches.length)
    node("services-control").innerHTML =
      '<p class="note">No matching services.</p>';
}
function renderUpdates(value: Updates) {
  node("package-manager").textContent = value.manager.toUpperCase();
  node("updates-control").innerHTML =
    `<p class="note">${esc(value.source)}</p>${value.terminal_exit_code != null && value.terminal_exit_code !== 0 ? `<p class="control-unavailable">Terminal launcher exited with code ${value.terminal_exit_code}. Check your terminal setup.</p>` : ""}<pre class="package-list" tabindex="0" aria-label="Package update listing">${esc(value.packages.length ? value.packages.join("\n") : "No updates reported by this package cache.")}</pre><p class="note">${value.manager === "apt" ? "APT lists cached metadata. Refresh repositories in your terminal with sudo apt update first." : value.manager === "arch" ? "Official repositories. AUR updates are handled by your usual helper." : "Repository results from DNF."}</p><div class="update-command"><span class="source">UPDATE COMMAND</span><code>${esc(value.command.join(" "))}</code></div><div class="control-actions"><button class="button" id="updates-check" ${value.can_check ? "" : "disabled"}>${value.manager === "apt" ? "Read package cache" : "Check updates"}</button><button class="button primary" id="updates-apply" ${value.can_apply && !value.terminal_running ? "" : "disabled"}>${value.terminal_running ? "Terminal running" : "Open update terminal ↗"}</button></div><p class="note">${value.can_apply ? "Review the transaction and any password prompt in your terminal. Completion is tracked there." : "Install xdg-terminal-exec to launch your preferred terminal."}${!value.can_check ? " Install pacman-contrib for fresh Arch update checks." : ""}</p>`;
  node<HTMLButtonElement>("updates-check").onclick = (event) => {
    feedback("Checking package metadata…");
    void operate(
      event.currentTarget as HTMLButtonElement,
      () => action<Updates>("controls/updates/check", {}, 70_000),
      (result) => {
        renderUpdates(result);
        feedback("Package listing updated.");
      },
    );
  };
  node<HTMLButtonElement>("updates-apply").onclick = (event) => {
    if (
      !confirm(
        `Open your terminal to run:\n\n${value.command.join(" ")}\n\nReview and approve the package transaction there.`,
      )
    )
      return;
    void operate(
      event.currentTarget as HTMLButtonElement,
      () =>
        action<{ message: string }>("controls/updates/apply", {
          manager: value.manager,
        }),
      (result) => {
        feedback(result.message);
        node<HTMLButtonElement>("updates-apply").disabled = true;
        node("updates-apply").dataset.keepDisabled = "true";
      },
    );
  };
}
