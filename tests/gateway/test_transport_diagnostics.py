"""Offline-only diagnostic receipt tests: no process, socket, model or fixture IO."""
import importlib.util
import json
from pathlib import Path
import unittest

path=Path(__file__).resolve().parents[2]/'dgx/qualification/paired_transport.py'
spec=importlib.util.spec_from_file_location('transport_diagnostics',path)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class TerminalDiagnosticsTest(unittest.TestCase):
    def test_first_cause_survives_cleanup(self):
        d=module.TerminalDiagnostics()
        d.native('backend_failure',False);d.failure('premature_native_stop')
        d.terminal({'reason':'native_failure','grpc_code':14,'detail':'operation failed'},2,81)
        d.failure('RuntimeError');d.phase('relay_terminate')
        d.terminal({'reason':'shutdown','grpc_code':0},2,82)
        r=d.snapshot()
        self.assertEqual(r['first_native_stop'],{'reason':'backend_failure','expected':False})
        self.assertEqual(r['first_harness_failure'],'premature_native_stop')
        self.assertEqual(r['first_error_terminal']['grpc_code'],14)
        self.assertEqual(r['first_error_terminal']['generation'],2)
        self.assertEqual(r['last_terminal']['reason'],'shutdown')
    def test_untrusted_text_is_never_retained(self):
        marker='fictional transcript and credential must not be logged'
        d=module.TerminalDiagnostics()
        d.native(marker,False)
        d.terminal({'reason':marker,'grpc_code':99,'detail':marker},2,1)
        d.stderr('observer',('rpc error: code = Unavailable desc = '+marker).encode())
        raw=json.dumps(d.snapshot())
        self.assertNotIn(marker,raw)
        self.assertEqual(d.snapshot()['stderr_code_counts'],{'observer:grpc_Unavailable':1})
        self.assertIsNone(d.snapshot()['last_terminal']['grpc_code'])
    def test_stderr_budget_is_bounded_and_still_accepts_drained_input(self):
        d=module.TerminalDiagnostics()
        for _ in range(1000):d.stderr('relay',b'x'*4096)
        r=d.snapshot()
        self.assertEqual(r['stderr_inspected_bytes']['relay'],65536)
        self.assertTrue(r['stderr_budget_exceeded'])
        self.assertEqual(r['stderr_code_counts'],{})
    def test_malformed_details_fail_closed(self):
        d=module.TerminalDiagnostics();d.native([],False)
        d.terminal({'reason':[],'grpc_code':True,'detail':[]},2,1)
        self.assertEqual(d.snapshot()['last_terminal']['reason'],'unclassified')
        self.assertIsNone(d.snapshot()['last_terminal']['grpc_code'])
    def test_structured_rollover_record_is_strict_enum_numeric_only(self):
        d=module.TerminalDiagnostics()
        record={'event':'mistt_rollover_terminal','version':1,'stage':'old_transcript_validation','cause':'transcript_end_clock_mismatch','sequence':81,'remote_offset_ns':110000000000,'cut_offset_ns':220000000000,'native_samples':[3520000,3520000],'remote_samples':[1760000,1760000]}
        d.stderr('relay',json.dumps(record).encode())
        self.assertEqual(d.snapshot()['first_rollover_terminal'],record)
        bad=dict(record,detail='fictional transcript must not escape')
        other=module.TerminalDiagnostics();other.stderr('relay',json.dumps(bad).encode())
        self.assertIsNone(other.snapshot()['first_rollover_terminal'])
        bad=dict(record,stage=[]);other.stderr('relay',json.dumps(bad).encode())
        bad=dict(record,native_samples=[True,0]);other.stderr('relay',json.dumps(bad).encode())
        self.assertIsNone(other.snapshot()['first_rollover_terminal'])

    def test_successful_budget_terminal_is_not_an_error(self):
        d=module.TerminalDiagnostics();d.terminal({'reason':'budget_rotation'},1,2)
        self.assertIsNone(d.snapshot()['first_error_terminal'])
        self.assertEqual(d.snapshot()['last_terminal']['grpc_code'],0)

if __name__=='__main__':unittest.main()
