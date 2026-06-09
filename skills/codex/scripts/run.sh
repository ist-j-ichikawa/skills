#!/usr/bin/env bash
# codex/run.sh — hardened wrapper for background `codex exec` runs.
#
# Launched once per task via Bash(run_in_background: true). Unlike a naive
# `codex exec &`, this script:
#   - stays the PARENT of codex (no detached spawn, no stdio:ignore) so a crash
#     is always observed — the failure mode the official codex-plugin leaves
#     unsolved in Issue #49.
#   - runs codex in its own process group (set -m) and a watchdog that enforces
#     an idle timeout (no log output for N seconds) and an optional wall timeout,
#     killing the WHOLE group on breach.
#   - records a durable, atomically-written status.json so status/result/cancel
#     work by reading the run dir directly — no app-server, no daemon.
#   - always leaves partial output behind (log.txt + result.txt) regardless of
#     how the run ends (completed | failed | timed_out | cancelled).
#
# See job.sh for the reader side (status/result/cancel/tail/list).

set -u
set -m  # job control: each background job becomes its own process group leader.

PROMPT_FILE=""
WORK_DIR=""
RUN_DIR=""
SANDBOX="read-only"
MODEL=""
EFFORT=""
RESUME=0
IDLE_TIMEOUT=300   # seconds with no log.txt growth before we declare a hang. 0 = off.
WALL_TIMEOUT=0     # max total seconds. 0 = unlimited (legitimate long runs).
declare -a EXTRA=()

usage() {
  cat <<'EOF'
Usage:
  run.sh --run-dir DIR --prompt-file FILE [options]

Required:
  --run-dir DIR           Directory for log.txt / result.txt / status.json / exit.
  --prompt-file FILE      File containing the prompt (never passed on argv).

Optional:
  --work-dir DIR          codex --cd DIR (default: $PWD). Ignored on --resume-last.
  --sandbox MODE          read-only | workspace-write | danger-full-access
                          (default: read-only).
  --model NAME            Override model (e.g. gpt-5.5, gpt-5.4-mini).
  --effort LEVEL          none|minimal|low|medium|high|xhigh.
  --idle-timeout SECS     Kill if log.txt stops growing for SECS (default 300; 0=off).
  --wall-timeout SECS     Kill after SECS total (default 0 = unlimited).
  --resume-last           Resume the most recent codex session (continues its cwd).
  --                      Anything after this is passed to codex verbatim.

status.json status values:
  queued -> running -> completed | failed | timed_out | cancelled
  (orphaned is assigned by job.sh when a running pid is found dead.)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)      RUN_DIR="$2"; shift 2 ;;
    --prompt-file)  PROMPT_FILE="$2"; shift 2 ;;
    --work-dir)     WORK_DIR="$2"; shift 2 ;;
    --sandbox)      SANDBOX="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    --effort)       EFFORT="$2"; shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    --wall-timeout) WALL_TIMEOUT="$2"; shift 2 ;;
    --resume-last)  RESUME=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; EXTRA=("$@"); break ;;
    *)              echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$RUN_DIR" ]] || { echo "--run-dir is required" >&2; exit 2; }
