#!/usr/bin/env python3
"""Save only allowlisted, non-secret run settings. Never dump the environment."""
from pathlib import Path
import hashlib,json,os,sys,datetime
root=Path(__file__).resolve().parents[1]
name=sys.argv[1]
keys=['FORK_BLOCK','FORK_BLOCK_HASH','POOL_HOOK','POOL_HOOK_CODEHASH','POOL_FEE','POOL_TICK_SPACING',
      'SELL_TOKENS','SELL_AMOUNT_RAW','LP_WETH_BUDGET_WEI','RANGE_GAP_TICKS','RANGE_WIDTH_TICKS',
      'RANGE_TICK_LOWER','RANGE_TICK_UPPER','SQRT_PRICE_LIMIT_X96','USE_POSITION_MANAGER',
      'ADD_HOOK_DATA','SWAP_HOOK_DATA','REMOVE_HOOK_DATA']
files=['foundry.toml','src/ForkSupport.sol','test/SurplusFork.t.sol','donors.json']
settings={k:os.environ[k] for k in keys if k in os.environ}
# Hook-data bytes can include signatures or private metadata; report hashes only.
for k in ('ADD_HOOK_DATA','SWAP_HOOK_DATA','REMOVE_HOOK_DATA'):
    if k in settings:
        settings[k]={'sha256_of_text':hashlib.sha256(settings[k].encode()).hexdigest(),'bytes_not_in_manifest':True}
report={'createdUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'run':name,'explicitSettings':settings,
        'defaults':{'SELL_TOKENS':'1000000','LP_WETH_BUDGET_WEI':'1000000000000000',
                    'RANGE_GAP_TICKS':'23000','RANGE_WIDTH_TICKS':'7000','USE_POSITION_MANAGER':'false'},
        'sha256':{f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in files},
        'scope':'Current complete pool; NOT locked-only. Local fork; not a mainnet transaction.'}
(root/'reports'/f'{name}-settings.json').write_text(json.dumps(report,indent=2)+'\n')
