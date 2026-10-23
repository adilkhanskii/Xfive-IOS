from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PAYWALL = ROOT / "X5" / "Views" / "PaywallView.swift"


class PaywallContrastSourceTests(unittest.TestCase):
    def test_credit_pack_button_uses_dark_content_on_neon_background(self):
        source = PAYWALL.read_text(encoding="utf-8")
        pack_card = source.split("private func packCard", 1)[1].split(
            "private func buy", 1
        )[0]

        self.assertIn("ProgressView().tint(.black)", pack_card)
        self.assertIn(".buttonStyle(.borderedProminent)", pack_card)
        self.assertIn(".tint(.accentColor)", pack_card)
        self.assertIn(".foregroundStyle(.black)", pack_card)


if __name__ == "__main__":
    unittest.main()
