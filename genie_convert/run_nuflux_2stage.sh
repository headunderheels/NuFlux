#!/bin/bash
# run_nuflux_2stage.sh
#
# Two-stage NuFlux run:
#   Stage 1 — physics container (nuflux.sif, from-source, ROOT 6.34 WITH PyROOT):
#             runs generate_nu_flux.py -> writes the GEANT4 .root flux file.
#             The script also TRIES to write the GENIE gsimple file and exits 1
#             when it can't load GENIE here — that's EXPECTED and harmless,
#             because the GEANT4 file is fully written before that step.
#   Stage 2 — GENIE container (genie.sif): runs make_gsimple.C via `root -b -q`
#             to build the gsimple file from stage 1's GEANT4 output. No PyROOT
#             needed (GENIE classes reached through ROOT's C++ interpreter).
#
# WHY TWO CONTAINERS: the physics image's ROOT has PyROOT (needed to run the
# Python script) but no GENIE; the GENIE image has GENIE but its ROOT lacks
# PyROOT. Each stage runs in the image equipped for it; a plain .root file is
# the only thing passed between them (both ROOT 6.x, dictionary-compatible).
#
# USAGE:
#   ./run_nuflux_2stage.sh
# Env overrides (defaults in brackets):
#   PHYS_SIF   [./nuflux.sif]     physics/simulation image
#   GENIE_SIF  [./genie.sif]      GENIE image
#   NUFLUX_WORK [./work]           bind-mounted work dir (script + acc-models-mc + output)
#   MACRO_DIR  [dir of this script] location of make_gsimple.C
#
# NOTE: stage 1 is interactive (input() prompts). Run this in a real terminal.

set -uo pipefail

PHYS_SIF="${PHYS_SIF:-./nuflux.sif}"
GENIE_SIF="${GENIE_SIF:-./genie.sif}"
NFWORK="${NUFLUX_WORK:-./work}"
MACRO_DIR="${MACRO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

say () { echo; echo ">>> $*"; }

# --- sanity checks ----------------------------------------------------------
for f in "$PHYS_SIF" "$GENIE_SIF"; do
    [ -f "$f" ] || { echo "ERROR: image not found: $f"; exit 1; }
done
[ -d "$NFWORK" ] || { echo "ERROR: work dir not found: $NFWORK (clone NuFlux + acc-models-mc into it)"; exit 1; }
[ -f "$MACRO_DIR/make_gsimple.C" ] || { echo "ERROR: make_gsimple.C not found in $MACRO_DIR"; exit 1; }
mkdir -p "$NFWORK/output"

# --- record which GEANT4 files exist before, so we can find the new one -----
before="$(ls -1 "$NFWORK"/*G4flux.root "$NFWORK"/output/*G4flux.root 2>/dev/null || true)"

# --- STAGE 1: simulation in the physics container ---------------------------
say "STAGE 1: running the simulation (physics container). Answer the prompts."
say "Note: an 'Could not load GENIE's libGTlFlx' error at the very end is"
say "EXPECTED here — the GEANT4 file is already written; stage 2 does GENIE."
apptainer run --bind "$NFWORK":/work "$PHYS_SIF"
# Deliberately NOT checking stage 1's exit code: the script exits 1 at the
# GENIE step by design in this container. We validate by the output file below.

# --- locate the GEANT4 output the run just produced -------------------------
say "Locating the GEANT4 flux file stage 1 produced..."
after="$(ls -1t "$NFWORK"/*G4flux.root "$NFWORK"/output/*G4flux.root 2>/dev/null || true)"
G4FILE=""
# Prefer a file that wasn't there before; else newest *G4flux.root
for f in $after; do
    if ! grep -qxF "$f" <<< "$before"; then G4FILE="$f"; break; fi
done
[ -z "$G4FILE" ] && G4FILE="$(echo "$after" | head -1)"

if [ -z "$G4FILE" ] || [ ! -f "$G4FILE" ]; then
    echo "ERROR: no *G4flux.root produced by stage 1 — the simulation did not"
    echo "complete its GEANT4 output. Re-run stage 1 alone to see the error:"
    echo "  apptainer run --bind $NFWORK:/work $PHYS_SIF"
    exit 1
fi
say "GEANT4 flux file: $G4FILE"

