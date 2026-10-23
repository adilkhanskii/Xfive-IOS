# X5 Native Home V2 Design

## Scope

Rebuild only the authenticated iOS Home surface and restore the five-tab system navigation. Existing authentication, backend services, CourseUP, Chats, Hub, Profile, deep links, generation tools, and App Store state remain unchanged.

## Source of truth

The client-approved 740 x 1600 reference at `/Users/tooyakov/Documents/Codex/2026-08-01/new-chat/outputs/x5-approved-target.png` defines the compact hierarchy, spacing, purple visual direction, and card proportions. It is a visual reference only. The app must not render that screenshot, crop it into UI pieces, or bake labels, controls, or navigation into raster assets.

## Navigation

Use SwiftUI `TabView` with five native `.tabItem` labels: Главная, CourseUP, Чаты, Hub, Профиль. Keep existing selection feedback, notification-driven tab switching, and deep-link routing. Remove `X5BottomTabBar`, manual geometry, hidden system tab-bar modifiers, and the 44 pt custom safe-area inset. Apply the project accent color with `.tint(X5Style.blue)`.

## Home layout

- Slightly lighter dark navy background with restrained violet and blue glow.
- Compact navigation title plus native Search and Gallery toolbar buttons.
- Native paged hero with content-only art, native eyebrow/title/subtitle/action button, native page dots, and a height close to the approved reference.
- Two equal white promo buttons below the hero. Each is a native `Button`, approximately 88 pt high, with compact icon, text, subtitle, chevron, and a minimum 44 pt touch target.
- Horizontally scrollable Trends rail with four portrait cards. Each card has native labels and a separate native preview control. Only one inline `AVPlayer` preview may play at once.
- Business design section with a wide Instagram card followed by compact two-column cards and one wide product card. Text, arrows, buttons, card chrome, and navigation remain SwiftUI.

## Media

Reuse the four existing X5-owned Supabase video exports (`transitions.mp4`, `lipsync.mp4`, `ai-stylist.mp4`, `face-swap.mp4`) as temporary functional previews. The two previously supplied Instagram links are not present as durable source files in the repository. They may replace the fallbacks only after the client supplies the exact URLs/files and confirms redistribution and likeness rights.

Current business and hero rasters were rejected visually. Replace them with new content-only generated artwork in a consistent premium violet/black direction. Generated assets must contain no UI, text, buttons, logos, watermarks, or navigation. Record each generated file and its role in `docs/home-media-provenance.md`.

## Adaptive and accessible behavior

Use flexible widths, Dynamic Type-aware fonts, minimum 44 pt controls, safe areas, and ordinary vertical/horizontal scrolling. Verify at least one compact iPhone and one large iPhone simulator. Reduce Motion and Low Power Mode disable inline motion without disabling navigation.

## Acceptance criteria

1. System tab bar is visible and all five tabs remain functional.
2. No custom bottom bar or manual tab geometry exists in source.
3. The Home screenshot/crops are not used in runtime Home source.
4. Hero, promos, Trends, business cards, Search, Gallery, and More are native controls with existing routes.
5. Trend preview plays actual video and enforces one active player.
6. Relevant tests and simulator build pass.
7. Fresh compact and large iPhone screenshots are visually reviewed before any TestFlight upload.
8. TestFlight, production, and App Store Review are unchanged in this task.
