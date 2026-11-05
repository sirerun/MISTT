"""Offline desired-state contracts; no Spark, credentials, or model requests."""
import importlib.util
import unittest
from pathlib import Path
spec = importlib.util.spec_from_file_location("practice_render", Path(__file__).with_name("render.py"))
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

class DesiredStateTests(unittest.TestCase):
    def test_asr_only_keeps_endpoint_and_removes_decision_allocation(self):
        manifest = renderer.render(asr_only=True, name="zendesk-asr-renewal-test", lifetime_seconds=14400)
        container = manifest["spec"]["containers"][0]
        self.assertEqual(container["ports"], [{"containerPort": 7870, "hostPort": 18772}])
        self.assertEqual(container["resources"]["requests"], {"cpu":"8", "memory":"48Gi", "nvidia.com/gpu":"1"})
        self.assertEqual(container["resources"]["limits"], container["resources"]["requests"])
        self.assertEqual(manifest["spec"]["restartPolicy"], "Never")
        self.assertIn("exec timeout 14400 bash", container["command"][-1])
        self.assertEqual(dict((x["name"], x["value"]) for x in container["env"])["MISTT_PRACTICE_MODE"], "asr-only")
        self.assertEqual(container["image"], renderer.IMAGE)

    def test_combined_is_explicit_and_retains_prior_resources(self):
        container = renderer.render()["spec"]["containers"][0]
        self.assertEqual(len(container["ports"]), 2)
        self.assertEqual(container["resources"]["requests"]["memory"], "64Gi")
        self.assertEqual(dict((x["name"], x["value"]) for x in container["env"])["MISTT_PRACTICE_MODE"], "paired-and-decision")

    def test_unbounded_lifetimes_and_unowned_names_refused(self):
        for value in (0, -1, 43300, True, "43200"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                renderer.render(lifetime_seconds=value)
        for value in ("../foreign", "UPPER", "x" * 64, "-foreign", "foreign-"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                renderer.render(name=value)

if __name__ == "__main__":
    unittest.main()
