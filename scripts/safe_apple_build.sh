#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage:
  safe_apple_build.sh [--developer-dir ABS_DIR] [--test-only-executable ABS_PATH] \
    flutter-ios-simulator-debug --flutter-bin ABS_PATH
  safe_apple_build.sh [--developer-dir ABS_DIR] [--test-only-executable ABS_PATH] \
    xcodebuild [--verbose] -- ARGS...
USAGE
}

fail() {
  echo "Safe Apple build configuration is invalid." >&2
  exit 2
}

absolute_directory() {
  [[ "$1" == /* && -d "$1" ]]
}

absolute_executable() {
  [[ "$1" == /* && -f "$1" && -x "$1" ]]
}

developer_dir=""
test_executable=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --developer-dir)
      [[ "$#" -ge 2 ]] || fail
      developer_dir="$2"
      shift 2
      ;;
    --test-only-executable)
      [[ "${MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST:-}" == "1" && "$#" -ge 2 ]] || fail
      test_executable="$2"
      shift 2
      ;;
    --)
      fail
      ;;
    *)
      break
      ;;
  esac
done

[[ "$#" -gt 0 ]] || { usage; exit 2; }
mode="$1"
shift

home_dir="${HOME:-}"
absolute_directory "$home_dir" || fail

tmp_dir="${TMPDIR:-/tmp}"
absolute_directory "$tmp_dir" || fail

if [[ -n "$developer_dir" ]]; then
  absolute_directory "$developer_dir" || fail
fi

if [[ -n "$test_executable" ]]; then
  absolute_executable "$test_executable" || fail
fi

case "$mode" in
  flutter-ios-simulator-debug)
    [[ "$#" -eq 2 && "$1" == "--flutter-bin" ]] || { usage; exit 2; }
    flutter_bin="$2"
    absolute_executable "$flutter_bin" || fail
    executable="${test_executable:-$flutter_bin}"
    child_path="$(dirname "$flutter_bin"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    child_args=(--suppress-analytics build ios --simulator --debug --no-codesign)
    ;;
  xcodebuild)
    verbose="false"
    if [[ "${1:-}" == "--verbose" ]]; then
      verbose="true"
      shift
    fi
    [[ "${1:-}" == "--" ]] || { usage; exit 2; }
    shift
    executable="${test_executable:-/usr/bin/xcodebuild}"
    absolute_executable "$executable" || fail
    child_path="/usr/bin:/bin:/usr/sbin:/sbin"
    child_args=()
    if [[ "$verbose" != "true" ]]; then
      child_args+=(-quiet)
    fi
    child_args+=("$@")
    ;;
  *)
    usage
    exit 2
    ;;
esac

env_args=(
  "PATH=$child_path"
  "HOME=$home_dir"
  "TMPDIR=$tmp_dir"
  "LANG=en_US.UTF-8"
  "LC_ALL=en_US.UTF-8"
  "COCOAPODS_DISABLE_STATS=true"
)
if [[ -n "$developer_dir" ]]; then
  env_args+=("DEVELOPER_DIR=$developer_dir")
fi

exec /usr/bin/env -i "${env_args[@]}" "$executable" "${child_args[@]}"
