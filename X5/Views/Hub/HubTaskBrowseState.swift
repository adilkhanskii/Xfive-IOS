struct HubTaskBrowseState: Equatable {
    enum Page: Equatable {
        case categories
        case results(categoryIds: Set<String>)
    }

    // Open tasks are the primary Tasks-tab content. Categories remain an
    // optional discovery/filter surface, but never hide the feed on entry.
    private(set) var page: Page = .results(categoryIds: [])
    private(set) var hasManualOverride = false
    private(set) var preferredCategoryIds: Set<String> = []
    private var didApplyProfileCategoriesOnEntry = false

    var isShowingResults: Bool {
        if case .results = page { return true }
        return false
    }

    var selectedCategoryIds: Set<String> {
        guard case let .results(categoryIds) = page else { return [] }
        return categoryIds
    }

    mutating func showAllResults() {
        hasManualOverride = true
        page = .results(categoryIds: [])
    }

    mutating func showResults(for categoryId: String) {
        hasManualOverride = true
        page = .results(categoryIds: [categoryId])
    }

    @discardableResult
    mutating func showResults(forProfileCategories categories: [String]?) -> Bool {
        hasManualOverride = true
        return setProfileCategories(categories)
    }

    /// Records the signed-in specialist's saved categories once when Hub is
    /// entered. They can prioritize matching tasks, but do not become a filter:
    /// only an explicit user action is allowed to hide other open tasks.
    @discardableResult
    mutating func applyProfileCategoriesOnEntry(_ categories: [String]?) -> Bool {
        guard !hasManualOverride, !didApplyProfileCategoriesOnEntry else { return false }
        let categoryIds = HubCategories.normalizedIDs(from: categories)
        guard !categoryIds.isEmpty else { return false }
        preferredCategoryIds = categoryIds
        didApplyProfileCategoriesOnEntry = true
        return true
    }

    private mutating func setProfileCategories(_ categories: [String]?) -> Bool {
        let categoryIds = HubCategories.normalizedIDs(from: categories)
        guard !categoryIds.isEmpty else {
            page = .categories
            return false
        }
        page = .results(categoryIds: categoryIds)
        return true
    }

    mutating func applyCategoryFilter(_ categoryIds: Set<String>) {
        guard !categoryIds.isEmpty else { return }
        hasManualOverride = true
        page = .results(categoryIds: categoryIds)
    }

    mutating func toggleResults(for categoryId: String) {
        hasManualOverride = true
        var categoryIds = selectedCategoryIds
        if categoryIds.contains(categoryId) {
            categoryIds.remove(categoryId)
        } else {
            categoryIds.insert(categoryId)
        }
        page = .results(categoryIds: categoryIds)
    }

    func includes(categoryId: String) -> Bool {
        selectedCategoryIds.isEmpty || selectedCategoryIds.contains(categoryId)
    }

    mutating func showCategories() {
        hasManualOverride = true
        page = .categories
    }
}
