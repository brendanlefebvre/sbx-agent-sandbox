#!/usr/bin/env bash
# sbx-agent-status - one-glance view of every agent session.
#
# Prints, per tmux window: idle time, whether a `claude` process is alive
# anywhere beneath the pane, and the pane title (Claude sets this to its live
# status line, so it tells you *what* the agent is doing).
#
# Sorted stalest-first, so at 10+ sessions the ones needing attention float up.
#
#   SBX_IDLE_WARN=10   minutes of no output before a claude session is flagged
#
# LIMITS - read before trusting this:
#   This detects LIVENESS and IDLENESS, not "blocked waiting for input." From
#   outside the process you cannot distinguish an agent waiting on a question
#   from one quietly running a long build; both emit nothing. The authoritative
#   signal is Claude Code's Notification hook. Use this as the cross-check that
#   catches agents which died without ever firing a hook.
set -uo pipefail

IDLE_WARN=${SBX_IDLE_WARN:-10}

command -v tmux >/dev/null 2>&1 || { echo "sbx-agent-status: tmux not found" >&2; exit 1; }
# Without ps the claude-liveness column silently reports everything as "shell"
# (debian-slim ships no procps) - fail loudly instead of degrading quietly.
command -v ps >/dev/null 2>&1 || { echo "sbx-agent-status: ps not found (install procps in the image)" >&2; exit 1; }
tmux has-session >/dev/null 2>&1 || { echo "no tmux sessions"; exit 0; }

now=$(date +%s)

# One ps call. Build pid->ppid and pid->comm.
# `ps -e -o pid=,ppid=,comm=` works on both Linux (procps) and macOS (BSD ps);
# macOS emits a full path in comm, so strip to basename.
declare -A PPID_OF COMM_OF
while read -r pid ppid comm; do
  [[ -n ${pid:-} ]] || continue
  PPID_OF[$pid]=$ppid
  COMM_OF[$pid]=$comm
done < <(ps -e -o pid=,ppid=,comm= 2>/dev/null |
         awk '{p=$1; q=$2; $1=""; $2=""; sub(/^ +/,""); n=$0; sub(/.*\//,"",n); print p, q, n}')

# Mark every `claude` process AND every ancestor of one. A pane whose pid is
# marked has claude running at or beneath it. Ancestors cover the wrapper-script
# case (start_bot.sh keeps claude out of the tty's foreground process group);
# marking claude itself covers sbx, where tmux runs claude as the pane command
# directly, so #{pane_pid} IS the claude pid with no ancestors in between.
declare -A HAS_CLAUDE
for pid in "${!COMM_OF[@]}"; do
  [[ ${COMM_OF[$pid]} == claude ]] || continue
  HAS_CLAUDE[$pid]=1
  cur=$pid
  for _ in $(seq 1 25); do
    cur=${PPID_OF[$cur]:-}
    [[ -n $cur && $cur != 1 && $cur != 0 ]] || break
    HAS_CLAUDE[$cur]=1
  done
done

# Header widths mirror the row printf exactly: %-24s name, 10-char idle
# ("idle=%4dm"), %-6s state.
printf '%-24s %-10s  %-6s  %s\n' 'WINDOW' 'IDLE' 'STATE' 'TITLE'
{
  tmux list-windows -a -F '#{session_name}:#{window_index}|#{window_activity}|#{pane_pid}|#{pane_title}' |
  while IFS='|' read -r name act pid title; do
    idle=$(( (now - act) / 60 ))
    if [[ -n ${HAS_CLAUDE[$pid]:-} ]]; then state=claude; else state=shell; fi
    flag=""
    [[ $state == claude && $idle -ge $IDLE_WARN ]] && flag="  <-- STALE"
    printf '%d\t%-24s idle=%4dm  %-6s  %-44.44s%s\n' \
      "$idle" "$name" "$idle" "$state" "$title" "$flag"
  done
} | sort -rn | cut -f2-
