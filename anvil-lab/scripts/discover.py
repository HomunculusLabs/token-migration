#!/usr/bin/env python3
"""READ ONLY. Discover the actual SURPLUS PoolKey and pinned hook bytecode.
Only calls eth_chainId, eth_getBlockByNumber, eth_getStorageAt, eth_getLogs,
eth_getCode and eth_call. No private keys, signing or transaction submission.
"""
from __future__ import annotations
import argparse, json, os, sys, time, urllib.request, urllib.error
from pathlib import Path
from mathlib import keccak256, word, words, address, signed, calldata, MANAGER, STATE_VIEW, TOKEN, WETH, POOL_ID
ROOT=Path(__file__).resolve().parents[1]
FLAGS=['afterRemoveLiquidityReturnDelta','afterAddLiquidityReturnDelta','afterSwapReturnDelta','beforeSwapReturnDelta','afterDonate','beforeDonate','afterSwap','beforeSwap','afterRemoveLiquidity','beforeRemoveLiquidity','afterAddLiquidity','beforeAddLiquidity','afterInitialize','beforeInitialize']
class RPC:
    def __init__(self,url): self.url=url; self.n=0
    def call(self,method,params):
        assert method in {'eth_chainId','eth_getBlockByNumber','eth_getStorageAt','eth_getLogs','eth_getCode','eth_call'}
        self.n+=1
        req=urllib.request.Request(self.url,json.dumps({'jsonrpc':'2.0','id':self.n,'method':method,'params':params}).encode(),{'Content-Type':'application/json'})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req,timeout=60) as r: out=json.load(r)
                if 'error' in out: raise RuntimeError(f"{method}: {out['error']}")
                return out['result']
            except (urllib.error.URLError,TimeoutError):
                if attempt==2: raise RuntimeError(f'{method}: RPC transport failure (URL deliberately omitted)')
                time.sleep(1+attempt)
    def ethcall(self,to,data,b): return self.call('eth_call',[{'to':to,'data':data},hex(b)])
