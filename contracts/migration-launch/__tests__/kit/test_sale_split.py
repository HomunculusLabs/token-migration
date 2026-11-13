"""The kit's split of the sale between the Doppler pool and the v3 tail (kit/safe_txs.py: best_tail, quote,
sale_split). The pools here are constant-product stand-ins sized like the real ones at the pin; each pays less for
every extra v1, which is the property the search relies on."""
import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

KIT = Path(__file__).resolve().parents[2] / "kit"
sys.path.insert(0, str(KIT))
import kitlib as k  # noqa: E402
import safe_txs  # noqa: E402

E18 = 10**18
V1_IN = 91_050_022_388 * E18
POOL_MANAGER = "0x498581fF718922c3f8e6A244956aF099B2652b2b"
V3_TAIL = "0xbCf23F30a90f6D7c288fACdc932fF8F8B68b0f30"
OLD_KEY = {"currency0": "0x4200000000000000000000000000000000000006",
           "currency1": "0xC52aeDec3374422d7510E294cfAa90799595CBa3",
           "fee": 0x800000, "tickSpacing": 200, "hooks": "0xbB7784A4d481184283Ed89619A3e3ed143e1Adc0"}
LIMIT = 1461446703485210103287273052203988822378723970341


def pool(weth: int, v1: int, fee_pips: int):
    """WETH out for x v1 in."""
    def out(x: int) -> int:
        net = x * (1_000_000 - fee_pips) // 1_000_000
        return weth * net // (v1 + net)
    return out


