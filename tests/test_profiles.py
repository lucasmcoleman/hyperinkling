"""Check that the example profiles use the packaged executable and mounted assets."""

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "profiles"
MODEL = "/models/Inkling-2-Mini-UD-Q4_K_M.gguf"


class ProfileTests(unittest.TestCase):
    def load(self, name):
        profile = json.loads((PROFILES / name).read_text(encoding="utf-8"))
        self.assertEqual(profile["exe"], "/opt/maya/bin/maya-ik2")
        self.assertEqual(profile["cwd"], "/opt/maya/source")
        self.assertEqual(profile["tokenizer"], "/assets/tokenizer")
        self.assertEqual(profile["model_name"], "inkling-2-mini")
        self.assertEqual(profile["port"], 8080)
        self.assertEqual(profile["args"][:2], ["--model", MODEL])
        return profile

    def test_default_profile(self):
        profile = self.load("64k-fp8.json")
        self.assertEqual(profile["args"][2:], ["--max-context", "65536", "--chunk", "4096"])
        self.assertEqual(profile["env"]["IK2_KV"], "fp8")
        dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn('ARG HYPERINKLING_MODE=stable', dockerfile)
        self.assertIn('CMD ["/opt/maya/profiles/64k-fp8.json"]', dockerfile)

    def test_draft_profile(self):
        profile = self.load("64k-fp8-dspark.json")
        self.assertEqual(profile["args"][2:], ["--max-context", "65536", "--draft", "/models/mtp.safetensors"])
        self.assertEqual(profile["env"]["IK2_DRAFT_WIDTH"], "7")
        self.assertEqual(profile["env"]["IK2_KV"], "fp8")

    def test_fp16_control_profile(self):
        profile = self.load("8k-f16.json")
        self.assertEqual(profile["args"][2:], ["--max-context", "8192"])
        self.assertEqual(profile["env"]["IK2_KV"], "f16")

    def test_batch_profile(self):
        profile = self.load("experimental-4x32k-fp8.json")
        self.assertEqual(profile["args"][2:], ["--max-context", "32768", "--chunk", "2048", "--parallel", "4"])
        self.assertEqual(profile["env"]["IK2_KV"], "fp8")


if __name__ == "__main__":
    unittest.main()
