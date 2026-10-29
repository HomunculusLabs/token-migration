#!/usr/bin/env python3
"""Reject non-loopback endpoints and verify the pinned Anvil snapshot."""
import json,os,sys,urllib.request,urllib.parse
url=os.environ.get('LOCAL_RPC_URL','http://127.0.0.1:8545')
u=urllib.parse.urlparse(url)
if u.scheme!='http' or u.hostname not in ('127.0.0.1','localhost','::1') or u.username or u.password:
    sys.exit('STOP: LOCAL_RPC_URL must be a loopback HTTP Anvil URL without credentials')
def rpc(method,params):
    req=urllib.request.Request(url,json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),{'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=30) as r: v=json.load(r)
    if 'error' in v: raise RuntimeError(v['error'])
    return v['result']
try:
    version=rpc('web3_clientVersion',[])
    if 'anvil' not in version.lower(): sys.exit('STOP: endpoint does not identify as Anvil')
    if int(rpc('eth_chainId',[]),16)!=8453: sys.exit('STOP: preserve Base chain ID 8453 in Anvil')
    b=rpc('eth_getBlockByNumber',['latest',False]); expected=int(os.environ['FORK_BLOCK'])
    if int(b['number'],16)!=expected: sys.exit('STOP: Anvil head is not the pinned block; restart the untouched fork')
    if b['hash'].lower()!=os.environ['FORK_BLOCK_HASH'].lower(): sys.exit('STOP: pinned block hash mismatch')
    # anvil_nodeInfo is an Anvil-specific method; do not accept chain ID alone.
    info=rpc('anvil_nodeInfo',[])
    # Intentionally do NOT save nodeInfo: it can contain the upstream private RPC URL.
    print('Confirmed loopback Anvil at Base block',expected,'with matching block hash.')
except Exception:
    sys.exit('STOP: could not validate local Anvil or pinned configuration. Check that Anvil is running; no calls were sent to modify state.')
