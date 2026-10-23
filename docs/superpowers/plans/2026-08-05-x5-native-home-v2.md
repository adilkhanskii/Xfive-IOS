# X5 Native Home V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the native five-tab iOS navigation and rebuild Home as a compact, adaptive SwiftUI screen matching the approved visual direction with real video previews.

**Architecture:** Keep the existing routes, services, `HomeRoute`, and `LoopingVideo` implementation. Replace only custom tab-bar presentation and Home presentation components. Content artwork remains isolated in asset catalogs while all labels, controls, chrome, and layout remain native SwiftUI.

**Tech Stack:** Swift 5, SwiftUI, AVFoundation/AVKit through existing `LoopingVideo`, XCTest/Python source-contract tests, Xcode Simulator.

---

### Task 1: Lock the native tab-bar contract

**Files:**
- Modify: `scripts/tests/test_xfive_marketing_home_source.py`
- Modify: `X5/Views/AppTabView.swift`

- [ ] **Step 1: Replace the custom-tab regression assertion with a native-tab assertion**

Assert five `.tabItem` calls and `.tint(X5Style.blue)`. Assert that `X5BottomTabBar`, `.toolbar(.hidden, for: .tabBar)`, `.safeAreaInset(edge: .bottom`, and `itemCenters` are absent.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `python3 -m unittest scripts.tests.test_xfive_marketing_home_source.XFiveMarketingHomeSourceTests.test_system_tab_bar_is_native_and_never_replaced`

Expected: FAIL because the current source still contains `X5BottomTabBar` and hidden tab-bar modifiers.

- [ ] **Step 3: Restore native `TabView` presentation**

Keep `X5AppTab`, five tagged screens, selection diagnostics, notification switching, and deep links. Remove all system-tab hiding and the custom bar. Add `.tint(X5Style.blue)` to the root `TabView`.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command. Expected: one passing test.

### Task 2: Lock compact Home proportions and real video behavior

**Files:**
- Modify: `scripts/tests/test_xfive_marketing_home_source.py`
- Modify: `scripts/tests/test_home_motion_source.py`
- Modify: `X5/Views/Home/HomeView.swift`

- [ ] **Step 1: Add failing source contracts**

Require `HomeLayout.heroHeight`, `HomeLayout.promoHeight`, `HomeLayout.trendCardSize`, native `Button` promo cards, horizontal Trends scrolling, four X5-owned video filenames, one-active-video state, and absence of raster mockup/crop types.

- [ ] **Step 2: Run both focused test modules and verify RED**

Run: `python3 -m unittest scripts.tests.test_xfive_marketing_home_source scripts.tests.test_home_motion_source`

Expected: FAIL on the new compact layout constants and system-tab contract.

- [ ] **Step 3: Refactor Home presentation without changing routes**

Add a small private `HomeLayout` namespace for adaptive, reviewable dimensions. Tighten vertical spacing, reduce promo cards from 130 pt to approximately 88 pt, keep the hero compact, shrink trend cards to the reference proportions, brighten the background slightly, and restyle business cards with the approved violet direction. Preserve `HomeRoute`, Search, Gallery, generated-image navigation, startup chat, Hub switching, video generator, voice generator, and Live Fruits routing.

- [ ] **Step 4: Run both focused modules and verify GREEN**

Run the Step 2 command. Expected: all Home source and motion tests pass.

### Task 3: Replace rejected content artwork

**Files:**
- Replace content image files inside `X5/Assets.xcassets/HomeCover*.imageset/`
- Replace content image files inside `X5/Assets.xcassets/HomeUtility*.imageset/`
- Replace content image files inside `X5/Assets.xcassets/HomeTrend*.imageset/` only where the image is not a client-specific poster
- Modify: `docs/home-media-provenance.md`

- [ ] **Step 1: Generate separate content-only artwork**

Use one built-in image-generation call per asset. Match the violet/black premium direction and the subject of each tool. Prohibit text, UI controls, card frames, navigation, logos, and watermarks.

- [ ] **Step 2: Inspect every generated output**

Reject outputs with text, fake buttons, multi-card collages, malformed subjects, or inconsistent style. Keep the original asset filenames so existing code and project generation remain stable.

- [ ] **Step 3: Copy selected outputs into their existing image sets**

Record generator, date, prompt role, asset path, and commercial-use provenance in `docs/home-media-provenance.md`.

- [ ] **Step 4: Run asset and source tests**

Run: `python3 -m unittest scripts.tests.test_xfive_marketing_home_source scripts.tests.test_home_motion_source`

Expected: all tests pass and no mockup crop names appear in runtime Home source.

### Task 4: Build and simulator verification

**Files:**
- Generated local project: `X5.xcodeproj`
- Output screenshots: `artifacts/home-v2/`

- [ ] **Step 1: Generate or copy the local Xcode project from audited `project.yml`**

Use the repository-pinned XcodeGen flow when available. If the local binary is unavailable, copy the already generated `X5.xcodeproj` from the clean parent checkout because it is derived from the same unchanged `project.yml`.

- [ ] **Step 2: Run the full relevant test suite and simulator build**

Run all `scripts/tests/test_*home*` modules, relevant X5 tests, then `xcodebuild` for an available iPhone Simulator. Expected: exit 0, zero failed tests.

- [ ] **Step 3: Launch on compact and large iPhones**

Install and launch the Debug app on one compact and one large simulator. Capture Home screenshots under `artifacts/home-v2/`.

- [ ] **Step 4: Verify interactions**

Exercise five tabs, Search, Gallery, hero action, both promo buttons, one trend preview, More, and representative business cards. Confirm that only one trend video plays and navigation remains responsive.

- [ ] **Step 5: Review against the reference**

Check hierarchy, purple lighting, compact controls, text legibility, safe areas, and standard system tab bar. Do not upload TestFlight until the user approves the fresh screenshots.

## Self-review

- Spec coverage: navigation, compact controls, native composition, video previews, generated art, adaptive sizing, routes, tests, screenshots, and release boundary are all mapped to tasks.
- Placeholder scan: no TBD/TODO or unspecified implementation steps remain.
- Type consistency: the plan preserves existing `HomeRoute`, `X5AppTab`, `NativeHome*`, and `LoopingVideo` names and introduces only `HomeLayout`.
