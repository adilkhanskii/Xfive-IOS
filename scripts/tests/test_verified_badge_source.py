from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
VERIFIED_BADGE_VIEW = ROOT / "X5" / "Views" / "VerifiedBadgeView.swift"


class VerifiedBadgeSourceTests(unittest.TestCase):
    def test_purchase_button_label_is_explicitly_black(self):
        source = VERIFIED_BADGE_VIEW.read_text(encoding="utf-8")
        purchase_block = source.split(
            "private var purchaseBlock: some View", 1
        )[1].split("private var activeBlock", 1)[0]

        self.assertIn(".foregroundStyle(.black)", purchase_block)


if __name__ == "__main__":
    unittest.main()
