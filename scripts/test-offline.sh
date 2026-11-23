#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 || ( "$1" != stable && "$1" != batching ) ]]; then
  echo "Usage: bash scripts/test-offline.sh {stable|batching} MAYA_SOURCE" >&2
  exit 2
fi

mode=$1
source_dir=$(cd -- "$2" && pwd)
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python=${PYTHON:-python3}
compiler=${CXX:-c++}
export PYTHONDONTWRITEBYTECODE=1

"$python" -m unittest discover -s "$repo/tests"
(
  cd -- "$source_dir"
  "$python" -m unittest serve.test_inkling2_frontend tools.test_maya_parallel
)

if [[ "$mode" == batching ]]; then
  build=$(mktemp -d)
  trap 'rm -rf -- "$build"' EXIT
  for test in ik2_serve_test ik2_serve_stop_probe; do
    "$compiler" -std=c++20 -O1 -Wall -Wextra -Wpedantic -pthread \
      -I "$source_dir/src/ik2" "$source_dir/tests/$test.cpp" -o "$build/$test"
    timeout 30 "$build/$test"
  done
fi
