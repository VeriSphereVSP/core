# Storage-layout regression gate

`check.sh` runs `forge inspect <C> storageLayout` for every UUPS contract
(VSPToken + the five GovernedUpgradeable children) and diffs the normalized
layout against the committed baseline in `baselines/<Contract>.json`.

- CI runs `check.sh --check` on every push (see `.github/workflows/test.yml`).
- Run it yourself before any UUPS upgrade ceremony (PATCH-17-DEPLOY pre-flight).

The comparator (`storage_layout.py`) strips `forge` astId churn
(`t_struct(Lot)1234_storage` -> `t_struct(Lot)_storage`) but keeps every
variable’s (label, slot, offset, type) and full struct member layout. Renames,
retypes, moves, adds, removes, and `__gap` length changes all FAIL the gate.

## Intended layout change

A legitimate, upgrade-safe change (append a new var + shrink `__gap`) WILL fail
the gate by design. To accept it deliberately:

    bash script/storage-layout/check.sh --update   # regenerates ALL baselines
    git diff script/storage-layout/baselines        # REVIEW the change
    git add script/storage-layout/baselines && git commit

Re-baselining is the explicit human acknowledgement that the change is intended.
Never re-baseline blindly to make red CI go green.
