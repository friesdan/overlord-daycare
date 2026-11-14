#!/usr/bin/env bash
# Stub worker for the demo project: applies the known fix with no AI at all.
# Used by `./init --demo` when no AI CLI is installed, and by tests/smoke.sh.
# It runs with the task worktree as its working directory (bin/worker arranges
# that), so `calc.py` below is the worktree's copy.
set -eu

sed -i.bak 's|sum(numbers) // len(numbers)|sum(numbers) / len(numbers)|' calc.py
rm -f calc.py.bak

python3 -m unittest discover

git add -A
git commit -qm "demo: fix mean() to use true division"
echo "stub worker: applied the fix, tests pass, committed"
