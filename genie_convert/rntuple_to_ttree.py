#!/usr/bin/env python3
"""
rntuple_to_ttree.py — bridge between stage 1 and stage 2.

WHY THIS EXISTS: stage 1 runs in the physics container with uproot 5.7.5, where
`out_file["NeutrinoFlux"] = {dict of arrays}` writes an RNTuple (uproot 5.x
default), NOT a classic TTree — despite the upstream script's comment. Stage 2's
GENIE container has ROOT 6.28, which predates RNTuple and errors with
"Unknown class ROOT::RNTuple" when trying to read it.

This runs IN THE PHYSICS CONTAINER (which can read the RNTuple with uproot) and
rewrites the same data as a classic TTree, which BOTH ROOT 6.28 and 6.34 read.
Output goes to <input>_ttree.root, leaving the original untouched.

Reads and writes with uproot only — no PyROOT needed, no ROOT version concerns.

Usage (inside the physics container):
    python3 rntuple_to_ttree.py /work/IMCC..._G4flux.root
Prints the path of the TTree file it wrote (last line) for the wrapper to grab.
"""
import sys
import uproot
import numpy as np

if len(sys.argv) < 2:
    sys.exit("usage: rntuple_to_ttree.py <input_G4flux.root> [output.root]")

in_path = sys.argv[1]
out_path = sys.argv[2] if len(sys.argv) > 2 else in_path.replace(".root", "_ttree.root")

# --- read the NeutrinoFlux data, whether it's an RNTuple or a TTree ----------
f = uproot.open(in_path)
if "NeutrinoFlux" not in [k.split(";")[0] for k in f.keys()]:
    sys.exit(f"ERROR: no 'NeutrinoFlux' object in {in_path}. keys={f.keys()}")

obj = f["NeutrinoFlux"]
# uproot exposes both RNTuple and TTree via .arrays(); library='np' -> dict of
# numpy arrays keyed by field name.
data = obj.arrays(library="np")

# Expected branches (from generate_nu_flux.py). If the upstream field set
# changes, this dict-comprehension still copies whatever is present.
expected = ["PDG", "Energy_GeV", "px", "py", "pz", "x_mm", "y_mm", "weight", "t_ns"]
missing = [b for b in expected if b not in data]
if missing:
    print(f"WARNING: expected branches missing from input: {missing}", file=sys.stderr)

# --- write a CLASSIC TTree (uproot 5.x: mktree forces TTree, not RNTuple) -----
# Preserve dtypes: PDG as int32, the rest float64 (matches how stage 1 built them).
branch_types = {}
for name, arr in data.items():
    branch_types[name] = arr.dtype

with uproot.recreate(out_path) as fout:
    fout.mktree("NeutrinoFlux", branch_types)
    fout["NeutrinoFlux"].extend({name: data[name] for name in data})

n = len(next(iter(data.values()))) if data else 0
print(f"Converted {n} entries from RNTuple to classic TTree.", file=sys.stderr)
# Last line = the output path, for the wrapper to capture.
print(out_path)
