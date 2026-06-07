#!/usr/bin/env python3
"""
vsp_storage_layout.py — storage-layout regression comparator for Verisphere core.

Pure stdlib. Installed at core/script/storage-layout/storage_layout.py and driven
by check.sh. Subcommands:

  canon          read `forge inspect <C> storageLayout --json` on stdin; emit a
                 normalized baseline JSON on stdout.
  check          read forge JSON on stdin; compare against a saved baseline.
                 exit 0 (match) / 1 (regression; prints diff) / 3 (baseline
                 missing or unreadable) / 2 (internal error).
  selftest       run synthetic layouts through normalize+diff; exit 0/1.
  install-edits  idempotently wire the gate into core/.gitignore and the CI
                 workflow. exit 0 / 2.

WHY normalize. `forge inspect` embeds astId integers in struct/enum type ids
(t_struct(Lot)1234_storage). Those renumber whenever *unrelated* source moves,
producing false "layout changed" alarms — the reason earlier patches compared a
"normalized hash". This comparator strips astId churn and the cosmetic `label`
on TYPE entries, but keeps everything that actually defines layout:
  * every storage variable's (label, slot, offset, type), so a rename, retype,
    move, add, or remove is caught;
  * full struct member layout (expanded from the types map), so a change to a
    struct's INTERNAL fields is caught even though the struct name is unchanged.
Array lengths (e.g. the __gap[500] vs __gap[499] suffix) are NOT astIds and are
deliberately preserved — a __gap shrink IS a layout change worth a re-baseline.
"""

import sys
import os
import json
import re
import hashlib
import argparse
import tempfile
import shutil
import datetime
from pathlib import Path

SCHEMA_VERSION = 2

# Strip the astId that solc/forge append to NAMED type identifiers: structs,
# enums, contracts, and user-defined value types. These integers renumber
# whenever *unrelated* source moves OR across a clean rebuild, with no real
# layout change -- e.g. t_contract(Authority)17856 vs t_contract(Authority)68777,
# or t_struct(Lot)1234_storage vs ...5678_storage. Array LENGTH digits
# (t_array(...)<len>_storage) sit in a different position and are intentionally
# NOT matched, so a __gap[500]->[499] shrink is still caught.
_ASTID = re.compile(r'(t_(?:struct|enum|contract|userDefinedValueType)\([^)]*\))\d+')


def canon_type(tid):
    if tid is None:
        return None
    return _ASTID.sub(r'\1', tid)


def _collect_types(storage_in, types_in):
    """Walk types referenced (transitively) from storage; return canon_tid -> normalized entry."""
    out = {}
    seen = set()

    def visit(tid):
        if tid is None or tid in seen:
            return
        seen.add(tid)
        entry = types_in.get(tid)
        if entry is None:
            return  # primitive forge didn't bother to list; nothing to expand
        norm = {}
        if entry.get("encoding") is not None:
            norm["encoding"] = entry["encoding"]
        if entry.get("numberOfBytes") is not None:
            norm["numberOfBytes"] = str(entry["numberOfBytes"])
        for ref in ("key", "value", "base"):
            v = entry.get(ref)
            if v is not None:
                norm[ref] = canon_type(v)
                visit(v)
        members = entry.get("members")
        if members is not None:
            nm = []
            for m in members:
                nm.append({
                    "label": m.get("label"),
                    "slot": int(m.get("slot", 0)),
                    "offset": int(m.get("offset", 0)),
                    "type": canon_type(m.get("type")),
                })
                visit(m.get("type"))
            nm.sort(key=lambda x: (x["slot"], x["offset"], x["label"] or ""))
            norm["members"] = nm
        # Two original tids that share a canon key must normalize identically;
        # last-writer-wins is therefore safe.
        out[canon_type(tid)] = norm

    for s in storage_in:
        visit(s.get("type"))
    return out


def canonicalize(raw):
    storage_in = raw.get("storage") or []
    types_in = raw.get("types") or {}
    storage = []
    for s in storage_in:
        storage.append({
            "label": s.get("label"),
            "slot": int(s.get("slot", 0)),
            "offset": int(s.get("offset", 0)),
            "type": canon_type(s.get("type")),
        })
    storage.sort(key=lambda x: (x["slot"], x["offset"], x["label"] or ""))
    types = _collect_types(storage_in, types_in)
    return {"storage": storage, "types": types}


