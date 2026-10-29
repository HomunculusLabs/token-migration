#!/usr/bin/env python3
"""Offline regression checks; no RPC, secrets, or external dependencies."""
import copy, json, random, re, unittest
from pathlib import Path
from unittest.mock import patch
import mathlib as m
import discover
class OfflineTests(unittest.TestCase):
    def test_keccak_known(self):
        self.assertEqual(m.keccak256(b'').hex(),'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470')
        self.assertEqual(m.keccak256(b'abc').hex(),'4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45')
        self.assertEqual(m.calldata('balanceOf(address)',[m.TOKEN])[:10],'0x70a08231')
    def test_keccak_optional_independent(self):
        try: from Crypto.Hash import keccak
        except ImportError: self.skipTest('Optional PyCryptodome not installed; fixed known vectors still tested')
        rng=random.Random(65)
        for n in [0,1,31,32,135,136,137,271,272,400,1000]:
            data=bytes(rng.randrange(256) for _ in range(n)); h=keccak.new(digest_bits=256);h.update(data)
            self.assertEqual(m.keccak256(data),h.digest())
    def test_signed_abi(self):
        self.assertEqual(m.signed(int.from_bytes(m.word(-23000),'big'),24),-23000)
        self.assertEqual(m.address(int(m.TOKEN,16)),m.TOKEN)
        self.assertEqual(m.words('0x'+m.word(2).hex()),[2])
        with self.assertRaises(ValueError): m.words('0x01')
    def test_tick_vectors(self):
        for tick,want in [(0,1<<96),(-887272,4295128739),(887272,1461446703485210103287273052203988822378723970342),(1,79232123823359799118286999568)]:
            self.assertEqual(m.sqrt_at_tick(tick),want)
        for t in [-800000,-1,0,1,250000,800000]: self.assertLess(m.sqrt_at_tick(t),m.sqrt_at_tick(t+1))
    def test_native_direction_and_reserves(self):
        L=10**18
        a0,a1=m.interval_amounts(100,200,L,m.sqrt_at_tick(0));self.assertGreater(a0,0);self.assertEqual(a1,0)
        b0,b1=m.interval_amounts(100,200,L,m.sqrt_at_tick(300));self.assertEqual(b0,0);self.assertGreater(b1,0)
        c0,c1=m.interval_amounts(100,200,L,m.sqrt_at_tick(150));self.assertGreater(c0,0);self.assertGreater(c1,0)
        self.assertLess(c0,a0);self.assertLess(c1,b1)
    def test_curve_reconciliation(self):
        ticks=[{'tick':100,'liquidityNet':10**18},{'tick':200,'liquidityNet':-(10**18)}]
        rows,a0,a1=m.reconstruct(ticks,m.sqrt_at_tick(150),150,10**18)
        self.assertEqual((a0,a1),m.interval_amounts(100,200,10**18,m.sqrt_at_tick(150)))
        with self.assertRaises(RuntimeError): m.reconstruct(ticks,m.sqrt_at_tick(150),150,1)
    def test_initialize_decode_and_hash_guard(self):
        # Synthetic fixture, NOT evidence of the real hook or fee.
        fee=0x800000;spacing=200;hook='0x'+'1'*40
        pid='0x'+m.keccak256(b''.join(m.word(x) for x in [m.WETH,m.TOKEN,fee,spacing,hook])).hex()
        log={'address':m.MANAGER,'topics':['0x'+m.keccak256(b'Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)').hex(),pid,'0x'+m.word(m.WETH).hex(),'0x'+m.word(m.TOKEN).hex()],
             'data':'0x'+b''.join(m.word(x) for x in [fee,spacing,hook,1<<96,0]).hex()}
        with patch.object(discover,'POOL_ID',pid):
            key=discover.decode_init(log);self.assertEqual(key['hooks'],hook)
            bad=copy.deepcopy(log);bad['topics'][0]='0x'+'0'*64
            with self.assertRaises(ValueError): discover.decode_init(bad)
        with self.assertRaises(ValueError): discover.decode_init(log)
    def test_solidity_addresses(self):
        src=(Path(__file__).resolve().parents[1]/'src/ForkSupport.sol').read_text()
        vals={n:f'0x{int(x,16):040x}' for n,x in re.findall(r'constant (PERMIT2|POSM)=address\(uint160\((0x[0-9a-f]+)\)',src)}
        self.assertEqual(vals['PERMIT2'],'0x000000000022d473030f116ddee9f6b43ac78ba3')
        self.assertEqual(vals['POSM'],m.POSITION_MANAGER)
if __name__=='__main__': unittest.main(verbosity=2)
