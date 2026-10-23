import XCTest
@testable import X5

final class HubTaskBrowseStateTests: XCTestCase {
    func testInitialStateShowsEveryTaskWithoutAFilter() {
        let state = HubTaskBrowseState()

        XCTAssertTrue(state.isShowingResults)
        XCTAssertEqual(state.selectedCategoryIds, [])
        XCTAssertTrue(state.includes(categoryId: "marketing"))
        XCTAssertTrue(state.includes(categoryId: "legal"))
    }

    func testAllResultsCanReturnToCategoryTiles() {
        var state = HubTaskBrowseState()

        state.showAllResults()
        XCTAssertTrue(state.isShowingResults)
        XCTAssertEqual(state.selectedCategoryIds, [])

        state.showCategories()
        XCTAssertFalse(state.isShowingResults)
        XCTAssertEqual(state.selectedCategoryIds, [])
    }

    func testCategoryResultsCanReturnToCategoryTiles() {
        var state = HubTaskBrowseState()

        state.showResults(for: "marketing")
        XCTAssertTrue(state.isShowingResults)
        XCTAssertEqual(state.selectedCategoryIds, ["marketing"])

        state.showCategories()
        XCTAssertFalse(state.isShowingResults)
        XCTAssertEqual(state.selectedCategoryIds, [])
    }

    func testSeveralCategoryFiltersCanBeCombinedAndToggled() {
        var state = HubTaskBrowseState()

        state.showResults(for: "marketing")
        state.toggleResults(for: "ugc")
        state.toggleResults(for: "design")

        XCTAssertEqual(state.selectedCategoryIds, ["marketing", "ugc", "design"])
        XCTAssertTrue(state.includes(categoryId: "ugc"))
        XCTAssertFalse(state.includes(categoryId: "seo"))

        state.toggleResults(for: "marketing")
        XCTAssertEqual(state.selectedCategoryIds, ["ugc", "design"])
    }

    func testNoSelectedCategoryMeansAllTasksMatch() {
        var state = HubTaskBrowseState()

        state.showAllResults()

        XCTAssertTrue(state.includes(categoryId: "marketing"))
        XCTAssertTrue(state.includes(categoryId: "ugc"))
    }

    func testCategoryFilterAppliesEveryManuallySelectedCategory() {
        var state = HubTaskBrowseState()

        state.applyCategoryFilter(["marketing", "ugc", "design"])

        XCTAssertTrue(state.isShowingResults)
        XCTAssertEqual(state.selectedCategoryIds, ["marketing", "ugc", "design"])
        XCTAssertTrue(state.includes(categoryId: "marketing"))
        XCTAssertTrue(state.includes(categoryId: "ugc"))
        XCTAssertFalse(state.includes(categoryId: "seo"))
    }

    func testCategoryFilterWithoutASelectionKeepsDefaultFeed() {
        var state = HubTaskBrowseState()

        state.applyCategoryFilter([])

        XCTAssertTrue(state.isShowingResults)
        XCTAssertEqual(state.selectedCategoryIds, [])
    }

    func testProfileCategoryFilterUsesEverySavedCategoryAndNormalizesAliases() {
        var state = HubTaskBrowseState()

        state.showResults(forProfileCategories: [
            " Marketing ",
            "target ads",
            "UI/UX",
            "unknown-category"
        ])

        XCTAssertTrue(state.isShowingResults)
        XCTAssertEqual(state.selectedCategoryIds, ["marketing", "targeting", "ui_ux"])
        XCTAssertTrue(state.includes(categoryId: "marketing"))
        XCTAssertTrue(state.includes(categoryId: "targeting"))
        XCTAssertTrue(state.includes(categoryId: "ui_ux"))
        XCTAssertFalse(state.includes(categoryId: "seo"))
    }

    func testProfileCategoryFilterStaysOnGridWhenProfileHasNoKnownCategories() {
        for categories in [nil, [], ["", "unknown-category"]] as [[String]?] {
            var state = HubTaskBrowseState()

            let didApply = state.showResults(forProfileCategories: categories)

            XCTAssertFalse(didApply)
            XCTAssertFalse(state.isShowingResults)
            XCTAssertEqual(state.selectedCategoryIds, [])
        }
    }

