#!/usr/bin/env bash
# codex/job.sh — reader/controller for run.sh background jobs.
#
# All state lives on disk under the run dir; there is no daemon. Commands:
#   status <run-dir>        Print status.json, reconciling orphans first.
#   result <run-dir> [N]    Print the final answer (result.txt), or the last N
#                           lines of log.txt if result is empty (partial output).
#   tail   <run-dir> [N]    Last N lines of log.txt (default 50).
#   cancel <run-dir>        Kill the codex process group and mark cancelled.
#   list   [runs-root]      One line per run dir (default root: see RUNS_ROOT).
#
# Orphan reconciliation: if status says "running" but the recorded pid is dead,
# the job died without run.sh updating status (host reboot, SIGKILL, OOM). We
# rewrite status to "orphaned" so callers never wait forever on a ghost — the
# exact gap the official codex-plugin leaves open (Issue #49).

set -u

RUNS_ROOT="${CODEX_RUNS_ROOT:-$HOME/.local/state/j-stack-codex/runs}"

die() { echo "$*" >&2; exit 2; }

# Validate a run-dir arg. Called as a statement (NOT in $(...)) so die's exit
# propagates to the real shell instead of just a command-substitution subshell.
require_dir() { # $1=run-dir
  [[ -n "${1:-}" ]] || die "run-dir required"
  [[ -d "$1" ]] || die "no such run dir: $1"
}

# Atomic status.json patch: run sed (caller supplies its flags/exprs) to a .tmp
# then rename, so readers never see a torn file.
rewrite_status() { # $1=file  $2..=sed args
  local f="$1"; shift; local tmp="$f.tmp"
  sed "$@" "$f" >"$tmp" && mv -f "$tmp" "$f"
}

# Pull a top-level scalar out of status.json without requiring jq.
field() { # $1=file $2=key
  sed -n "s/.*\"$2\":[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -1
}

# True only if pid is alive AND still a codex process. The command-name check
# guards against PID reuse: after codex dies the OS may hand its pid to an
# unrelated process, which a bare `kill -0` would read as "still running" —
# masking an orphan and (worse, in cancel) risking a kill of an innocent group.
alive_codex() { # $1=pid
  local pid="$1"
  [[ -n "$pid" && "$pid" != "null" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -qi codex
}

reconcile() { # $1=run-dir — flip a dead "running" job to "orphaned" (atomic)
  local dir="$1"; local st_file="$dir/status.json"
  [[ -f "$st_file" ]] || return 0
  local st pid; st="$(field "$st_file" status)"; pid="$(field "$st_file" pid)"
  [[ "$st" == "running" ]] || return 0
  [[ -n "$pid" && "$pid" != "null" ]] || return 0
  if ! alive_codex "$pid"; then
    rewrite_status "$st_file" \
      -e 's/"status":[[:space:]]*"running"/"status": "orphaned"/' \
      -e "s/\"reason\":[[:space:]]*\"[^\"]*\"/\"reason\": \"pid $pid not alive; reconciled by job.sh\"/"
  fi
}

cmd_status() {
  require_dir "${1:-}"; local dir="$1"
  reconcile "$dir"
  cat "$dir/status.json" 2>/dev/null || die "no status.json in $dir"
}

cmd_result() {
  require_dir "${1:-}"; local dir="$1"; local n="${2:-80}"
  reconcile "$dir"
  local st; st="$(field "$dir/status.json" status)"
  echo "# status: ${st:-unknown}"
  if [[ -s "$dir/result.txt" ]]; then
    cat "$dir/result.txt"
  else
    echo "# (no final message — partial output, last $n lines of log.txt:)"
    tail -n "$n" "$dir/log.txt" 2>/dev/null
  fi
}

cmd_tail() {
  require_dir "${1:-}"; local dir="$1"; local n="${2:-50}"
  tail -n "$n" "$dir/log.txt" 2>/dev/null
}

cmd_cancel() {
  require_dir "${1:-}"; local dir="$1"
  # Drop the sentinel FIRST so the running run.sh classifies the imminent codex
  # death as "cancelled", not "failed".
  : >"$dir/cancel.requested"
  local pid; pid="$(field "$dir/status.json" pid)"
  if alive_codex "$pid"; then
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null
    sleep 1
    kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
    echo "cancelled pid $pid"
  else
    echo "no live codex process for $dir"
  fi
  # If run.sh is already gone (can't write status itself), force it here.
  # NOTE: -E (ERE) so the (running|queued) alternation works on BSD/macOS sed too
  # — BSD BRE does not support \| and would silently no-op.
  sleep 1
  local st_file="$dir/status.json"
  if [[ -f "$st_file" ]]; then
    local st; st="$(field "$st_file" status)"
    if [[ "$st" == "running" || "$st" == "queued" ]]; then
      rewrite_status "$st_file" -E 's/"status":[[:space:]]*"(running|queued)"/"status": "cancelled"/'
    fi
  fi
}

cmd_list() {
  local root="${1:-$RUNS_ROOT}"
  [[ -d "$root" ]] || { echo "no runs under $root"; return 0; }
  local d
  for d in "$root"/*/; do
    [[ -d "$d" ]] || continue
    reconcile "$d"
    printf '%s\t%s\t%s\n' \
      "$(field "$d/status.json" status)" \
      "$(field "$d/status.json" started_at)" \
      "${d%/}"
  done
}

sub="${1:-}"; shift || true
case "$sub" in
  status) cmd_status "$@" ;;
  result) cmd_result "$@" ;;
  tail)   cmd_tail "$@" ;;
  cancel) cmd_cancel "$@" ;;
  list)   cmd_list "$@" ;;
  ""|-h|--help)
    cat <<EOF
Usage: job.sh <status|result|tail|cancel|list> [args]
  status <run-dir>        status.json (orphan-reconciled)
  result <run-dir> [N]    final answer, or last N log lines if empty
  tail   <run-dir> [N]    last N log lines (default 50)
  cancel <run-dir>        kill the codex process group, mark cancelled
  list   [runs-root]      list runs (default: \$CODEX_RUNS_ROOT or
                          ~/.local/state/j-stack-codex/runs)
EOF
    ;;
  *) die "unknown subcommand: $sub (try -h)" ;;
esac
