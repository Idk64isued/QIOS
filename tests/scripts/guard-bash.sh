#!/bin/bash
# .claude/hooks/guard-bash: commands in, allow or deny out. Prints ok/FAIL per case; exits 1 on any FAIL.
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/.claude/hooks/guard-bash"
AGENT=/Users/x/Developer/LightTouchMac/.claude/worktrees/agent-1
MAIN=/Users/x/Developer/LightTouchMac
failed=0
# expect allow|deny CWD COMMAND
expect() {
    local json status
    json="$(perl -MJSON::PP -e 'print encode_json({hook_event_name => "PreToolUse", tool_name => "Bash",
        cwd => $ARGV[0], tool_input => {command => $ARGV[1]}})' "$2" "$3")"
    env -u LTM_GUARD_OFF "$HOOK" <<<"$json" 2>/dev/null
    status=$?
    if [[ ($1 == allow && $status == 0) || ($1 == deny && $status == 2) ]]; then echo "ok   $1: $3"
    else echo "FAIL $1 (got exit $status): $3"; failed=1; fi
}
expect deny "$AGENT" 'pkill -f qemu-system-arm'
expect deny "$AGENT" 'sleep 2; killall LightTouchDevice'
expect deny "$AGENT" 'sudo pkill -9 -f "Light Touch"'
expect deny "$AGENT" 'until ! pgrep -f qemu-system; do sleep 1; done'
expect deny "$AGENT" 'git stash push -m wip'
expect deny "$AGENT" 'cd x && git -C /tmp/r stash pop'
expect deny "$AGENT" 'git push origin HEAD'
expect deny "$MAIN" 'open -a "Light Touch"'
expect deny "$MAIN" 'open ~/Applications/Light\ Touch.app'
expect deny "$MAIN" '"/Applications/Light Touch.app/Contents/MacOS/LightTouch" &'
expect deny "$MAIN" 'build/qemu-system-arm -M iPod-Touch,bootrom=x -nographic'
expect deny "$MAIN" 'X=1 $(echo pkill) ; pkill qemu'
expect allow "$AGENT" 'kill 12345'
expect allow "$AGENT" 'pgrep -fl qemu-system'
expect allow "$AGENT" 'grep -n "pkill qemu" notes.md'
expect allow "$AGENT" 'git commit -m "never git stash or git push from here"'
expect allow "$AGENT" 'git log --grep=stash'
expect allow "$AGENT" 'git commit -m "fix; git push later" && echo "a; pkill qemu"'
expect allow "$MAIN" 'git push origin main'
expect allow "$MAIN" 'git stash list'
expect allow "$AGENT" 'pkill -f my-own-http-server'
expect allow "$AGENT" 'sessions single BASE --app "build/Light Touch.app"'
expect allow "$AGENT" '"/x/Light Touch.app/Contents/MacOS/LightTouchDevice" --version'
expect allow "$AGENT" 'build/qemu-system-arm -M iPod-Touch -audio driver=none -nographic'
expect allow "$AGENT" 'echo "open -a Light Touch"'
expect allow "$AGENT" 'ls build/qemu-system-arm'
expect allow "$AGENT" 'LTM_GUARD_OFF=1 pkill -f qemu-system-arm'
exit $failed