def decode_init(log):
    if log['address'].lower()!=MANAGER or len(log['topics'])!=4: raise ValueError('Wrong Initialize event emitter/shape')
    expected='0x'+keccak256(b'Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)').hex()
    if log['topics'][0].lower()!=expected: raise ValueError('Wrong Initialize event signature')
    w=words(log['data'])
    if len(w)!=5: raise ValueError('Wrong Initialize data length')
    key={'currency0':address(int(log['topics'][2],16)), 'currency1':address(int(log['topics'][3],16)), 'fee':w[0], 'tickSpacing':signed(w[1],24),'hooks':address(w[2])}
    got='0x'+keccak256(b''.join(word(key[x]) for x in ('currency0','currency1','fee','tickSpacing','hooks'))).hex()
    if got!=POOL_ID or log['topics'][1].lower()!=POOL_ID: raise ValueError('Pool key does NOT hash to SURPLUS pool ID')
    if key['currency0']!=WETH or key['currency1']!=TOKEN: raise ValueError('Unexpected currencies/order: stop and review')
    if not 0<key['tickSpacing']<=32767: raise ValueError('Invalid tick spacing')
    return key

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--block',type=int,help='Pinned Base block (default latest minus 20)')
    ap.add_argument('--init-block',type=int,help='Known Initialize block; skips archive binary search')
    ap.add_argument('--init-log',type=Path,help='Saved Initialize log JSON; skips history lookup')
    a=ap.parse_args(); url=os.environ.get('BASE_RPC_URL')
    if not url: ap.error('Set BASE_RPC_URL to a Base archive RPC. Do not paste it into chat.')
    rpc=RPC(url)
    if int(rpc.call('eth_chainId',[]),16)!=8453: raise RuntimeError('Upstream is not Base chain 8453')
    b=a.block
    if b is None: b=int(rpc.call('eth_getBlockByNumber',['latest',False])['number'],16)-20
    if b<1: raise RuntimeError('Invalid block')
    block=rpc.call('eth_getBlockByNumber',[hex(b),False])
    if block is None: raise RuntimeError('Pinned block missing')
    base_slot='0x'+keccak256(word(POOL_ID)+word(6)).hex()
    raw=int(rpc.call('eth_getStorageAt',[MANAGER,base_slot,hex(b)]),16)
    slot0={'sqrtPriceX96':str(raw&((1<<160)-1)), 'tick':signed(raw>>160,24),'protocolFee':(raw>>184)&0xffffff,'lpFee':(raw>>208)&0xffffff}
    if int(slot0['sqrtPriceX96'])==0: raise RuntimeError('Pool uninitialized at chosen block or unexpected storage layout')
    # Independently cross-check documented core layout against deployed StateView.
    check=words(rpc.ethcall(STATE_VIEW,calldata('getSlot0(bytes32)',[POOL_ID]),b))
    if check != [int(slot0['sqrtPriceX96']),word_int_signed(slot0['tick']),slot0['protocolFee'],slot0['lpFee']]:
        raise RuntimeError('StateView and direct storage disagree; refusing to discover with this layout')
    topic='0x'+keccak256(b'Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)').hex()
    if a.init_log:
        log=json.loads(a.init_log.read_text()); ib=int(log['blockNumber'],16)
    else:
        ib=a.init_block
        if ib is None:
            lo,hi=0,b
            print('Finding Initialize block with archive storage reads...',flush=True)
            while lo<hi:
                mid=(lo+hi)//2
                x=int(rpc.call('eth_getStorageAt',[MANAGER,base_slot,hex(mid)]),16)&((1<<160)-1)
                if x: hi=mid
                else: lo=mid+1
            ib=lo
        logs=rpc.call('eth_getLogs',[{'address':MANAGER,'fromBlock':hex(ib),'toBlock':hex(ib),'topics':[topic,POOL_ID]}])
        if len(logs)!=1: raise RuntimeError(f'Expected one Initialize at block {ib}, found {len(logs)}; no guessing')
        log=logs[0]
    if ib>b or ib<1: raise RuntimeError('Initialize block outside the pinned history')
    # Even an imported log is confirmed against the provider's exact block.
    actual=rpc.call('eth_getLogs',[{'address':MANAGER,'fromBlock':hex(ib),'toBlock':hex(ib),'topics':[topic,POOL_ID]}])
    if len(actual)!=1 or actual[0]['data'].lower()!=log['data'].lower() or actual[0]['topics']!=log['topics']:
        raise RuntimeError('Initialize evidence not confirmed by RPC')
    log=actual[0]; key=decode_init(log); hook=key['hooks']
    code=rpc.call('eth_getCode',[hook,hex(b)])
    if hook!='0x'+'0'*40 and code=='0x': raise RuntimeError('Nonzero hook has no code at pin')
    codehash='0x'+keccak256(bytes.fromhex(code[2:])).hex()
    getters={}
    for sig in ['owner()','poolManager()','getHookPermissions()']:
        try: getters[sig]={'raw':rpc.ethcall(hook,calldata(sig,[]),b)}
        except Exception as e: getters[sig]={'error':str(e)}
    slots={}
    for label in ('implementation','admin','beacon'):
        s='0x'+((int.from_bytes(keccak256(('eip1967.proxy.'+label).encode()),'big')-1)%(1<<256)).to_bytes(32,'big').hex()
        v=rpc.call('eth_getStorageAt',[hook,s,hex(b)])
        slots[label]={'slot':s,'value':v}
        if label in ('implementation','beacon') and int(v,16)>0 and int(v,16)<1<<160:
            addr=address(int(v,16)); bytecode=rpc.call('eth_getCode',[addr,hex(b)])
            slots[label]['address']=addr; slots[label]['runtimeBytecode']=bytecode
    report={'status':'RPC-observed at pinned block; not a source-code audit','chainId':8453,'blockNumber':b,'blockHash':block['hash'],'timestamp':int(block['timestamp'],16),'poolId':POOL_ID,'poolManager':MANAGER,'stateView':STATE_VIEW,'initializeBlock':ib,'initializeLog':log,'poolKey':key,'poolKeyHashVerified':True,'slot0':slot0,'keyUsesDynamicFees':bool(key['fee']&0x800000),'hookRuntimeHash':codehash,'hookPermissionsByAddress':{n:bool(int(hook,16)&(1<<i)) for i,n in enumerate(FLAGS)},'optionalGetterProbes':getters,'eip1967SlotProbes':slots,'limitations':['Address flags identify callbacks, not what their code does.','Zero EIP-1967 slots do not rule out every proxy/delegation pattern.','Current LP fee is not necessarily all-in or next-swap fee.','No position is declared permanently locked by this script.']}
    # Pin stability check to catch an RPC returning inconsistent history.
    if rpc.call('eth_getBlockByNumber',[hex(b),False])['hash']!=block['hash']: raise RuntimeError('Pinned block changed; rerun')
    out=ROOT/'reports'; out.mkdir(exist_ok=True)
    (out/'discovery.json').write_text(json.dumps(report,indent=2)+'\n')
    (out/'hook-runtime.hex').write_text(code+'\n')
    (out/'initialize-log.json').write_text(json.dumps(log,indent=2)+'\n')
    env={'FORK_BLOCK':b,'FORK_BLOCK_HASH':block['hash'],'POOL_HOOK':hook,'POOL_HOOK_CODEHASH':codehash,'POOL_FEE':key['fee'],'POOL_TICK_SPACING':key['tickSpacing'],'POOL_INITIAL_TICK':slot0['tick'],'SURPLUS_FORK_ACK':'true'}
    (ROOT/'.env.fork').write_text('# Generated public constants only. No RPC URL or private key.\n'+''.join(f'export {k}={v}\n' for k,v in env.items()))
    print(json.dumps({'block':b,'poolKey':key,'slot0':slot0,'hookPermissionsByAddress':report['hookPermissionsByAddress']},indent=2))
    print('\nSaved reports/discovery.json and .env.fork. Start Anvil next.')
def word_int_signed(x): return x % (1<<256)
if __name__=='__main__':
    try: main()
    except Exception as e:
        print('STOP:',str(e),file=sys.stderr); sys.exit(1)
