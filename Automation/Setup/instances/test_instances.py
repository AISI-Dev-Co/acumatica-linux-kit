import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

from catalog import load_catalog, new_profile, ordered_packages, parse_profile, select_build, verify_packages
from control import Instances, parser


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.raw = new_profile("client-a", "26.101.0225").wire()

    def package(self, name="X", depends=()):
        return {"name": name, "path": f"development/package/{name}/{name}.zip", "sha256": "a" * 64,
                "level": 0, "dependsOn": list(depends)}

    def test_create_release_pins_the_matching_installer_and_ui(self):
        for release, build, ui in (("25r1", "25.101.0153", "classic"), ("26r1", "26.101.0225", "modern")):
            with self.subTest(release=release):
                args = parser().parse_args(["create", "new-client", "--release", release])
                selected = select_build(release=args.release, build=args.build)
                profile = parse_profile(new_profile(args.id, selected.build).wire())
                self.assertEqual((selected.build, selected.ui), (build, ui))
                self.assertEqual(profile.installerRoot, f"C:\\AcumaticaBuilds\\{build}\\Acumatica ERP")

    def test_legacy_create_default_and_exact_build_selection(self):
        args = parser().parse_args(["create", "new-client"])
        self.assertEqual(select_build(release=args.release, build=args.build).build, "26.101.0225")
        self.assertEqual(select_build(build="25.101.0153").release, "25r1")

    def test_unapproved_builds_and_ambiguous_selection_fail_before_provisioning(self):
        for build in ("25.100.0054", "25.101.0153.6", "24.201.0000", "26.201.0000"):
            with self.subTest(build=build), self.assertRaises(ValueError):
                new_profile("new-client", build)
        with self.assertRaisesRegex(ValueError, "either"):
            select_build(release="25r1", build="26.101.0225")

    def test_identity_cannot_be_retargeted_to_another_clients_database_or_path(self):
        for field, value in (("database", "AcumaticaDB"), ("path", "D:\\AcumaticaERP"),
                             ("pool", "AcumaticaERPAppPool"), ("protected", True),
                             ("installerRoot", "C:\\AcumaticaInstallTools")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                parse_profile({**self.raw, field: value})

    def test_rejects_missing_and_cyclic_prerequisites(self):
        for packages in ([self.package("NewWork", ["X"])],
                         [self.package("X", ["Y"]), self.package("Y", ["X"])]):
            with self.subTest(packages=packages), self.assertRaises(ValueError):
                parse_profile({**self.raw, "packages": packages})

    def test_prerequisites_import_before_dependents(self):
        profile = parse_profile({**self.raw, "packages": [self.package("NewWork", ["X", "Y"]),
                                                         self.package("Y", ["X"]), self.package("X")]})
        self.assertEqual([p.name for p in ordered_packages(profile)], ["X", "Y", "NewWork"])

    def test_rejects_case_duplicate_projects_and_unsafe_paths(self):
        with self.assertRaises(ValueError):
            parse_profile({**self.raw, "packages": [self.package("X"), self.package("x")]})
        for path in ("../client-b.zip", "/tmp/package.zip", "C:/package.zip", "x/../package.zip"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                parse_profile({**self.raw, "packages": [{**self.package(), "path": path}]})

    def test_profile_filename_cannot_hide_a_different_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "client-b.json").write_text(json.dumps(self.raw))
            with self.assertRaisesRegex(ValueError, "filename"):
                load_catalog(Path(directory))

    def test_pins_actual_archive_bytes_and_embedded_levels(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            archive = repo / "X.zip"
            with ZipFile(archive, "w") as package:
                package.writestr("project.xml", '<Customization level="10" product-version="26.101"/>')
            definition = {**self.package(), "path": "X.zip", "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
            profile = parse_profile({**self.raw, "packages": [definition]})
            with self.assertRaisesRegex(ValueError, "level"):
                verify_packages(profile, repo)
            profile = parse_profile({**self.raw, "packages": [{**definition, "level": 10}]})
            self.assertEqual(verify_packages(profile, repo)[0]["guestPath"], "C:\\Acumatica-ERP\\X.zip")
            archive.write_bytes(archive.read_bytes() + b"changed")
            with self.assertRaisesRegex(ValueError, "changed"):
                verify_packages(profile, repo)

    def test_rejects_zip_traversal_before_import(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            archive = repo / "X.zip"
            with ZipFile(archive, "w") as package:
                package.writestr("project.xml", '<Customization level="0"/>')
                package.writestr("..\\other-site\\Bin\\bad.dll", b"bad")
            profile = parse_profile({**self.raw, "packages": [{**self.package(), "path": "X.zip",
                "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}]})
            with self.assertRaisesRegex(ValueError, "unsafe ZIP"):
                verify_packages(profile, repo)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.default = parse_profile(json.loads((Path(__file__).parent / "profiles/default.json").read_text()))
        self.clean = new_profile("clean", "26.101.0225")
        self.events = []

        class Transport:
            def __init__(self, events):
                self.events = events

            def command(self, name, *args, **kwargs):
                self.events.append((name, *args))

            def call(self, action, **payload):
                self.events.append((action, payload.get("profile", {}).get("id")))
                if action == "status":
                    return [{"id": p["id"], "state": "Started"} for p in payload["profiles"]]

        self.manager = Instances(Transport(self.events), {"default": self.default, "clean": self.clean})

    @patch("control.wait_for_login", side_effect=RuntimeError("failed readiness"))
    def test_failed_swap_keeps_previous_instance_and_automation_running(self, _):
        with self.assertRaisesRegex(RuntimeError, "failed readiness"):
            self.manager.activate([self.clean], exclusive=True)
        self.assertIn(("stop", "clean"), self.events)
        self.assertNotIn(("stop", "default"), self.events)
        self.assertNotIn(("n8n-down.sh",), self.events)

    def test_failed_start_response_still_stops_the_target(self):
        call = self.manager.guest.call

        def failed_response(action, **payload):
            result = call(action, **payload)
            if action == "start":
                raise RuntimeError("status response failed after pool start")
            return result

        with patch.object(self.manager.guest, "call", side_effect=failed_response):
            with self.assertRaisesRegex(RuntimeError, "status response failed"):
                self.manager.ready(self.clean)
        self.assertLess(self.events.index(("start", "clean")), self.events.index(("stop", "clean")))

    def test_cleanup_failure_does_not_hide_original_start_error(self):
        with patch.object(self.manager.guest, "call", side_effect=[RuntimeError("start response lost"), RuntimeError("stop unreachable")]):
            with self.assertRaisesRegex(RuntimeError, "start response lost; target cleanup also failed: stop unreachable"):
                self.manager.ready(self.clean)

    @patch("control.wait_for_login")
    def test_exclusive_swap_stops_old_automation_before_its_pool(self, _):
        self.manager.activate([self.clean], exclusive=True)
        self.assertLess(self.events.index(("start", "clean")), self.events.index(("n8n-down.sh",)))
        self.assertLess(self.events.index(("n8n-down.sh",)), self.events.index(("stop", "default")))

    @patch("control.wait_for_login")
    def test_parallel_start_does_not_stop_another_instance(self, _):
        self.manager.activate([self.default, self.clean], exclusive=False)
        self.assertNotIn(("stop", "default"), self.events)
        self.assertNotIn(("stop", "clean"), self.events)
        self.assertIn(("n8n-up.sh",), self.events)


if __name__ == "__main__":
    unittest.main()
