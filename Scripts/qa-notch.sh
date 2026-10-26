#!/bin/zsh
# Visual QA: drives every emotion through the real pipeline
# (hook payload → notch-hook → socket → app → notch) and captures the notch.
#
#   Scripts/qa-notch.sh [out_dir]      (the app must be running)
#
# Needs Screen Recording permission for the terminal running it.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/qa}"
mkdir -p "$OUT"
H="$HOME/Library/Application Support/NotchCompanion/bin/notch-hook"
CWD="$PWD"

# Capture rect: 560×180 pt centred on the notch.
read X W <<< "$(swift - <<'EOF'
import AppKit
let s = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
let cx = s.auxiliaryTopLeftArea.map { l in (l.maxX + s.auxiliaryTopRightArea!.minX) / 2 } ?? s.frame.midX
print(Int(cx - 280), 560)
EOF
)"
shot() { screencapture -x -R "$X,0,$W,180" "$OUT/$1.png"; }

claude() {  # claude <hook> <session> [extra json]
  echo "{\"session_id\":\"$2\",\"cwd\":\"$CWD\",\"hook_event_name\":\"$1\"${3:-}}" | "$H" claude-code
}
codex() {
  echo "{\"session_id\":\"$2\",\"cwd\":\"$CWD\",\"hook_event_name\":\"$1\"${3:-}}" | "$H" codex
}
resolve() { claude UserPromptSubmit "$1" ',"prompt":"x"'; }

# Clear anything left from earlier runs.
for s in qa-perm qa-question qa-idle preview-permission preview-question test-claude-code; do resolve $s; done
sleep 1.2

# Anxiety: permission request, then the duplicate Notification merges.
claude PermissionRequest qa-perm ',"tool_name":"Bash","tool_input":{"command":"rm -rf build"}'
sleep 0.2;  shot 01-anxiety-entry
sleep 0.35; shot 02-anxiety-reaction
sleep 1.2;  shot 03-anxiety-detail
claude Notification qa-perm ',"notification_type":"permission_prompt","message":"needs permission"'
sleep 0.5;  shot 04-anxiety-merged
claude PostToolUse qa-perm ',"tool_name":"Bash","tool_input":{},"tool_response":{}'
sleep 0.15; shot 05-resolved-exit
sleep 0.8;  shot 06-collapsed

# Embarrassment: AskUserQuestion.
claude PreToolUse qa-question ',"tool_name":"AskUserQuestion","tool_input":{}'
sleep 1.8;  shot 07-embarrassment
resolve qa-question; sleep 1

# Transient outcomes.
claude PostToolUseFailure qa-build ',"tool_name":"Bash","tool_input":{"command":"swift build"},"error":"exit 1"'
sleep 1.8;  shot 08-anger-build-failed
claude PostToolUseFailure qa-test ',"tool_name":"Bash","tool_input":{"command":"npm test"},"error":"exit 1"'
sleep 1.8;  shot 09-disgust-tests-failed
claude StopFailure qa-crit ',"error_type":"rate_limit"'
sleep 1.8;  shot 10-fear-critical
claude PostToolUseFailure qa-stop ',"tool_name":"Bash","tool_input":{"command":"sleep 9"},"is_interrupt":true'
sleep 1.8;  shot 11-sadness-stopped
claude Stop qa-done ',"stop_hook_active":false'
sleep 1.8;  shot 12-joy-completed
sleep 5.5

# Ennui: idle is low priority → compact.
claude Notification qa-idle ',"notification_type":"idle_prompt","message":"waiting"'
sleep 1.2;  shot 13-ennui-compact
sleep 4

# Envy: two agents waiting at once.
claude PermissionRequest qa-perm ',"tool_name":"Edit","tool_input":{}'
codex PermissionRequest qa-codex ',"tool_name":"shell","tool_input":{"command":["ls"]}'
sleep 1.8;  shot 14-envy-two-waiting
resolve qa-perm
echo '{"session_id":"qa-codex","cwd":"'"$CWD"'","hook_event_name":"UserPromptSubmit"}' | "$H" codex
sleep 1.2;  shot 15-cleared

python3 - "$OUT" <<'EOF'
import sys, glob
from PIL import Image
out = sys.argv[1]
files = sorted(glob.glob(f"{out}/[0-9]*.png"))
ims = [Image.open(f) for f in files]
w, h = ims[0].size
sheet = Image.new("RGB", (w * 2 + 10, (h + 10) * ((len(ims) + 1) // 2)), (255, 0, 255))
for i, im in enumerate(ims):
    sheet.paste(im, ((i % 2) * (w + 10), (i // 2) * (h + 10)))
sheet.save(f"{out}/contact-sheet.png")
print(f"{len(ims)} frames → {out}/contact-sheet.png")
EOF
