#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v zig >/dev/null || { echo 'Zig 0.16.0 is required.' >&2; exit 1; }
command -v npm >/dev/null || { echo 'Node.js and npm are required.' >&2; exit 1; }
[[ -d "$project_dir/frontend/node_modules" ]] || { echo 'Run: cd frontend && npm ci' >&2; exit 1; }
(cd "$project_dir/backend" && zig build)
backend_pid=''
frontend_pid=''
cleanup() {
  trap - EXIT INT TERM
  [[ -z "$frontend_pid" ]] || kill "$frontend_pid" 2>/dev/null || true
  [[ -z "$backend_pid" ]] || kill "$backend_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$project_dir/backend/zig-out/bin/ricehub" &
backend_pid=$!
(cd "$project_dir/frontend" && exec node node_modules/vite/bin/vite.js) &
frontend_pid=$!
wait -n "$backend_pid" "$frontend_pid"
