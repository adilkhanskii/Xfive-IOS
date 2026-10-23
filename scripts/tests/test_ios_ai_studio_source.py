from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class IOSAIStudioSourceTests(unittest.TestCase):
    def test_hub_exposes_real_server_gated_tools(self):
        source = (ROOT / "X5/Views/Home/AIStudioHubView.swift").read_text(
            encoding="utf-8"
        )
        for value in (
            "Генерация изображений",
            "Редактор изображения",
            "Карточки товаров",
            "Обложки YouTube",
            "Логотип PNG",
            "Контент-пак",
            "Moodboard",
            "Озвучка MiniMax",
            "Video Studio",
            "Cinema Studio",
            "VFX",
            "AI-инфлюенсер",
            "Lipsync",
            "Presets",
            "Облачная галерея",
            "Живые продукты",
        ):
            self.assertIn(value, source)
        self.assertIn("service.capabilities(accessToken: token)", source)
        self.assertIn("ForEach(tools)", source)
        self.assertIn('Text("ВСЕ AI-ИНСТРУМЕНТЫ")', source)
        self.assertNotIn("tools.filter { toolState($0).available }", source)
        self.assertNotIn(".disabled(!state.available)", source)
        self.assertIn("при временном сбое запуск блокируется без списания кредитов", source)
        self.assertNotIn('Text("В разработке")', source)

    def test_influencer_is_a_confirmed_four_stage_pipeline(self):
        source = (ROOT / "X5/Views/Home/AIInfluencerView.swift").read_text(
            encoding="utf-8"
        )
        for value in (
            'sectionTitle("1 · ПЕРСОНАЖ")',
            'sectionTitle("2 · ИЗОБРАЖЕНИЕ")',
            'sectionTitle("3 · ГОЛОС")',
            'sectionTitle("4 · ВИДЕО")',
            'Toggle("У меня есть права на это изображение"',
            'Picker("Формат", selection: $imageFormat)',
            'Picker("Качество", selection: $imageQuality)',
            "approveCharacterImage",
            "approveCharacterVoice",
            "startInfluencer",
        ):
            self.assertIn(value, source)

    def test_lipsync_accepts_cloud_or_user_media_and_minimax_text(self):
        source = (ROOT / "X5/Views/Home/LipsyncView.swift").read_text(
            encoding="utf-8"
        )
        for value in (
            'uploadButton(title: "Загрузить MP4"',
            'uploadButton(title: "Загрузить MP3, WAV или M4A"',
            "voiceService.generate(",
            "service.startLipsync(",
            "service.uploadAsset(",
        ):
            self.assertIn(value, source)

    def test_private_ai_schema_and_provider_disclosure_exist(self):
        migration = (
            ROOT / "supabase/migrations/20260825110000_ai_studio_core.sql"
        ).read_text(encoding="utf-8")
        privacy = (ROOT / "site/privacy.html").read_text(encoding="utf-8")
        for table in (
            "generated_assets",
            "ai_characters",
            "ai_influencer_jobs",
            "lipsync_generation_jobs",
            "user_ai_presets",
            "ai_provider_health",
        ):
            self.assertIn(table, migration)
        self.assertIn("fal.ai Sync Lipsync", privacy)
        self.assertIn("MiniMax Speech", privacy)
        self.assertIn("BytePlus ModelArk Seedance", privacy)


if __name__ == "__main__":
    unittest.main()
