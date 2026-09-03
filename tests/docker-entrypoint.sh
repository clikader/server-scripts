#!/usr/bin/env bash
# Entrypoint for the CLiKader test container.
#
#   docker-entrypoint.sh            Run bats under kcov, print coverage, gate on 80%.
#   docker-entrypoint.sh --no-coverage   Run bats only (fast iteration, no coverage).
#
# Coverage is restricted to the repo scripts (clikader.sh, install.sh,
# components/*.sh); the tests/ directory itself is excluded.

set -euo pipefail

REPO="${REPO_ROOT:-/workspace/server-scripts}"
THRESHOLD="${COVERAGE_THRESHOLD:-80}"
COV_DIR="${COV_DIR:-${REPO}/coverage}"
MODE="${1:-coverage}"

run_bats() {
    bats "${REPO}/tests"/*.bats "${REPO}/tests/components"/*.bats
}

if [[ "$MODE" == "--no-coverage" ]]; then
    run_bats
    exit $?
fi

echo "== Running bats under kcov (threshold: ${THRESHOLD}%) =="
rm -rf "$COV_DIR"
kcov \
    --include-path="$REPO" \
    --exclude-path="${REPO}/tests" \
    --clean \
    "$COV_DIR" \
    bats "${REPO}/tests"/*.bats "${REPO}/tests/components"/*.bats

# kcov writes a <binary>.<hash>/coverage.json per traced binary. Collect them
# all and merge the line counts for our report (normally a single one).
json_files=()
while IFS= read -r -d '' f; do
    json_files+=("$f")
done < <(find "$COV_DIR" -name coverage.json -print0)

if [[ ${#json_files[@]} -eq 0 ]]; then
    echo "ERROR: no coverage.json produced by kcov" >&2
    exit 1
fi

# Merge all files: sum lines per source file across the runs.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat "${json_files[@]}" | jq -s '
    [ .[].files[] ] | group_by(.file) | map({
        file: .[0].file,
        total_lines: ([.[].total_lines | tonumber] | add),
        covered_lines: ([.[].covered_lines | tonumber] | add)
    })
' > "$tmp/merged.json"

echo ""
printf '%-70s %10s %10s %10s\n' "FILE" "COVERED" "TOTAL" "PERCENT"
printf '%s\n' "--------------------------------------------------------------------------------------------------------------"
total_cov=0
total_all=0
while IFS=$'\t' read -r file covered total; do
    pct="$(awk -v c="$covered" -v t="$total" 'BEGIN{ printf "%.1f", c*100/t }')"
    printf '%-70s %10s %10s %10s%%\n' "$file" "$covered" "$total" "$pct"
    total_cov=$((total_cov + covered))
    total_all=$((total_all + total))
done < <(jq -r '.[] | [.file, .covered_lines, .total_lines] | @tsv' "$tmp/merged.json")

echo ""
if [[ "$total_all" -eq 0 ]]; then
    echo "ERROR: no coverable lines found" >&2
    exit 1
fi
overall="$(awk -v c="$total_cov" -v t="$total_all" 'BEGIN{ printf "%.2f", c*100/t }')"
printf 'OVERALL: %s%% (%s/%s lines)  threshold: %s%%\n' "$overall" "$total_cov" "$total_all" "$THRESHOLD"

if awk "BEGIN{exit !($overall >= $THRESHOLD)}"; then
    echo "PASS: coverage >= ${THRESHOLD}%"
    exit 0
else
    echo "FAIL: coverage < ${THRESHOLD}%" >&2
    exit 1
fi