[[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]] || { echo "--prompt-file must point to an existing file" >&2; exit 2; }
command -v codex >/dev/null 2>&1 || { echo "codex CLI not found on PATH" >&2; exit 2; }
[[ "$IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "--idle-timeout must be a non-negative integer" >&2; exit 2; }
[[ "$WALL_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "--wall-timeout must be a non-negative integer" >&2; exit 2; }

mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/log.txt"
RESULT="$RUN_DIR/result.txt"
META="$RUN_DIR/meta.json"
STATUS="$RUN_DIR/status.json"
EXIT_FILE="$RUN_DIR/exit"
: >"$LOG"
: >"$RESULT"

WORK_DIR_EFFECTIVE="${WORK_DIR:-$PWD}"

now() { date +%s; }
# Portable file mtime (epoch). `date -r FILE` works on both BSD/macOS and GNU.
mtime() { date -r "$1" +%s 2>/dev/null || echo 0; }
jstr() { # JSON string escaper: control chars -> space, then backslash + quote.
  local s; s="$(printf '%s' "$1" | tr '\n\r\t' '   ')"
  s=${s//\\/\\\\}; printf '%s' "${s//\"/\\\"}"
}

# Atomic status writer: build to .tmp then rename so readers never see a torn file.
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"
write_status() { # $1=status $2=pid $3=exit $4=reason
  local st="$1" pid="$2" ex="$3" reason="$4" tmp="$STATUS.tmp"
  cat >"$tmp" <<EOF
{
  "status":        "$st",
  "pid":           ${pid:-null},
  "pgid":          ${pid:-null},
  "exit":          ${ex:-null},
  "reason":        "$(jstr "$reason")",
  "started_at":    "$STARTED_AT",
  "updated_at":    "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_output_at": $(mtime "$LOG"),
  "work_dir":      "$(jstr "$WORK_DIR_EFFECTIVE")",
  "sandbox":       "$(jstr "$SANDBOX")",
  "model":         "$(jstr "$MODEL")",
  "effort":        "$(jstr "$EFFORT")",
  "resume":        $([[ $RESUME -eq 1 ]] && echo true || echo false),
  "idle_timeout":  $IDLE_TIMEOUT,
  "wall_timeout":  $WALL_TIMEOUT
}
EOF
  mv -f "$tmp" "$STATUS"
}

cat >"$META" <<EOF
{
  "started_at":  "$STARTED_AT",
  "work_dir":    "$(jstr "$WORK_DIR_EFFECTIVE")",
  "sandbox":     "$(jstr "$SANDBOX")",
  "model":       "$(jstr "$MODEL")",
  "effort":      "$(jstr "$EFFORT")",
  "resume":      $([[ $RESUME -eq 1 ]] && echo true || echo false),
  "prompt_file": "$(jstr "$PROMPT_FILE")"
}
EOF

write_status queued "" "" ""

# Build codex args. NOTE the resume subcommand is restricted: it rejects
# --sandbox/--cd/--profile/--color, so those go through -c overrides instead.
PROMPT_TEXT="$(cat "$PROMPT_FILE")"
declare -a ARGS=(exec)
if [[ $RESUME -eq 1 ]]; then
  ARGS+=(resume --last --skip-git-repo-check --output-last-message "$RESULT"
         -c "approval_policy=\"never\"" -c "sandbox_mode=\"$SANDBOX\"")
else
  ARGS+=(--color never --skip-git-repo-check --output-last-message "$RESULT"
         --cd "$WORK_DIR_EFFECTIVE" --sandbox "$SANDBOX" -c "approval_policy=\"never\"")
fi
[[ -n "$MODEL" ]]  && ARGS+=(--model "$MODEL")
[[ -n "$EFFORT" ]] && ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
ARGS+=("$PROMPT_TEXT")

# Launch codex as a background job => it leads its own process group (pgid == pid).
# </dev/null: with run_in_background the stdin stays open and `codex exec` would
# hang on "Reading additional input from stdin..." — the prompt is on argv, so
# stdin can be closed.
codex "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} </dev/null >"$LOG" 2>&1 &
CODEX_PID=$!

KILLED_REASON=""
cleanup() { # kill the whole codex process group, then unconditionally KILL-sweep
  kill -- -"$CODEX_PID" 2>/dev/null || kill "$CODEX_PID" 2>/dev/null
  sleep 1
  # Always sweep with KILL: harmless if already gone, and it reaps a stuck
  # grandchild even when the group leader has already exited (so a liveness
  # probe on the leader pid alone would wrongly skip escalation).
  kill -9 -- -"$CODEX_PID" 2>/dev/null || kill -9 "$CODEX_PID" 2>/dev/null
}
on_signal() { KILLED_REASON="cancelled"; cleanup; }
trap on_signal TERM INT

write_status running "$CODEX_PID" "" ""

# Watchdog: poll codex liveness + idle/wall timeouts every TICK. Refresh
# status.json only every REFRESH_EVERY ticks — a full atomic rewrite per 5s tick
# is pure I/O/fork churn on hour-long runs, and readers reconcile last_output_at
# from log.txt's mtime themselves, so a coarser cadence loses nothing.
TICK=5
REFRESH_EVERY=6   # ~30s between status.json refreshes
ticks=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  sleep "$TICK"
  t="$(now)"
  if [[ "$IDLE_TIMEOUT" -gt 0 ]]; then
    idle=$(( t - $(mtime "$LOG") ))
    if [[ "$idle" -ge "$IDLE_TIMEOUT" ]]; then
      KILLED_REASON="idle_timeout (${idle}s >= ${IDLE_TIMEOUT}s, no output)"; cleanup; break
    fi
  fi
  if [[ "$WALL_TIMEOUT" -gt 0 ]]; then
    elapsed=$(( t - START_EPOCH ))
    if [[ "$elapsed" -ge "$WALL_TIMEOUT" ]]; then
      KILLED_REASON="wall_timeout (${elapsed}s >= ${WALL_TIMEOUT}s)"; cleanup; break
    fi
  fi
  ticks=$(( ticks + 1 ))
  [[ $(( ticks % REFRESH_EVERY )) -eq 0 ]] && write_status running "$CODEX_PID" "" ""
done

wait "$CODEX_PID" 2>/dev/null
rc=$?
echo "$rc" >"$EXIT_FILE"

# A cancel via job.sh kills codex's group from outside, so run.sh sees a signal
# exit (not its own trap). The sentinel makes that case deterministic. Only honor
# it when codex actually exited non-zero — an rc==0 run finished cleanly before
# the kill landed and must not be relabelled cancelled.
[[ -z "$KILLED_REASON" && "$rc" -ne 0 && -e "$RUN_DIR/cancel.requested" ]] && KILLED_REASON="cancelled"

if [[ -n "$KILLED_REASON" ]]; then
  case "$KILLED_REASON" in
    cancelled) write_status cancelled "$CODEX_PID" "$rc" "killed by cancel request" ;;
    *)         write_status timed_out "$CODEX_PID" "$rc" "$KILLED_REASON" ;;
  esac
  exit 124
elif [[ "$rc" -eq 0 ]]; then
  write_status completed "$CODEX_PID" 0 ""
else
  write_status failed "$CODEX_PID" "$rc" "codex exited non-zero"
fi
exit "$rc"
