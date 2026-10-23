# App Store Connect audit for X5 1.1.1 build 143

## Current known ASC state

- App: X5 Creators
- Bundle ID: com.x5studio.app
- Primary locale: en-US
- Current local version/build: 1.1.1 / 143
- Last accepted App Store version: 1.1.0 / build 69
- Current 1.1.1 ASC card from the last read-only inspection: DEVELOPER_REJECTED with build 143 attached
- Latest accidental review submission was cancelled by the account owner before this cleanup
- Do not submit again until metadata, privacy, screenshots and review notes are rechecked

## Positioning rule

Do not position X5 as an AI app or AI creator studio. X5 should be described as a creator workspace / marketplace. Image generation is a secondary tool and should be mentioned only once in customer-facing metadata.

## What changed versus the accepted build

- Home is now a creator tools screen, not only a marketplace entry screen.
- Image generation is live for prompts and optional reference images.
- Generated images can be previewed, edited, shared, saved to Photos and stored in the local Generated Gallery.
- Generation uses a credit balance and shows cost before generation.
- Hub supports specialists, tasks, proposals and starting chats.
- Chats support text, photo attachments, voice messages, search, replies, pin, mute, archive, report and block.
- Portfolio supports photo/video items, likes, comments, pinned work and profile display.
- CourseUP supports course browsing, lesson playback and Pro-gated access.
- Profile includes onboarding, roles, public profile, social links, verified badge, Pro status and settings.
- Settings include language, Face ID app lock, notifications, cache, subscription management, sign out and account deletion.

## Apple Connect items that must be checked before upload

- App Information: name, subtitle, categories, age rating, support URL, marketing URL and privacy URL.
- App Privacy: Photos, User Content, Contact Info, User ID, Purchase History and Diagnostics must match current app behavior.
- Version 1.1.1 metadata: subtitle, promotional text, description, keywords and What's New must match build 143.
- Review Information: demo account, image generation, credits, subscriptions, UGC safety, report/block and account deletion.
- Screenshots: must be replaced; old marketplace-only screenshots are not enough for build 143.
- IAP: X5 Pro Monthly must be ready and have a review screenshot. Verified badge is credit-based in this build.
- TestFlight: build 143 must remain processed and valid before attaching/submitting.

## Required screenshot set

Use fresh build 143 screenshots only:

1. Login or onboarding.
2. Home creator tools screen.
3. Image generator with prompt/reference images/model/size/credits visible.
4. Generated result viewer or Generated Gallery.
5. Hub specialists/tasks.
6. Chat thread with message controls.
7. Portfolio/Profile.
8. CourseUP course/lesson.
9. X5 Pro paywall with subscription terms.

## Hard rule before App Store submit

Upload metadata/screenshots only after fresh ASC read-only inspection. Submit for review only after the owner confirms the final Apple Connect card in the browser or via a fresh ASC inspection log.