    func testProfileCategoriesApplyAutomaticallyOnFirstHubEntry() {
        var state = HubTaskBrowseState()

        XCTAssertTrue(state.applyProfileCategoriesOnEntry(["Marketing", "UI/UX"]))
        XCTAssertEqual(state.selectedCategoryIds, [])
        XCTAssertEqual(state.preferredCategoryIds, ["marketing", "ui_ux"])
        XCTAssertTrue(state.includes(categoryId: "seo"))
        XCTAssertFalse(state.hasManualOverride)
    }

    func testDelayedProfileCanApplyAfterInitialEmptyValue() {
        var state = HubTaskBrowseState()

        XCTAssertFalse(state.applyProfileCategoriesOnEntry(nil))
        XCTAssertTrue(state.applyProfileCategoriesOnEntry(["SEO"]))
        XCTAssertEqual(state.selectedCategoryIds, [])
        XCTAssertEqual(state.preferredCategoryIds, ["seo"])
    }

    func testManualChoiceBeforeProfileLoadIsPreserved() {
        var state = HubTaskBrowseState()

        state.showResults(for: "ugc")
        XCTAssertFalse(state.applyProfileCategoriesOnEntry(["marketing"]))
        XCTAssertEqual(state.selectedCategoryIds, ["ugc"])
    }

    func testManualChoiceAfterAutomaticFilterIsPreservedOnProfileRefresh() {
        var state = HubTaskBrowseState()

        XCTAssertTrue(state.applyProfileCategoriesOnEntry(["marketing"]))
        state.showAllResults()
        XCTAssertFalse(state.applyProfileCategoriesOnEntry(["seo"]))
        XCTAssertEqual(state.selectedCategoryIds, [])
        XCTAssertEqual(state.preferredCategoryIds, ["marketing"])
        XCTAssertTrue(state.hasManualOverride)
    }

    func testProfileCategoryNormalizationReturnsOnlyKnownHubCategoryIds() {
        XCTAssertEqual(
            HubCategories.normalizedIDs(from: ["SMM specialist", "web development", "Game Dev"]),
            ["smm", "web_dev", "gamedev"]
        )
        XCTAssertEqual(HubCategories.normalizedIDs(from: ["unknown", "  "]), [])
    }

    func testProfessionOrderStartsWithMarketingAndIsSharedByHub() {
        let expectedStart = ["marketing", "smm", "targeting", "context_ads", "ugc", "sales", "copy", "seo"]

        XCTAssertEqual(Array(HubCategories.all.prefix(expectedStart.count)).map(\.id), expectedStart)
        XCTAssertEqual(HubCategories.hubDisplayOrder, HubCategories.all)
    }

    func testSMMAndMobileContentShareOneProfession() {
        XCTAssertEqual(
            HubCategories.label(for: "smm", language: .ru),
            "SMM Мобилография"
        )
        XCTAssertEqual(HubCategories.all.filter { $0.id == "smm" }.count, 1)
    }

    func testMobileDevelopmentUsesTheFullProfessionName() {
        XCTAssertEqual(
            HubCategories.label(for: "mobile_dev", language: .ru),
            "Мобильная разработка"
        )
    }

    func testRequestedProfessionsAreAvailableAndCrossedOutOnesAreAbsent() {
        let available = Set(HubCategories.all.map(\.id))
        let requested = Set([
            "context_ads", "videographer", "camera_operator", "journalist", "correspondent",
            "operator", "producer", "director", "actor_film", "actor_ads",
            "actor_music_video", "accountant"
        ])
        let crossedOut = Set(["administrator", "artist", "manager", "editor", "screenwriter"])

        XCTAssertTrue(requested.isSubset(of: available))
        XCTAssertTrue(crossedOut.isDisjoint(with: available))
    }

    func testEveryHubProfessionHasItsOwnIcon() {
        let symbols = HubCategories.all.map { HubCategories.symbol(for: $0.id) }

        XCTAssertEqual(symbols.count, Set(symbols).count)
        XCTAssertFalse(symbols.contains("questionmark.circle.fill"))
        XCTAssertEqual(HubCategories.symbol(for: "operator"), "slider.horizontal.3")
        XCTAssertEqual(HubCategories.symbol(for: "producer"), "person.3.fill")
        XCTAssertNotEqual(
            HubCategories.symbol(for: "operator"),
            HubCategories.symbol(for: "producer")
        )
    }

    func testSavedProfileCategoriesFollowCanonicalProfessionOrder() {
        XCTAssertEqual(
            HubCategories.orderedIDs(from: ["design", "ugc", "marketing", "seo"]),
            ["marketing", "ugc", "seo", "design"]
        )
    }
}
