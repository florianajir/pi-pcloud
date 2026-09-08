#!/bin/sh
# Tests for scripts/sarif-merge.py, which collapses Trivy's one-run-per-image
# SARIF into the single run the image scan uploads.
#
# The failure this file exists to catch is silent and wrong rather than loud:
# `ruleIndex` is an offset into the run's own rules array, so concatenating two
# runs without remapping relabels every finding from the second file with
# whatever rule happens to sit at that offset. The alert would name the wrong
# CVE at the right severity, and nothing would look broken.
#
# Nothing here runs Trivy or touches the network; the fixtures are shaped like
# its output, and the invariant asserted is the one that matters: every result's
# ruleIndex must resolve to a rule whose id is that result's own ruleId.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
MERGE="$REPO_DIR/scripts/sarif-merge.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$2" "$3"
    fi
}

# sarif <uri> <cve>... : one Trivy-shaped run, one rule and one result per CVE.
sarif() {
    _uri="$1"
    shift
    printf '%s' "$*" | tr ' ' '\n' | python3 -c '
import json, sys
uri = sys.argv[1]
cves = [line for line in sys.stdin.read().split() if line]
print(json.dumps({
    "version": "2.1.0",
    "runs": [{
        "tool": {"driver": {
            "name": "Trivy",
            "version": "0.74.0",
            "informationUri": "https://github.com/aquasecurity/trivy",
            "rules": [
                {"id": cve, "name": "OsPackageVulnerability",
                 "properties": {"security-severity": "8.0", "tags": ["vulnerability", "HIGH"]}}
                for cve in cves
            ],
        }},
        "results": [
            {"ruleId": cve, "ruleIndex": i, "level": "error",
             "message": {"text": f"Vulnerability {cve}"},
             "locations": [{"physicalLocation": {"artifactLocation": {"uri": uri}}}]}
            for i, cve in enumerate(cves)
        ],
    }],
}))
' "$_uri"
}

# The invariant, asked of the merged file rather than of the code that wrote it.
mismatches() {
    jq -r '.runs[0] as $r
        | [$r.results[] | select($r.tool.driver.rules[.ruleIndex].id != .ruleId)]
        | length' "$1"
}

# --- two images with no CVE in common --------------------------------------

sarif "library/traefik" CVE-1111 CVE-2222 >"$WORK/a.sarif"
sarif "mvance/unbound-rpi" CVE-3333 >"$WORK/b.sarif"
python3 "$MERGE" "$WORK/out.sarif" "$WORK/a.sarif" "$WORK/b.sarif" >/dev/null

ok "the merge is one run"            "$(jq -r '.runs | length' "$WORK/out.sarif")" 1
ok "every rule is carried over"      "$(jq -r '.runs[0].tool.driver.rules | length' "$WORK/out.sarif")" 3
ok "every result is carried over"    "$(jq -r '.runs[0].results | length' "$WORK/out.sarif")" 3
ok "and every one still names its own rule" "$(mismatches "$WORK/out.sarif")" 0
ok "both images are still identifiable" \
    "$(jq -r '[.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri] | unique | length' "$WORK/out.sarif")" 2
ok "the tool survives, for the upload to attribute" \
    "$(jq -r '.runs[0].tool.driver.name' "$WORK/out.sarif")" Trivy

# --- the same CVE in both images -------------------------------------------
#
# What the remapping is for. Both files call it rule index 0 in their own run,
# and the second file's other findings sit at indices the first file also used.

sarif "library/traefik" CVE-9999 CVE-1111 >"$WORK/c.sarif"
sarif "some/other" CVE-9999 CVE-8888 CVE-7777 >"$WORK/d.sarif"
python3 "$MERGE" "$WORK/dup.sarif" "$WORK/c.sarif" "$WORK/d.sarif" >/dev/null

ok "a CVE seen twice is one rule"    "$(jq -r '.runs[0].tool.driver.rules | length' "$WORK/dup.sarif")" 4
ok "but both findings are kept"      "$(jq -r '.runs[0].results | length' "$WORK/dup.sarif")" 5
ok "no rule id appears twice" \
    "$(jq -r '.runs[0].tool.driver.rules | (map(.id) | unique | length) == length' "$WORK/dup.sarif")" true
ok "and no finding was relabelled"   "$(mismatches "$WORK/dup.sarif")" 0

# The shared CVE has to resolve from either side, which is the whole point.
ok "the shared CVE resolves for both images" \
    "$(jq -r '.runs[0] as $r | [$r.results[] | select(.ruleId == "CVE-9999")
        | $r.tool.driver.rules[.ruleIndex].id] | unique | join(",")' "$WORK/dup.sarif")" \
    CVE-9999

# --- an image that came back clean -----------------------------------------
#
# Trivy still emits a run, with no rules and no results. It has to merge, or a
# quiet week would fail the upload and leave every open alert unrefreshed.

sarif "clean/image" >"$WORK/empty.sarif"
python3 "$MERGE" "$WORK/withempty.sarif" "$WORK/a.sarif" "$WORK/empty.sarif" >/dev/null
ok "a clean image contributes nothing and breaks nothing" \
    "$(jq -r '.runs[0].results | length' "$WORK/withempty.sarif")" 2

python3 "$MERGE" "$WORK/allempty.sarif" "$WORK/empty.sarif" >/dev/null
ok "and a week where every image is clean still uploads" \
    "$(jq -r '.runs[0].results | length' "$WORK/allempty.sarif")" 0

# --- what it must refuse ----------------------------------------------------
#
# Each of these would otherwise produce a plausible-looking file that quietly
# describes the wrong thing, or an empty upload that closes every real alert.

refuses() {
    _label="$1"
    _needle="$2"
    shift 2
    _got="$(python3 "$MERGE" "$WORK/refused.sarif" "$@" 2>&1 >/dev/null || true)"
    case "$_got" in
        *"$_needle"*) pass=$((pass + 1)) ;;
        *)
            fail=$((fail + 1))
            printf 'FAIL %s\n  got  [%s]\n  want [*%s*]\n' "$_label" "$_got" "$_needle"
            ;;
    esac
}

printf '{"version": "2.1.0", "runs": []}' >"$WORK/noruns.sarif"
refuses "a file with no run at all" "expected exactly one run" "$WORK/noruns.sarif"

python3 - "$WORK/tworuns.sarif" <<'PY'
import json, sys
run = {"tool": {"driver": {"name": "Trivy", "rules": []}}, "results": []}
with open(sys.argv[1], "w") as handle:
    json.dump({"version": "2.1.0", "runs": [run, run]}, handle)
PY
refuses "a file that already holds two runs" "expected exactly one run" "$WORK/tworuns.sarif"

# A result pointing past the end of its own rules array is the corruption this
# script exists to avoid creating; it must not pass one through either.
jq '.runs[0].results[0].ruleIndex = 7' "$WORK/a.sarif" >"$WORK/badindex.sarif"
refuses "a result pointing at a rule its file never defined" \
    "which the file does not define" "$WORK/badindex.sarif"

jq 'del(.runs[0].tool.driver.rules[0].id)' "$WORK/a.sarif" >"$WORK/noid.sarif"
refuses "a rule with no id to dedupe on" "has no id" "$WORK/noid.sarif"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
