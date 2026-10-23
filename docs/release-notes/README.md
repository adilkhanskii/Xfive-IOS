# Release-note localizations

App Store Connect currently supports English and Russian metadata, but not a
Kazakh (`kk`) metadata locale. Uploadable notes therefore live under
`fastlane/metadata/en-US` and `fastlane/metadata/ru`. Kazakh client-facing copy
is preserved here by version/build instead of placing an unsupported locale in
the Fastlane upload tree.

Reference:
https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/
