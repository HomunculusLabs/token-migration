#!/usr/bin/env bash
# Regenerates the token's storage layout and fails on any difference from storage-layout.json.
# An intended append-only change fails too: review the diff, rerun with --write, and commit the new
# snapshot with the code (DESIGN.md, "Storage layout and future upgrades").
#
#   scripts/check-storage-layout.sh            check SurplusTokenV2 against the snapshot
#   scripts/check-storage-layout.sh --write    replace the snapshot with the current layout
#   LAYOUT_CONTRACT=<successor> scripts/...    diff a proposed successor against the snapshot
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

snapshot=storage-layout.json
contract=${LAYOUT_CONTRACT:-SurplusTokenV2}
mode=${1:-check}
if [[ $# -gt 1 || ($mode != check && $mode != --write) ]]; then
  echo "usage: [LAYOUT_CONTRACT=<name>] $0 [--write]" >&2
  exit 2
fi

raw=$(mktemp)
fresh=$(mktemp)
build=$(mktemp -d)
trap 'rm -rf "$raw" "$fresh" "$build"' EXIT

# A private out/cache: the project's cached artifacts may lack the layout, and a parallel build or test
# must not see its out/ rewritten underneath it.
forge inspect "$contract" storageLayout --json --out "$build/out" --cache-path "$build/cache" >"$raw"

# Keep only what decides where state lives. AST ids change with the set of sources in a compilation:
# drop every astId and the id solc appends to struct/enum/contract type names (t_struct(RoleData)23_storage).
# `contract` repeats the compiled contract's path on every entry; dropping it lets a successor diff
# cleanly against this snapshot. Keys are sorted; arrays keep their slot order.
node - "$raw" >"$fresh" <<'JS'
const fs = require('fs');

const stripAstId = (text) => text.replace(/(t_(?:struct|enum|contract)\([^)]*\))\d+/g, '$1');

const normalize = (value) => {
  if (Array.isArray(value)) return value.map(normalize);
  if (typeof value === 'string') return stripAstId(value);
  if (value === null || typeof value !== 'object') return value;
  const entries = Object.entries(value)
    .filter(([key]) => key !== 'astId' && key !== 'contract')
    .map(([key, inner]) => [stripAstId(key), normalize(inner)])
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const keys = entries.map(([key]) => key);
  if (new Set(keys).size !== keys.length) throw new Error(`type ids collide once AST ids are dropped: ${keys}`);
  return Object.fromEntries(entries);
};

const layout = normalize(JSON.parse(fs.readFileSync(process.argv[2], 'utf8')));
if (!Array.isArray(layout.storage) || layout.storage.length === 0) {
  throw new Error('forge inspect returned no storage entries');
}
process.stdout.write(`${JSON.stringify(layout, null, 2)}\n`);
JS

if [[ $mode == --write ]]; then
  cp "$fresh" "$snapshot"
  echo "wrote $snapshot from $contract"
  exit 0
fi

if [[ ! -f $snapshot ]]; then
  echo "$snapshot is missing; generate it with: $0 --write" >&2
  exit 1
fi

if ! diff -u "$snapshot" "$fresh"; then
  echo "$contract storage layout differs from $snapshot (- committed snapshot, + $contract)." >&2
  exit 1
fi
echo "$contract storage layout matches $snapshot"
