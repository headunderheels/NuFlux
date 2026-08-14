# NuFlux | muon collider lattice neutrino flux file generator

`Now containerized!`

This repository provides an (Apptainer-based) containerized repackaging of [GEANT4_MuC_Nu_Flux_Gen](https://github.com/jon-rositas/GEANT4_MuC_Nu_Flux_Gen), which propagates a muon beam through the IMCC 3 TeV / 10 TeV collider lattices using BDSIM/GEANT4, producing neutrino flux files for downstream studies.

Each run writes two outputs: a GEANT4-format `.root` and a GENIE-format "gsimple" `.root`.

## Contents

```
nuflux.def            Apptainer definition in case you care to build the image yourself.
generate_nu_flux.py   The simulation script.
examples/             Annotated run configuration files.
patches/              `pybdsim` MUON/ANTIMUON patch applied during the build.
checks/
  prebuild-checks.sh  Pre-build checks (if building the image yourself).
  postbuild-checks.sh Run inside the .sif to confirm the stack links and imports.
```

## Quick start

### 1. Pull the pre-built image

```bash
apptainer pull nuflux.sif oras://ghcr.io/headunderheels/nuflux:0.1.0
```

Or build it yourself: see [Building](#building).

### 2. Clone the lattice geometry

```bash
git clone https://gitlab.cern.ch/acc-models/acc-models-mc.git geometry/acc-models-mc
```

### 3. Configure your run

Each run has its own subdirectory containing a configuration and outputs (once they are produced). Create a run directory and populate it:

```bash
mkdir -p runs/my-run
cp examples/template.conf runs/my-run/run.conf
```

Be sure to edit `run.conf` as desired *before* your run!

### 4. Run

```bash
apptainer exec \
  --bind "$PWD/runs/my-run":/work \
  --bind "$PWD/geometry/acc-models-mc":/geometry \
  --bind "$PWD/generate_nu_flux.py":/opt/generate_nu_flux.py \
  nuflux.sif \
  bash -c '. /opt/geant4/bin/geant4.sh && . /opt/root/bin/thisroot.sh && cd /work && python3 /opt/generate_nu_flux.py'
```

Both `.root` files land in `runs/my-run/`.

Three separate mounts, each with one job: the run directory is the working directory, the geometry is read-only and shared, and the script is supplied from the repo so you can edit it without rebuilding.

## Building the image

`Probably don't do this! :D`

```bash
./checks/prebuild-checks.sh
apptainer build --fakeroot nuflux.sif nuflux.def
apptainer exec --bind $PWD:/checks nuflux.sif bash /checks/checks/postbuild-checks.sh
```

The build compiles GEANT4, BDSIM, LHAPDF, Pythia6, and GENIE from source and takes hours. See [README-apptainer.md](README-apptainer.md) for the stage
layout, version pins, and the non-obvious fixes baked in.

## Caveats

- **Geometry version.** The script expects IMCC v0.6 lattice filenames. If `acc-models-mc` has moved on, pin a commit.
- The pipeline produces well-formed output; whether the flux is correct for a given configuration is a domain judgment.
