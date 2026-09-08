"""Merge one-run SARIF files into a single run, for one code scanning upload.

Trivy scans one image per invocation and emits one SARIF run each. GitHub keys
a code scanning alert's lifecycle to the (category, rule, location) it arrived
under, and closes an alert when a later upload for the same category no longer
carries it. Uploading a file per image would mean a category per image, and a
category whose image came back clean would never be uploaded again - so every
alert it ever raised would sit open forever, describing a CVE that was patched
months ago.

One run, one category, one upload: the whole picture is replaced every time, and
a CVE that has been fixed closes by itself.

Usage: sarif-merge.py [--keep-tag TAG] <out.sarif> <in.sarif>...

A rule is identified by its `id`, which for Trivy is the CVE, and the same CVE
turns up in several images. The first spelling wins and every result is
repointed at it, because `ruleIndex` is an offset into the run's own rules array
and concatenating two runs' results without remapping would silently relabel
findings with whatever rule happened to sit at that offset.

--keep-tag drops every finding whose rule does not carry that tag, and then the
rules nothing points at any more. The image scan uploads CRITICAL alone:
measured on this stack, HIGH and CRITICAL together are 4886 findings over 1050
CVEs, of which four images are 93% - and 4886 individually tracked alerts is not
alerting. The per-image counts for both severities go in the run summary.
"""

import json
import sys

# GitHub accepts 5000 results per upload and silently drops the rest, so a run
# over the limit is not a big report - it is an arbitrary subset of one, and
# whichever findings fell off the end are invisible. Refused rather than
# truncated: the answer is to narrow what is scanned, and a loud failure is the
# only thing that will make anyone do it. Left below GitHub's own number, with
# room to see it coming.
MAX_RESULTS = 4900


def load_run(path):
    """The single run in a SARIF file, or a reason it cannot be used."""
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)

    runs = document.get("runs") or []
    if len(runs) != 1:
        return None, f"{path}: expected exactly one run, found {len(runs)}"
    return runs[0], None


def main():
    args = sys.argv[1:]
    keep_tag = None
    if len(args) >= 2 and args[0] == "--keep-tag":
        keep_tag = args[1]
        args = args[2:]

    if len(args) < 2:
        print("usage: sarif-merge.py [--keep-tag TAG] <out.sarif> <in.sarif>...", file=sys.stderr)
        return 2

    out_path = args[0]
    in_paths = args[1:]

    problems = []
    driver = None
    rule_by_id = {}
    kept = []

    def tagged(rule):
        return keep_tag is None or keep_tag in ((rule.get("properties") or {}).get("tags") or [])

    for path in in_paths:
        run, problem = load_run(path)
        if problem:
            problems.append(problem)
            continue

        tool_driver = (run.get("tool") or {}).get("driver") or {}
        if driver is None:
            # Everything but the rules: name, version, informationUri. Taken
            # from the first file because every file came from the same Trivy.
            driver = {key: value for key, value in tool_driver.items() if key != "rules"}

        # index -> id for this file alone, so a result carrying an offset its own
        # run never defined is caught rather than silently relabelled.
        id_at = {}
        for position, rule in enumerate(tool_driver.get("rules") or []):
            rule_id = rule.get("id")
            if not rule_id:
                problems.append(f"{path}: a rule at index {position} has no id")
                continue
            id_at[position] = rule_id
            rule_by_id.setdefault(rule_id, rule)

        for result in run.get("results") or []:
            index = result.get("ruleIndex")
            rule_id = result.get("ruleId")
            if index is not None:
                if index not in id_at:
                    problems.append(f"{path}: a result points at rule index {index}, which the file does not define")
                    continue
                rule_id = id_at[index]
            if rule_id is None:
                problems.append(f"{path}: a result names no rule at all")
                continue
            if not tagged(rule_by_id.get(rule_id) or {}):
                continue
            kept.append((rule_id, result))

    # Built from what survived, in first-seen order, so --keep-tag leaves behind
    # no rule that nothing points at.
    rules = []
    index_of = {}
    results = []
    for rule_id, result in kept:
        if rule_id not in index_of:
            index_of[rule_id] = len(rules)
            rules.append(rule_by_id[rule_id])
        result["ruleIndex"] = index_of[rule_id]
        result["ruleId"] = rule_id
        results.append(result)

    if driver is None:
        problems.append("no usable run in any input file")

    if len(results) > MAX_RESULTS:
        problems.append(
            f"{len(results)} results is past the {MAX_RESULTS} this will upload: GitHub keeps the first 5000 "
            f"of any run and discards the rest without saying so. Narrow the scan instead."
        )

    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1

    driver["rules"] = rules
    merged = {
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": [{"tool": {"driver": driver}, "results": results}],
    }

    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(merged, handle)

    kept_note = f" carrying {keep_tag}" if keep_tag else ""
    print(f"merged {len(in_paths)} files into {len(results)} results{kept_note} over {len(rules)} rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
