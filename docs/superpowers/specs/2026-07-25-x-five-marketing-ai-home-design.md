# Xfive marketing AI Home and Video Creation Design

## Goal

Turn the existing iOS Home tab into the working creative entry point for the
product. The product name shown to users is always **Xfive marketing**. “AI”
describes a section or a tool; it is not the application name.

The implementation must reuse the existing SwiftUI home shell, image generator,
credit infrastructure, Supabase project, chat and Hub tabs, and the licensed
provider SDK/API foundations already selected for this repository.

## Home information architecture

The first visible area contains:

1. A compact brand header with `Xfive marketing`.
2. A primary “Генерация изображений” hero that opens the existing working
   `ImageGeneratorView`.
3. Two real promo cards:
   - “Стартап чат” opens the AI startup assistant.
   - “Hub” switches to the existing Hub tab.
4. A tool grid below the promos. Video generation is the first video tool; image
   tools continue to use the existing image generator.
5. “Популярные пресеты” and “Тренды”. The “Живые фрукты” trend opens its own
   guided creation flow.

Only one video may actively play on Home at a time. Every other visual card uses
a poster until the user explicitly opens it.

## Startup Chat

Startup Chat is an authenticated AI assistant, not a human chat draft. It uses
the existing Supabase session and a server-side Edge Function so provider keys
never ship in the app. The first version keeps a short conversation in the
current screen and supports:

- business idea clarification;
- offer and audience suggestions;
- a concise action plan;
- safe retry and visible failure states.

## Shared video generation

All video entry points use one shared job model and one shared provider adapter.
The selected mature foundations are fal's asynchronous queue with Kling V3
Standard, Google's documented Gemini Omni Flash Interactions API, and OpenAI's
documented Videos API with Sora 2. fal is preferred when configured; Google is
next, and OpenAI is the final fallback only after a definitive pre-acceptance
Google 403/429 response. Ambiguous provider responses never start a second
provider request. The server owns every provider key.

The flow is:

1. The authenticated client submits a validated request with an idempotency key.
2. OpenAI `omni-moderation-latest` checks the text and optional selected start
   image. Rejected or unavailable checks do not reserve credits.
3. The backend atomically reserves the configured number of credits and creates
   one job.
4. The backend submits the provider request and stores the provider request ID.
5. The client polls the X5 job, never the provider directly.
6. A verified webhook or bounded server-side reconciliation updates the job.
7. A successful result is copied to private X5 storage and served by a signed
   URL. A terminal technical failure refunds the reserved credits exactly once.

No provider secret or service-role key is returned to the app.

## Live Fruits

Version 1 intentionally supports one main fruit and three scenes:

1. Questionnaire: fruit, character, purpose, location, main event, ending,
   style, and aspect ratio.
2. Scenario: the server returns strict structured data containing one title, one
   short story, one canonical character description, and exactly three scenes.
3. Storyboard: generate one canonical fruit image, then three scene images by
   reusing the current image-generation foundation and the same character
   reference.
4. Review: the user can edit scene text, reorder scenes, and regenerate an
   individual frame.
5. Final video: submit the approved three-scene storyboard to the shared video
   job. Version 1 is silent and targets a 9–10 second vertical result.

The recommended initial credit schedule is 60 credits for the character, 60 per
scene image, and 1,200 for the final video. Scenario creation is free. The
server remains the authority for prices.

## Moderation

Text and uploaded references pass basic automated safety checks before provider
submission. Explicit sexual content, sexual content involving minors, graphic
violence, and other disallowed content are rejected. Ordinary publishing does
not wait for a manual review queue.

## Course video upload reliability

Course lesson upload is independent from AI generation and does not use Bunny.
The app uploads directly to Supabase Storage using TUS.

The live project is on Supabase Free, whose global object limit is 50 MB. Build
189 attempted original files above that limit and the live storage logs show
HTTP 413 at `POST /upload/resumable`. Build 190 prepares oversized files below
the server boundary before creating the TUS upload.

The UI must clearly distinguish:

- preparing/compressing;
- uploading with progress;
- upload complete;
- a retryable network interruption;
- a server size rejection.

The editor may save only after every selected lesson video has a confirmed
remote URL.

## Verification and release

Each production change starts with a failing test. The release gate is:

- Swift unit tests on macOS CI;
- source and backend contract tests;
- successful archive and TestFlight upload;
- TestFlight build state `VALID`;
- assignment to the two approved internal groups;
- a live storage-log check for a build-191 upload attempt;
- a short client message listing the exact changes in that build.
