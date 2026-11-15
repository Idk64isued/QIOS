#!/usr/bin/env python3
"""Every option the workflow passes to xcodebuild has to be one xcodebuild actually has.

xcodebuild-options.txt is the option list xcodebuild itself printed on the CI runner (Xcode 26), after the update 30
build died on '-continueBuildingAfterErrors', which only exists as an Xcode preference.
"""
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
known = {l.strip() for l in open(os.path.join(here, "xcodebuild-options.txt")) if l.strip()}
wf = open(os.path.join(here, "..", "..", ".github", "workflows", "ios.yml")).read()
bad = []
for m in re.finditer(r"(?<![\^\"'\w])xcodebuild[ \t]+(-(?:[^\n]*\\\n)*[^\n]*)", wf):
    for flag in re.findall(r"(?<![\w-])-[A-Za-z][A-Za-z0-9]+", m.group(1)):
        if flag not in known:
            bad.append(flag)
for flag in sorted(set(bad)):
    print(f".github/workflows/ios.yml: error: xcodebuild has no option {flag}")
sys.exit(1 if bad else 0)
