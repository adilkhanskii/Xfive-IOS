# X5 Home demo on iPhone

This branch contains a temporary, Debug-only client preview for the real
SwiftUI Home screen.

## Verified media mapping

| X5 surface | Demo media | Verified purpose |
| --- | --- | --- |
| Image-generation hero | Higgsfield Seedream 5.0 Pro landing clip | Image generation |
| AI Video cards | Higgsfield AI Video Generator landing clip | Text/image-to-video |
| Voice Studio hero | Higgsfield Create Audio landing clip | Voiceovers and voice change |
| Live Fruits | Existing licensed Pexels fruit clip | Fruit/product motion |

The unrelated Higgsfield Supercomputer, Academy, After Effects, and App Contest
clips are not referenced by the iOS app.

## Demo boundary

- The external demo clips are streamed and are not committed as media files.
- Debug builds enable the client preview by default.
- Set the Xcode scheme environment variable `X5_HOME_DEMO_MODE=0` to use only
  the licensed bundled X5 motion clips while debugging.
- Release builds always disable the Higgsfield references, regardless of the
  environment variable.

## Run on an iPhone from the MacBook

1. Fetch the handoff branch from GitHub and switch to it.
2. Install XcodeGen if needed: `brew install xcodegen`.
3. Run `xcodegen generate` in the repository root.
4. Open `X5.xcodeproj`.
5. Select the connected iPhone and run the `X5` scheme in Debug.

The demo requires an internet connection because the temporary review media is
streamed from the source landing pages.
