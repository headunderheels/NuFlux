# NuFlux — containerized muon-collider neutrino flux generator

Containerized repackaging of [GEANT_MiC_Nu_Flux_Gen](https://github.com/jon-rositas/GEANT4_MuC_Nu_Flux_Gen), which propagates a muon beam through the IMCC 3 TeV / 10 TeV collider lattices with BDSIM/GEANT4 and produces neutrino flux files for downstream studies.

The upstream `generate_nu_flux.py` writes **two outputs**: 
- A GEANT4-format `.root`, and
- A GENIE-format "gsimple" `.root`.

The script depends on a large software stack (GEANT4 and BDSIM configured against CLHEP, as well as ROOT, BDSIM, MAD-X, and GENIE). (For now,) this repo runs the workflow as two stages across two images: one image for the bulk of the work (which can be built from `nuflux.def`), and a seperate image hosted at [ghcr.io/lawrenceleejr/g4targetpractice-genie]() for the GENIE conversion step.

Everything here is runnable with Apptainer (e.g. on the OSG cluster).

## Contents

```
nuflux.def            Apptainer definition (CLHEP, GEANT4 11.2.1, ROOT 6.34 w/ PyROOT, BDSIM, MAD-X).
patches/
  patch_pybdsim.py    Teaches pybdsim the MUON/ANTIMUON particles.
genie_convert/        Wrapper + RNTuple->TTree bridge (workaround for issues with ROOT versioning) + GENIE gsimple converter. See genie_convert/README.md.
checks/
  prebuild-checks.sh  Host preflight — run BEFORE building (apptainer, fakeroot,
                      files, network, disk). Nothing compiles.
  validate_stack.sh   Post-build check — run INSIDE the .sif to confirm the
                      stack links and imports.
README-apptainer.md   Full build details, privileges, and caveats.
```

Not tracked in git (see `.gitignore`): `nuflux.sif` (the ~2.2 GB built image),
`work/` (the runtime working set), and `*.root` outputs.

## Quick start

### 1. Pull the images

```bash
# Main image configured in this repository
apptainer pull nuflux.sif oras://ghcr.io/headunderheels/nuflux:0.1.0

# GENIE image (!!! NOT YET LIKELY TO BE STABLE !!!)
apptainer pull ~/images/genie.sif \
  docker://ghcr.io/lawrenceleejr/g4targetpractice-genie:claude-gdml-target-practice-refactor-mrygc9-f1e0631
```


### 2. Set up the working set

Clone the accelerator geometry into `work/` — this is where the pipeline reads inputs and writes outputs. The core script (`generate_nu_flux.py`) ships in this repo and is copied in automatically when you run.

```bash
mkdir -p work && git clone https://gitlab.cern.ch/acc-models/acc-models-mc.git work/acc-models-mc
```

Point `NUFLUX_WORK` at this directory in the next step.

### 3. Run the two-stage pipeline

```bash
export GENIE_SIF=~/images/genie.sif
export NUFLUX_WORK=$PWD/work
./genie_convert/run_nuflux_2stage.sh
```

You'll answer a few interactive prompts (geometry, particle, energy, distance,
particle count), then both flux files land in `work/output/`.