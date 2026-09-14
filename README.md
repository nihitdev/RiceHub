# RiceHub

> A fast local Linux control center for your rice — configs, system controls, and more.

[![Linux](https://img.shields.io/badge/platform-Linux-89b4fa?logo=linux&logoColor=white)](https://www.kernel.org/)
[![Zig 0.16](https://img.shields.io/badge/backend-Zig%200.16-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![TypeScript](https://img.shields.io/badge/frontend-TypeScript-3178c6?logo=typescript&logoColor=white)](https://www.typescriptlang.org/)
[![Vite](https://img.shields.io/badge/bundler-Vite-646cff?logo=vite&logoColor=white)](https://vite.dev/)

RiceHub is a lightweight dashboard for inspecting and controlling a Linux desktop from a browser on the same machine. It reads real host data, discovers your `~/.config` tree, and keeps optional desktop integrations available without making them requirements. It is designed for Arch and Omarchy, while remaining useful on other Linux distributions, window managers, and desktop environments.

There is no React, database, telemetry, remote service, or large runtime dependency. The Zig service binds to loopback, and the Vite frontend proxies requests to it during development.

## Features

- System snapshot: distribution, kernel, hostname, shell, desktop/session, uptime, CPU, and memory.
- Config browser: navigate and filter `$XDG_CONFIG_HOME` or `$HOME/.config` without requiring a Git repository.
- Config editor: UTF-8 text editing up to 256 KiB, diff review, revision checks, private backups, and atomic saves.
- Desktop controls: Hyprland reload, PipeWire/PulseAudio volume and mute, backlight brightness, and systemd user services.
- Package updates: cached and refreshed Arch, APT, or DNF listings, with an explicit command and optional terminal launch.
- Dark terminal-inspired interface with responsive layout, accessible controls, and independent endpoint loading.

## Screenshots

No screenshots are committed yet. Run the app locally to view the Overview, Config files, and Controls screens.

## Architecture

```text
Browser (TypeScript + Vite + CSS)
             │ /api through Vite proxy
             ▼
Zig HTTP service (127.0.0.1:7070)
       ├── /proc and /etc/os-release
       ├── environment and config directory
       └── bounded system commands
```

The backend uses Zig 0.16's standard library I/O APIs. `system.zig` reads Linux pseudo-files and environment values. `config.zig` confines config operations beneath one trusted root. `controls.zig` runs fixed argument arrays for supported desktop tools. `api.zig` validates hosts, origins, methods, bodies, paths, and action headers before routing. Each request receives an arena allocator and JSON response.

The frontend is plain TypeScript. `api.ts` owns typed fetch helpers, `main.ts` renders the overview, `config-browser.ts` implements browsing and editing, and `controls.ts` loads each control independently. CSS is kept in one responsive stylesheet.

## Config browser and editor

RiceHub automatically lists immediate entries in `$XDG_CONFIG_HOME` when it is absolute, otherwise `$HOME/.config`. Set `RICEHUB_DOTFILES` to use another absolute config directory. A Git repository is optional; when `.git` exists, branch and working-tree metadata is shown as additional information.

The editor opens existing UTF-8 text files up to 256 KiB. It rejects absolute paths, parent traversal, internal RiceHub files, symlinks, special files, binary data, oversized files, and files that are read-only or multiply hard-linked. Before saving, it displays a diff. Saving checks the SHA-256 revision, creates a private `0600` backup, preserves POSIX mode bits, syncs an atomic replacement, and rechecks the source to catch concurrent edits. Syntax validation is intentionally left to the user and the application that owns each config file.

## System controls

Controls detect available tools and show a clear unavailable state when a capability is missing.

- **Audio:** `wpctl`, falling back to `pactl`, for the default output volume and mute state.
- **Brightness:** `brightnessctl` for a backlight device from 1–100%.
- **User services:** `systemctl --user` service state plus confirmed start, stop, and restart jobs. D-Bus and Wayland session infrastructure is read-only.
- **Package updates:** `pacman`/`checkupdates`, `apt`, or `dnf`. Applying updates opens your configured `xdg-terminal-exec` terminal with the exact command shown first. RiceHub does not accept passwords or claim that an interactive transaction succeeded.
- **Hyprland:** `hyprctl reload` is enabled only when a Hyprland session signature is present.

## Supported environments and tools

RiceHub targets Linux with `/proc` mounted and an os-release file. It works especially well on Arch, Omarchy, Hyprland, and Wayland, but the status dashboard does not depend on any particular desktop. Optional capabilities depend on the tools listed above and the permissions of the current user session.

Required: Zig 0.16.0, Node.js 20.19+ or 22.12+, npm, and Python 3 for the test suite. Optional: Git, `hyprctl`, `wpctl` or `pactl`, `brightnessctl`, `systemctl`, `pacman`/`apt`/`dnf`, `checkupdates`, and `xdg-terminal-exec`.

## Installation

```sh
git clone https://github.com/nihitdev/RiceHub.git
cd RiceHub/frontend
npm ci
```

Use a normal desktop user so inherited session variables and compositor access are available.

## Quick start

```sh
# terminal 1
cd backend
zig build run

# terminal 2
cd frontend
npm run dev
```

Open <http://127.0.0.1:5173>. The API listens on <http://127.0.0.1:7070>. Or run `./scripts/dev.sh` from the project root.

Set an alternative config directory for one run with `RICEHUB_DOTFILES=/absolute/path ./scripts/dev.sh`.

## Development and verification

```sh
cd frontend && npm ci
cd ../backend && zig fmt --check build.zig src
zig build -Doptimize=ReleaseSafe
python3 tests/integration.py
python3 tests/features.py
cd ../frontend && npm run build
```

The tests compare live Linux values and use isolated temporary directories and mock commands for editing, backups, stale revisions, path confinement, audio, brightness, services, package updates, and missing tools. They never modify your real config, desktop, services, or package database.

Production assets are built with `npm run build` into `frontend/dist`; the compiled backend is `backend/zig-out/bin/ricehub`. `npm run preview` serves the built frontend locally on port 4173.

## API overview

All responses are JSON with `Cache-Control: no-store`. Unavailable values are `null`; errors include `error_message` and a stable `code` where applicable.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/api/system` | OS, kernel, host, uptime, shell, desktop/session, Hyprland availability |
| GET | `/api/memory` | Total, used, and available RAM in bytes |
| GET | `/api/cpu` | CPU model and logical core count |
| GET | `/api/dotfiles` | Config root entries and optional Git metadata |
| POST | `/api/hypr/reload` | Reload a running Hyprland session |
| GET | `/api/config/list?path=...` | List one confined config directory |
| GET | `/api/config/file?path=...` | Read one confined UTF-8 text file |
| POST | `/api/config/save` | Save `{path, content, revision}` after validation and backup |
| GET/POST | `/api/controls/audio` | Read or set default output volume/mute |
| GET/POST | `/api/controls/brightness` | Read or set backlight percentage |
| GET/POST | `/api/controls/services` | Read or queue a user service action |
| GET | `/api/controls/updates` | Read cached package update information |
| POST | `/api/controls/updates/check` | Refresh package metadata/listing |
| POST | `/api/controls/updates/apply` | Open the configured terminal for an update command |

Control POST requests require `X-RiceHub-Action: control` and `Content-Type: application/json`. The Hyprland action requires `X-RiceHub-Action: reload`. Commands and arbitrary shell arguments are never accepted.

## Project structure

```text
backend/
  build.zig
  src/main.zig          loopback listener and request lifecycle
  src/api.zig           routing, validation, JSON responses
  src/system.zig        Linux and environment readers
  src/commands.zig      config discovery, Git, Hyprland command helpers
  src/config.zig        confined reads, revision checks, atomic saves
  src/controls.zig      audio, brightness, services, package controls
  tests/                 live and isolated integration suites
frontend/
  index.html
  src/main.ts            overview and navigation
  src/api.ts             typed API clients
  src/config-browser.ts  explorer, editor, diff, and save flow
  src/controls.ts        control panels and action feedback
  src/style.css          responsive terminal-inspired styling
scripts/dev.sh           build and run both local services
```

## Security considerations

RiceHub is a single-user loopback tool, not a remote administration server. The backend binds to `127.0.0.1`, restricts Host and Origin headers to known local development ports, uses custom action headers, rejects bodies on status routes, and never invokes a shell with user input. Config paths are relative, component-validated, opened without following links, and limited to text files beneath the selected root. Commands use fixed executable arguments and bounded output.

Any process running as your user can access the loopback API. Keep the service stopped when it is not needed, and do not expose it through a reverse proxy without reviewing the trusted-origin policy. Update commands can change the system after you confirm them in your terminal.

## Current limitations

- No config-language syntax validation or application-specific reload hooks.
- Backups preserve file content and mode bits, but not ACLs, extended attributes, or inode identity.
- Package listings and update behavior depend on distribution tools and local caches.
- Brightness targets backlight devices, not external-monitor DDC.
- User service actions queue jobs; refresh the page to observe state.
- No authentication beyond loopback and request validation.

## Roadmap

- Config-language aware validation and optional app reload actions.
- Better package-manager progress and reboot/restart hints.
- Optional process, disk, network, and GPU cards.
- Import/export of explicit RiceHub preferences.
- More focused accessibility and keyboard navigation improvements.

## Contributing

Issues and focused pull requests are welcome. Keep backend and frontend changes small, preserve the localhost-only safety model, add fixture coverage for new actions, and run the full verification commands before opening a pull request.
