#!/usr/bin/env python3
"""Read-only full Transfer sweep for SURPLUS at the pinned block.
Builds the complete holder set from token history, verifies against totalSupply,
classifies top holders as EOA/contract via getCode at the pin. No secrets.
"""
import json, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

ENDPOINT = sys.argv[1] if len(sys.argv) > 1 else 'https://mainnet.base.org'
TOKEN = '0xc52aedec3374422d7510e294cfaa90799595cba3'
DEPLOY, PIN = 46077742, 51702954
TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
SPAN = 2000

def rpc_batch_raw(calls):
    payload = json.dumps([{'jsonrpc': '2.0', 'id': i, 'method': m, 'params': p} for i, (m, p) in enumerate(calls)]).encode()
    req = urllib.request.Request(ENDPOINT, payload, {'Content-Type': 'application/json',
                                                     'User-Agent': 'curl/8.7.1', 'Accept': 'application/json'})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                out = json.load(r)
            return out
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError):
            if attempt == 4:
                raise
            time.sleep(2 + 2 * attempt)

rpc_batch = rpc_batch_raw  # legacy name kept for classify path

# 1) sweep
bal = {}
nlogs = 0
spans = []
c = DEPLOY
while c <= PIN:
    spans.append((c, min(c + SPAN - 1, PIN)))
    c += SPAN

def fetch(span):
    frm, to = span
    last_err = None
    for attempt in range(6):
        out = rpc_batch_raw([('eth_getLogs', [{'address': TOKEN, 'fromBlock': hex(frm), 'toBlock': hex(to), 'topics': [TRANSFER]}])])
        item = None
        if isinstance(out, list) and out:
            item = next((i for i in out if i.get('id') == 0), out[0])
        elif isinstance(out, dict):
            item = out
        if item is None:
            last_err = 'empty batch response'
        elif 'error' in item:
            last_err = str(item['error'])[:120]
        else:
            return item.get('result') or []
        time.sleep(1.5 + 1.5 * attempt)
    raise RuntimeError(f'span {frm}-{to} failed after retries: {last_err}')

done = 0
t0 = time.time()
with ThreadPoolExecutor(max_workers=4) as ex:
    for span, logs in zip(spans, ex.map(fetch, spans)):
        for lg in logs:
            frm = '0x' + lg['topics'][1][-40:]
            to = '0x' + lg['topics'][2][-40:]
            v = int(lg['data'], 16)
            bal[frm] = bal.get(frm, 0) - v
            bal[to] = bal.get(to, 0) + v
            nlogs += 1
        done += 1
        if done % 200 == 0:
            print(f'{done}/{len(spans)} spans, {nlogs} transfers, {time.time()-t0:.0f}s', flush=True)

bal.pop('0x' + '0' * 40, None)
tot = sum(bal.values())
print(json.dumps({'endpoint': ENDPOINT, 'spans': len(spans), 'transfers': nlogs,
                  'holders': len(bal), 'sum_balances_raw': str(tot),
                  'total_supply_raw': '100000000000000000000000000000',
                  'matches_supply': tot == 100000000000000000000000000000}), flush=True)
# Persist raw balances immediately so classification can't lose the sweep.
with open('reports/balances-raw.json', 'w') as f:
    json.dump({a: str(v) for a, v in bal.items()}, f)

# 2) classify top holders at pin via getCode on the LOCAL pinned Anvil
LOCAL = 'http://127.0.0.1:8545'

def local_rpc(method, params):
    payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
    req = urllib.request.Request(LOCAL, payload, {'Content-Type': 'application/json'})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                out = json.load(r)
            if 'error' in out:
                raise RuntimeError(out['error'])
            return out['result']
        except Exception:
            if attempt == 3:
                raise
            time.sleep(1)

FORBIDDEN = {'0x498581ff718922c3f8e6a244956af099b2652b2b', '0xbb7784a4d481184283ed89619a3e3ed143e1adc0',
             '0x7c5f5a4bbd8fd63184577525326123b519429bdc', '0x000000000022d473030f116ddee9f6b43ac78ba3',
             '0x4200000000000000000000000000000000000006'}
ranked = sorted(bal.items(), key=lambda kv: -kv[1])[:80]
rows = []
for a, v in ranked:
    if v <= 0:
        continue
    code = local_rpc('eth_getCode', [a, 'latest'])
    kind = 'EOA' if code == '0x' else 'CONTRACT'
    if a in FORBIDDEN:
        kind = 'FORBIDDEN'
    rows.append({'addr': a, 'bal_raw': str(v), 'bal_tokens': round(v / 1e18, 2), 'kind': kind,
                 'code_len': (len(code) - 2) // 2, 'pct_supply': round(100 * v / 1e32, 3)})
print(json.dumps(rows, indent=1))