def canon_json(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def layout_sha(comparable):
    return hashlib.sha256(canon_json(comparable).encode()).hexdigest()


def make_baseline(comparable, contract, forge_version):
    return {
        "_meta": {
            "contract": contract,
            "forge_version": forge_version,
            "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "schema": SCHEMA_VERSION,
            "layout_sha256": layout_sha(comparable),
            "note": ("Storage-layout regression baseline. Regenerate ONLY for an intended, "
                     "reviewed, upgrade-safe layout change via check.sh --update."),
        },
        "layout": comparable,
    }


def diff_layouts(old, new):
    """Human-readable diff lines. Presentational only; pass/fail is decided by equality."""
    msgs = []

    def index(layout):
        return {(e["slot"], e["offset"]): e for e in layout.get("storage", [])}

    o, n = index(old), index(new)
    for k in sorted(set(o) | set(n)):
        oe, ne = o.get(k), n.get(k)
        if oe and not ne:
            msgs.append(f"  - REMOVED slot {k[0]} off {k[1]}: {oe['label']} : {oe['type']}")
        elif ne and not oe:
            msgs.append(f"  + ADDED   slot {k[0]} off {k[1]}: {ne['label']} : {ne['type']}")
        else:
            if oe["label"] != ne["label"]:
                msgs.append(f"  ~ RENAMED slot {k[0]} off {k[1]}: {oe['label']} -> {ne['label']}")
            if oe["type"] != ne["type"]:
                msgs.append(f"  ~ RETYPED slot {k[0]} off {k[1]} ({ne['label']}): {oe['type']} -> {ne['type']}")

    ot, nt = old.get("types", {}), new.get("types", {})
    for t in sorted(set(ot) | set(nt)):
        oe, ne = ot.get(t), nt.get(t)
        if oe is None or ne is None:
            who = ne or oe
            if who and "members" in who:
                msgs.append(f"  {'ADDED' if oe is None else 'REMOVED'} struct type {t}")
            continue
        if oe != ne and ("members" in oe or "members" in ne):
            msgs.append(f"  ~ struct {t} internal layout changed:")
            om = {(m['slot'], m['offset']): m for m in oe.get('members', [])}
            nm = {(m['slot'], m['offset']): m for m in ne.get('members', [])}
            for mk in sorted(set(om) | set(nm)):
                a, b = om.get(mk), nm.get(mk)
                if a and not b:
                    msgs.append(f"      - {a['label']} : {a['type']} (slot {mk[0]} off {mk[1]})")
                elif b and not a:
                    msgs.append(f"      + {b['label']} : {b['type']} (slot {mk[0]} off {mk[1]})")
                elif a != b:
                    msgs.append(f"      ~ slot {mk[0]} off {mk[1]}: {a['label']}:{a['type']} -> {b['label']}:{b['type']}")
        elif oe != ne:
            msgs.append(f"  ~ type {t} changed: {canon_json(oe)} -> {canon_json(ne)}")
    return msgs


# ---------------------------------------------------------------------------
# Atomic write that preserves the target's mode (lesson 28: os.replace inherits
# the temp file's mode and can silently drop +x).
# ---------------------------------------------------------------------------
def atomic_write(path, content):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        if os.path.exists(path):
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
def cmd_canon(args):
    raw = json.load(sys.stdin)
    comp = canonicalize(raw)
    json.dump(make_baseline(comp, args.contract, args.forge_version), sys.stdout,
              indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def cmd_check(args):
    raw = json.load(sys.stdin)
    new = canonicalize(raw)
    try:
        with open(args.baseline) as f:
            baseline = json.load(f)
    except FileNotFoundError:
        print(f"[FAIL] baseline not found: {args.baseline}", file=sys.stderr)
        return 3
    except Exception as e:  # noqa: BLE001
        print(f"[FAIL] baseline unreadable ({args.baseline}): {e}", file=sys.stderr)
        return 3
    old = baseline.get("layout")
    if old is None:
        print(f"[FAIL] baseline missing 'layout' key: {args.baseline}", file=sys.stderr)
        return 3
    bschema = baseline.get("_meta", {}).get("schema")
    if bschema != SCHEMA_VERSION:
        print(f"[STALE] {args.baseline}: baseline schema v{bschema} != comparator v{SCHEMA_VERSION}; "
              f"re-baseline required (normalization changed)", file=sys.stderr)
        return 4
    stored = baseline.get("_meta", {}).get("layout_sha256")
    if stored and stored != layout_sha(old):
        print(f"[WARN] {args.baseline}: _meta.layout_sha256 disagrees with its own layout "
              f"(hand-edited baseline?)", file=sys.stderr)
    if canon_json(old) == canon_json(new):
        return 0
    name = baseline.get("_meta", {}).get("contract", args.baseline)
    print(f"[FAIL] storage-layout REGRESSION for {name}:", file=sys.stderr)
    for line in diff_layouts(old, new):
        print(line, file=sys.stderr)
    print(f"  baseline_sha={layout_sha(old)}  current_sha={layout_sha(new)}", file=sys.stderr)
    print("  If this change is INTENDED and upgrade-safe (append-only / __gap shrink),", file=sys.stderr)
    print("  re-baseline deliberately: check.sh --update, then review the diff and commit.", file=sys.stderr)
    return 1


# ----- install-edits -----
GITIGNORE_MARKER = "!script/storage-layout/baselines/*.json"
GITIGNORE_BLOCK = (
    "\n# patch_storage_layout_gate: keep storage-layout regression baselines tracked\n"
    "# (the global *.json rule above would otherwise ignore them).\n"
    "!script/storage-layout/baselines/*.json\n"
)
WORKFLOW_ANCHOR = "      - name: Run Forge build\n        run: forge build --sizes\n"
WORKFLOW_STEP = (
    "      - name: Run Forge build\n        run: forge build --sizes\n"
    "\n      - name: Storage layout regression gate\n"
    "        run: bash script/storage-layout/check.sh --check\n"
)
WORKFLOW_MARKER = "Storage layout regression gate"

# foundry.toml: make every `forge build` emit the storageLayout artifact field,
# so CI's clean-checkout build (and any future build) produces it and
# `forge inspect ... storageLayout` never hits the "missing from artifact" cache wart.
FOUNDRY_ANCHOR = "[profile.default]\n"
FOUNDRY_INSERT = ('[profile.default]\n'
                  'extra_output = ["storageLayout"]  '
                  '# patch_storage_layout_gate: emit storage layout for the CI gate\n')


def cmd_install_edits(args):
    gi = Path(args.gitignore)
    txt = gi.read_text()
    if GITIGNORE_MARKER in txt:
        print("[=] .gitignore already un-ignores baselines")
    else:
        if "*.json" not in txt:
            print("[WARN] no '*.json' rule found in .gitignore; adding negation anyway", file=sys.stderr)
        atomic_write(str(gi), txt + GITIGNORE_BLOCK)
        print("[+] .gitignore: added baseline un-ignore")

    wf = Path(args.workflow)
    wtxt = wf.read_text()
    if WORKFLOW_MARKER in wtxt:
        print("[=] workflow already has the storage-layout step")
    else:
        n = wtxt.count(WORKFLOW_ANCHOR)
        if n != 1:
            print(f"[FATAL] workflow build-step anchor found {n}x (expected 1); not editing {wf}", file=sys.stderr)
            return 2
        new = wtxt.replace(WORKFLOW_ANCHOR, WORKFLOW_STEP, 1)
        if WORKFLOW_MARKER not in new:
            print("[FATAL] post-edit marker missing; aborting workflow edit", file=sys.stderr)
            return 2
        atomic_write(str(wf), new)
        print("[+] workflow: inserted 'Storage layout regression gate' step after Forge build")

    # foundry.toml (optional): ensure storageLayout is emitted on every build.
    if getattr(args, "foundry_toml", None):
        ft = Path(args.foundry_toml)
        ftxt = ft.read_text()
        if "extra_output" in ftxt and "storageLayout" in ftxt:
            print("[=] foundry.toml already emits storageLayout")
        elif "extra_output" in ftxt:
            print("[WARN] foundry.toml has an extra_output key but maybe not \"storageLayout\"; "
                  "leaving it as-is — ensure it includes \"storageLayout\"", file=sys.stderr)
        else:
            fn = ftxt.count(FOUNDRY_ANCHOR)
            if fn != 1:
                print(f"[FATAL] [profile.default] anchor found {fn}x in foundry.toml (expected 1)", file=sys.stderr)
                return 2
            atomic_write(str(ft), ftxt.replace(FOUNDRY_ANCHOR, FOUNDRY_INSERT, 1))
            print("[+] foundry.toml: added extra_output = [\"storageLayout\"]")
    return 0


# ----- selftest -----
def _sample(struct_astid, member_extra=False, rename=False, gap_len=499, enum_astid=7, contract_astid=555):
    members = [
        {"astId": 1, "contract": "src/X.sol:X", "label": "staker", "offset": 0, "slot": "0", "type": "t_address"},
        {"astId": 2, "contract": "src/X.sol:X", "label": "amount", "offset": 0, "slot": "1", "type": "t_uint256"},
        {"astId": 3, "contract": "src/X.sol:X", "label": "side", "offset": 0, "slot": "2", "type": f"t_enum(Side){enum_astid}"},
    ]
    if member_extra:
        members.append({"astId": 9, "contract": "src/X.sol:X", "label": "extra", "offset": 0, "slot": "3", "type": "t_uint256"})
    gov = "governanceRenamed" if rename else "governance"
    auth_id = f"t_contract(Authority){contract_astid}"
    struct_id = f"t_struct(Lot){struct_astid}_storage"
    map_id = f"t_mapping(t_uint256,t_struct(Lot){struct_astid}_storage)"
    gap_id = f"t_array(t_uint256){gap_len}_storage"
    storage = [
        {"astId": 8, "contract": "src/X.sol:X", "label": "authority", "offset": 0, "slot": "0", "type": auth_id},
        {"astId": 10, "contract": "src/X.sol:X", "label": gov, "offset": 0, "slot": "1", "type": "t_address"},
        {"astId": 11, "contract": "src/X.sol:X", "label": "posts", "offset": 0, "slot": "2", "type": map_id},
        {"astId": 12, "contract": "src/X.sol:X", "label": "__gap", "offset": 0, "slot": "3", "type": gap_id},
    ]
    types = {
        "t_address": {"encoding": "inplace", "label": "address", "numberOfBytes": "20"},
        "t_uint256": {"encoding": "inplace", "label": "uint256", "numberOfBytes": "32"},
        auth_id: {"encoding": "inplace", "label": "contract Authority", "numberOfBytes": "20"},
        f"t_enum(Side){enum_astid}": {"encoding": "inplace", "label": "enum X.Side", "numberOfBytes": "1"},
        struct_id: {"encoding": "inplace", "label": "struct X.Lot", "numberOfBytes": "96", "members": members},
        map_id: {"encoding": "mapping", "key": "t_uint256", "label": "mapping(uint256 => struct X.Lot)",
                 "numberOfBytes": "32", "value": struct_id},
        gap_id: {"encoding": "inplace", "base": "t_uint256", "label": f"uint256[{gap_len}]",
                 "numberOfBytes": str(32 * gap_len)},
    }
    return {"storage": storage, "types": types}


def cmd_selftest(args):
    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    # canon_type behavior
    check(canon_type("t_struct(Lot)1234_storage") == "t_struct(Lot)_storage", "struct astId not stripped")
    check(canon_type("t_enum(Side)9") == "t_enum(Side)", "enum astId not stripped")
    check(canon_type("t_contract(Authority)17856") == "t_contract(Authority)", "contract astId not stripped")
    check(canon_type("t_userDefinedValueType(UFixed)42") == "t_userDefinedValueType(UFixed)", "UDVT astId not stripped")
    check(canon_type("t_array(t_uint256)499_storage") == "t_array(t_uint256)499_storage",
          "array LENGTH wrongly stripped")
    check(canon_type("t_mapping(t_uint256,t_struct(Lot)55_storage)") ==
          "t_mapping(t_uint256,t_struct(Lot)_storage)", "nested struct astId not stripped")

    base = canonicalize(_sample(100, enum_astid=7, contract_astid=555))

    # (1) astId-only churn (struct + enum + CONTRACT) -> identical comparable.
    #     This is the exact false positive seen on VSPToken: t_contract(Authority)
    #     renumbering across a clean rebuild must NOT register as a regression.
    only_astids = canonicalize(_sample(200, enum_astid=88, contract_astid=99999))
    check(canon_json(base) == canon_json(only_astids),
          "astId-only churn produced a different layout (false positive risk)")

    # (2) added struct member -> different
    extra = canonicalize(_sample(100, member_extra=True))
    check(canon_json(base) != canon_json(extra), "added struct member NOT detected")
    check(any("internal layout changed" in m for m in diff_layouts(base, extra)),
          "struct-internal diff not surfaced")

    # (3) renamed top-level var -> different + reported
    renamed = canonicalize(_sample(100, rename=True))
    check(canon_json(base) != canon_json(renamed), "rename NOT detected")
    check(any("RENAMED" in m for m in diff_layouts(base, renamed)), "rename not surfaced in diff")

    # (4) __gap shrink (append surrogate) -> different
    shrunk = canonicalize(_sample(100, gap_len=498))
    check(canon_json(base) != canon_json(shrunk), "__gap length change NOT detected")

    # (5) identical input -> identical sha (stability)
    check(layout_sha(base) == layout_sha(canonicalize(_sample(100, enum_astid=7))),
          "sha not stable for identical input")

    if failures:
        print("SELFTEST FAILED:", file=sys.stderr)
        for f in failures:
            print("  - " + f, file=sys.stderr)
        return 1
    print("selftest OK (canon_type, astId-churn-stable, struct/rename/gap regressions all detected)")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Verisphere storage-layout regression comparator")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("canon", help="forge JSON (stdin) -> baseline JSON (stdout)")
    c.add_argument("--contract", required=True)
    c.add_argument("--forge-version", default="unknown")
    c.set_defaults(fn=cmd_canon)

    k = sub.add_parser("check", help="forge JSON (stdin) vs baseline file")
    k.add_argument("--baseline", required=True)
    k.set_defaults(fn=cmd_check)

    s = sub.add_parser("selftest")
    s.set_defaults(fn=cmd_selftest)

    e = sub.add_parser("install-edits")
    e.add_argument("--gitignore", required=True)
    e.add_argument("--workflow", required=True)
    e.add_argument("--foundry-toml", default=None)
    e.set_defaults(fn=cmd_install_edits)

    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except BrokenPipeError:
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"[ERROR] {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
