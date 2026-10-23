from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHAT = ROOT / "X5" / "Views" / "Chats" / "ChatThreadView.swift"
GROUPING = ROOT / "X5" / "Services" / "ChatAlbumGrouping.swift"
GROUPING_TESTS = ROOT / "X5Tests" / "ChatAlbumGroupingTests.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class ChatAlbum20261010SourceTests(unittest.TestCase):
    """Адильхан 10.10 19:16: «разом до 10 фоток, как ватсап, а то по одному»."""

    def test_chat_uses_uikit_gallery_with_ten_photos_and_videos(self):
        chat = read(CHAT)
        # SwiftUI-шная галерея после Face ID закрывалась/открывалась по кругу — в чате её нет.
        self.assertNotIn("PhotosPicker(", chat)
        self.assertNotIn("PhotosPickerItem", chat)
        self.assertNotIn("mediaItem", chat)
        self.assertIn(".x5PhotoPicker(\n            isPresented: $showingMediaPicker,", chat)
        self.assertIn("limit: ChatAlbumGrouping.pickLimit,", chat)
        self.assertIn("filter: .any(of: [.images, .videos])", chat)
        self.assertIn("static let pickLimit = 10", read(GROUPING))

    def test_batch_is_sent_one_by_one_and_failures_are_reported(self):
        chat = read(CHAT)
        sender = chat.split("private func sendPickedMedia(", 1)[1].split("private static func isVideo", 1)[0]
        self.assertIn("for (offset, provider) in batch.enumerated()", sender)
        self.assertIn("failure = await sendPickedVideo(provider)", sender)
        self.assertIn("failure = await sendPickedPhoto(provider)", sender)
        self.assertNotIn("withTaskGroup", sender)
        self.assertNotIn("async let", sender)
        self.assertIn("ChatMediaBatchProgress(current: offset + 1, total: batch.count)", sender)
        self.assertIn("Не отправилось \\(failures.count) из \\(batch.count)", sender)
        self.assertIn("Отправка \\(current) из \\(total)", read(GROUPING))
        self.assertIn("mediaBatchBanner", chat)

    def test_photo_is_loaded_from_provider_and_compressed_like_before(self):
        chat = read(CHAT)
        photo = chat.split("private func sendPickedPhoto(", 1)[1].split("private func sendPickedVideo(", 1)[0]
        self.assertIn("PickedPhotoLoader.loadMedia(from: provider)", photo)
        self.assertIn("jpegData(compressionQuality: 0.82)", photo)
        self.assertIn("Task.detached", photo)
        self.assertIn("deleteUploadedAttachment", photo)

    def test_video_goes_through_staged_file_and_resumable_upload(self):
        chat = read(CHAT)
        video = chat.split("private func sendPickedVideo(", 1)[1].split("private func chatVideoFormat(", 1)[0]
        self.assertIn("ChatPickedVideo.stage(from: provider)", video)
        self.assertIn("CourseVideoStaging.removeIfManaged(fileURL)", video)
        self.assertIn("service.uploadVideoAttachment(", video)
        self.assertIn('CourseVideoStaging.stage(sourceURL: url, lessonID: "chat")', chat)

    def test_feed_groups_photos_into_album_bubbles(self):
        chat = read(CHAT)
        self.assertIn("ForEach(ChatAlbumGrouping.group(visibleMessages)) { item in", chat)
        self.assertIn("album: item.isAlbum ? item.messages : nil,", chat)
        self.assertIn("PrivateChatAlbumBubble(messages: album", chat)
        self.assertIn('Text("+\\(extra)")', chat)
        self.assertIn(".fullScreenCover(item: $photoViewer)", chat)
        self.assertIn(".tabViewStyle(.page(indexDisplayMode: .never))", chat)
        # Закреп фото из середины альбома: крутим к строке альбома.
        self.assertIn("ChatAlbumGrouping.anchorID(for: id, in: ChatAlbumGrouping.group(visibleMessages))", chat)

    def test_grouping_rules_and_xctest_exist(self):
        grouping = read(GROUPING)
        self.assertIn("static let window: TimeInterval = 120", grouping)
        self.assertIn('message.type == "image"', grouping)
        self.assertIn("messages[end].senderId == first.senderId", grouping)
        tests = read(GROUPING_TESTS)
        self.assertIn("final class ChatAlbumGroupingTests: XCTestCase", tests)
        self.assertIn("testAlbumHoldsAtMostTenPhotos", tests)


if __name__ == "__main__":
    unittest.main()
