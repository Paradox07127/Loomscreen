#!/usr/bin/env python3
"""Unit tests for the structured Xcode test reporter."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import xcode_test_runner as runner


class XcodeTestRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.summary = {
            "result": "Passed",
            "totalTestCount": 3,
            "passedTests": 3,
            "failedTests": 0,
            "skippedTests": 0,
        }
        self.tests = {
            "testNodes": [
                {
                    "children": [
                        {
                            "nodeType": "Test Case",
                            "nodeIdentifier": "RequiredSuite/fastTest()",
                            "durationInSeconds": 0.1,
                        },
                        {
                            "nodeType": "Test Case",
                            "nodeIdentifier": "RequiredSuite/slowTest()",
                            "durationInSeconds": 1.5,
                        },
                    ]
                }
            ]
        }

    def test_valid_summary_and_required_suite_pass(self) -> None:
        self.assertEqual(runner.validate_summary(self.summary, 3), [])
        self.assertEqual(
            runner.required_suites_missing(self.tests, ["RequiredSuite"]), []
        )

    def test_zero_or_incomplete_run_fails(self) -> None:
        self.assertIn("below required minimum", runner.validate_summary(self.summary, 4)[0])
        self.assertEqual(
            runner.required_suites_missing(self.tests, ["MissingSuite"]),
            ["MissingSuite"],
        )

    def test_failed_result_fails_even_with_a_nonzero_count(self) -> None:
        failed = dict(self.summary, result="Failed", failedTests=1)
        errors = runner.validate_summary(failed, 1)
        self.assertEqual(len(errors), 2)

    def test_slowest_tests_are_sorted(self) -> None:
        self.assertEqual(
            runner.slowest_tests(self.tests, 1),
            [(1.5, "RequiredSuite/slowTest()")],
        )

    def test_failure_excerpt_includes_nearby_assertion_context(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text(
                "unrelated\nsetup\nExpectation failed: value was 2\n"
                "at ExampleTests.swift:42\nteardown\nunrelated tail\n",
                encoding="utf-8",
            )
            excerpt = runner.failure_excerpt(log)
        self.assertIn("setup", excerpt)
        self.assertIn("Expectation failed: value was 2", excerpt)
        self.assertIn("at ExampleTests.swift:42", excerpt)


if __name__ == "__main__":
    unittest.main()
