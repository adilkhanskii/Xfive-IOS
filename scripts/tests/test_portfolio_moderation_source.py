from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
EDGE_FUNCTION = ROOT / "supabase" / "functions" / "moderate-portfolio" / "index.ts"
DECISION_MODULE = (
    ROOT / "supabase" / "functions" / "moderate-portfolio" / "decision.mjs"
)
MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260724123000_portfolio_automatic_moderation_queue.sql"
)
CAS_HARDENING_MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260724134000_harden_portfolio_moderation_cas.sql"
)
AUTOMATIC_ONLY_MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260726193000_portfolio_automatic_only_moderation.sql"
)
PENDING_DEFAULT_MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260728121500_portfolio_default_pending.sql"
)
PORTFOLIO_SERVICE = ROOT / "X5" / "Services" / "PortfolioService.swift"
PORTFOLIO_VIEW = ROOT / "X5" / "Views" / "PortfolioView.swift"
SETTINGS_VIEW = ROOT / "X5" / "Views" / "SettingsView.swift"


class PortfolioModerationSourceTests(unittest.TestCase):
    def test_edge_function_has_no_developer_approval_or_manual_review_path(self):
        source = EDGE_FUNCTION.read_text(encoding="utf-8")

        self.assertIn('type ModerationAction = "moderate" | "retry";', source)
        self.assertNotIn('"approve"', source)
        self.assertNotIn('"reject"', source)
        self.assertNotIn("developerDecision", source)
        self.assertNotIn('.rpc("is_x5_developer")', source)
        self.assertNotIn("manual_review", source)

    def test_edge_function_auto_approves_safe_content_rejects_forbidden_and_retries_failures(self):
        source = (
            EDGE_FUNCTION.read_text(encoding="utf-8")
            + DECISION_MODULE.read_text(encoding="utf-8")
        )

        self.assertIn('status: "approved"', source)
        self.assertIn('status: "rejected"', source)
        self.assertIn("automaticPendingDecision", source)
        self.assertIn('status: "pending"', source)
        self.assertNotIn('reason: "video_requires_developer_review"', source)
        self.assertIn('reason: "moderation_response_invalid"', source)
        self.assertNotIn("Ручная проверка", source)

    def test_video_uses_generated_thumbnail_and_text_in_existing_moderation(self):
        source = EDGE_FUNCTION.read_text(encoding="utf-8")
        image_lookup = source.index(
            "const imageUrl = await signedImageURLFor(admin, item)"
        )
        video_guard = source.index('if (item.type === "video" && !imageUrl)')
        provider_call = source.index("fetch(OPENAI_MODERATION_URL")

        self.assertLess(image_lookup, video_guard)
        self.assertLess(video_guard, provider_call)
        self.assertIn('.from("portfolio")', source)
        self.assertIn(".createSignedUrl(path, 300)", source)
        self.assertIn(
            'result: { reason: "video_preview_missing" }', source
        )
        self.assertIn('if (text) input.push({ type: "text", text })', source)
        self.assertIn(
            'if (imageUrl) input.push({ type: "image_url", image_url: { url: imageUrl } })',
            source,
        )
        self.assertIn("automaticPendingDecision", source)

    def test_edge_function_uses_revision_compare_and_swap(self):
        source = EDGE_FUNCTION.read_text(encoding="utf-8")
        hardening = CAS_HARDENING_MIGRATION.read_text(encoding="utf-8")

        self.assertIn("moderation_revision?: number;", source)
        self.assertIn("moderation_revision: number;", source)
        self.assertIn("if (!Number.isSafeInteger(revision)", source)
        claim = source.index('"x5_claim_portfolio_moderation_job"')
        complete = source.index('"x5_complete_portfolio_moderation_job"')
        readback = source.index(
            '.eq("moderation_revision", claim.item.moderation_revision)'
        )
        self.assertLess(claim, complete)
        self.assertLess(complete, readback)
        self.assertIn("p_moderation_revision: revision", source)
        self.assertIn("p_owner_id: userData.user.id", source)
        self.assertIn("p_job_id: claim.job_id", source)
        self.assertGreaterEqual(source.count("p_lease_token: leaseToken"), 3)
        self.assertIn('["stale_item", "completed", "already_completed", "exhausted", "superseded"]', source)
        self.assertIn("return json({ error: status }, 409)", source)
        self.assertIn(
            "new.moderation_revision := old.moderation_revision + 1", hardening
        )

    def test_rejected_media_is_removed_from_public_portfolio_storage(self):
        source = EDGE_FUNCTION.read_text(encoding="utf-8")

        self.assertIn('decision.status === "rejected"', source)
        self.assertIn('.storage.from("portfolio")', source)
        self.assertIn(".remove(paths)", source)
        self.assertIn("item.media_url", source)
        self.assertIn("item.thumbnail_url", source)
        self.assertIn("portfolioObjectPath(value, item.user_id)", source)
        self.assertIn("segments[0] !== expectedOwnerId", source)
        self.assertIn("resolvedPaths.some((value) => value == null)", source)
        self.assertIn("parsed.username || parsed.password", source)
        self.assertIn("parsed.search || parsed.hash", source)
        self.assertIn("const marker = markers.find", source)
        self.assertIn("parsed.pathname.startsWith(candidate)", source)
        self.assertIn("if (!marker) return null", source)
        self.assertIn('segment === "." || segment === ".."', source)

    def test_unapproved_queue_never_loads_untrusted_media_urls(self):
        edge = EDGE_FUNCTION.read_text(encoding="utf-8")

        self.assertIn("hasInvalidPortfolioMediaURL(item)", edge)
        self.assertIn("portfolioObjectPath(value, item.user_id)", edge)

    def test_new_moderation_sources_do_not_contain_mojibake(self):
        sources = [
            EDGE_FUNCTION,
            DECISION_MODULE,
            PORTFOLIO_SERVICE,
            PORTFOLIO_VIEW,
        ]
        signatures = ("РќР", "РћР", "РџС", "Р”Р", "Р‘Р", "вЂ")

        for path in sources:
            source = path.read_text(encoding="utf-8")
            for signature in signatures:
                self.assertNotIn(signature, source, f"{path.name}: {signature}")

    def test_video_thumbnail_is_uploaded_before_moderation(self):
        service = PORTFOLIO_SERVICE.read_text(encoding="utf-8")
        view = PORTFOLIO_VIEW.read_text(encoding="utf-8")

        self.assertIn("thumbnailData: Data?", service)
        self.assertIn("thumbnailURL = await uploadPortfolioMedia", service)
        self.assertLess(
            service.index("thumbnailURL = await uploadPortfolioMedia"),
            service.index("let moderated = await moderate"),
        )
        self.assertIn("import AVFoundation", view)
        self.assertIn("@State private var videoThumbnailData: Data?", view)
        self.assertIn("makeVideoThumbnail", view)
        self.assertIn("let thumbnail = await makeVideoThumbnail", view)
        self.assertIn("videoThumbnailData = thumbnail", view)
        self.assertIn("thumbnailData: thumbnailData", view)
        self.assertIn("videoThumbnailData,", view)
        self.assertIn("@State private var preparingMedia = false", view)
        self.assertIn(".disabled(saving || preparingMedia || mediaData == nil || coverPick.loading)", view)
        self.assertIn("let thumbnailFractions:", view)
        self.assertGreaterEqual(view.count("generator.copyCGImage"), 1)

    def test_video_thumbnail_is_a_multi_frame_contact_sheet(self):
        view = PORTFOLIO_VIEW.read_text(encoding="utf-8")

        self.assertIn("var frames: [UIImage] = []", view)
        self.assertIn("frames.append(UIImage(cgImage: cgImage))", view)
        self.assertIn("makeVideoContactSheet(from: frames)", view)
        self.assertIn(
            "nonisolated private static func makeVideoContactSheet", view
        )
        self.assertIn("UIGraphicsImageRenderer", view)

    def test_approved_storage_objects_are_immutable_and_moderation_is_revision_bound(self):
        service = PORTFOLIO_SERVICE.read_text(encoding="utf-8")
        edge = EDGE_FUNCTION.read_text(encoding="utf-8")
        migration = MIGRATION.read_text(encoding="utf-8")

        self.assertNotIn('upload.setValue("true", forHTTPHeaderField: "x-upsert")', service)
        self.assertIn('upload.setValue("false", forHTTPHeaderField: "x-upsert")', service)
        self.assertIn("moderation_revision bigint not null default 1", migration)
        self.assertIn("new.moderation_revision := old.moderation_revision + 1", migration)
        self.assertIn("moderation_revision: number", edge)
        self.assertIn('"x5_claim_portfolio_moderation_job"', edge)
        self.assertIn("p_moderation_revision: revision", edge)
        self.assertIn('"x5_complete_portfolio_moderation_job"', edge)
        self.assertIn(
            '.eq("moderation_revision", claim.item.moderation_revision)', edge
        )
        self.assertIn("return json({ error: status }, 409)", edge)

    def test_developer_manual_queue_is_not_reachable(self):
        settings = SETTINGS_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("PortfolioModerationQueueView()", settings)
        self.assertNotIn("Проверка портфолио", settings)
        self.assertFalse(
            (ROOT / "X5" / "Views" / "PortfolioModerationQueueView.swift").exists()
        )
        self.assertFalse(
            (
                ROOT
                / "X5"
                / "Services"
                / "PortfolioModerationQueueService.swift"
            ).exists()
        )

    def test_pending_items_retry_automatic_moderation_without_manual_ui(self):
        service = PORTFOLIO_SERVICE.read_text(encoding="utf-8")

        self.assertIn("retryAutomaticModeration", service)
        self.assertIn('action: "retry"', service)
        self.assertIn('moderationStatusRaw = "pending"', service)
        self.assertNotIn("Ручная проверка", service)
        self.assertNotIn("Ожидает ручную проверку", service)

    def test_database_removes_developer_queue_and_normalizes_old_manual_statuses(self):
        source = MIGRATION.read_text(encoding="utf-8")
        automatic_only = AUTOMATIC_ONLY_MIGRATION.read_text(encoding="utf-8")

        self.assertIn("moderation_revision bigint not null default 1", source)
        self.assertIn("old.moderation_revision + 1", source)
        self.assertIn("owner_id = (select auth.uid())::text", source)
        self.assertIn("storage.foldername(name)", source)
        self.assertIn(
            'drop policy if exists "portfolio_auth_insert" on storage.objects',
            source,
        )
        self.assertIn(
            'drop policy if exists "portfolio_auth_update" on storage.objects',
            source,
        )
        self.assertIn(
            'drop policy if exists "portfolio_auth_delete" on storage.objects',
            source,
        )

        update_policy = source.split(
            'create policy "x5 storage authenticated update"', 1
        )[1].split(";", 1)[0]
        delete_policy = source.split(
            'create policy "x5 storage authenticated delete own"', 1
        )[1].split(";", 1)[0]
        self.assertNotIn("'portfolio'", update_policy)
        self.assertNotIn("'portfolio'", delete_policy)
        self.assertIn(
            "where moderation_status in ('manual_review', 'failed')",
            automatic_only,
        )
        self.assertIn(
            "set_config('request.jwt.claim.role', 'service_role', true)",
            automatic_only,
        )
        self.assertIn("set moderation_status = 'pending'", automatic_only)
        self.assertNotIn("public.is_x5_developer()", automatic_only)
        public_policy = automatic_only.split(
            'create policy "portfolio public read"', 1
        )[1].split(";", 1)[0]
        self.assertNotIn("is_x5_developer", public_policy)
        self.assertNotIn("manual_review", public_policy)

    def test_portfolio_uploads_are_immutable_and_media_prep_is_race_safe(self):
        service = PORTFOLIO_SERVICE.read_text(encoding="utf-8")
        view = PORTFOLIO_VIEW.read_text(encoding="utf-8")

        self.assertIn('upload.setValue("false", forHTTPHeaderField: "x-upsert")', service)
        self.assertIn("@State private var preparingMedia", view)
        self.assertIn("@State private var mediaPreparationGeneration", view)
        self.assertIn(
            ".disabled(saving || preparingMedia || mediaData == nil || coverPick.loading)", view
        )
        self.assertIn(
            "guard generation == mediaPreparationGeneration else { return }", view
        )

        load_media = view.split("private func loadMedia", 1)[1]
        self.assertLess(
            load_media.index("let thumbnail = await makeVideoThumbnail"),
            load_media.index("mediaData = data"),
        )
        source = MIGRATION.read_text(encoding="utf-8")
        self.assertIn(
            'drop policy if exists "x5 storage authenticated write"', source
        )
        self.assertIn(
            "bucket_id = any (array['chat-media', 'avatars'])", source
        )
        self.assertIn("owner_id = (select auth.uid())::text", source)

    def test_video_preview_samples_twelve_points_across_the_video(self):
        view = PORTFOLIO_VIEW.read_text(encoding="utf-8")

        self.assertIn("let thumbnailSampleCount = 12", view)
        self.assertIn("0..<thumbnailSampleCount", view)
        self.assertIn("columns = 4", view)

    def test_portfolio_rows_default_to_pending(self):
        migration = PENDING_DEFAULT_MIGRATION.read_text(encoding="utf-8")
        normalized = " ".join(migration.lower().split())

        self.assertIn(
            "alter column moderation_status set default 'pending'",
            normalized,
        )

    def test_pending_or_rejected_media_cannot_be_shared(self):
        view = PORTFOLIO_VIEW.read_text(encoding="utf-8")

        # 09.10: старый неиспользуемый PortfolioPostViewer удалён — остался один
        # экран поста, и «Поделиться» в нём по-прежнему только для approved.
        action_row = view.split("private var actionRow", 1)[1].split("private var captionBlock", 1)[0]
        gate = action_row.index('if item.moderationStatus == "approved" {')
        self.assertLess(gate, action_row.index("await prepareShare()"))

    def test_owner_sees_badge_only_while_moderation_is_pending_or_rejected(self):
        # 09.10 (Адильхан): зелёная плашка «Автопроверка пройдена» лишняя —
        # плашку видно, только пока кейс ждёт проверку или отклонён.
        service = PORTFOLIO_SERVICE.read_text(encoding="utf-8")
        view = PORTFOLIO_VIEW.read_text(encoding="utf-8")

        self.assertIn('default: return "Автопроверка пройдена"', service)
        self.assertNotIn("if canEdit || item.needsModerationBadge", view)
        caption = view.split("private var captionBlock", 1)[1].split("private var commentsView", 1)[0]
        self.assertIn("if item.needsModerationBadge {", caption)
        self.assertIn("PortfolioModerationBadge(item: item)", caption)

    def test_post_has_no_fake_video_editor_and_working_social_actions(self):
        # 09.10: «Монтаж видео» нигде не был реализован — убран. Лайки и
        # комментарии ходят в те же таблицы, что сайт (portfolio_likes /
        # portfolio_comments): portfolio_item_* в проде не существует.
        service = PORTFOLIO_SERVICE.read_text(encoding="utf-8")
        view = PORTFOLIO_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("showVideoEditorNotice", view)
        self.assertNotIn("Открыть монтаж видео", view)
        self.assertNotIn('Label("Монтаж видео"', view)
        self.assertNotIn("localLikedComments", view)
        self.assertNotIn("rest/v1/portfolio_item_likes", service)
        self.assertNotIn("rest/v1/portfolio_item_comments", service)
        self.assertIn('appendingPathComponent("rest/v1/portfolio_likes")', service)
        self.assertIn('appendingPathComponent("rest/v1/portfolio_comments")', service)
        self.assertIn('case itemId = "portfolio_id"', service)
        self.assertNotIn("userName: auth.userEmail", view)
        self.assertIn("commentFieldFocused = true", view)
        self.assertNotIn('ShareLink(item: item.displayMediaUrl', view)
        self.assertIn("URLSession.shared.download(from: remoteURL)", view)

    def test_video_tiles_show_one_play_icon_and_a_cover(self):
        view = PORTFOLIO_VIEW.read_text(encoding="utf-8")
        service = PORTFOLIO_SERVICE.read_text(encoding="utf-8")
        cell = view.split("private struct PortfolioGridCell", 1)[1].split("private var imageURLString", 1)[0]

        self.assertEqual(cell.count('Image(systemName: "play'), 1)
        self.assertIn("PortfolioVideoTileCover(item: item)", cell)
        self.assertIn('static let videoCoverSuffix = "-cover.jpg"', service)
        self.assertIn("thumbnailHasCover: thumbnailHasCover", view)
        self.assertIn("PortfolioVideoCover.compose(cover:", view)


if __name__ == "__main__":
    unittest.main()
