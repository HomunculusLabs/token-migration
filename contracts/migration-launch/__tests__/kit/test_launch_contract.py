"""The launch contract's kit helpers: its CREATE2 address and constructor encoding, and the outputs check.py records."""
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

KIT = Path(__file__).resolve().parents[2] / "kit"
sys.path.insert(0, str(KIT))
import check  # noqa: E402
import kitlib as k  # noqa: E402
import safe_txs  # noqa: E402

SAFE = "0x5afe00000000000000000000000000000000beef"
VAULT = "0x0000000000000000000000000000000000000a11"
V2 = "0x0000000000000000000000000000000000002222"
SETTLER = "0x0000000000000000000000000000000000005e77"
WETH = "0x4200000000000000000000000000000000000006"
V1 = "0x0000000000000000000000000000000000001111"


def params() -> dict:
    """Shaped like a real launch: a negative opening tick and a range below it exercise the signed words."""
    return {"oldKey": {"currency0": WETH, "currency1": V1, "fee": 0x800000, "tickSpacing": 200, "hooks": SETTLER},
            "v1In": 2_200 * 10**18, "tailIn": 220 * 10**18,
            "tailLimit": 1461446703485210103287273052203988822378723970341,
            "newKey": {"currency0": V2, "currency1": WETH, "fee": 3000, "tickSpacing": 60, "hooks": SETTLER},
            "openTick": -175_920,
            "v2Ranges": [{"tickLower": -887_220, "tickUpper": -200_040, "liquidity": 10**18},
                         {"tickLower": -200_040, "tickUpper": -175_920, "liquidity": 3 * 10**23}],
            "minWethOut": 269_663_702_174_597_524}


class LaunchContractEncoding(unittest.TestCase):
    def test_create2_address_matches_eip_1014(self):
        # EIP-1014 examples 0 and 1.
        self.assertEqual(safe_txs.create2_address("0x" + "00" * 20, b"\x00" * 32, b"\x00"),
                         k.checksum("0x4D1A2e2bB4F88F0250f26Ffff098B0b30B26BF38"))
        self.assertEqual(safe_txs.create2_address("0xdeadbeef00000000000000000000000000000000", b"\x00" * 32, b"\x00"),
                         k.checksum("0xB928f69Bb1D91Cd65274e3c79d8986362984fDA3"))

    def test_settle_data_wraps_the_tuple_behind_one_offset(self):
        p = params()
        self.assertEqual(safe_txs.settle_data(p),
                         k.selector(safe_txs.SETTLE_SIG) + k.word(32) + safe_txs.settle_words(p))

    @unittest.skipUnless(shutil.which("cast"), "needs foundry's cast")
    def test_constructor_args_match_cast(self):
        p = params()
        d = {"safe": SAFE, "vault": VAULT, "v2": V2, "settler": SETTLER}
        ranges = ",".join(f"({r['tickLower']},{r['tickUpper']},{r['liquidity']})" for r in p["v2Ranges"])
        settle = (f"({safe_txs.key_arg(p['oldKey'])},{p['v1In']},{p['tailIn']},{p['tailLimit']},"
                  f"{safe_txs.key_arg(p['newKey'])},{p['openTick']},[{ranges}],{p['minWethOut']})")
        out = subprocess.run(["cast", "abi-encode", safe_txs.LAUNCH_CONSTRUCTOR,
                              f"({SAFE},{VAULT},{V2},{SETTLER},5,7)", settle],
                             capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(safe_txs.launch_args(d, p, 5, 7), bytes.fromhex(out[2:]))

    def test_the_launch_records_its_deployment_not_a_builder_file(self):
        self.assertIn("output/safe-txs/launch-batch.deploy.json", check.RECORDED_OUTPUTS)
        self.assertNotIn("output/safe-txs/launch-batch.json", check.RECORDED_OUTPUTS)
        self.assertIn("output/safe-txs/commitRoot.json", check.RECORDED_OUTPUTS)


if __name__ == "__main__":
    unittest.main()
