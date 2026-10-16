"""Acoustic admission and decoder wiring, without torch/numpy/model downloads."""
import ast
from contextlib import nullcontext
import math
from pathlib import Path
import random
import struct
import threading
import time
from types import SimpleNamespace
import unittest

from speech_gate import has_speech


def pcm(samples):
    return b"".join(struct.pack("<h", sample) for sample in samples)


def voiced(milliseconds=200):
    return pcm(round(1000 * math.sin(2 * math.pi * 200 * i / 16000))
               for i in range(16 * milliseconds))


class SpeechGateTests(unittest.TestCase):
    def test_empty_and_digital_silence(self):
        self.assertFalse(has_speech(b""))
        self.assertFalse(has_speech(bytes(5 * 16000 * 2)))

    def test_quiet_nonzero_noise(self):
        rng = random.Random(719)
        self.assertFalse(has_speech(pcm(rng.randint(-40, 40) for _ in range(5 * 16000))))

    def test_isolated_click_and_separated_clicks(self):
        click = pcm([20000] * 320)
        self.assertFalse(has_speech(bytes(16000) + click + bytes(16000)))
        self.assertFalse(has_speech((click + bytes(640)) * 10))

    def test_short_voiced_word(self):
        self.assertTrue(has_speech(voiced()))
        self.assertTrue(has_speech(bytes(16000) + voiced() + bytes(16000)))

    def test_contiguous_duration_and_partial_frame(self):
        self.assertFalse(has_speech(pcm([1000] * (16 * 79))))
        self.assertTrue(has_speech(pcm([1000] * (16 * 80))))
        self.assertFalse(has_speech(pcm([1000] * 960) + bytes(640) + pcm([1000] * 960)))

    def test_little_endian_signed_rms_floor(self):
        self.assertFalse(has_speech(b"\x01\x00" * 1600))  # little endian +1
        self.assertTrue(has_speech(b"\x00\x01" * 1600))   # little endian +256
        self.assertTrue(has_speech(pcm([-256] * 1600)))
        self.assertFalse(has_speech(pcm([65] * 1600)))
        self.assertTrue(has_speech(pcm([66] * 1600)))

    def test_odd_bytes_rejected_even_after_voiced_prefix(self):
        for data in (b"\x00", voiced() + b"\x01"):
            with self.subTest(length=len(data)):
                with self.assertRaises(ValueError):
                    has_speech(data)


class DecoderGateTests(unittest.TestCase):
    def setUp(self):
        # Compile the actual decoder function with small boundary doubles so
        # these tests cannot load a model, import ML runtimes or access a GPU.
        source = ast.parse(Path(__file__).with_name("server.py").read_text())
        decode = next(node for node in source.body if isinstance(node, ast.FunctionDef) and node.name == "decode")
        self.calls = []

        class Array:
            def astype(self, _): return self
            def __truediv__(self, _): return self
            def to(self, _): return self

        class Tokens:
            def __getitem__(self, _): return 2

        def generate(*args, **kwargs):
            self.calls.append("generate")
            return SimpleNamespace(sequences=Tokens())

        def processor(*args, **kwargs):
            self.calls.append("processor")
            return SimpleNamespace(input_features=Array())

        processor.batch_decode = lambda *args, **kwargs: ["a short word"]
        self.app = SimpleNamespace(state=SimpleNamespace(
            processor=processor,
            model=SimpleNamespace(generate=generate, generation_config=SimpleNamespace(eos_token_id=2)),
            device="cpu", prompt_ids=None, decode_token_budget=32))
        names = {"threading": threading, "time": time, "has_speech": has_speech,
                 "StoppingCriteriaList": lambda value: value,
                 "StopRequested": lambda *args: None,
                 "np": SimpleNamespace(frombuffer=lambda *args, **kwargs: Array(), float32="float32"),
                 "torch": SimpleNamespace(inference_mode=nullcontext)}
        exec(compile(ast.Module(body=[decode], type_ignores=[]), "server.py:decode", "exec"), names)
        self.decode = names["decode"]

    def test_quiet_checkpoint_is_fully_finalized_without_model(self):
        data = pcm([12] * (5 * 16000))
        self.assertEqual(self.decode(self.app, data), {"text": "", "finalized_samples": 80000})
        self.assertEqual(self.calls, [])

    def test_quiet_chunks_never_generate_and_full_coverage_is_retained(self):
        data = bytes(30 * 16000 * 2) + voiced() + bytes(30 * 16000 * 2)
        self.assertEqual(self.decode(self.app, data),
                         {"text": "a short word", "finalized_samples": len(data) // 2})
        self.assertEqual(self.calls, ["processor", "generate"])

    def test_isolated_click_never_generates(self):
        data = bytes(32000) + pcm([24000] * 320) + bytes(32000)
        self.assertEqual(self.decode(self.app, data)["text"], "")
        self.assertEqual(self.calls, [])

    def test_empty_and_invalid_pcm(self):
        self.assertEqual(self.decode(self.app, b""), {"text": "", "finalized_samples": 0})
        with self.assertRaises(ValueError):
            self.decode(self.app, b"\x00")
        self.assertEqual(self.calls, [])

    def test_cancellation_does_not_certify_quiet_coverage(self):
        stop = threading.Event()
        stop.set()
        with self.assertRaises(RuntimeError):
            self.decode(self.app, bytes(32000), stop)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
