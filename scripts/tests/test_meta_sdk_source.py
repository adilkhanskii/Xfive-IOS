"""Meta (Facebook) SDK wiring for iOS 14+ ads (AEM + SKAdNetwork), 2026-11-02."""
from pathlib import Path
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
META_SKAN_IDS = {"v9wttpbfk9.skadnetwork", "n38lu8286q.skadnetwork"}


class MetaSDKSourceTests(unittest.TestCase):
    def test_info_plist_has_meta_keys_skadnetwork_and_att_text(self):
        with (ROOT / "X5" / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        self.assertEqual(info["FacebookAppID"], "$(FACEBOOK_APP_ID)")
        self.assertEqual(info["FacebookClientToken"], "$(FACEBOOK_CLIENT_TOKEN)")
        self.assertTrue(info["FacebookAutoLogAppEventsEnabled"])
        self.assertTrue(info["NSUserTrackingUsageDescription"].strip())
        ids = [item["SKAdNetworkIdentifier"] for item in info["SKAdNetworkItems"]]
        self.assertEqual(len(ids), len(set(ids)), "duplicate SKAdNetwork ids")
        self.assertTrue(META_SKAN_IDS.issubset(ids))
        schemes = [s for t in info["CFBundleURLTypes"] for s in t["CFBundleURLSchemes"]]
        self.assertIn("fb$(FACEBOOK_APP_ID)", schemes)

    def test_project_yml_matches_plist_and_pins_the_sdk(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("url: https://github.com/facebook/facebook-ios-sdk", project)
        self.assertIn('revision: "80d0ee82f6370d1bace1431a80cb80575f98ee90"', project)
        self.assertIn("product: FacebookCore", project)
        self.assertIn("FacebookAppID: $(FACEBOOK_APP_ID)", project)
        self.assertIn("FacebookClientToken: $(FACEBOOK_CLIENT_TOKEN)", project)
        for skan in META_SKAN_IDS:
            self.assertIn(f"SKAdNetworkIdentifier: {skan}", project)

    def test_client_token_is_never_committed(self):
        # The token comes only from the CI secret; committed values stay empty.
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn('FACEBOOK_CLIENT_TOKEN: ""', project)
        xcconfig = (ROOT / "Release.xcconfig").read_text(encoding="utf-8")
        self.assertRegex(xcconfig, r"(?m)^FACEBOOK_CLIENT_TOKEN =\s*$")
        workflow = (ROOT / ".github" / "workflows" / "ios-build.yml").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn("FACEBOOK_CLIENT_TOKEN: ${{ secrets.FACEBOOK_CLIENT_TOKEN }}", workflow)
        self.assertIn("FACEBOOK_CLIENT_TOKEN = ${FACEBOOK_CLIENT_TOKEN}", workflow)

    def test_att_strings_are_localized(self):
        for language in ("en", "ru", "kk"):
            source = (ROOT / "X5" / f"{language}.lproj" / "InfoPlist.strings").read_text(
                encoding="utf-8"
            )
            self.assertRegex(source, r'"NSUserTrackingUsageDescription" = ".+";')

    def test_sdk_is_gated_and_events_are_wired(self):
        meta = (ROOT / "X5" / "Services" / "MetaAnalytics.swift").read_text(encoding="utf-8")
        self.assertIn("guard isConfigured, !started", meta)
        self.assertIn("ATTrackingManager.requestTrackingAuthorization()", meta)
        self.assertIn(".completedRegistration", meta)
        self.assertIn("logPurchase(amount:", meta)

        delegate = (ROOT / "X5" / "Services" / "PushNotifications.swift").read_text(encoding="utf-8")
        self.assertIn("MetaAnalytics.start(application, launchOptions: launchOptions)", delegate)

        iap = (ROOT / "X5" / "Services" / "IAPService.swift").read_text(encoding="utf-8")
        purchase = iap[iap.index("func purchase(productID: String)"):iap.index("func restore()")]
        self.assertRegex(
            purchase,
            re.compile(r"if applyResult\.isPurchaseSuccess \{\s*//[^\n]*\n\s*MetaAnalytics\.logPurchase"),
        )

        # Отказ Apple 5.1.2(i) 04.11: ATT — на первом экране при первом запуске,
        # SDK стартует только после ответа, пуши ждут ATT.
        app = (ROOT / "X5" / "X5App.swift").read_text(encoding="utf-8")
        self.assertIn(".task { await MetaAnalytics.requestTrackingOnLaunch() }", app)
        content = (ROOT / "X5" / "ContentView.swift").read_text(encoding="utf-8")
        self.assertNotIn("requestTracking", content, "single ATT entry point")
        self.assertIn("await MetaAnalytics.waitForTrackingPrompt()", delegate)
        start = meta[meta.index("static func start("):meta.index("private static func startSDK(")]
        self.assertIn("trackingAuthorizationStatus == .notDetermined", start)
        self.assertIn("pendingLaunchOptions = launchOptions", start)
        prompt = meta[meta.index("static func requestTrackingOnLaunch()"):meta.index("static func waitForTrackingPrompt()")]
        self.assertIn("applicationState != .active", prompt)
        self.assertLess(
            prompt.index("requestTrackingAuthorization()"),
            prompt.index("startSDK("),
            "SDK starts only after the ATT answer",
        )


if __name__ == "__main__":
    unittest.main()
