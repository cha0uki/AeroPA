#!/bin/zsh
# Runs AeroPACore's unit tests with only the Swift toolchain (no Xcode / XCTest).
# With Xcode installed, prefer:  swift test   or   xcodebuild test -scheme AeroPA
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="${TMPDIR:-/tmp}/aeropa-localtests"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cd "$BUILD"
core=("${(@f)$(find "$ROOT/Sources/AeroPACore" -name '*.swift')}")
tests=("$ROOT"/Tests/AeroPACoreTests/*.swift)
swiftc -emit-module -emit-library -module-name XCTest -parse-as-library "$ROOT/Tools/LocalTestRunner/XCTestShim.swift" -o libXCTest.dylib
swiftc -emit-module -emit-library -enable-testing -module-name AeroPACore -parse-as-library "${core[@]}" -o libAeroPACore.dylib
python3 "$ROOT/Tools/LocalTestRunner/generate_runner.py" "$ROOT/Tests/AeroPACoreTests" main.swift
swiftc -I . -L . -lXCTest -lAeroPACore -module-name AeroPACoreTests "${tests[@]}" main.swift -o runtests -Xlinker -rpath -Xlinker "$BUILD"
./runtests
