# Two-stage NuFlux run (GEANT4 file + GENIE gsimple file)

`generate_nu_flux.py` produces two outputs: a GEANT4-format `.root` and a
GENIE-format "gsimple" `.root`. Producing the second one needs GENIE's
`libGTlFlx` **and** the ability to call GENIE from ROOT. No single available
image does both cleanly:

- The **physics image** (`nuflux.sif`, built from `nuflux.def`) has ROOT 6.34
  **with PyROOT** — needed to run the Python script — but no GENIE.
- The **GENIE image** (`genie.sif`) has GENIE and its ROOT 6.28, but that ROOT
  was built **without PyROOT**, so `import ROOT` fails there and the script
  can't run in it. (We confirmed this: no PyROOT module, and pip `cppyy`
  collides with the image's Cling.)

So we split the work across both images and pass a plain `.root` file between
them (both ROOT 6.x, dictionary-compatible):

```
 ┌─────────────── nuflux.sif (physics) ───────────────┐
 │ generate_nu_flux.py:                                │
 │   MAD-X -> pybdsim -> BDSIM/GEANT4 -> read output   │
 │   -> write  *_flux.root   (GEANT4 format) ✅        │
 │   -> tries GENIE step, exits 1 here (no GENIE) — OK │
 └─────────────────────────────────────────────────────┘
                        │  *_flux.root
                        ▼
 ┌─────────────── genie.sif (GENIE) ──────────────────┐
 │ make_gsimple.C via `root -b -q` (C++, no PyROOT):   │
 │   read *_flux.root -> reconstruct GENIE inputs      │
 │   -> write *_gsimple.root  (GENIE format) ✅        │
 └─────────────────────────────────────────────────────┘
```

The stage-1 GEANT4 file is fully written and closed *before* the script's
GENIE step, so stage 1 exiting at that step is expected and leaves a complete
handoff file.

## Files

- `make_gsimple.C` — ROOT C++ macro (runs in the GENIE image). Reads the
  `NeutrinoFlux` tree from the GEANT4 file and writes the gsimple `flux`/`meta`
  trees, reproducing the exact field mapping and unit conversions from
  `generate_nu_flux.py` (mm→m, normalized→raw momentum, t·1e-9, vtxz=−6). No
  PyROOT — GENIE's classes are reached through ROOT's C++ interpreter.
- `run_nuflux_2stage.sh` — wrapper that runs stage 1 (interactive) then stage 2
  automatically, locates the GEANT4 file, parses the shot count from its
  filename for the meta tree, and reports both outputs.

## Prerequisites

- `nuflux.sif` built from `nuflux.def` (the from-source stack, ROOT 6.34).
- `genie.sif` — pull once from GHCR:
  `apptainer pull genie.sif docker://ghcr.io/lawrenceleejr/g4targetpractice-genie:<tag>`
- A `work/` dir with the script + geometry:
  ```bash
  git clone https://github.com/headunderheels/NuFlux.git work
  cd work && git clone https://gitlab.cern.ch/acc-models/acc-models-mc.git && mkdir -p output && cd ..
  ```

## Run

```bash
./run_nuflux_2stage.sh
```

Overrides (env vars): `PHYS_SIF`, `GENIE_SIF`, `WORK`, `MACRO_DIR`.

Or run the two stages by hand:
```bash
# stage 1 (answer prompts; ignore the GENIE-load error at the end)
apptainer run --bind ./work:/work nuflux.sif

# stage 2 (replace <file> and <shots>)
apptainer exec --bind ./work:/work --bind "$PWD":/macro:ro genie.sif \
  bash -lc 'cd /work/output && root -l -b -q "/macro/make_gsimple.C(\"/work/output/<file>_flux.root\", <shots>)"'
```

## First-run gotchas (expected, debuggable)

- **`libGTlFlx` not found in stage 2** → the GENIE image's `LD_LIBRARY_PATH`
  isn't reaching its own libs under `apptainer exec`. Try `apptainer exec ...
  bash -lc` (login shell, as the wrapper does) so the image's `%environment`
  is applied, or prepend `/opt/genie/lib` to `LD_LIBRARY_PATH`.
- **A `genie::flux::GSimpleNtpEntry` field name error** → this GENIE version
  (3.04.02) may name a field differently than the script assumed. Open
  `make_gsimple.C`, adjust the offending `entry->...` line to match, re-run
  stage 2 only (no need to redo the simulation).
- **Momentum/vertex look wrong** → check the conversion lines in
  `make_gsimple.C` against `generate_nu_flux.py`; they must stay in sync if the
  upstream script changes how it stores the GEANT4 branches.
