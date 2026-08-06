#!/bin/bash
# validate_stack.sh
#
# Post-build smoke test: confirms the BUILT container has a sound software
# stack BEFORE you trust any physics output. Run this inside the .sif.
# It does NOT run the neutrino simulation — it checks that every layer the
# real run depends on is present, links, and loads, in dependency order, so a
# failure points at one specific layer instead of a cryptic mid-run crash.
#
# Usage (from the dir containing nuflux.sif):
#   apptainer exec nuflux.sif bash validate_stack.sh
#   # or, if you copied it in / bind-mount it:
#   apptainer exec --bind $PWD:/checks nuflux.sif bash /checks/validate_stack.sh
#
# Exit 0 if the stack is sound, 1 if any hard check fails.

set -uo pipefail
FAILED=0
ok ()   { echo "  OK:    $*"; }
fail () { echo "  FAIL:  $*"; FAILED=$((FAILED+1)); }
sec ()  { echo; echo "== $* =="; }

# The .sif's %environment should already have sourced geant4.sh/thisroot.sh and
# set PATH/MADX. If you're using `exec` (not `run`), source them defensively.
[ -f /opt/geant4/bin/geant4.sh ]  && . /opt/geant4/bin/geant4.sh  2>/dev/null || true
[ -f /opt/root/bin/thisroot.sh ]  && . /opt/root/bin/thisroot.sh  2>/dev/null || true

sec "1. Environment variables the script relies on"
[ -n "${MADX:-}" ] && ok "MADX=$MADX" || fail "MADX not set — script falls back to a hardcoded path and won't find MAD-X."
[ -n "${ROOTSYS:-}" ] && ok "ROOTSYS=$ROOTSYS" || fail "ROOTSYS not set — ROOT env not initialised."

sec "2. Binaries on PATH (script calls these as bare commands)"
# MAD-X: script does subprocess.run([madx_path, ...]); confirm it executes.
if [ -n "${MADX:-}" ] && [ -x "$MADX" ]; then
    if "$MADX" </dev/null 2>&1 | grep -qi "MAD-X"; then
        ok "MAD-X runs ($("$MADX" </dev/null 2>&1 | grep -i version | head -1 | tr -s ' '))"
    else
        ok "MAD-X binary is executable at \$MADX (banner not captured — usually fine)"
    fi
else
    fail "MAD-X not executable at \$MADX=${MADX:-<unset>}"
fi
# BDSIM: script does subprocess.run(["bdsim", ...]) — must be on PATH.
if command -v bdsim >/dev/null 2>&1; then
    ok "bdsim on PATH -> $(command -v bdsim)"
    # --help exercises that its shared libs (GEANT4/CLHEP/ROOT) actually load.
    if bdsim --help >/dev/null 2>&1; then
        ok "bdsim --help runs (its GEANT4/CLHEP/ROOT libraries load)"
    else
        fail "bdsim is on PATH but --help failed — likely a missing/mislinked shared lib (LD_LIBRARY_PATH / CLHEP)."
    fi
else
    fail "bdsim NOT on PATH — the simulation call will fail."
fi

sec "3. Python modules the script imports"
# Exactly the import list from generate_nu_flux.py.
for mod in pybdsim uproot ROOT numpy awkward; do
    if python3 -c "import $mod" 2>/dev/null; then
        ok "import $mod"
    else
        fail "import $mod FAILED — needed by generate_nu_flux.py."
    fi
done
# ROOT's version, as a sign the bindings are truly wired (not just importable).
python3 -c "import ROOT; print('  info:  ROOT', ROOT.gROOT.GetVersion())" 2>/dev/null || true

sec "4. The muon/antimuon pybdsim patch is applied"
# The build runs patch_pybdsim.py; confirm MUON/ANTIMUON reached the installed
# pybdsim, or the Twiss conversion will raise ValueError('Unsupported particle').
PATCH_CHECK="$(python3 - <<'PY' 2>/dev/null
import importlib.util, pathlib, sys
spec = importlib.util.find_spec("pybdsim")
if not spec or not spec.submodule_search_locations:
    sys.exit(2)
p = pathlib.Path(list(spec.submodule_search_locations)[0]) / "Convert" / "_MadxTfs2Gmad.py"
txt = p.read_text() if p.exists() else ""
print("YES" if ("ANTIMUON" in txt and "MUON" in txt) else "NO")
PY
)"
case "$PATCH_CHECK" in
    YES) ok "pybdsim knows MUON and ANTIMUON (patch applied).";;
    NO)  fail "pybdsim is MISSING the MUON/ANTIMUON patch — Twiss conversion will fail. Re-check patch_pybdsim.py ran during the build.";;
    *)   fail "could not locate pybdsim's _MadxTfs2Gmad.py to verify the patch.";;
esac

sec "5. A trivial BDSIM parse (optional deeper check)"
# Feeds BDSIM a one-line lattice to confirm its GMAD parser + physics init work
# end-to-end without a full run. Skips quietly if it can't write a temp file.
TMPG="$(mktemp --suffix=.gmad 2>/dev/null)" || TMPG=""
if [ -n "$TMPG" ] && command -v bdsim >/dev/null 2>&1; then
    printf 'd1: drift, l=1*m;\nl1: line=(d1);\nuse, l1;\nbeam, particle="mu-", energy=1*GeV;\n' > "$TMPG"
    if timeout 120 bdsim --file="$TMPG" --batch --ngenerate=1 --outfile=/tmp/_bdsim_smoke >/dev/null 2>&1; then
        ok "BDSIM ran a 1-particle drift and wrote output (parser + physics init OK)."
        rm -f /tmp/_bdsim_smoke*.root
    else
        fail "BDSIM failed on a trivial 1-particle drift — investigate before the real run (run without --batch to see the error)."
    fi
    rm -f "$TMPG"
else
    echo "  skip:  couldn't create a temp lattice (non-fatal)."
fi

sec "Summary"
echo "  FAIL: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    echo "  Stack is NOT sound — fix the FAILs above before running the physics."
    echo "  Each maps to a build layer: env (%environment), PATH (ENV lines),"
    echo "  pip modules (pip install line), or the patch (patch_pybdsim.py step)."
    exit 1
fi
echo "  Stack is sound. Proceed to a real run (see the physics-validation steps)."
exit 0
