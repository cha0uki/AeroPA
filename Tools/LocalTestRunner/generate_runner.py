#!/usr/bin/env python3
"""Generates main.swift that runs every `func testXxx()` of every XCTestCase subclass."""
import re, sys, pathlib
out = ["import Foundation", "import XCTest", "@testable import AeroPACore", "",
       "var passed = 0, failed = 0", "func run<T: XCTestCase>(_ t: T.Type, _ name: String, _ body: (T) throws -> Void) {",
       "  let c = T(); _xctCurrentTest = \"\\(T.self).\\(name)\"; let before = _xctFailures.count",
       "  let start = Date(); c.setUp()",
       "  do { try body(c) } catch { _xctRecord(\"threw \\(error)\", #file, #line) }",
       "  c.tearDown()",
       "  let ok = _xctFailures.count == before; if ok { passed += 1 } else { failed += 1 }",
       "  print(\"\\(ok ? \"✓\" : \"✗\") \\(_xctCurrentTest) (\\(String(format: \"%.2f\", Date().timeIntervalSince(start)))s)\")",
       "}", ""]
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.swift")):
    cls = None
    for line in f.read_text().splitlines():
        m = re.match(r"\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", line)
        if m: cls = m.group(1); continue
        m = re.match(r"\s*func\s+(test\w+)\s*\(\s*\)\s*(throws)?", line)
        if m and cls:
            out.append(f"run({cls}.self, \"{m.group(1)}\") {{ {'try ' if m.group(2) else ''}$0.{m.group(1)}() }}")
out += ["", "for f in _xctFailures { print(\"FAIL:\", f) }", "print(\"\\n\\(passed) passed, \\(failed) failed\")", "exit(failed == 0 ? 0 : 1)"]
pathlib.Path(sys.argv[2]).write_text("\n".join(out) + "\n")
