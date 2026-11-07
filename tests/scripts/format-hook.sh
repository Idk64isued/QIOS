#!/bin/bash
# scripts/hooks/pre-commit and scripts/format in a scratch repository: a staged Swift or C file is formatted and
# committed formatted; a partly staged file whose staged text isn't formatted is refused and left as it was; a file
# that doesn't parse is refused; excluded and non-source files are committed untouched; the hook runs in a linked
# worktree; --check lists what isn't formatted. Prints ok/FAIL per check; exits 1 on any FAIL.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/ltm-format-hook-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
R="$T/repo"
mkdir -p "$R/scripts/hooks" "$R/build-support/patches" "$R/Sources"
cp "$SRC/scripts/format" "$R/scripts/"
cp "$SRC/scripts/hooks/pre-commit" "$R/scripts/hooks/"
cp "$SRC/.swift-format" "$SRC/.clang-format" "$R/"
cd "$R" || exit 1
git init -q -b main .
git config user.name test && git config user.email test@example.invalid && git config commit.gpgsign false
git config core.hooksPath scripts/hooks
git add -A && git commit -q -m setup || exit 1
failed=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failed=1; fi; }
commit() { git commit -q -m "$1" >"$T/out" 2>&1; }

printf 'let x = [1,2,3]\n' >Sources/A.swift
git add Sources/A.swift
check "a staged Swift file is committed formatted" \
    'commit swift && [[ "$(git show HEAD:Sources/A.swift)" == "let x = [1, 2, 3]" ]] && git diff --quiet'

printf 'int f( ){return 1;}\n' >Sources/f.c
git add Sources/f.c
check "a staged C file is committed formatted" \
    'commit c && [[ "$(git show HEAD:Sources/f.c)" == "int f() { return 1; }" ]] && git diff --quiet'

printf 'let x = [1, 2, 3]\nlet y = [4,5]\n' >Sources/A.swift
git add Sources/A.swift
printf 'let x = [1, 2, 3]\nlet y = [4,5]\nlet z = 6\n' >Sources/A.swift
before="$(git rev-parse :Sources/A.swift)"
check "a partly staged, unformatted file is refused with the command to run" \
    '! commit partial && grep -q "scripts/format .Sources/A.swift. && git add -p" "$T/out"'
check "and the index and working copy are left as they were" \
    '[[ "$(git rev-parse :Sources/A.swift)" == "$before" && "$(tail -1 Sources/A.swift)" == "let z = 6" ]]'

printf 'let x = [1, 2, 3]\nlet y = [4, 5]\n' >"$T/staged"
git update-index --add --cacheinfo "100644,$(git hash-object -w "$T/staged"),Sources/A.swift"
check "a partly staged, formatted file is committed as staged" \
    'commit partial-ok && [[ "$(git show HEAD:Sources/A.swift | tail -1)" == "let y = [4, 5]" ]] && [[ "$(tail -1 Sources/A.swift)" == "let z = 6" ]]'
git checkout -q -- Sources/A.swift

printf 'func f( {\n' >Sources/Bad.swift
git add Sources/Bad.swift
check "a file the formatter can't parse is refused" '! commit bad && ! git cat-file -e HEAD:Sources/Bad.swift 2>/dev/null'
git rm -q --cached Sources/Bad.swift && rm Sources/Bad.swift

printf 'int  g( ){return 2;}\n' >build-support/patches/g.c
printf 'some   text\n' >notes.md
git add build-support/patches/g.c notes.md
check "excluded and non-source files are committed untouched" \
    'commit untouched && [[ "$(git show HEAD:build-support/patches/g.c)" == "int  g( ){return 2;}" && "$(git show HEAD:notes.md)" == "some   text" ]]'

git worktree add -q "$T/linked" -b linked
printf 'let w = [7,8]\n' >"$T/linked/W.swift"
check "the hook runs in a linked worktree" \
    '(cd "$T/linked" && git add W.swift && commit linked) && [[ "$(git show linked:W.swift)" == "let w = [7, 8]" ]]'

check "--check passes a formatted tree" 'scripts/format --check'
printf 'let v = [9,10]\n' >Sources/V.swift
git add Sources/V.swift
check "--check lists an unformatted tracked file, exit 1" '[[ "$(scripts/format --check)" == Sources/V.swift ]]; (($? == 0)) && ! scripts/format --check >/dev/null'
check "--all formats it" 'scripts/format --all && scripts/format --check && [[ "$(cat Sources/V.swift)" == "let v = [9, 10]" ]]'
exit $failed
