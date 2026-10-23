from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
LOGGER = ROOT / "X5" / "Services" / "DiagnosticLogger.swift"


class DiagnosticLoggerSourceTests(unittest.TestCase):
    def test_extra_fields_are_encoded_into_existing_summary_column(self):
        source = LOGGER.read_text(encoding="utf-8")

        self.assertIn('payload["summary"] = extra', source)
        self.assertIn('.sorted { $0.key < $1.key }', source)
        self.assertNotIn('for (k, v) in extra { payload[k] = v }', source)


if __name__ == "__main__":
    unittest.main()
