"""Rehearsal transaction receipts and safe recovery after an interrupted deposit replay."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'kit'))
import rehearse

TX = '0x' + 'ab' * 32
SENDER = '0x' + '01' * 20
TARGET = '0x' + '02' * 20


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ReceiptRpc:
    def __init__(self, clock, available_at=None, status='0x1'):
        self.clock = clock
        self.available_at = available_at
        self.status = status
        self.sent = 0

    def call(self, method, arguments):
        if method == 'eth_sendTransaction':
            self.sent += 1
            return TX
        if method == 'eth_getTransactionReceipt':
            if self.available_at is None or self.clock.now < self.available_at:
                return None
            return {'transactionHash': TX, 'status': self.status, 'gasUsed': '0x10000'}
        raise AssertionError((method, arguments))


class ReceiptTests(unittest.TestCase):
    def run_send(self, rpc, clock):
        with patch.object(rehearse.time, 'monotonic', clock.monotonic), \
                patch.object(rehearse.time, 'sleep', clock.sleep):
            return rehearse.send(rpc, SENDER, TARGET, b'')

    def test_delayed_receipt_does_not_fail_or_resubmit_a_successful_transaction(self):
        clock = Clock()
        rpc = ReceiptRpc(clock, available_at=15)
        with contextlib.redirect_stderr(io.StringIO()):
            receipt = self.run_send(rpc, clock)
        self.assertEqual(receipt['transactionHash'], TX)
        self.assertEqual(receipt['status'], '0x1')
        self.assertEqual(rpc.sent, 1)

    def test_unconfirmed_receipt_is_not_reported_as_a_revert(self):
        clock = Clock()
        rpc = ReceiptRpc(clock)
        message = io.StringIO()
        with contextlib.redirect_stderr(message), self.assertRaises(SystemExit):
            self.run_send(rpc, clock)
        self.assertIn('not yet confirmed', message.getvalue())
        self.assertIn(TX, message.getvalue())
        self.assertNotIn('failed:', message.getvalue())
        self.assertEqual(rpc.sent, 1)

    def test_mined_revert_still_stops(self):
        clock = Clock()
        rpc = ReceiptRpc(clock, available_at=0, status='0x0')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.run_send(rpc, clock)
        self.assertEqual(rpc.sent, 1)


V1 = '0x' + '03' * 20
BOB = '0x' + '04' * 20


class DepositRpc:
    def __init__(self):
        self._url = 'http://127.0.0.1:18551'
        self.credited = {SENDER: 100, BOB: 0}
        self.withdrawn = {SENDER: 0, BOB: 0}
        self.balances = {SENDER: 0, BOB: 100}
        self.pending = False
        self.phase = 0
        self.sent = []

    def call(self, method, arguments):
        if method == 'txpool_status':
            return {'pending': '0x1' if self.pending else '0x0', 'queued': '0x0'}
        if method == 'anvil_setBalance':
            return True
        raise AssertionError((method, arguments))

    def eth_call(self, target, data, block='latest'):
        selector = data[2:10]
        account = '0x' + data[-40:]
        if selector == rehearse.k.selector('balanceOf(address)').hex():
            value = self.balances[account]
        elif selector == rehearse.k.selector('credited(address)').hex():
            value = self.credited[account]
        elif selector == rehearse.k.selector('withdrawn(address)').hex():
            value = self.withdrawn[account]
        elif selector == rehearse.k.selector('totalDepositedV1()').hex():
            value = sum(self.credited.values())
        elif selector == rehearse.k.selector('phase()').hex():
            value = self.phase
        elif selector == rehearse.k.selector('root()').hex():
            value = 0
        else:
            raise AssertionError((target, data, block))
        return '0x' + rehearse.k.word(value).hex()

    def send(self, rpc, sender, target, data, gas):
        self.sent.append((sender, target, data))
        if target == TARGET:
            amount = int.from_bytes(data[4:], 'big')
            self.credited[sender] += amount
            self.balances[sender] -= amount
        return {'gasUsed': '0x10000'}

    def block(self):
        return {'number': '0x1'}


class DepositResumeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        (self.directory / 'plan.json').write_text(json.dumps({'vault': TARGET}))
        (self.directory / 'resolved.json').write_text(json.dumps({'v1': V1}))
        self.cohort = self.directory / 'cohort.json'
        self.cohort.write_text(json.dumps({'accounts': [SENDER, BOB], 'amounts': ['100', '100'],
                                          'eligibleCount': 2, 'eligibleTotal': '200'}))
        self.rpc = DepositRpc()

    def replay(self):
        with patch.object(rehearse, 'DEPLOY', self.directory), \
                patch.object(rehearse.k, 'Rpc', return_value=self.rpc), \
                patch.object(rehearse, 'send', side_effect=self.rpc.send), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rehearse.deposit(self.rpc, self.cohort)

    def test_resume_skips_confirmed_deposits_and_a_completed_rerun_sends_nothing(self):
        self.replay()
        self.assertEqual([sender for sender, _, _ in self.rpc.sent], [BOB, BOB])
        self.assertEqual(self.rpc.credited, {SENDER: 100, BOB: 100})
        self.replay()
        self.assertEqual(len(self.rpc.sent), 2)

    def test_partial_ledger_is_refused_before_another_deposit(self):
        self.rpc.credited[SENDER] = 50
        self.rpc.balances[SENDER] = 100
        with self.assertRaises(SystemExit):
            self.replay()
        self.assertEqual(self.rpc.sent, [])

    def test_non_open_vault_blocks_replay_before_sending(self):
        self.rpc.credited[SENDER] = 0
        self.rpc.balances[SENDER] = 100
        self.rpc.phase = 1
        with self.assertRaises(SystemExit):
            self.replay()
        self.assertEqual(self.rpc.sent, [])

    def test_pending_transactions_block_replay_before_sending(self):
        self.rpc.credited[SENDER] = 0
        self.rpc.balances[SENDER] = 100
        self.rpc.pending = True
        with self.assertRaises(SystemExit):
            self.replay()
        self.assertEqual(self.rpc.sent, [])


if __name__ == '__main__':
    unittest.main()
