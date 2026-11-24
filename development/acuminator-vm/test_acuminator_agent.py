from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

import acuminator_agent


class ParseDiagnosticLineTests(unittest.TestCase):
    def test_parses_roslyn_style_location(self) -> None:
        diagnostic = acuminator_agent.parse_diagnostic_line(
            '[Warning] PX1099: Avoid this API: "C:/src/Example.cs: (12,34)-(12,56)"',
            project_name="Demo",
        )

        self.assertEqual(diagnostic["severity"], "Warning")
        self.assertEqual(diagnostic["diagnosticId"], "PX1099")
        self.assertEqual(diagnostic["message"], "Avoid this API")
        self.assertEqual(diagnostic["path"], "C:/src/Example.cs")
        self.assertEqual(diagnostic["startLine"], 12)
        self.assertEqual(diagnostic["endColumn"], 56)

    def test_parses_parenthesized_location(self) -> None:
        diagnostic = acuminator_agent.parse_diagnostic_line(
            '[Error] PX1000: Bad action signature: "/tmp/Example.cs(5,6,5,10)"',
            project_name="Demo",
        )

        self.assertEqual(diagnostic["severity"], "Error")
        self.assertEqual(diagnostic["diagnosticId"], "PX1000")
        self.assertEqual(diagnostic["path"], "/tmp/Example.cs")
        self.assertEqual(diagnostic["startColumn"], 6)
        self.assertEqual(diagnostic["endLine"], 5)

    def test_keeps_unparsed_locations(self) -> None:
        diagnostic = acuminator_agent.parse_diagnostic_line(
            '[Info] PX1041: Suggested refactor: "some custom location"',
            project_name="Demo",
        )

        self.assertEqual(diagnostic["path"], "some custom location")
        self.assertIsNone(diagnostic["startLine"])


if __name__ == "__main__":
    unittest.main()