# Both priced at ~8.75e-9 WETH per v1, as arbitrage keeps them: the Doppler pool (1.2%) and the v3 tail (1%).
DOPPLER = pool(163_730 * E18 // 1000, 18_700_000_000 * E18, 12_000)
TAIL = pool(3_557 * E18 // 1000, 406_000_000 * E18, 10_000)


def sale(v1_in: int = V1_IN, doppler=DOPPLER, tail=TAIL, doppler_fills: int | None = None,
         tail_fills: int | None = None):
    """raised(t) as sale_split builds it: None where a leg would not fill."""
    def raised(t: int) -> int | None:
        if doppler_fills is not None and v1_in - t > doppler_fills:
            return None
        if t and tail is None or tail_fills is not None and t > tail_fills:
            return None
        return doppler(v1_in - t) + (tail(t) if t else 0)
    return raised


class BestTailTests(unittest.TestCase):
    def test_no_other_split_raises_more(self):
        raised = sale()

        def value(t: int) -> int:
            r = raised(t)
            assert r is not None  # both stand-in pools fill any amount
            return r

        tail = safe_txs.best_tail(raised, V1_IN)
        best = value(tail)
        step = V1_IN // 1_000_000  # the search stops once the maximum is bracketed this tightly
        coarse = [V1_IN * i // 20_000 for i in range(20_000)]
        near = [tail + d * step for d in range(-50, 51) if 0 <= tail + d * step < V1_IN]
        self.assertLessEqual(max(value(t) for t in coarse + near), best + 10**9)  # within a gwei
        self.assertGreater(best, value(0))
        self.assertGreater(best, value(V1_IN // 10))  # the fixed 10% this replaces
        self.assertTrue(0 < tail < V1_IN // 10)

    def test_a_tail_that_cannot_quote_gets_nothing(self):
        self.assertEqual(safe_txs.best_tail(sale(tail=None), V1_IN), 0)

    def test_a_tail_that_adds_nothing_gets_nothing(self):
        self.assertEqual(safe_txs.best_tail(sale(tail=lambda t: 0), V1_IN), 0)

    def test_a_tail_that_fills_only_so_far_gets_at_most_that(self):
        unconstrained = safe_txs.best_tail(sale(), V1_IN)
        cap = unconstrained // 3
        tail = safe_txs.best_tail(sale(tail_fills=cap), V1_IN)
        self.assertLessEqual(tail, cap)
        self.assertLessEqual(cap - tail, V1_IN // 1_000_000)

    def test_a_doppler_pool_that_cannot_take_the_whole_sale_pushes_the_rest_to_the_tail(self):
        fills = V1_IN // 2
        tail = safe_txs.best_tail(sale(doppler_fills=fills), V1_IN)
        self.assertGreaterEqual(tail, V1_IN - fills)
        self.assertIsNotNone(sale(doppler_fills=fills)(tail))

    def test_no_split_that_fills_stops_the_kit(self):
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            safe_txs.best_tail(lambda t: None, V1_IN)
        self.assertIn("no split of the sale fills", err.getvalue())

    def test_a_tiny_sale_terminates_near_the_maximum(self):
        tail = safe_txs.best_tail(lambda t: 10_000 - (t - 37) ** 2, 100)
        self.assertLessEqual(abs(tail - 37), 8)


def leg(low: int, limit: int, partial: bool = True):
    """A leg that sells in full every amount from low to limit, reverts below low (it would pay nothing), and above
    the limit sells only the limit, or reverts. Returns it and the list of amounts it was quoted."""
    calls = []

    def sold(x: int) -> int | None:
        calls.append(x)
        if x < low:
            return None
        if x <= limit:
            return x
        return limit if partial else None
    return sold, calls


class LargestFillTests(unittest.TestCase):
    def test_a_partial_quote_names_the_limit(self):
        # Only 4 or 5 of 100 sell in full: halving from 100 (50, 25, 12, 6, 3, 1) never lands on either.
        sold, _ = leg(4, 5)
        self.assertEqual(safe_txs.largest_fill(sold, 100), 5)

    def test_the_limit_is_exact_to_the_wei(self):
        limit = V1_IN // 3 + 7
        for partial in (True, False):
            with self.subTest(partial=partial):
                sold, calls = leg(1, limit, partial)
                self.assertEqual(safe_txs.largest_fill(sold, V1_IN), limit)
                self.assertLessEqual(len(calls), 2 * V1_IN.bit_length() + 2)

    def test_a_leg_that_sells_nothing_gives_zero(self):
        for n in (0, 1, 2, V1_IN):
            with self.subTest(n=n):
                sold, calls = leg(n + 1, n + 1)
                self.assertEqual(safe_txs.largest_fill(sold, n), 0)
                self.assertLessEqual(len(calls), n.bit_length() + 1)


class FakeChain:
    """eth_call against the stand-in pools, decoded the way SaleQuoter is called."""
    V4 = k.selector(f"quoteV4(address,{safe_txs.POOL_KEY},uint256)")
    V3 = k.selector("quoteV3(address,uint256,uint160)")

    def __init__(self, tail_fills: int | None = None, tail_reverts: bool = False, quoter_code: str = "0x",
                 doppler_fills: int | None = None):
        self.tail_fills, self.tail_reverts, self.quoter_code = tail_fills, tail_reverts, quoter_code
        self.doppler_fills = doppler_fills
        self.calls = []

    def call(self, method: str, params: list):
        assert method == "eth_getCode" and params[0] == safe_txs.QUOTER
        return self.quoter_code

    def _request(self, method: str, params: list) -> dict:
        assert method == "eth_call"
        tx, block, overrides = params
        self.calls.append((tx, block, overrides))
        data = bytes.fromhex(tx["data"][2:])
        words = [int.from_bytes(data[4 + 32 * i:36 + 32 * i], "big") for i in range((len(data) - 4) // 32)]
        if data[:4] == self.V4:
            amount = words[6]
            paid = amount if self.doppler_fills is None else min(amount, self.doppler_fills)
            out = DOPPLER(paid)
            if out == 0:  # the quoter refuses a v4 leg that pays nothing, as the settler does
                return {"error": {"code": 3, "message": "execution reverted: UnexpectedSwapDelta"}}
        elif data[:4] == self.V3:
            amount = words[1]
            if self.tail_reverts:
                return {"error": {"code": 3, "message": "execution reverted: AS"}}
            paid = amount if self.tail_fills is None else min(amount, self.tail_fills)
            out = TAIL(paid)
        else:
            raise AssertionError("unexpected call")
        return {"result": "0x" + (k.word(out) + k.word(paid)).hex()}


def quote_split(chain: FakeChain, bps: int) -> dict:
    """sale_split on the fake chain, the tail capped at bps / 10 000 of what it can take."""
    with mock.patch.object(safe_txs, "quoter_code", return_value="0x6000"):
        return safe_txs.sale_split(chain, {"poolManager": POOL_MANAGER, "v3Tail": V3_TAIL}, OLD_KEY, V1_IN, LIMIT, bps)


class SaleSplitTests(unittest.TestCase):
    def split(self, chain: FakeChain) -> dict:
        return quote_split(chain, 10_000)  # no cap, so these tests check the search itself (TailCapacityTests: the cap)

    def test_each_quote_runs_the_quoter_code_at_the_quoter_address_on_the_latest_block(self):
        chain = FakeChain()
        split = self.split(chain)
        self.assertTrue(all(block == "latest" and tx["to"] == safe_txs.QUOTER
                            and overrides == {safe_txs.QUOTER: {"code": "0x6000"}}
                            for tx, block, overrides in chain.calls))
        self.assertEqual(split["tailIn"], safe_txs.best_tail(sale(), V1_IN))
        self.assertEqual(split["raised"], sale()(split["tailIn"]))
        self.assertEqual(split["dopplerOnly"], DOPPLER(V1_IN))
        self.assertGreater(split["quotedSplits"], len(safe_txs.TAIL_GRID_BPS))

    def test_a_partial_fill_on_the_tail_is_never_chosen(self):
        fills = 100_000_000 * E18
        split = self.split(FakeChain(tail_fills=fills))
        self.assertLessEqual(split["tailIn"], fills)

    def test_a_reverting_tail_leaves_the_whole_sale_on_the_doppler_pool(self):
        split = self.split(FakeChain(tail_reverts=True))
        self.assertEqual((split["tailIn"], split["raised"]), (0, DOPPLER(V1_IN)))

    def test_a_fillable_band_between_the_grid_points_is_found(self):
        # The Doppler pool fills at most 60% of the sale and the tail at most 45%: only 40%-45% on the tail fills,
        # between the grid's 20% and 50%. Concave totals put the best of that band at its low end.
        split = self.split(FakeChain(doppler_fills=V1_IN * 60 // 100, tail_fills=V1_IN * 45 // 100))
        self.assertTrue(V1_IN * 40 // 100 <= split["tailIn"] <= V1_IN * 45 // 100)
        self.assertLessEqual(split["tailIn"] - V1_IN * 40 // 100, V1_IN // 1_000_000)
        self.assertIsNone(split["dopplerOnly"])

    def test_a_split_above_the_grid_is_reachable(self):
        # The Doppler pool takes at most 0.005% of the sale, so every split that fills sells over 99.99% on the tail.
        fills = V1_IN // 20_000
        split = self.split(FakeChain(doppler_fills=fills))
        self.assertGreaterEqual(split["tailIn"], V1_IN - fills)
        self.assertLess(split["tailIn"], V1_IN)

    def test_no_split_fills_when_the_pools_together_cannot_take_the_sale(self):
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            self.split(FakeChain(doppler_fills=V1_IN * 40 // 100, tail_fills=V1_IN * 40 // 100))
        self.assertIn("no split of the sale fills", err.getvalue())

    def test_a_one_wei_band_of_splits_that_fill_is_found(self):
        # The Doppler pool takes at most half the sale and 1 wei, the tail half less 1 wei: exactly one split fills.
        half = V1_IN // 2
        split = self.split(FakeChain(doppler_fills=half + 1, tail_fills=half - 1))
        self.assertEqual((split["tailIn"], split["raised"]), (half - 1, DOPPLER(half + 1) + TAIL(half - 1)))

    def test_code_at_the_quoter_address_stops_the_kit(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.split(FakeChain(quoter_code="0x60"))

    def test_an_rpc_error_that_is_not_a_revert_stops_the_kit(self):
        chain = FakeChain()
        chain._request = lambda method, params: {"error": {"code": -32602, "message": "invalid params"}}
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.split(chain)


# About what the real tail could take at block 56,952,081 (236.6M v1), plus 3 wei so that 70% of it rounds down.
CAPACITY = 236_621_422_516 * 10**15 + 3


class TailCapacityTests(unittest.TestCase):
    """sale.tailCapacityBps: the tail gets at most that share of the most it can take at signing."""

    def test_a_tail_that_cannot_take_the_best_share_gets_exactly_70_percent_of_its_capacity(self):
        split = quote_split(FakeChain(tail_fills=CAPACITY), 7_000)
        self.assertEqual((split["tailIn"], split["tailCapacity"]), (CAPACITY * 7_000 // 10_000, CAPACITY))
        self.assertEqual(split["raised"], DOPPLER(V1_IN - split["tailIn"]) + TAIL(split["tailIn"]))

    def test_with_no_cap_the_same_tail_gets_all_it_can_take(self):
        split = quote_split(FakeChain(tail_fills=CAPACITY), 10_000)
        self.assertEqual((split["tailIn"], split["tailCapacity"]), (CAPACITY, CAPACITY))

    def test_a_tail_that_takes_everything_keeps_the_best_split(self):
        capped, uncapped = quote_split(FakeChain(), 7_000), quote_split(FakeChain(), 10_000)
        self.assertEqual(capped["tailIn"], safe_txs.best_tail(sale(), V1_IN))
        self.assertEqual({key: value for key, value in capped.items() if key != "tailCapacity"},
                         {key: value for key, value in uncapped.items() if key != "tailCapacity"})
        self.assertEqual(capped["tailCapacity"], -(-V1_IN * 10_000 // 7_000))  # it took the whole probe

    def test_a_capacity_between_the_sale_and_the_sale_over_0_7_caps_the_search_below_the_whole_sale(self):
        capacity = V1_IN * 12 // 10
        for bps, measured, hi in ((10_000, V1_IN, V1_IN - 1), (7_000, capacity, capacity * 7_000 // 10_000)):
            with self.subTest(bps=bps), mock.patch.object(safe_txs, "best_tail", wraps=safe_txs.best_tail) as search:
                self.assertEqual(quote_split(FakeChain(tail_fills=capacity), bps)["tailCapacity"], measured)
                self.assertEqual(search.call_args.args[3], hi)
        self.assertLess(capacity * 7_000 // 10_000, V1_IN - 1)

    def test_a_doppler_pool_that_cannot_take_what_the_cap_leaves_stops_the_kit(self):
        # The Doppler pool takes all but 200M v1: the tail can take that, but not within 70% of its capacity.
        chain = FakeChain(doppler_fills=V1_IN - 200_000_000 * E18, tail_fills=CAPACITY)
        self.assertEqual(quote_split(chain, 10_000)["tailIn"], CAPACITY)
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            quote_split(chain, 7_000)
        self.assertIn(f"capped at {CAPACITY * 7_000 // 10_000} (sale.tailCapacityBps 7000 of its measured capacity, "
                      f"{CAPACITY}). The cap is what stops it", err.getvalue())

    def test_the_stop_says_when_the_cap_is_not_what_stops_the_sale(self):
        # The Doppler pool takes all but 400M v1, more than the tail can take at all: no cap would fill the sale.
        chain = FakeChain(doppler_fills=V1_IN - 400_000_000 * E18, tail_fills=CAPACITY)
        for bps in (7_000, 10_000):
            with self.subTest(bps=bps), contextlib.redirect_stderr(io.StringIO()) as err, \
                    self.assertRaises(SystemExit):
                quote_split(chain, bps)
            self.assertIn(f"The cap is not what stops it: with no cap the tail could take {CAPACITY}.", err.getvalue())

    def test_the_signed_record_carries_what_the_signer_checklist_compares(self):
        split = quote_split(FakeChain(tail_fills=CAPACITY), 7_000)
        params = k.load_params()
        record = safe_txs.sale_record({"v1In": V1_IN, "tailIn": split["tailIn"], "tailLimit": LIMIT}, params["sale"],
                                      split, "0x" + "ab" * 32, 2**96)
        self.assertEqual((record["tailIn"], record["tailCapacity"]), (str(split["tailIn"]), str(CAPACITY)))
        self.assertIs(type(record["tailCapacityBps"]), int)
        self.assertEqual(record["tailCapacityBps"], 7_000)
        # SIGNER-CHECKLIST: sale.tailIn is at most sale.tailCapacity × sale.tailCapacityBps / 10 000
        self.assertLessEqual(int(record["tailIn"]), int(record["tailCapacity"]) * record["tailCapacityBps"] // 10_000)
        self.assertEqual((record["v1In"], record["tailShare"], record["quotedRaise"]),
                         (str(V1_IN), "maximize-raise", str(split["raised"])))

    def test_v1_sold_on_the_tail_before_execution_leaves_the_signed_amount_filling_up_to_the_margin(self):
        def fills(signed: int, sold_first: int) -> bool:
            # v1 sold on the tail first leaves it able to take that much less.
            data = safe_txs.encode("quoteV3(address,uint256,uint160)", k.addr_word(V3_TAIL), k.word(signed),
                                   k.word(LIMIT))
            quoted = safe_txs.quote(FakeChain(tail_fills=CAPACITY - sold_first), "0x6000", data)
            return quoted is not None and quoted[1] == signed

        margin = CAPACITY - CAPACITY * 7_000 // 10_000  # the 30% the cap leaves
        signed = quote_split(FakeChain(tail_fills=CAPACITY), 7_000)["tailIn"]
        self.assertTrue(fills(signed, margin // 2) and fills(signed, margin))
        self.assertFalse(fills(signed, margin + 1))
        uncapped = quote_split(FakeChain(tail_fills=CAPACITY), 10_000)["tailIn"]
        self.assertFalse(fills(uncapped, 1))  # with no cap, one wei sold first leaves signed v1 unsold

    def test_the_cap_is_a_required_integer_from_1_to_10000(self):
        class Validated(Exception):
            pass

        d = {"v2": "0x" + "22" * 20, "hook": "0x" + "20" * 20}
        for value, ok in ((1, True), (7_000, True), (10_000, True), (0, False), (10_001, False), (-7_000, False),
                          (7_000.0, False), ("7000", False), (True, False), (None, False), ("TBD", False)):
            params = k.load_params()
            params["sale"]["tailCapacityBps"] = value
            with self.subTest(value=value), contextlib.redirect_stderr(io.StringIO()) as err, \
                    mock.patch.object(safe_txs.seeds, "build", side_effect=Validated), \
                    self.assertRaises(Validated if ok else SystemExit):
                safe_txs.settle_params(params, None, d, V1_IN)  # the seed is read only after the params are checked
            if not ok:
                self.assertIn(f"params sale.tailCapacityBps is {value!r}", err.getvalue())
        del params["sale"]["tailCapacityBps"]
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            safe_txs.settle_params(params, None, d, V1_IN)
        self.assertIn("missing key sale.tailCapacityBps", err.getvalue())


if __name__ == "__main__":
    unittest.main()
