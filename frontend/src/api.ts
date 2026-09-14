export interface SystemInfo {
  os: string | null;
  kernel: string | null;
  hostname: string | null;
  uptime_seconds: number | null;
  shell: string | null;
  desktop: string | null;
  session_type: string | null;
  hyprland_available: boolean;
}
export interface MemoryInfo {
  total_bytes: number | null;
  used_bytes: number | null;
  available_bytes: number | null;
}
export interface CpuInfo {
  model: string | null;
  logical_cores: number | null;
}
export interface DotfilesInfo {
  entries: string[];
  truncated: boolean;
  git_available: boolean;
  git_error: string | null;
  available: boolean;
  path: string | null;
  branch: string | null;
  dirty: boolean | null;
  changed_files: number | null;
  error_message: string | null;
}
export async function request<T>(path: string, action = false): Promise<T> {
  const response = await fetch(`/api/${path}`, {
    method: action ? "POST" : "GET",
    headers: action ? { "X-RiceHub-Action": "reload" } : {},
    signal: AbortSignal.timeout(12_000),
    cache: "no-store",
  });
  const data = await response.json().catch(() => {
    throw new Error(`API returned an invalid response (${response.status})`);
  });
  if (!response.ok)
    throw new Error(
      data.error_message || `Request failed (${response.status})`,
    );
  return data as T;
}

export async function action<T>(
  path: string,
  payload: unknown,
  timeout = 15_000,
): Promise<T> {
  const response = await fetch(`/api/${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-RiceHub-Action": "control",
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(timeout),
    cache: "no-store",
  });
  const data = await response.json().catch(() => {
    throw new Error(`Invalid API response (${response.status})`);
  });
  if (!response.ok)
    throw new Error(
      data.error_message || `Request failed (${response.status})`,
    );
  return data as T;
}
