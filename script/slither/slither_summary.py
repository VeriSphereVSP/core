#!/usr/bin/env python3
"""Summarize a Slither JSON report and write a stable baseline.

Read-only: consumes the report produced by `slither . --json <report>`, prints a
severity-categorized summary scoped to first-party code (src/), and writes a
baseline.json of stable finding fingerprints for a later no-new-findings gate.

Usage:
    slither_summary.py <slither-report.json> --baseline-out <baseline.json>
"""
import argparse
import datetime
import hashlib
import json
import sys

IMPACT_ORDER = ["High", "Medium", "Low", "Informational", "Optimization"]
# Results whose elements live entirely under these prefixes are out of scope
# (dependencies, tests, deploy scripts). Slither --filter-paths should already
# drop most; this is a belt-and-suspenders net.
FILTER_PREFIXES = ("lib/", "test/", "script/", "node_modules/", "dependencies/")


def load(path):
    with open(path) as f:
        return json.load(f)


def first_location(det):
    for el in det.get("elements", []):
        sm = el.get("source_mapping") or {}
        fn = sm.get("filename_relative") or sm.get("filename_short") or ""
        lines = sm.get("lines") or []
        if fn:
            return fn, (lines[0] if lines else 0), el.get("name", "")
    return "", 0, ""


def in_scope(det):
    els = det.get("elements", [])
    if not els:
        return True
    for el in els:
        sm = el.get("source_mapping") or {}
        fn = sm.get("filename_relative") or ""
        if fn and not fn.startswith(FILTER_PREFIXES):
            return True
    return False


def fingerprint(det):
    """Line-INDEPENDENT stable id: hash of (check | file | element-name).

    Deliberately NOT Slither's own `id`, which embeds line numbers and so churns
    on every reformat (and we reformat with forge fmt). This trades exact
    per-line granularity — two findings of the same check in the same element
    collapse to one fingerprint — for robustness to fmt/edits, which is the right
    call for a no-new-findings gate."""
    fn, _, name = first_location(det)
    basis = "{}|{}|{}".format(det.get("check", ""), fn, name)
    return hashlib.sha1(basis.encode()).hexdigest()[:16]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--baseline-out", required=True)
    args = ap.parse_args()

    data = load(args.report)
    if not data.get("success", False):
        print("[FATAL] Slither did not complete successfully:")
        print("  " + str(data.get("error")))
        sys.exit(3)

    dets = (data.get("results") or {}).get("detectors") or []
    scoped = [d for d in dets if in_scope(d)]
    filtered_out = len(dets) - len(scoped)

    by_impact = {k: 0 for k in IMPACT_ORDER}
    by_check = {}
    findings = []
    for d in scoped:
        imp = d.get("impact", "Informational")
        by_impact[imp] = by_impact.get(imp, 0) + 1
        chk = d.get("check", "?")
        entry = by_check.setdefault(chk, {"impact": imp, "count": 0})
        entry["count"] += 1
        fn, ln, name = first_location(d)
        findings.append(
            {
                "fingerprint": fingerprint(d),
                "check": chk,
                "impact": imp,
                "confidence": d.get("confidence", ""),
                "location": "{}:{}".format(fn, ln) if fn else "",
                "element": name,
            }
        )

    bar = "=" * 66
    print(bar)
    print(" Slither baseline summary   (scope: src/ — excludes lib/test/script)")
    print(bar)
    total = len(scoped)
    print(" findings in scope: {}   (out-of-scope filtered: {})".format(total, filtered_out))
    print(" by impact:")
    for k in IMPACT_ORDER:
        print("   {:<14} {}".format(k, by_impact.get(k, 0)))

    if by_check:
        print(" by detector:")

        def sort_key(kv):
            imp = kv[1]["impact"]
            return (IMPACT_ORDER.index(imp) if imp in IMPACT_ORDER else 99, -kv[1]["count"])

        for chk, v in sorted(by_check.items(), key=sort_key):
            print("   {:<36} {:<14} {}".format(chk, v["impact"], v["count"]))

    hi = [f for f in findings if f["impact"] in ("High", "Medium")]
    if hi:
        print(" HIGH / MEDIUM detail (review these first):")
        for f in hi:
            print(
                "   [{}] {}  {}  ({} confidence)".format(
                    f["impact"], f["check"], f["location"], f["confidence"]
                )
            )
    else:
        print(" No High/Medium findings in scope.")
    print(bar)

    baseline = {
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "src (excludes lib,test,script)",
        "total": total,
        "by_impact": by_impact,
        "findings": sorted(findings, key=lambda f: f["fingerprint"]),
    }
    with open(args.baseline_out, "w") as f:
        json.dump(baseline, f, indent=2, sort_keys=True)
        f.write("\n")
    print("[+] baseline written: {}  ({} findings)".format(args.baseline_out, total))


if __name__ == "__main__":
    main()
