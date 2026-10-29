"""The split seed's v2 side (kit/seed.py): an old-pool v1 ladder becomes successor v2 ranges.

The fork suite and the kit rehearsal check the same code against the real pool; these cases pin the edges: the grid
rounding, merging, gaps, the seam at the opening tick, both pair orders, and every loud stop."""
import contextlib
import io
from pathlib import Path
import sys
import unittest

KIT = Path(__file__).resolve().parents[2] / "kit"
sys.path.insert(0, str(KIT))
import seed  # noqa: E402

E21 = 10**21
L = 10**18


def ladder(ticks, tick, liquidity, offset=0):
    return {"sqrtPriceX96": seed.sqrt_at(tick) + offset, "tick": tick, "liquidity": liquidity, "ticks": ticks}


# Shaped like the old pool at the September pin: a deep block to tick 121,000 and a thinner one through the price.
TODAY = ladder([(-887_200, 2356 * E21), (121_000, (957 - 2356) * E21), (176_200, -957 * E21)], 175_894, 957 * E21,
               offset=12_345)


class SeedTests(unittest.TestCase):
    def stops(self, fn, *args) -> str:
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            fn(*args)
        return err.getvalue()

    def test_tick_math_matches_v4(self):
        # The values test/LaunchMath.t.sol pins for the Solidity side.
        self.assertEqual(seed.sqrt_at(-887_272), 4_295_128_739)
        self.assertEqual(seed.sqrt_at(887_272), 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342)
        self.assertEqual(seed.sqrt_at(0), 1 << 96)
        self.assertEqual(seed.sqrt_at(-887_220), 4_306_310_044)
        self.assertEqual(seed.sqrt_at(887_220), 1_457_652_066_949_847_389_969_617_340_386_294_118_487_833_376_468)
        self.assertEqual(seed.sqrt_at(60), 79_466_191_966_197_645_195_421_774_833)
        self.assertEqual(seed.sqrt_at(-60), 78_990_846_045_029_531_151_608_375_686)
        self.assertEqual((seed.edge(60), seed.edge(200)), (887_220, 887_200))

    def test_grid_rounding_is_half_up(self):
        cases = {(175_894, 60): 175_920, (29, 60): 0, (30, 60): 60, (-30, 60): 0, (-31, 60): -60,
                 (121_000, 60): 121_020, (-887_200, 60): -887_220}
        for (tick, spacing), want in cases.items():
            self.assertEqual(seed.to_grid(tick, spacing), want, (tick, spacing))

    def test_v2_side_copies_each_block_on_the_successor_grid(self):
        blocks, total = seed.ladder_blocks(TODAY, 100)
        sqrt_p = TODAY["sqrtPriceX96"]
        deep = 2356 * E21 * (seed.sqrt_at(121_000) - seed.sqrt_at(-887_200)) // seed.Q96
        near = 957 * E21 * (sqrt_p - seed.sqrt_at(121_000)) // seed.Q96
        self.assertEqual([(b["lower"], b["upper"], b["amount"]) for b in blocks],
                         [(-887_200, 121_000, deep), (121_000, 176_200, near)])
        self.assertEqual(total, deep + near)
        seam = seed.to_grid(TODAY["tick"], 60)
        above = seed.v2_ranges(blocks, seam, 60, v2_first=False)
        below = seed.v2_ranges(blocks, seam, 60, v2_first=True)
        self.assertEqual([(r["tickLower"], r["tickUpper"]) for r in above], [(-887_220, 121_020), (121_020, 175_920)])
        # v2 sorting first quotes the inverse price: the same ranges, negated, above the price.
        self.assertEqual([(r["tickLower"], r["tickUpper"]) for r in below], [(-121_020, 887_220), (-175_920, -121_020)])
        for ranges, v2_first in ((above, False), (below, True)):
            for r, b in zip(ranges, blocks):
                need = seed.v2_need([r], v2_first)
                self.assertLessEqual(need, b["amount"], "a range must never need more than its block")
                self.assertLessEqual(b["amount"] - need, seed.copy_slack([r], v2_first), "a range fell short")
            self.assertLessEqual(total - seed.v2_need(ranges, v2_first), seed.copy_slack(ranges, v2_first))

    def test_near_equal_segments_merge_and_gaps_split(self):
        merging = ladder([(0, 1000 * L), (200, 5 * L), (400, -1005 * L), (600, 2000 * L), (1200, -1500 * L),
                          (1400, -500 * L)], 1000, 2000 * L)
        blocks, _ = seed.ladder_blocks(merging, 100)
        # 1000 and 1005 are within 1% and merge; the empty [400, 600) splits; [1200, 1400) is above the price.
        self.assertEqual([(b["lower"], b["upper"]) for b in blocks], [(0, 400), (600, 1200)])
        ranges = seed.v2_ranges(blocks, seed.to_grid(1000, 60), 60, v2_first=False)
        self.assertEqual([(r["tickLower"], r["tickUpper"]) for r in ranges], [(0, 420), (600, 1020)])
        exact, _ = seed.ladder_blocks(merging, 0)
        self.assertEqual([(b["lower"], b["upper"]) for b in exact], [(0, 200), (200, 400), (600, 1200)])

    def test_no_v1_at_the_price_stops(self):
        gap = ladder([(0, 1000 * L), (400, -1000 * L)], 1000, 0)
        self.assertIn("holds no v1 at its price", self.stops(seed.ladder_blocks, gap, 100))

    def test_a_ladder_walk_that_disagrees_with_the_pool_stops(self):
        wrong = dict(TODAY, liquidity=TODAY["liquidity"] + 1)
        self.assertIn("ladder walk gives", self.stops(seed.ladder_blocks, wrong, 100))

    def test_nothing_to_copy_stops(self):
        empty = ladder([(2000, 1000 * L), (2200, -1000 * L)], 1000, 0)
        self.assertIn("nothing to copy", self.stops(seed.ladder_blocks, empty, 100))

    def test_a_block_that_collapses_on_the_grid_stops(self):
        # The price sits 10 ticks above a liquidity step: the near block rounds to nothing at the seam.
        step = ladder([(0, 1000 * L), (1000, 500 * L), (2000, -1500 * L)], 1010, 1500 * L)
        blocks, _ = seed.ladder_blocks(step, 100)
        message = self.stops(seed.v2_ranges, blocks, seed.to_grid(1010, 60), 60, False)
        self.assertIn("collapses on the 60-tick grid", message)


if __name__ == "__main__":
    unittest.main()
