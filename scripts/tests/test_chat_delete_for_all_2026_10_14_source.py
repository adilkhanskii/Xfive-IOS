from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"
FIX = MIGRATIONS / "20261014150000_chat_delete_for_all_text_sender.sql"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class ChatDeleteForAll20261014SourceTests(unittest.TestCase):
    """Адильхан 14.10 15:10: «Не удалось удалить сообщение у всех» — RPC падал на text = uuid."""

    def test_sender_check_compares_as_text(self):
        sql = read(FIX)
        # На проде messages.sender_id — text, auth.uid() — uuid: сравнение без ::text падает 42883.
        self.assertIn("if msg.sender_id::text is distinct from auth.uid()::text then", sql)
        self.assertNotRegex(sql, r"sender_id\s+is distinct from\s+auth\.uid\(\)\s+then")

    def test_fix_is_the_latest_definition_of_the_rpc(self):
        # Более поздняя миграция не должна вернуть старое сравнение.
        later = sorted(
            p for p in MIGRATIONS.glob("*.sql")
            if p.name > FIX.name and "x5_delete_message_for_all" in read(p)
        )
        for path in later:
            self.assertNotRegex(read(path), r"sender_id\s+is distinct from\s+auth\.uid\(\)\s+then", path.name)

    def test_only_signed_in_users_can_call_it(self):
        sql = read(FIX)
        self.assertIn("grant execute on function public.x5_delete_message_for_all(uuid) to authenticated;", sql)
        self.assertIn("revoke execute on function public.x5_delete_message_for_all(uuid) from anon;", sql)
        self.assertTrue(re.search(r"errcode = '42501'", sql))


if __name__ == "__main__":
    unittest.main()
