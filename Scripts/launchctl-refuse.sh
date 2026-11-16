#!/bin/sh
# A launchctl that refuses everything — the Makefile's DOZ_TEST_LAUNCHCTL for every test target, so no test run ever
# loads, unloads, starts or even looks at a real launchd job. `print` answers "not loaded" (exit 1) like a job launchd
# does not have; every other verb fails the same way, and doz says so as it would on a Mac where launchd refused it.
# `make test-cli-daemon` uses Scripts/fake-launchctl.py instead (it records, keeps a state, and runs a kickstarted job).
echo "launchctl (test seam): refused: $*" >&2
exit 1