# --- shots: needed for the gsimple meta tree --------------------------------
# The script bakes the particle count into the filename as
#   IMCC<geom>_<matter>_<cap>GeV_<shots>_<dist>m_flux.root
# Extract <shots> from the filename; fall back to prompting if the pattern differs.
base="$(basename "$G4FILE")"
SHOTS="$(sed -n 's/.*GeV_\([0-9][0-9]*\)_.*/\1/p' <<< "$base")"
if [ -z "$SHOTS" ]; then
    read -r -p "Could not parse shot count from '$base'. Enter number of particles fired: " SHOTS
fi
say "Using shots=$SHOTS for the gsimple meta tree."

# --- BRIDGE: convert RNTuple -> classic TTree in the PHYSICS container -------
# Stage 1's uproot 5.x writes NeutrinoFlux as an RNTuple, which the GENIE
# container's ROOT 6.28 cannot read ("Unknown class ROOT::RNTuple"). Rewrite it
# as a classic TTree here, using the physics image (uproot reads RNTuple fine).
say "Bridging: converting RNTuple output to a classic TTree for ROOT 6.28..."
G4_IN_PHYS="/work/${G4FILE#"$NFWORK"/}"
TTREE_LINE="$(apptainer exec --bind "$NFWORK":/work --bind "$MACRO_DIR":/macro:ro "$PHYS_SIF" \
    bash -lc ". /opt/root/bin/thisroot.sh 2>/dev/null; python3 /macro/rntuple_to_ttree.py '$G4_IN_PHYS'" \
    2>/dev/null | tail -1)"
if [ -z "$TTREE_LINE" ]; then
    echo "ERROR: RNTuple->TTree conversion failed. Run it directly to see why:"
    echo "  apptainer exec --bind $NFWORK:/work --bind $MACRO_DIR:/macro:ro $PHYS_SIF \\"
    echo "    bash -lc 'python3 /macro/rntuple_to_ttree.py $G4_IN_PHYS'"
    exit 1
fi
say "TTree handoff file (in container): $TTREE_LINE"

# --- STAGE 2: gsimple conversion in the GENIE container ---------------------
# Bind the work dir (for the input/output files) AND the macro dir (read-only).
say "STAGE 2: converting to GENIE gsimple format (GENIE container)..."
# Use the TTree file produced above (container path), not the RNTuple original.
G4_IN_CONTAINER="$TTREE_LINE"
OUT_BASENAME="$(basename "${G4FILE%_G4flux.root}_gsimple.root")"

apptainer exec \
    --bind "$NFWORK":/work \
    --bind "$MACRO_DIR":/macro:ro \
    "$GENIE_SIF" \
    bash -lc "
        # The GENIE image ships root.exe (the real ROOT binary) and thisroot.sh,
        # but NOT the 'root' wrapper script — so 'root' is not a command here.
        # Source thisroot.sh for env, then invoke root.exe directly (it runs
        # macros exactly like 'root' does). Fall back across known names.
        if [ -f /opt/root/bin/thisroot.sh ]; then . /opt/root/bin/thisroot.sh; fi
        ROOT_BIN=\"\$(command -v root || command -v root.exe || echo /opt/root/bin/root.exe)\"
        cd /work/output && \"\$ROOT_BIN\" -l -b -q '/macro/make_gsimple.C(\"$G4_IN_CONTAINER\", $SHOTS, \"$OUT_BASENAME\")'
    "
rc=$?

if [ $rc -ne 0 ]; then
    echo
    echo "ERROR: stage 2 (gsimple conversion) failed (exit $rc)."
    echo "Most likely causes: libGTlFlx not on the GENIE image's LD_LIBRARY_PATH,"
    echo "or a genie::flux::GSimpleNtp* field name differs in this GENIE version."
    echo "Debug interactively:"
    echo "  apptainer exec --bind $NFWORK:/work --bind $MACRO_DIR:/macro:ro $GENIE_SIF \\"
    echo "    bash -lc \"root -l /macro/make_gsimple.C\""
    exit $rc
fi

say "DONE. Outputs in $NFWORK/output/:"
ls -1 "$NFWORK"/output/*.root 2>/dev/null
echo
echo "  - *_G4flux.root  : GEANT4-format flux (stage 1)"
echo "  - *_gsimple.root  : GENIE-format flux (stage 2)"
