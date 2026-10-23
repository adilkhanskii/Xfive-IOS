"""Wiring regression; isolated PostgreSQL red/green proof is in diagnostics/x5-audit."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class VerifiedProjectionLock(unittest.TestCase):
    def test_profile_lock_precedes_entitlement_snapshot(self):
        source = (ROOT / "supabase/migrations/20260907070000_serialize_verified_profile_projection.sql").read_text(encoding="utf-8")
        self.assertLess(source.index("from public.profiles where id = p_user_id for update"), source.index("select max(active_entitlement.expires_date)"))
        self.assertIn("if not found then return null; end if;", source)
        self.assertIn("from public, anon, authenticated, service_role", source)
        self.assertIn("set search_path = ''", source)


if __name__ == "__main__":
    unittest.main()
