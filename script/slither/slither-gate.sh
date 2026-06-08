#!/usr/bin/env bash
#
# slither-gate.sh — Slither no-new-findings gate (item 252, step 2).
#
#   --check   (default) run Slither, FAIL if any finding at/above --min-impact
#             is not in the committed baseline. This is the CI gate.
#   --update  run Slither and (re)write the baseline from current findings.
#             Use after intentionally accepting findings. (Supersedes the
#             earlier slither-baseline.sh — this is its --update mode.)
#   --min-impact <High|Medium|Low|Informational|Optimization>
#             gate threshold (default Low → gates High/Medium/Low; Informational
#             and Optimization are recorded in the baseline but not gated).
#
# Resolves Slither from an isolated venv (local) or the PATH (CI, where it is
# pip-installed globally). Compiles via forge. Judges success by the JSON, not
# the exit code (Slither exits non-zero merely when findings exist).
#
set -uo pipefail

VERISPHERE="${VERISPHERE:-$HOME/verisphere}"
CORE="${CORE:-$VERISPHERE/core}"
TOOLS="${TOOLS:-$VERISPHERE/tools}"
VENV="${SLITHER_VENV:-$TOOLS/.slither-venv}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR"                       # committed location: core/script/slither
SUMMARY_PY="${SLITHER_SUMMARY_PY:-$SCRIPT_DIR/slither_summary.py}"
GATE_PY="${SLITHER_GATE_PY:-$SCRIPT_DIR/slither_gate.py}"
REPORT="$OUT/slither-report.json"
BASELINE="$OUT/slither-baseline.json"
RUNLOG="$OUT/slither-run.log"

MODE="check"
MIN_IMPACT="Low"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --update) MODE="update" ;;
    --min-impact) shift; MIN_IMPACT="${1:-Low}" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "[FATAL] unknown arg: $1"; exit 2 ;;
  esac
  shift
done

hr() { printf '%s\n' "=================================================================="; }
[ -d "$CORE" ] || { echo "[FATAL] core repo not found at $CORE"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "[FATAL] python3 not on PATH"; exit 2; }
command -v forge   >/dev/null 2>&1 || { echo "[FATAL] forge not on PATH"; exit 2; }
[ -f "$SUMMARY_PY" ] || { echo "[FATAL] missing $SUMMARY_PY"; exit 2; }
[ -f "$GATE_PY" ]    || { echo "[FATAL] missing $GATE_PY"; exit 2; }

# ---- resolve slither: venv (local) -> PATH (CI) -> install into venv ----
SLITHER_BIN=""
if [ -x "$VENV/bin/slither" ]; then
  SLITHER_BIN="$VENV/bin/slither"
elif command -v slither >/dev/null 2>&1; then
  SLITHER_BIN="$(command -v slither)"
else
  echo "[*] installing slither-analyzer into venv (first local run)…"
  mkdir -p "$TOOLS"
  python3 -m venv "$VENV" || { echo "[FATAL] venv create failed"; exit 3; }
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q slither-analyzer || { echo "[FATAL] slither install failed (pypi egress?)"; exit 3; }
  SLITHER_BIN="$VENV/bin/slither"
fi

hr; echo " slither-gate ($MODE, min-impact=$MIN_IMPACT)"; echo " slither: $("$SLITHER_BIN" --version 2>/dev/null || echo '?')"; hr

# ---- run slither ----
rm -f "$REPORT"
( cd "$CORE" && "$SLITHER_BIN" . --json "$REPORT" --filter-paths "lib/|test/|script/" --exclude-dependencies ) \
  >"$RUNLOG" 2>&1 || true
if [ ! -s "$REPORT" ]; then
  echo "[FATAL] Slither produced no JSON. Tail of run log:"; tail -40 "$RUNLOG" | sed 's/^/   /'
  echo "  (solc? try: $VENV/bin/pip install solc-select && $VENV/bin/solc-select install 0.8.30 && $VENV/bin/solc-select use 0.8.30)"
  exit 4
fi

# ---- dispatch ----
if [ "$MODE" = "update" ]; then
  python3 "$SUMMARY_PY" "$REPORT" --baseline-out "$BASELINE"
  rc=$?
  [ "$rc" -eq 0 ] && echo "[+] baseline updated: $BASELINE  (review & commit it)"
  exit "$rc"
else
  python3 "$GATE_PY" "$REPORT" --baseline "$BASELINE" --min-impact "$MIN_IMPACT"
  exit $?
fi
