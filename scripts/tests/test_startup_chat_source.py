from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "X5" / "Services" / "StartupChatService.swift"
VIEW = ROOT / "X5" / "Views" / "Home" / "StartupChatView.swift"
EDGE = ROOT / "supabase" / "functions" / "startup-chat" / "index.ts"
PROVIDER = ROOT / "supabase" / "functions" / "startup-chat" / "provider.mjs"
MIGRATIONS = ROOT / "supabase" / "migrations"


class StartupChatSourceTests(unittest.TestCase):
    def test_native_service_calls_only_the_x5_edge_function(self):
        source = SERVICE.read_text(encoding="utf-8")

        self.assertIn("functions/v1/startup-chat", source)
        self.assertIn("X5Config.supabaseBaseURL", source)
        self.assertIn("X5Config.supabaseAnonKey", source)
        self.assertIn("maxTotalCharacters = 12_000", source)
        self.assertIn("normalizeForTransport", source)
        self.assertIn("normalizeUserMessage", source)
        self.assertIn("request_id", source)
        self.assertIn("request.timeoutInterval = 55", source)
        self.assertNotIn("OPENAI_API_KEY", source)
        self.assertNotIn("api.openai.com", source)

    def test_client_maps_all_non_retryable_conversation_contract_errors(self):
        source = SERVICE.read_text(encoding="utf-8")

        for code in (
            "conversation_too_long",
            "too_many_messages",
            "message_too_long",
            "invalid_role",
            "message_empty",
            "invalid_message",
        ):
            self.assertIn(f'"{code}"', source)

    def test_native_screen_is_a_real_russian_chat_with_local_history(self):
        source = VIEW.read_text(encoding="utf-8")

        self.assertIn('navigationTitle("Стартап чат")', source)
        self.assertIn("StartupChatService", source)
        self.assertIn("messages.append", source)
        self.assertIn("auth.freshAccessToken()", source)
        self.assertIn("Xfive marketing", source)
        self.assertIn("Отправить", source)
        self.assertIn("errorCanRetry", source)
        self.assertIn("serviceError != .invalidConversation", source)
        self.assertIn("StartupChatPendingRequestStore", source)
        self.assertIn("pendingStore.clear", source)
        self.assertNotIn("Скоро добавим", source)

    def test_native_screen_enforces_retry_cooldown_and_countdown(self):
        source = VIEW.read_text(encoding="utf-8")

        self.assertIn("@State private var retryAvailableAt: Date?", source)
        self.assertIn("TimelineView(.periodic", source)
        self.assertIn("retryAfterSeconds", source)
        self.assertIn("Date().addingTimeInterval", source)
        self.assertIn("retryAvailableAt <= now", source)
        self.assertIn("Повторить можно через", source)
        retry_guard = re.search(
            r"private func retry\(\) \{(?P<body>.*?)\n    \}",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(retry_guard)
        self.assertIn("canRetry", retry_guard.group("body"))

    def test_cooldown_disables_the_entire_composer_and_resigns_editing(self):
        source = VIEW.read_text(encoding="utf-8")
        composer = re.search(
            r"private func composerContent\(now: Date\).*?"
            r"\n    private func errorBanner",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(composer)
        self.assertIn(".disabled(!canRetry(at: now))", composer.group(0))
        self.assertRegex(
            source,
            r"if let retryAfter = serviceError\?\.retryAfterSeconds "
            r"\{[\s\S]*?draftFocused = false",
        )

    def test_assistant_reply_is_normalized_before_display(self):
        source = VIEW.read_text(encoding="utf-8")
        service = SERVICE.read_text(encoding="utf-8")

        self.assertIn("normalizeAssistantReply(result.reply)", source)
        self.assertIn("content: displayedReply", source)
        self.assertIn("static func normalizeAssistantReply", service)
        self.assertIn(
            "prefixUTF16(clean, limit: maxMessageCharacters)",
            service,
        )

    def test_native_screen_owns_and_invalidates_each_send_lifecycle(self):
        source = VIEW.read_text(encoding="utf-8")

        self.assertIn(
            "@State private var sendTask: Task<Void, Never>?",
            source,
        )
        self.assertIn("@State private var sendGeneration = UUID()", source)
        self.assertIn(".onDisappear", source)
        self.assertIn(".onChange(of: auth.userId)", source)
        self.assertIn("sendTask?.cancel()", source)
        self.assertIn("Task.checkCancellation()", source)
        self.assertIn("isSendCurrent(", source)
        send_history = re.search(
            r"private func sendHistory\(\) \{(?P<body>.*?)"
            r"\n    private func retryCountdownText",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(send_history)
        self.assertRegex(
            send_history.group("body"),
            r"await auth\.freshAccessToken\(\)[\s\S]*?"
            r"Task\.checkCancellation\(\)[\s\S]*?"
            r"isSendCurrent\([\s\S]*?"
            r"await service\.send\([\s\S]*?"
            r"Task\.checkCancellation\(\)[\s\S]*?"
            r"isSendCurrent\([\s\S]*?"
            r"pendingStore\.clear\(",
        )
        self.assertRegex(
            source,
            r"pendingStore\.clear\(\s*"
            r"userID:\s*userID,\s*"
            r"requestID:\s*requestID\s*"
            r"\)",
        )

    def test_pending_request_clear_is_compare_and_clear(self):
        source = SERVICE.read_text(encoding="utf-8")

        clear = re.search(
            r"func clear\(\s*"
            r"userID: String,\s*"
            r"requestID: UUID\s*"
            r"\) \{(?P<body>.*?)\n    \}",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(clear)
        self.assertIn("existing.requestID == requestID", clear.group("body"))
        self.assertIn("removeObject", clear.group("body"))

    def test_edge_function_keeps_openai_credentials_server_side(self):
        source = EDGE.read_text(encoding="utf-8")
        provider = PROVIDER.read_text(encoding="utf-8")

        self.assertIn('Deno.env.get("OPENAI_API_KEY")', source)
        self.assertIn("createOpenAIStartupChatProvider", source)
        self.assertIn("https://api.openai.com/v1/moderations", provider)
        self.assertIn("https://api.openai.com/v1/responses", provider)
        self.assertIn("verifyUser", source)
        self.assertIn("safeError", source)
        self.assertNotIn("providerPayload?.error?.message", source)

    def test_edge_moderates_inside_the_owned_lease_and_never_charges_credits(self):
        source = EDGE.read_text(encoding="utf-8")
        provider = PROVIDER.read_text(encoding="utf-8")

        self.assertLess(
            source.index("claim_startup_chat_request"),
            source.index("await generateReply"),
        )
        self.assertLess(
            provider.index("OPENAI_MODERATIONS_URL"),
            provider.index("OPENAI_RESPONSES_URL"),
        )
        self.assertIn('"Idempotency-Key": requestID', provider)
        self.assertNotRegex(
            source,
            r"claim_generation_credits|deduct_credits|generation_credits",
        )

    def test_private_startup_chat_idempotency_migration_exists(self):
        migrations = list(MIGRATIONS.glob("*_startup_chat_idempotency.sql"))
        self.assertEqual(len(migrations), 1)
        source = migrations[0].read_text(encoding="utf-8")
        self.assertIn("claim_startup_chat_request", source)
        self.assertIn("complete_startup_chat_request", source)
        self.assertIn("auth.uid()", source)
        self.assertIn("p_lease_token uuid", source)
        self.assertIn("lease_token = v_lease_token", source)
        self.assertIn("set status = 'retryable'", source)
        release = re.search(
            r"create or replace function "
            r"public\.release_startup_chat_request.*?\$function\$;",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(release)
        self.assertNotIn(
            "delete from public.startup_chat_requests",
            release.group(0),
        )


if __name__ == "__main__":
    unittest.main()
