#!/usr/bin/env bash
# Run upstream's three CI test shards plus the legacy-unsharded suites (which no
# shard runs, among them MeetingAutoStopPolicyTests) on the checkout of the
# current directory, with build.sh's SwiftPM cache. Prints one result line per
# run; full logs go to a fresh directory under $TMPDIR. Exits non-zero if any
# run fails. A pure upstream tag has no fork-infra/: copy this script out first.
#
#   fork-infra/test.sh [core] [dictation-transcription] [meetings] [unsharded]
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)" || exit 2
export MUESLI_SWIFTPM_SCRATCH_PATH="${MUESLI_SWIFTPM_SCRATCH_PATH:-$HOME/Library/Caches/muesli-spm/qm-release/swiftpm}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muesli-qm-tests.XXXXXX")"
RUNS=("$@")
[[ ${#RUNS[@]} -gt 0 ]] || RUNS=(core dictation-transcription meetings unsharded)
cd "$ROOT"

# Mirrors scripts/run_ci_test_shard.sh for the suites listed in
# scripts/ci_unsharded_test_suites.txt.
run_unsharded() {
  local build_args=(--package-path native/MuesliNative --build-system native --scratch-path "$MUESLI_SWIFTPM_SCRATCH_PATH")
  local args=("${build_args[@]}") suite bin_path metallib
  while read -r suite; do args+=(--filter "$suite"); done \
    < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' scripts/ci_unsharded_test_suites.txt)
  swift build "${build_args[@]}" --build-tests || return
  bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
  metallib="$(find "$bin_path" -path '*mlx-swift_Cmlx.bundle/*' -name default.metallib -print -quit)"
  if [[ -z "$metallib" ]]; then
    metallib="$bin_path/muesli-test.metallib"
    bash scripts/build_mlx_test_metallib.sh "$MUESLI_SWIFTPM_SCRATCH_PATH/checkouts/mlx-swift" "$metallib" || return
  fi
  MUESLI_MLX_EVAL_METALLIB="$metallib" swift test "${args[@]}" --skip-build
}

echo "Testing $(git rev-parse --short HEAD) ($(git describe --tags --always HEAD)); logs in $LOG_DIR"
failed=0
for run in "${RUNS[@]}"; do
  log="$LOG_DIR/$run.log"
  start=$SECONDS
  case "$run" in
    # Separate streams: SwiftPM warnings on stderr would split the summary line.
    core|dictation-transcription|meetings) ./scripts/run_ci_test_shard.sh "$run" >"$log" 2>"$log.stderr" ;;
    unsharded) run_unsharded >"$log" 2>"$log.stderr" ;;
    *) echo "unknown run: $run" >&2; exit 2 ;;
  esac
  status=$?
  [[ $status == 0 ]] || failed=1
  summary="$(cat "$log" "$log.stderr" | grep -aoE 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed).*' | tail -1)"
  printf '%-24s exit=%s %4ss  %s\n' "$run" "$status" "$((SECONDS - start))" "${summary:-no test summary (build failure?)}"
  if [[ $status != 0 ]]; then
    cat "$log" "$log.stderr" | grep -aE 'Test .* (failed|recorded an issue)|error:' | sort -u | head -20 | sed 's/^/    /'
  fi
done
exit $failed
