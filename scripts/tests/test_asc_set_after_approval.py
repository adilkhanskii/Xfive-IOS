import importlib.util
import pathlib
import unittest


SCRIPT_PATH = (
    pathlib.Path(__file__).resolve().parents[1]
    / "asc_set_after_approval.py"
)
WORKFLOW_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / ".github"
    / "workflows"
    / "asc-release-audit.yml"
)
SUBMIT_WORKFLOW_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / ".github"
    / "workflows"
    / "asc-release-submit.yml"
)


def load_script():
    spec = importlib.util.spec_from_file_location(
        "asc_set_after_approval", SCRIPT_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class SetAfterApprovalContractTests(unittest.TestCase):
    def test_guarded_release_type_script_exists(self):
        self.assertTrue(
            SCRIPT_PATH.exists(),
            "A guarded AFTER_APPROVAL patch script is required",
        )

    def test_patches_only_release_type_and_confirms_unchanged_review_state(self):
        module = load_script()
        self.assertTrue(hasattr(module, "set_after_approval"))

        class FakeClient:
            def __init__(self):
                self.updates = []
                self.version = {
                    "id": "version-116",
                    "attributes": {
                        "versionString": "1.1.12",
                        "platform": "IOS",
                        "appStoreState": "WAITING_FOR_REVIEW",
                        "releaseType": "MANUAL",
                    },
                }

            def find_app_id(self, bundle_id):
                self.bundle_id = bundle_id
                return "app-1"

            def list_versions(self, app_id):
                self.app_id = app_id
                return [self.version]

            def get_attached_build(self, version_id):
                self.version_id = version_id
                return {
                    "id": "build-257",
                    "attributes": {
                        "version": "257",
                        "processingState": "VALID",
                        "expired": False,
                    },
                }

            def update_release_type(self, version_id, release_type):
                self.updates.append((version_id, release_type))
                self.version["attributes"]["releaseType"] = release_type

            def get_version(self, version_id):
                return self.version

        client = FakeClient()
        result = module.set_after_approval(
            client,
            bundle_id="com.x5studio.app",
            version_string="1.1.12",
            build_number="257",
        )

        self.assertEqual(client.updates, [("version-116", "AFTER_APPROVAL")])
        self.assertEqual(result["releaseType"], "AFTER_APPROVAL")
        self.assertEqual(result["appStoreState"], "WAITING_FOR_REVIEW")

        module.set_after_approval(
            client,
            bundle_id="com.x5studio.app",
            version_string="1.1.12",
            build_number="257",
        )
        self.assertEqual(len(client.updates), 1)

    def test_rejects_unexpected_version_build_or_review_state_before_patch(self):
        module = load_script()

        class UnsafeClient:
            updates = []

            def find_app_id(self, _bundle_id):
                return "app-1"

            def list_versions(self, _app_id):
                return [
                    {
                        "id": "version-116",
                        "attributes": {
                            "versionString": "1.1.12",
                            "platform": "IOS",
                            "appStoreState": "PENDING_DEVELOPER_RELEASE",
                            "releaseType": "MANUAL",
                        },
                    }
                ]

            def get_attached_build(self, _version_id):
                return {
                    "id": "build-257",
                    "attributes": {
                        "version": "257",
                        "processingState": "VALID",
                        "expired": False,
                    },
                }

            def update_release_type(self, version_id, release_type):
                self.updates.append((version_id, release_type))

            def get_version(self, _version_id):
                return self.list_versions("app-1")[0]

        client = UnsafeClient()
        for version, build in (
            ("1.1.5", "257"),
            ("1.1.12", "226"),
            ("1.1.12", "257"),
        ):
            with self.subTest(version=version, build=build):
                with self.assertRaises(ValueError):
                    module.set_after_approval(
                        client,
                        bundle_id="com.x5studio.app",
                        version_string=version,
                        build_number=build,
                    )
        self.assertEqual(client.updates, [])

    def test_accepts_only_the_supported_pre_review_and_review_states(self):
        module = load_script()

        for state in (
            "PREPARE_FOR_SUBMISSION",
            "READY_FOR_REVIEW",
            "WAITING_FOR_REVIEW",
            "IN_REVIEW",
        ):
            with self.subTest(state=state):
                class SafeClient:
                    def __init__(self):
                        self.updates = []
                        self.version = {
                            "id": "version-116",
                            "attributes": {
                                "versionString": "1.1.12",
                                "platform": "IOS",
                                "appStoreState": state,
                                "releaseType": "MANUAL",
                            },
                        }

                    def find_app_id(self, _bundle_id):
                        return "app-1"

                    def list_versions(self, _app_id):
                        return [self.version]

                    def get_attached_build(self, _version_id):
                        return {
                            "id": "build-257",
                            "attributes": {
                                "version": "257",
                                "processingState": "VALID",
                                "expired": False,
                            },
                        }

                    def update_release_type(self, version_id, release_type):
                        self.updates.append((version_id, release_type))
                        self.version["attributes"]["releaseType"] = release_type

                    def get_version(self, _version_id):
                        return self.version

                client = SafeClient()
                result = module.set_after_approval(
                    client,
                    bundle_id="com.x5studio.app",
                    version_string="1.1.12",
                    build_number="257",
                )
                self.assertEqual(result["appStoreState"], state)
                self.assertEqual(result["releaseType"], "AFTER_APPROVAL")

    def test_rejects_post_release_states_without_mutation(self):
        module = load_script()

        for state in (
            "PENDING_APPLE_RELEASE",
            "PENDING_DEVELOPER_RELEASE",
            "PROCESSING_FOR_DISTRIBUTION",
            "READY_FOR_SALE",
        ):
            with self.subTest(state=state):
                class PostReleaseClient:
                    def __init__(self):
                        self.updates = []
                        self.version = {
                            "id": "version-116",
                            "attributes": {
                                "versionString": "1.1.12",
                                "platform": "IOS",
                                "appStoreState": state,
                                "releaseType": "MANUAL",
                            },
                        }

                    def find_app_id(self, _bundle_id):
                        return "app-1"

                    def list_versions(self, _app_id):
                        return [self.version]

                    def get_version(self, _version_id):
                        return self.version

                    def get_attached_build(self, _version_id):
                        raise AssertionError("unsafe state must fail before build lookup")

                    def update_release_type(self, version_id, release_type):
                        self.updates.append((version_id, release_type))

                client = PostReleaseClient()
                with self.assertRaises(ValueError):
                    module.set_after_approval(
                        client,
                        bundle_id="com.x5studio.app",
                        version_string="1.1.12",
                        build_number="257",
                    )
                self.assertEqual(client.updates, [])

    def test_release_audit_workflow_exposes_explicit_guarded_action(self):
        self.assertEqual(load_script().EXPECTED_BUILD, "257")
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn('default: "audit"', workflow)
        self.assertIn("set_after_approval", workflow)
        self.assertIn("scripts/asc_set_after_approval.py", workflow)
        self.assertIn('EXPECTED_VERSION: "1.1.12"', workflow)
        self.assertIn('EXPECTED_BUILD: "257"', workflow)

    def test_standalone_submit_locks_and_rechecks_after_approval(self):
        workflow = SUBMIT_WORKFLOW_PATH.read_text(encoding="utf-8")
        guard = "python scripts/asc_set_after_approval.py"
        submit = "- name: Submit App Store version for review"
        guard_positions = [
            index
            for index in range(len(workflow))
            if workflow.startswith(guard, index)
        ]
        self.assertEqual(len(guard_positions), 2)
        self.assertLess(guard_positions[0], workflow.index(submit))
        self.assertLess(workflow.index(submit), guard_positions[1])


if __name__ == "__main__":
    unittest.main()
