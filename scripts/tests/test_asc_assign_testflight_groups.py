import importlib.util
import pathlib
import unittest


SCRIPT_PATH = (
    pathlib.Path(__file__).resolve().parents[1]
    / "asc_assign_testflight_groups.py"
)
WORKFLOW_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / ".github"
    / "workflows"
    / "asc-tf-status.yml"
)


class AssignTestFlightGroupsContractTests(unittest.TestCase):
    def test_safe_assignment_script_exists(self):
        self.assertTrue(
            SCRIPT_PATH.exists(),
            "A guarded TestFlight group assignment script is required",
        )

    def test_assigns_only_the_expected_build_to_both_safe_internal_groups(self):
        spec = importlib.util.spec_from_file_location(
            "asc_assign_testflight_groups", SCRIPT_PATH
        )
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        self.assertTrue(
            hasattr(module, "assign_internal_groups"),
            "assign_internal_groups must implement the guarded operation",
        )

        class FakeClient:
            def __init__(self):
                self.memberships = {"group-123": set(), "group-321": set()}
                self.added = []

            def find_app_id(self, bundle_id):
                self.bundle_id = bundle_id
                return "app-1"

            def list_builds(self, app_id):
                self.app_id = app_id
                return [
                    {
                        "id": "build-251",
                        "attributes": {
                            "version": "251",
                            "processingState": "VALID",
                            "expired": False,
                        },
                    }
                ]

            def list_beta_groups(self, app_id):
                return [
                    {
                        "id": "group-123",
                        "attributes": {
                            "name": "123",
                            "isInternalGroup": True,
                            "publicLinkEnabled": None,
                        },
                    },
                    {
                        "id": "group-321",
                        "attributes": {
                            "name": "321",
                            "isInternalGroup": True,
                            "publicLinkEnabled": False,
                        },
                    },
                ]

            def list_group_build_ids(self, group_id):
                return set(self.memberships[group_id])

            def add_build_to_group(self, group_id, build_id):
                self.added.append((group_id, build_id))
                self.memberships[group_id].add(build_id)

        client = FakeClient()
        result = module.assign_internal_groups(
            client,
            bundle_id="com.x5studio.app",
            build_number="251",
            group_names=("123", "321"),
        )

        self.assertEqual(
            client.added,
            [("group-123", "build-251"), ("group-321", "build-251")],
        )
        self.assertEqual(result, {"123": "confirmed", "321": "confirmed"})

        # Idempotent retry must not add duplicate relationships.
        module.assign_internal_groups(
            client,
            bundle_id="com.x5studio.app",
            build_number="251",
            group_names=("123", "321"),
        )
        self.assertEqual(len(client.added), 2)

    def test_rejects_wrong_build_or_unsafe_group_before_mutation(self):
        spec = importlib.util.spec_from_file_location(
            "asc_assign_testflight_groups_reject", SCRIPT_PATH
        )
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        self.assertTrue(hasattr(module, "assign_internal_groups"))

        class UnsafeClient:
            added = []

            def find_app_id(self, _bundle_id):
                return "app-1"

            def list_builds(self, _app_id):
                return [
                    {
                        "id": "build-251",
                        "attributes": {
                            "version": "251",
                            "processingState": "VALID",
                            "expired": False,
                        },
                    }
                ]

            def list_beta_groups(self, _app_id):
                return [
                    {
                        "id": "external",
                        "attributes": {
                            "name": "123",
                            "isInternalGroup": False,
                            "publicLinkEnabled": True,
                        },
                    },
                    {
                        "id": "safe",
                        "attributes": {
                            "name": "321",
                            "isInternalGroup": True,
                            "publicLinkEnabled": None,
                        },
                    },
                ]

            def list_group_build_ids(self, _group_id):
                return set()

            def add_build_to_group(self, group_id, build_id):
                self.added.append((group_id, build_id))

        client = UnsafeClient()
        with self.assertRaises(ValueError):
            module.assign_internal_groups(
                client,
                bundle_id="com.x5studio.app",
                build_number="251",
                group_names=("123", "321"),
            )
        self.assertEqual(client.added, [])

        with self.assertRaisesRegex(ValueError, "non-X5"):
            module.assign_internal_groups(
                client, bundle_id="com.unrelated.app", build_number="251",
                group_names=("123", "321"),
            )
        self.assertEqual(client.added, [])

        with self.assertRaises(ValueError):
            module.assign_internal_groups(
                client,
                bundle_id="com.x5studio.app",
                build_number="190",
                group_names=("123", "321"),
            )
        self.assertEqual(client.added, [])

    def test_existing_status_workflow_exposes_explicit_guarded_assignment(self):
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn('default: "251"', workflow)
        self.assertIn('default: "inspect"', workflow)
        self.assertIn("assign_internal_groups", workflow)
        self.assertIn(
            "uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2",
            workflow,
        )
        self.assertNotIn("uses: actions/checkout@v4", workflow)
        self.assertIn("scripts/asc_assign_testflight_groups.py", workflow)
        self.assertIn('--group "123"', workflow)
        self.assertIn('--group "321"', workflow)

    def test_status_workflow_never_logs_individual_tester_emails(self):
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        individual_testers = workflow.split(
            "=== Individual testers on build", maxsplit=1
        )[1].split("# 5. App-level beta groups", maxsplit=1)[0]

        self.assertIn("len(testers)", individual_testers)
        self.assertNotIn("get('email'", individual_testers)
        self.assertNotIn('get("email"', individual_testers)
        self.assertNotRegex(
            individual_testers,
            r"for\s+\w+\s+in\s+testers",
        )


if __name__ == "__main__":
    unittest.main()
