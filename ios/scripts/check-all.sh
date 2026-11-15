#!/bin/bash
# Everything that can be checked without a Mac, in one go. Run before every push / update zip:
#     bash ios/scripts/check-all.sh
# Needs: python3 with tree-sitter==0.26.1 tree-sitter-swift==0.7.4 and PyYAML; actionlint if installed.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
step() { printf '%-34s' "$1"; shift; if out=$("$@" 2>&1); then echo ok; else echo FAILED; echo "$out" | tail -40; fail=1; fi; }

step "Swift sources (precheck)"      python3 ios/scripts/precheck.py ios/App/Sources
step "precheck still catches bugs"   python3 ios/scripts/precheck-selftest.py
step "Info.plist parses"             python3 -c "import plistlib; plistlib.load(open('ios/App/Info.plist','rb'))"
step "project specs parse"           python3 -c "import yaml; [yaml.safe_load(open(f)) for f in ('ios/App/project.yml','ios/App/project-lite.yml')]"
step "workflow parses"               python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ios.yml'))"
if command -v actionlint >/dev/null; then
    step "workflow lint (actionlint)" actionlint .github/workflows/ios.yml
fi
step "xcodebuild options exist"      python3 ios/scripts/check-workflow-flags.py
step "shell scripts parse"           bash -c 'for f in ios/scripts/*.sh sync-upstream.sh; do bash -n "$f" || exit 1; done'
step "FirmwareKit patch script"      python3 -m py_compile ios/scripts/patch-firmwarekit.py
rm -rf ios/scripts/__pycache__
[ $fail = 0 ] && echo "All checks passed." || echo "Some checks failed."
exit $fail
