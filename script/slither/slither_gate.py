#!/usr/bin/env python3
"""Slither no-new-findings gate (item 252, step 2).

Compares the current Slither report against the committed baseline and FAILS if
any finding at or above --min-impact is present now but not in the baseline.
Resolved findings (in baseline, gone now) are reported as info, not a failure.

Shares fingerprinting / scoping with slither_summary.py so the keys match.

Usage:
    slither_gate.py <slither-report.json> --baseline <baseline.json> [--min-impact Low]
"""
import argparse
import sys

from slither_summary import IMPACT_ORDER, first_location, fingerprint, in_scope, load


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--baseline", required=True)
    ap.add_argument(
        "--min-impact",
        default="Low",
        choices=IMPACT_ORDER,
        help="gate on findings at this impact or higher (default: Low; "
        "Informational/Optimization are not gated by default — too churny)",
    )
    args = ap.parse_args()

    data = load(args.report)
    if not data.get("success", False):
        print("[FATAL] Slither did not complete successfully: " + str(data.get("error")))
        sys.exit(3)

    try:
        base = load(args.baseline)
    except FileNotFoundError:
        print("[FATAL] baseline not found: {} (run with --update first)".format(args.baseline))
        sys.exit(3)
    base_fps = {f["fingerprint"] for f in base.get("findings", [])}

    cutoff = IMPACT_ORDER.index(args.min_impact)

    def gated(imp):
        return imp in IMPACT_ORDER and IMPACT_ORDER.index(imp) <= cutoff

    dets = (data.get("results") or {}).get("detectors") or []
    current_fps = set()
    new = []
    for d in dets:
        if not in_scope(d):
            continue
        imp = d.get("impact", "Informational")
        fp = fingerprint(d)
        current_fps.add(fp)
        if not gated(imp):
            continue
        if fp not in base_fps:
            fn, ln, name = first_location(d)
            new.append((imp, d.get("check", "?"), "{}:{}".format(fn, ln), name, fp))

    resolved = base_fps - current_fps

    if new:
        print("[FAIL] {} NEW Slither finding(s) at impact >= {} (not in baseline):".format(
            len(new), args.min_impact))
        for imp, chk, loc, name, fp in sorted(new):
            print("   [{}] {}  {}  ({})  fp={}".format(imp, chk, loc, name, fp))
        print("")
        print(" If a finding is intentional or a false positive, review it, then accept it")
        print(" into the baseline:  bash script/slither/slither-gate.sh --update   (then commit).")
        sys.exit(1)

    msg = "[OK] No new Slither findings at impact >= {} (baseline fingerprints: {}).".format(
        args.min_impact, len(base_fps))
    if resolved:
        msg += " {} baseline finding(s) no longer present — consider --update to shrink the baseline.".format(
            len(resolved))
    print(msg)


if __name__ == "__main__":
    main()
