#!/usr/bin/env bash
#
# Single source of truth for the CI "committed private configuration" scan.
#
# Fails (exit 1) if any tracked file contains a leaked secret VALUE. It matches
# secret values rather than bare variable names on purpose:
#
#   * The names (service_role, DATABASE_URL, crash_sk_) show up
#     legitimately in prose, docs, and this very tooling. An earlier inline
#     version matched the names and therefore matched the workflow line that
#     defined the patterns -- `git grep` returned exit 0, the leading `!`
#     inverted it, and the step failed on every run. Matching values fixes that
#     class of self-match at the root.
#   * The scan tooling itself (which necessarily contains value-shaped patterns
#     and test fixtures) lives under .github/scripts and is excluded below, so it
#     can never trip its own check.
#
# Run locally:   bash .github/scripts/check-private-config.sh
# Print pattern: bash .github/scripts/check-private-config.sh --print-pattern
# Self-test:     bash .github/scripts/check-private-config.test.sh
#
set -uo pipefail

# Each alternative requires an assignment/JWT/credential -- an actual value --
# not just a mention of the name:
#   service_role...=eyJ   a service_role key assigned to a JWT
#   DATABASE_URL=postgres://user:pass@   a connection string WITH credentials
#   <prefix>_sk_<20+ chars>  a secret ingest key, under any key prefix
#                            (noticebird_sk_, and crash_sk_ from before the
#                            rename)
# Scanned case-insensitively so real UPPERCASE env vars (DATABASE_URL, ...) match.
PRIVATE_CONFIG_PATTERN="service_role[a-z0-9_]*[[:space:]\"':=]+eyj|database_url[[:space:]\"']*[:=][[:space:]\"']*postgres(ql)?://[^[:space:]:@/]+:[^[:space:]@/]+@|[a-z][a-z0-9]*_sk_[A-Za-z0-9_-]{20,}"

if [[ "${1:-}" == "--print-pattern" ]]; then
  printf '%s\n' "$PRIVATE_CONFIG_PATTERN"
  exit 0
fi

# Run from the repo (worktree) root so the exclude pathspecs resolve correctly.
cd "$(git rev-parse --show-toplevel)"

# .github/scripts holds this scan and its fixtures, which legitimately contain
# value-shaped strings, so it is excluded.
git grep -niE "$PRIVATE_CONFIG_PATTERN" -- ':!.github/scripts'
rc=$?

if [[ "$rc" -eq 0 ]]; then
  echo "ERROR: committed private configuration detected (see matches above)." >&2
  exit 1
elif [[ "$rc" -eq 1 ]]; then
  echo "OK: no committed private configuration found."
  exit 0
else
  echo "ERROR: git grep failed (exit $rc)." >&2
  exit "$rc"
fi
