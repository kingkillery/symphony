#!/bin/sh
set -eu

workflow_file="${SYMPHONY_WORKFLOW_FILE:-/opt/symphony/WORKFLOW.md}"
logs_root="${SYMPHONY_LOGS_ROOT:-/var/log/symphony}"
codex_home_root="${SYMPHONY_CODEX_HOME:-/var/lib/symphony/codex-home}"
host_codex_dir="${SYMPHONY_HOST_CODEX_DIR:-/opt/symphony/host-codex}"

mkdir -p "$logs_root"
mkdir -p "${SYMPHONY_WORKSPACES_ROOT:-/var/lib/symphony/workspaces}"
mkdir -p "$codex_home_root/.codex"

# Run Codex with an isolated home so desktop-specific MCP/tool config does not
# leak into unattended Symphony sessions. Reuse host auth when present.
export HOME="$codex_home_root"
export CODEX_HOME="$codex_home_root/.codex"

if [ -f "$host_codex_dir/auth.json" ] && [ ! -f "$CODEX_HOME/auth.json" ]; then
  cp "$host_codex_dir/auth.json" "$CODEX_HOME/auth.json"
fi

if [ -f "$host_codex_dir/version.json" ] && [ ! -f "$CODEX_HOME/version.json" ]; then
  cp "$host_codex_dir/version.json" "$CODEX_HOME/version.json"
fi

cat > "$CODEX_HOME/config.toml" <<'EOF'
personality = "pragmatic"
model = "gpt-5.4"
model_reasoning_effort = "medium"

[features]
js_repl = true
multi_agent = true
apps = true
prevent_idle_sleep = true
EOF

set -- symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$logs_root"

if [ -n "${SYMPHONY_PORT:-}" ]; then
  set -- "$@" --port "$SYMPHONY_PORT"
fi

set -- "$@" "$workflow_file"

exec "$@"
