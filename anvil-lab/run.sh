#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ -f .env.fork ]] || { echo 'Run python3 scripts/discover.py first.' >&2; exit 1; }
source .env.fork
export LOCAL_RPC_URL="${LOCAL_RPC_URL:-http://127.0.0.1:8545}"
python3 scripts/check_local.py
command -v forge >/dev/null || { echo 'Install Foundry first.' >&2; exit 1; }
mkdir -p reports
forge --version > reports/foundry-version.txt
case "${1:-probe}" in
  probe) pattern='test_0[012]'; name='probe';;
  compare) pattern='test_2[012]'; name="compare-${SELL_TOKENS:-raw-${SELL_AMOUNT_RAW:-1000000}}";;
  *) echo 'Usage: ./run.sh [probe|compare]' >&2; exit 1;;
esac
name="${name}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
python3 scripts/run_manifest.py "$name"
# forge TEST only: executes inside the local test VM. No broadcast, send, wallet or keys.
forge test --fork-url "$LOCAL_RPC_URL" --match-contract SurplusForkTest --match-test "$pattern" -vvvv 2>&1 | tee "reports/${name}.txt"
