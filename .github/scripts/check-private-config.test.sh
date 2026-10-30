#!/usr/bin/env bash
#
# Self-test for check-private-config.sh. Proves:
#   1. the scan PASSES on the current clean tree (no self-match, no existing leak)
#   2. the pattern CATCHES each kind of planted secret value
#   3. the pattern IGNORES benign mentions of the same variable names
#
# The planted secrets are assembled from fragments so no full, real-looking
# secret literal is ever committed to the repo.
#
# Run: bash .github/scripts/check-private-config.test.sh
#
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPT=".github/scripts/check-private-config.sh"
PATTERN="$(bash "$SCRIPT" --print-pattern)"
fail=0

# 1. The real scan must accept the current tree (exit 0).
if bash "$SCRIPT" >/dev/null; then
  echo "ok  : clean tree accepted"
else
  echo "FAIL: clean tree rejected (self-match or a real leak?)"
  fail=1
fi

# 2. Realistic leaks, assembled from fragments -- every one must be caught.
jwt="eyJ""hbGciOiJIUzI1NiJ9.eyJ""role_is_service_role_EXAMPLE_ONLY"
planted=(
  "SERVICE_ROLE_KEY=${jwt}"
  'DATABASE_URL=postgres://appuser:EXAMPLE_PW@db.example.com:5432/postgres'
  "crash_sk_""EXAMPLE0NOT0A0REAL0KEY000000"
  "noticebird_sk_""EXAMPLE0NOT0A0REAL0KEY000000"
  "acme_sk_""EXAMPLE0NOT0A0REAL0KEY000000"
)
for line in "${planted[@]}"; do
  if printf '%s\n' "$line" | grep -qniE "$PATTERN"; then
    echo "ok  : caught   -> ${line%%=*}..."
  else
    echo "FAIL: MISSED   -> $line"
    fail=1
  fi
done

# 3. Benign mentions of the names (no value) must NOT be flagged.
benign=(
  'Never commit your service_role key to this public repo.'
  'Set the service secrets only in the server environment.'
  'The DATABASE_URL uses the postgres protocol on the backend.'
  'Rotate the crash_sk secret key if it is ever exposed.'
)
for line in "${benign[@]}"; do
  if printf '%s\n' "$line" | grep -qniE "$PATTERN"; then
    echo "FAIL: FALSE POSITIVE -> $line"
    fail=1
  else
    echo "ok  : ignored  -> $line"
  fi
done

if [[ "$fail" -eq 0 ]]; then
  echo "ALL PASS"
else
  echo "FAILURES DETECTED"
fi
exit "$fail"
