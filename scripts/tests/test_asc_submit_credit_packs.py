import importlib.util
import pathlib
import sys
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "asc_submit_credit_packs.py"
SPEC = importlib.util.spec_from_file_location("asc_submit_credit_packs", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPT.parent))
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class CreditPackSubmissionTests(unittest.TestCase):
    def test_release_is_locked_to_build_238(self):
        self.assertEqual(MODULE.TARGET_VERSION, "1.1.8")
        self.assertEqual(MODULE.TARGET_BUILD, "238")

    def test_iap_version_payload_targets_parent_purchase(self):
        payload = MODULE.iap_version_payload("iap-1")
        self.assertEqual(
            payload["data"]["relationships"]["inAppPurchase"]["data"],
            {"type": "inAppPurchases", "id": "iap-1"},
        )

    def test_review_item_can_attach_iap_version(self):
        payload = MODULE.review_item_payload(
            "submission-1",
            "inAppPurchaseVersion",
            "inAppPurchaseVersions",
            "version-1",
        )
        relationships = payload["data"]["relationships"]
        self.assertEqual(
            relationships["reviewSubmission"]["data"]["id"],
            "submission-1",
        )
        self.assertEqual(
            relationships["inAppPurchaseVersion"]["data"],
            {"type": "inAppPurchaseVersions", "id": "version-1"},
        )

    def test_combined_submission_targets_ios_app(self):
        payload = MODULE.review_submission_payload("app-1")
        self.assertEqual(payload["data"]["attributes"]["platform"], "IOS")
        self.assertEqual(
            payload["data"]["relationships"]["app"]["data"],
            {"type": "apps", "id": "app-1"},
        )

    def test_developer_rejected_iap_version_is_reused(self):
        rejected = {
            "id": "version-1",
            "attributes": {"state": "DEVELOPER_REJECTED"},
        }

        class FakeAPI:
            def list_all(self, path):
                return [rejected]

            def request(self, *args, **kwargs):
                raise AssertionError("must not create a duplicate version")

        self.assertEqual(
            MODULE.ensure_iap_version(FakeAPI(), "iap-1"),
            rejected,
        )

    def test_single_ready_submission_is_reused(self):
        ready = {
            "id": "submission-1",
            "attributes": {"state": "READY_FOR_REVIEW"},
        }
        complete = {
            "id": "submission-2",
            "attributes": {"state": "COMPLETE"},
        }
        self.assertEqual(
            MODULE.single_ready_submission([complete, ready]),
            ready,
        )

    def test_multiple_ready_submissions_fail_closed(self):
        rows = [
            {"id": "one", "attributes": {"state": "READY_FOR_REVIEW"}},
            {"id": "two", "attributes": {"state": "READY_FOR_REVIEW"}},
        ]
        with self.assertRaisesRegex(RuntimeError, "More than one"):
            MODULE.single_ready_submission(rows)

    def test_submit_only_from_ready_to_submit(self):
        self.assertTrue(
            MODULE.should_submit("READY_TO_SUBMIT", action="submit")
        )
        for state in ("APPROVED", "WAITING_FOR_REVIEW", "IN_REVIEW"):
            with self.subTest(state=state):
                self.assertFalse(
                    MODULE.should_submit(state, action="submit")
                )

    def test_audit_never_mutates(self):
        self.assertFalse(
            MODULE.should_submit("MISSING_METADATA", action="audit")
        )

    def test_unsafe_submit_state_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "MISSING_METADATA"):
            MODULE.should_submit("MISSING_METADATA", action="submit")

    def test_exact_combined_review_targets_are_extracted(self):
        payload = {
            "included": [
                {
                    "id": "item-app",
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {
                                "type": "appStoreVersions",
                                "id": "version-1",
                            }
                        }
                    },
                },
                *[
                    {
                        "id": f"item-iap-{index}",
                        "type": "reviewSubmissionItems",
                        "relationships": {
                            "inAppPurchaseVersion": {
                                "data": {
                                    "type": "inAppPurchaseVersions",
                                    "id": f"iap-version-{index}",
                                }
                            }
                        },
                    }
                    for index in range(1, 4)
                ],
            ]
        }

        self.assertEqual(
            MODULE.review_item_targets(payload),
            {
                ("appStoreVersions", "version-1"),
                ("inAppPurchaseVersions", "iap-version-1"),
                ("inAppPurchaseVersions", "iap-version-2"),
                ("inAppPurchaseVersions", "iap-version-3"),
            },
        )

    def test_combined_review_submits_only_after_exactly_four_targets(self):
        class FakeAPI:
            def __init__(self):
                self.targets = set()
                self.submitted = False

            def request(self, method, path, expected=(200,), payload=None):
                if method == "GET" and "?filter[app]=" in path:
                    return {
                        "data": [
                            {
                                "id": "submission-1",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                            }
                        ]
                    }
                if method == "GET" and "/items?limit=50&include=" in path:
                    included = []
                    for index, (resource_type, resource_id) in enumerate(
                        sorted(self.targets)
                    ):
                        relationship = (
                            "appStoreVersion"
                            if resource_type == "appStoreVersions"
                            else "inAppPurchaseVersion"
                        )
                        included.append(
                            {
                                "id": f"item-{index}",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    relationship: {
                                        "data": {
                                            "type": resource_type,
                                            "id": resource_id,
                                        }
                                    }
                                },
                            }
                        )
                    return {"included": included}
                if method == "POST" and path == "/v1/reviewSubmissionItems":
                    relationships = payload["data"]["relationships"]
                    relationship = next(
                        name
                        for name in (
                            "appStoreVersion",
                            "inAppPurchaseVersion",
                        )
                        if name in relationships
                    )
                    target = relationships[relationship]["data"]
                    self.targets.add((target["type"], target["id"]))
                    return {"data": {"id": f"item-{len(self.targets)}"}}
                if method == "PATCH":
                    self.submitted = True
                    self.assert_exact_targets()
                    return {
                        "data": {
                            "id": "submission-1",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                raise AssertionError(f"Unexpected request {method} {path}")

            def assert_exact_targets(self):
                expected = {
                    ("appStoreVersions", "version-1"),
                    ("inAppPurchaseVersions", "iap-1"),
                    ("inAppPurchaseVersions", "iap-2"),
                    ("inAppPurchaseVersions", "iap-3"),
                }
                if self.targets != expected:
                    raise AssertionError(
                        f"submitted with wrong targets {self.targets}"
                    )

        api = FakeAPI()
        submission_id = MODULE.create_combined_review(
            api,
            "app-1",
            "version-1",
            [{"id": "iap-1"}, {"id": "iap-2"}, {"id": "iap-3"}],
        )
        self.assertEqual(submission_id, "submission-1")
        self.assertTrue(api.submitted)
        api.assert_exact_targets()

    def test_review_can_submit_app_without_already_reviewed_iaps(self):
        class FakeAPI:
            def __init__(self):
                self.targets = set()
                self.submitted = False

            def request(self, method, path, expected=(200,), payload=None):
                if method == "GET" and "?filter[app]=" in path:
                    return {"data": []}
                if method == "POST" and path == "/v1/reviewSubmissions":
                    return {
                        "data": {
                            "id": "submission-app-only",
                            "attributes": {"state": "READY_FOR_REVIEW"},
                        }
                    }
                if method == "GET" and "/items?limit=50&include=" in path:
                    included = []
                    for index, (resource_type, resource_id) in enumerate(
                        sorted(self.targets)
                    ):
                        included.append(
                            {
                                "id": f"item-{index}",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {
                                            "type": resource_type,
                                            "id": resource_id,
                                        }
                                    }
                                },
                            }
                        )
                    return {"included": included}
                if method == "GET" and path.endswith("/items?limit=50"):
                    return {"data": []}
                if method == "POST" and path == "/v1/reviewSubmissionItems":
                    target = payload["data"]["relationships"][
                        "appStoreVersion"
                    ]["data"]
                    self.targets.add((target["type"], target["id"]))
                    return {"data": {"id": "item-app"}}
                if method == "PATCH":
                    self.submitted = True
                    self.assert_app_only()
                    return {
                        "data": {
                            "id": "submission-app-only",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                raise AssertionError(f"Unexpected request {method} {path}")

            def assert_app_only(self):
                if self.targets != {("appStoreVersions", "version-1")}:
                    raise AssertionError(
                        f"submitted with wrong targets {self.targets}"
                    )

        api = FakeAPI()
        submission_id = MODULE.create_combined_review(
            api,
            "app-1",
            "version-1",
            [],
        )

        self.assertEqual(submission_id, "submission-app-only")
        self.assertTrue(api.submitted)
        api.assert_app_only()

    def test_existing_opaque_app_only_item_is_reused_without_duplicate(self):
        class FakeAPI:
            def __init__(self):
                self.submitted = False

            def request(self, method, path, expected=(200,), payload=None):
                if method == "GET" and "?filter[app]=" in path:
                    return {
                        "data": [
                            {
                                "id": "submission-ready",
                                "attributes": {
                                    "state": "READY_FOR_REVIEW"
                                },
                            }
                        ]
                    }
                if method == "GET" and "/items?limit=50&include=" in path:
                    return {"included": []}
                if method == "GET" and path.endswith("/items?limit=50"):
                    return {
                        "data": [
                            {
                                "type": "reviewSubmissionItems",
                                "id": "opaque-item-ref",
                                "attributes": {
                                    "state": "READY_FOR_REVIEW"
                                },
                            }
                        ]
                    }
                if method == "POST":
                    raise AssertionError(
                        "must not create a duplicate app review item"
                    )
                if method == "PATCH":
                    self.submitted = True
                    self.assert_submit_payload(payload)
                    return {
                        "data": {
                            "id": "submission-ready",
                            "attributes": {
                                "state": "WAITING_FOR_REVIEW"
                            },
                        }
                    }
                raise AssertionError(f"Unexpected request {method} {path}")

            def assert_submit_payload(self, payload):
                if payload["data"]["attributes"] != {"submitted": True}:
                    raise AssertionError(f"wrong submit payload {payload}")
                if "relationships" in payload["data"]:
                    raise AssertionError("review relationship is not allowed on PATCH")

        api = FakeAPI()
        submission_id = MODULE.create_combined_review(
            api,
            "app-1",
            "version-1",
            [],
        )

        self.assertEqual(submission_id, "submission-ready")
        self.assertTrue(api.submitted)

    def test_rejected_app_item_is_resolved_and_existing_review_is_resubmitted(self):
        class FakeAPI:
            def __init__(self):
                self.item_state = "REJECTED"
                self.verified_empty = False
                self.submitted = False

            def unresolved_items(self):
                return {
                    "data": [
                        {
                            "type": "reviewSubmissionItems",
                            "id": "item-app-rejected",
                            "attributes": {"state": self.item_state},
                            "relationships": {
                                "appStoreVersion": {
                                    "data": {
                                        "type": "appStoreVersions",
                                        "id": "version-1",
                                    }
                                }
                            },
                        }
                    ]
                }

            def request(self, method, path, expected=(200,), payload=None):
                if method == "GET" and "?filter[app]=" in path:
                    return {
                        "data": [
                            {
                                "id": "submission-empty",
                                "attributes": {
                                    "state": "READY_FOR_REVIEW"
                                },
                            },
                            {
                                "id": "submission-rejected",
                                "attributes": {
                                    "state": "UNRESOLVED_ISSUES"
                                },
                            },
                        ]
                    }
                if (
                    method == "GET"
                    and "/submission-rejected/items?" in path
                ):
                    return self.unresolved_items()
                if method == "GET" and "/submission-empty/items?" in path:
                    self.verified_empty = True
                    return {"data": []}
                if method == "PATCH" and path.endswith(
                    "/item-app-rejected"
                ):
                    self.item_state = "READY_FOR_REVIEW"
                    self.assert_resolve_payload(payload)
                    return {
                        "data": {
                            "id": "item-app-rejected",
                            "attributes": {"state": self.item_state},
                        }
                    }
                if method == "PATCH" and path.endswith(
                    "/submission-rejected"
                ):
                    self.submitted = True
                    self.assert_submit_payload(payload)
                    return {
                        "data": {
                            "id": "submission-rejected",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                if method == "POST":
                    raise AssertionError(
                        "must resolve the existing rejected review"
                    )
                raise AssertionError(f"Unexpected request {method} {path}")

            def assert_resolve_payload(self, payload):
                self.assert_attributes(payload, {"resolved": True})

            def assert_submit_payload(self, payload):
                self.assert_attributes(payload, {"submitted": True})

            @staticmethod
            def assert_attributes(payload, expected):
                if payload["data"]["attributes"] != expected:
                    raise AssertionError(f"wrong payload {payload}")

        api = FakeAPI()
        submission_id = MODULE.create_combined_review(
            api,
            "app-1",
            "version-1",
            [],
        )

        self.assertEqual(submission_id, "submission-rejected")
        self.assertTrue(api.verified_empty)
        self.assertEqual(api.item_state, "READY_FOR_REVIEW")
        self.assertTrue(api.submitted)

    def test_app_only_opaque_item_count_fails_closed(self):
        class FakeAPI:
            def request(self, method, path, **kwargs):
                return {
                    "data": [
                        {
                            "type": "reviewSubmissionItems",
                            "id": "item-1",
                            "attributes": {"state": "READY_FOR_REVIEW"},
                        },
                        {
                            "type": "reviewSubmissionItems",
                            "id": "item-2",
                            "attributes": {"state": "READY_FOR_REVIEW"},
                        },
                    ]
                }

        with self.assertRaisesRegex(RuntimeError, "at most one item"):
            MODULE.app_only_item_readback(
                FakeAPI(),
                "submission-ready",
            )

    def test_all_reviewed_iaps_still_submit_the_app_version(self):
        class FakeAPI:
            def request(self, method, path, **kwargs):
                if path.startswith("/v1/apps?filter[bundleId]="):
                    return {"data": [{"id": "app-1"}]}
                raise AssertionError(f"Unexpected request {method} {path}")

            def list_all(self, path):
                if path == "/v1/apps/app-1/inAppPurchasesV2?limit=200":
                    return [
                        {
                            "id": f"purchase-{index}",
                            "attributes": {
                                "productId": pack.product_id,
                                "inAppPurchaseType": "CONSUMABLE",
                                "state": "APPROVED",
                            },
                        }
                        for index, pack in enumerate(MODULE.CREDIT_PACKS)
                    ]
                if path.startswith("/v2/inAppPurchases/"):
                    return []
                raise AssertionError(f"Unexpected list {path}")

        target_version = {"id": "version-1"}
        with (
            mock.patch.object(MODULE, "AppStoreConnect", return_value=FakeAPI()),
            mock.patch.object(
                MODULE,
                "app_version",
                return_value=target_version,
            ) as find_version,
            mock.patch.object(MODULE, "verify_target_build") as verify_build,
            mock.patch.object(
                MODULE,
                "cancel_waiting_app_review",
            ) as cancel_review,
            mock.patch.object(
                MODULE,
                "create_combined_review",
                return_value="submission-app-only",
            ) as create_review,
        ):
            MODULE.run("submit")

        find_version.assert_called_once_with(mock.ANY, "app-1")
        verify_build.assert_called_once_with(mock.ANY, "version-1")
        cancel_review.assert_called_once_with(
            mock.ANY,
            "app-1",
            "version-1",
        )
        create_review.assert_called_once_with(
            mock.ANY,
            "app-1",
            "version-1",
            [],
        )

    def test_ready_submission_waits_for_eventual_exact_target_readback(self):
        expected_targets = {
            ("appStoreVersions", "version-1"),
            ("inAppPurchaseVersions", "iap-1"),
            ("inAppPurchaseVersions", "iap-2"),
            ("inAppPurchaseVersions", "iap-3"),
        }

        class FakeAPI:
            def __init__(self):
                self.target_readbacks = [
                    expected_targets,
                    set(),
                    expected_targets,
                ]
                self.submitted = False

            def request(self, method, path, expected=(200,), payload=None):
                if method == "GET" and "?filter[app]=" in path:
                    return {
                        "data": [
                            {
                                "id": "submission-ready",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                            }
                        ]
                    }
                if method == "GET" and "/items?limit=50&include=" in path:
                    targets = self.target_readbacks.pop(0)
                    included = []
                    for index, (resource_type, resource_id) in enumerate(
                        sorted(targets)
                    ):
                        relationship = (
                            "appStoreVersion"
                            if resource_type == "appStoreVersions"
                            else "inAppPurchaseVersion"
                        )
                        included.append(
                            {
                                "id": f"item-{index}",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    relationship: {
                                        "data": {
                                            "type": resource_type,
                                            "id": resource_id,
                                        }
                                    }
                                },
                            }
                        )
                    return {"included": included}
                if method == "PATCH":
                    self.submitted = True
                    return {
                        "data": {
                            "id": "submission-ready",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                if method == "POST":
                    raise AssertionError(
                        "rerun must reuse the ready submission and its items"
                    )
                raise AssertionError(f"Unexpected request {method} {path}")

        api = FakeAPI()
        with mock.patch.object(MODULE.time, "sleep") as sleep:
            submission_id = MODULE.create_combined_review(
                api,
                "app-1",
                "version-1",
                [{"id": "iap-1"}, {"id": "iap-2"}, {"id": "iap-3"}],
            )

        self.assertEqual(submission_id, "submission-ready")
        self.assertTrue(api.submitted)
        self.assertEqual(api.target_readbacks, [])
        sleep.assert_called_once_with(2)

    def test_replace_workflow_delegates_final_submission_to_combined_script(self):
        workflow = (
            pathlib.Path(__file__).parents[2]
            / ".github"
            / "workflows"
            / "asc-release-replace-submit.yml"
        ).read_text(encoding="utf-8")

        self.assertIn('EXPECTED_VERSION: "1.1.8"', workflow)
        self.assertIn('EXPECTED_BUILD: "238"', workflow)
        self.assertIn(
            "python scripts/asc_submit_credit_packs.py --action submit",
            workflow,
        )
        self.assertIn("python scripts/asc_set_after_approval.py", workflow)
        guard = "python scripts/asc_set_after_approval.py"
        guard_positions = [
            index
            for index in range(len(workflow))
            if workflow.startswith(guard, index)
        ]
        submit_position = workflow.index(
            "python scripts/asc_submit_credit_packs.py --action submit"
        )
        self.assertEqual(len(guard_positions), 2)
        self.assertLess(
            guard_positions[0],
            submit_position,
        )
        self.assertLess(submit_position, guard_positions[1])
        self.assertNotIn("Attached app version item.", workflow)

    def test_review_manager_delegates_submit_to_guarded_release_scripts(self):
        workflow = (
            pathlib.Path(__file__).parents[2]
            / ".github"
            / "workflows"
            / "asc-review-submission.yml"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "python scripts/asc_submit_credit_packs.py --action submit",
            workflow,
        )
        self.assertIn("python scripts/asc_set_after_approval.py", workflow)
        self.assertIn("if: ${{ inputs.action == 'submit' }}", workflow)
        self.assertIn("if: ${{ inputs.action != 'submit' }}", workflow)
        self.assertIn('"attributes": {"canceled": True}', workflow)
        self.assertNotIn(
            'requests.delete(f"{base}/reviewSubmissions/{tid}"',
            workflow,
        )

    def test_replace_workflow_requires_an_explicit_manual_dispatch(self):
        workflow = (
            pathlib.Path(__file__).parents[2]
            / ".github"
            / "workflows"
            / "asc-release-replace-submit.yml"
        ).read_text(encoding="utf-8")

        trigger_block = workflow.split("jobs:", maxsplit=1)[0]
        self.assertIn("workflow_dispatch:", trigger_block)
        self.assertNotIn("\n  push:", trigger_block)

    def test_replace_workflow_fails_closed_when_metadata_upload_fails(self):
        workflow = (
            pathlib.Path(__file__).parents[2]
            / ".github"
            / "workflows"
            / "asc-release-replace-submit.yml"
        ).read_text(encoding="utf-8")
        metadata_step = workflow.split(
            "- name: Upload latest review metadata",
            maxsplit=1,
        )[1].split(
            "- name: Attach build and submit for review",
            maxsplit=1,
        )[0]

        self.assertNotIn("continue-on-error: true", metadata_step)

    def test_replace_workflow_waits_for_valid_build_before_cancelling_review(self):
        workflow = (
            pathlib.Path(__file__).parents[2]
            / ".github"
            / "workflows"
            / "asc-release-replace-submit.yml"
        ).read_text(encoding="utf-8")

        preflight = "- name: Wait for expected build before changing review"
        cancellation = "- name: Cancel waiting review submission before replacing build"
        self.assertIn(preflight, workflow)
        self.assertLess(workflow.index(preflight), workflow.index(cancellation))

        preflight_step = workflow.split(preflight, maxsplit=1)[1].split(
            "- name: Developer-reject pending App Store version",
            maxsplit=1,
        )[0]
        self.assertIn('state = attrs.get("processingState")', preflight_step)
        self.assertIn('if state == "VALID" and not expired:', preflight_step)
        self.assertNotIn("requests.patch(", preflight_step)
        self.assertNotIn("requests.post(", preflight_step)


if __name__ == "__main__":
    unittest.main()
