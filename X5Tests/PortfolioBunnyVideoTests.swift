import XCTest
@testable import X5

// Видео портфолио хранится в Bunny Stream (Диас 22.10), в базе — bunny-stream:<id>.
final class PortfolioBunnyVideoTests: XCTestCase {
    func testBunnyMediaURLRoundTrip() {
        let id = "092d3930-ef7e-412c-bacf-cba72fcf9fb8"
        let media = PortfolioMediaPolicy.bunnyMediaURL(videoID: id.uppercased())
        XCTAssertEqual(media, "bunny-stream:\(id)")
        XCTAssertEqual(PortfolioMediaPolicy.bunnyVideoID(fromMediaURL: media), id)
    }

    func testStorageAndJunkURLsAreNotBunny() {
        XCTAssertNil(PortfolioMediaPolicy.bunnyVideoID(fromMediaURL: "https://x.supabase.co/storage/v1/object/public/portfolio/u/a.mov"))
        XCTAssertNil(PortfolioMediaPolicy.bunnyVideoID(fromMediaURL: "bunny-stream:not-a-uuid"))
        XCTAssertNil(PortfolioMediaPolicy.bunnyVideoID(fromMediaURL: nil))
    }

    func testPlaybackPrefersMP4AndOnlyTrustsBunnyCDN() {
        let mp4 = PortfolioBunnyPlayback(hlsUrl: "https://vz-1.b-cdn.net/t/v/playlist.m3u8", mp4Url: "https://vz-1.b-cdn.net/t/v/play_720p.mp4")
        XCTAssertEqual(PortfolioMediaPolicy.bunnyPlaybackURL(from: mp4)?.lastPathComponent, "play_720p.mp4")
        let hlsOnly = PortfolioBunnyPlayback(hlsUrl: "https://vz-1.b-cdn.net/t/v/playlist.m3u8", mp4Url: nil)
        XCTAssertEqual(PortfolioMediaPolicy.bunnyPlaybackURL(from: hlsOnly)?.lastPathComponent, "playlist.m3u8")
        let foreign = PortfolioBunnyPlayback(hlsUrl: "https://evil.example/playlist.m3u8", mp4Url: "http://vz-1.b-cdn.net/a.mp4")
        XCTAssertNil(PortfolioMediaPolicy.bunnyPlaybackURL(from: foreign))
    }
}
