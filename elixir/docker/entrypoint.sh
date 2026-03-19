#!/bin/sh
set -eu

workflow_file="${SYMPHONY_WORKFLOW_FILE:-/opt/symphony/WORKFLOW.md}"
logs_root="${SYMPHONY_LOGS_ROOT:-/var/log/symphony}"

mkdir -p "$logs_root"
mkdir -p "${SYMPHONY_WORKSPACES_ROOT:-/var/lib/symphony/workspaces}"

set -- symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$logs_root"

if [ -n "${SYMPHONY_PORT:-}" ]; then
  set -- "$@" --port "$SYMPHONY_PORT"
fi

set -- "$@" "$workflow_file"

exec "$@"
