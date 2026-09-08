"""Merge one-run SARIF files into a single run, for one code scanning upload.

Trivy scans one image per invocation and emits one SARIF run each. GitHub keys
a code scanning alert's lifecycle to the (category, rule, location) it arrived
under, and closes an alert when a later upload for the same category no longer
carries it. Uploading a file per image would mean a category per image, and a
category whose images all came back clean would never be uploaded again — so
every alert it ever raised would sit open forever, describing a CVE that was
patched months ago.

One run, one category, one upload: the whole picture is replaced every time, and
a CVE that has been fixed closes by itself.

Usage: sarif-merge.py <out.sarif> <in.sarif>...

A rule is identified by its `id`, which for Trivy is the CVE, and the same CVE
turns up in several images. The first spelling wins and every later result is
repointed at it, because `ruleIndex` is an offset into the run's own rules array
and concatenating two runs' results without remapping would silently relabel
findings with whatever rule happened to sit at that offset.
"""

import json
import sys


def load_run(path):
    """The single run in a SARIF file, or a reason it cannot be used."""
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)

    runs = document.get("runs") or []
    if len(runs) != 1:
        return None, f"{path}: expected exactly one run, found {len(runs)}"
    return runs[0], None


def main():
    if len(sys.argv) < 3:
        print("usage: sarif-merge.py <out.sarif> <in.sarif>...", file=sys.stderr)
        return 2

    out_path = sys.argv[1]
    in_paths = sys.argv[2:]

    problems = []
    driver = None
    rule_index_by_id = {}
    rules = []
    results = []

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

        run_rules = tool_driver.get("rules") or []
        remap = {}
        for position, rule in enumerate(run_rules):
            rule_id = rule.get("id")
            if not rule_id:
                problems.append(f"{path}: a rule at index {position} has no id")
                continue
            if rule_id not in rule_index_by_id:
                rule_index_by_id[rule_id] = len(rules)
                rules.append(rule)
            remap[position] = rule_index_by_id[rule_id]

        for result in run.get("results") or []:
            old_index = result.get("ruleIndex")
            if old_index is None:
                # Nothing to remap, and GitHub resolves the rule by ruleId.
                results.append(result)
                continue
            if old_index not in remap:
                problems.append(f"{path}: a result points at rule index {old_index}, which the file does not define")
                continue
            result["ruleIndex"] = remap[old_index]
            results.append(result)

    if driver is None:
        problems.append("no usable run in any input file")

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

    print(f"merged {len(in_paths)} files into {len(results)} results over {len(rules)} rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
