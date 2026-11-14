#!/usr/bin/env bash
# Stub reviewer: prints a canned clean review with no AI at all.
# Used by `./init --demo` when no AI CLI is installed, and by tests/smoke.sh.
set -eu

cat <<'EOF'
Stub review (no AI CLI involved).

- calc.py mean(): floor division replaced with true division — matches the
  task and makes test_mean_fractional pass; no other behavior changes.
- No blocking findings. No non-blocking findings.
EOF
echo "VERDICT: CLEAN"
