#!/usr/bin/env bash
#
# check.sh — storage-layout regression gate for Verisphere core UUPS contracts.
# Installed at core/script/storage-layout/check.sh. Run by CI and before any
# UUPS upgrade ceremony (PATCH-17-DEPLOY pre-flight).
#
# Modes:
#   --check           (default) compare each contract to its committed baseline;
#                     FAIL (exit 1) on mismatch OR on a missing baseline.
#   --update          (re)generate ALL baselines from current source. Use ONLY
#                     for an intended, reviewed, upgrade-safe layout change.
#   --update-missing  generate baselines only for contracts that lack one; check
#                     the rest. Used by the installer for first-run bootstrap.
#
# Read-only against chain/DB/network: `forge inspect ... storageLayout` is a pure
# local compile. No RPC.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_ROOT="$(cd "$HERE/../.." && pwd)"
PY="$HERE/storage_layout.py"
BASELINE_DIR="$HERE/baselines"

# Every concrete contract intended to sit behind a UUPS proxy. The abstract base
# GovernedUpgradeable is inherited by the five children and is never deployed
# standalone, so its layout is covered transitively — do not list it.
CONTRACTS=(
  "src/VSPToken.sol:VSPToken"
  "src/StakeEngine.sol:StakeEngine"
  "src/PostRegistry.sol:PostRegistry"
  "src/LinkGraph.sol:LinkGraph"
  "src/ScoreEngine.sol:ScoreEngine"
  "src/ProtocolViews.sol:ProtocolViews"
)

MODE="check"
case "${1:-}" in
  ""|--check) MODE="check" ;;
  --update) MODE="update" ;;
  --update-missing) MODE="update-missing" ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "[FATAL] unknown arg: $1 (use --check | --update | --update-missing)" >&2; exit 2 ;;
esac

command -v forge >/dev/null 2>&1 || { echo "[FATAL] forge not on PATH" >&2; exit 2; }
[ -f "$PY" ] || { echo "[FATAL] comparator not found: $PY" >&2; exit 2; }
mkdir -p "$BASELINE_DIR"

FORGE_VERSION="$(forge --version 2>/dev/null | head -1 || echo unknown)"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Capture forge inspect output to $TMPD/forge.json. No silent fallback to an
# empty body: a forge failure is surfaced loudly and aborts.
CLEANED=0

_try_inspect() {  # $1 = contract id ; writes JSON to $TMPD/forge.json
  ( cd "$CORE_ROOT" && forge inspect "$1" storageLayout --json ) >"$TMPD/forge.json" 2>"$TMPD/forge.err" && return 0
  # older foundry spelled the field "storage"
  ( cd "$CORE_ROOT" && forge inspect "$1" storage --json ) >"$TMPD/forge.json" 2>>"$TMPD/forge.err" && return 0
  return 1
}

get_layout() {  # $1 = contract id
  local id="$1"
  if _try_inspect "$id"; then return 0; fi
  # Foundry sometimes serves a cached artifact that lacks the storageLayout
  # field; the error itself suggests `forge clean`. Self-heal once (forcing a
  # layout-emitting rebuild) and retry, rather than dying on a caching wart.
  if [ "$CLEANED" -eq 0 ] && grep -qiE "storage layout missing|caching issue|forge clean" "$TMPD/forge.err"; then
    echo "[*] storage layout missing from build cache — running 'forge clean' + rebuild once, then retrying" >&2
    ( cd "$CORE_ROOT" && forge clean && forge build --extra-output storageLayout ) >/dev/null 2>>"$TMPD/forge.err" || true
    CLEANED=1
    if _try_inspect "$id"; then return 0; fi
  fi
  return 1
}

run_check() {  # $1 = contract id, $2 = baseline path ; sets LAST_RC
  if python3 "$PY" check --baseline "$2" <"$TMPD/forge.json"; then LAST_RC=0; else LAST_RC=$?; fi
  return 0
}

write_baseline() {  # $1 = contract id, $2 = baseline path
  if python3 "$PY" canon --contract "$1" --forge-version "$FORGE_VERSION" \
      <"$TMPD/forge.json" >"$2.tmp"; then
    mv "$2.tmp" "$2"
  else
    rm -f "$2.tmp"
    echo "[FATAL] could not canonicalize layout for $1" >&2
    return 1
  fi
}

regressions=0
missing=0
checked=0
written=0

echo "[*] storage-layout gate ($MODE) — forge: $FORGE_VERSION"
echo "[*] core root: $CORE_ROOT"
echo "----"

for id in "${CONTRACTS[@]}"; do
  name="${id##*:}"
  base="$BASELINE_DIR/$name.json"

  if ! get_layout "$id"; then
    echo "[FATAL] forge inspect failed for $id:" >&2
    sed 's/^/    forge: /' "$TMPD/forge.err" >&2
    exit 2
  fi
  if [ ! -s "$TMPD/forge.json" ]; then
    echo "[FATAL] empty storage layout for $id" >&2
    exit 2
  fi

  case "$MODE" in
    update)
      write_baseline "$id" "$base"; echo "[BASELINE] wrote   $name"; written=$((written + 1)) ;;
    update-missing)
      if [ -f "$base" ]; then
        run_check "$id" "$base"
        case "$LAST_RC" in
          0) echo "[OK]   $name"; checked=$((checked + 1)) ;;
          4) write_baseline "$id" "$base"; echo "[BASELINE] regenerated $name (schema bump)"; written=$((written + 1)) ;;
          *) echo "[FAIL] $name (existing baseline mismatch — NOT auto-overwritten; use --update if intended)"; regressions=$((regressions + 1)) ;;
        esac
      else
        write_baseline "$id" "$base"; echo "[BASELINE] created $name"; written=$((written + 1))
      fi ;;
    check)
      if [ ! -f "$base" ]; then
        echo "[FAIL] $name: baseline MISSING ($base) — run 'check.sh --update-missing' and commit"
        missing=$((missing + 1)); continue
      fi
      run_check "$id" "$base"
      case "$LAST_RC" in
        0) echo "[OK]   $name"; checked=$((checked + 1)) ;;
        4) echo "[FAIL] $name: baseline schema OUTDATED — run 'check.sh --update' and commit"; regressions=$((regressions + 1)) ;;
        *) regressions=$((regressions + 1)) ;;
      esac ;;
  esac
done

echo "----"
if [ "$MODE" = "check" ]; then
  if [ "$regressions" -gt 0 ] || [ "$missing" -gt 0 ]; then
    echo "[VERDICT] STORAGE-LAYOUT GATE FAILED (regressions=$regressions missing=$missing ok=$checked)"
    exit 1
  fi
  echo "[VERDICT] storage-layout gate PASS ($checked/${#CONTRACTS[@]} contracts match baseline)"
  exit 0
fi

echo "[VERDICT] baselines written=$written, checked=$checked, regressions=$regressions"
[ "$regressions" -gt 0 ] && exit 1
exit 0
