#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
shopt -s nullglob
for f in tests/*-test.el; do args+=(-l "$f"); done
emacs -Q --batch -L . -L tests -l tests/seance-test-helpers.el \
  ${args[@]+"${args[@]}"} -f ert-run-tests-batch-and-exit
