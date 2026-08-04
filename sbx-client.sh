#!/bin/sh
# sbx (in-container) - c-heavy sync client. See docs/SYNC.md on the host.
set -eu
# Both overridable for tests, exactly as sbx-sync-exec.ps1 does it host-side;
# the live values are the container's. Nothing is given away by allowing this -
# this client is not the security boundary. The agent holds the key and can run
# ssh by hand; what constrains it is the forced command at the far end.
conf="${SBX_SYNC_CONF:-/home/agent/.ssh-ro/sync.conf}"
key="${SBX_SYNC_KEY:-$HOME/.ssh/id_sbx_sync}"
die() { echo "sbx: $*" >&2; exit 2; }
case "${1:-}" in
  sync) shift ;;
  pr) shift; cmd="pr" ;;
  ""|-h|--help|help)
    echo "usage: sbx sync [<project>] <push|pull|fetch>" >&2
    echo "       sbx pr check" >&2
    echo "  sync runs the git op HOST-side in the project workspace dir, with host" >&2
    echo "  credentials. Project defaults to the one containing your cwd." >&2
    echo "  pr check lists CodeRabbit's review comments on the current branch's" >&2
    echo "  PR (c-gh) - see docs/GH.md. Everything else PR-related (create," >&2
    echo "  push, reply) is plain 'gh'/'git', already authenticated - no wrapper" >&2
    echo "  needed. Every other sbx command is host-side only - run it on the host." >&2
    exit 0 ;;
  *) die "unknown command: $1 - inside the sandbox only 'sbx sync'/'sbx pr' exist; run other sbx commands on the host" ;;
esac

if [ "${cmd:-}" = "pr" ]; then
  case "${1:-}" in
    check)
      # Read-only, no push: CodeRabbit takes several minutes to review a new
      # push, so a verb that pushed AND checked in one call would only ever
      # see nothing or CodeRabbit's bare "review started" ack. Push separately
      # with plain `git push`, wait, then check.
      pr_number=$(gh pr view --json number -q .number) || die "no PR found for this branch - run 'gh pr create --fill' first"
      # --paginate: the comments endpoint defaults to 30/page, and a PR with
      # more CodeRabbit comments than that would silently truncate without it.
      exec gh api --paginate "repos/{owner}/{repo}/pulls/$pr_number/comments" \
        --jq '.[] | select(.user.login == "coderabbitai[bot]") | "#\(.id) \(.path):\(.line // .original_line)\n\(.body)\n---"'
      ;;
    *) die "usage: sbx pr check" ;;
  esac
fi
case $# in
  1) name=""; op="$1" ;;
  2) name="$1"; op="$2" ;;
  *) die "usage: sbx sync [<project>] <push|pull|fetch>" ;;
esac
# Provisioning first: otherwise an unconfigured sandbox complains about the
# cwd, sending you to look in entirely the wrong place.
[ -f "$conf" ] || die "c-heavy sync is not provisioned - run 'sbx sync-setup --address ...' on the host, then 'sbx rebuild'"
[ -f "$key" ] || die "sync key missing at $key - run 'sbx rebuild' on the host"
if [ -z "$name" ]; then
  case "$PWD" in
    /work/*) name=$(printf %s "${PWD#/work/}" | cut -d/ -f1) ;;
    *) die "not inside a project (cwd $PWD) - name it: sbx sync <project> $op" ;;
  esac
fi
host=$(sed -n 's/^host=//p' "$conf" | head -1)
user=$(sed -n 's/^user=//p' "$conf" | head -1)
port=$(sed -n 's/^port=//p' "$conf" | head -1)
[ -n "$host" ] || die "no host= in $conf"
[ -n "$user" ] || die "no user= in $conf"
[ -n "$port" ] || port=22
# The remote command is fixed two tokens; sbx-sync-exec re-validates both.
# IdentitiesOnly/IdentityAgent: offer the sync key and NOTHING else. -i alone
# only appends to the candidate list, so any other key reachable from this
# container could authenticate instead - landing on a session with no
# restrict and no forced command, i.e. a shell on the host.
exec ssh -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -o IdentityAgent=none -i "$key" -p "$port" "$user@$host" "$name $op"
