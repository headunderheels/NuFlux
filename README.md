# GEANT4_MuC_Nu_Flux_Gen
Script that generates flux files using MAD-X, GEANT4, and BDSIM, specifically for neutrino interaction studies for future Muon Colliders.

These scripts use the official muon collider 3 TeV and 10 TeV ring magnet layout MAD-X files and information to propagate a muon beam using BDSIM to generate muons with a biased lifetime to facilitate decays to neutrinos, which are read out 6 meters from the interaction point. This generates two neutrino flux files, one optimized for GEANT4 investigations and one specifically created to be GENIE-readable. This is all done within an interactive Python wrapper that aims to make the process of generating and saving these files as intuitive and accessible as possible.

## Dependencies and Software
This installation process assumes that you already have Python and ROOT installed and configured for your terminal. You will also need MAD-X, BDSIM, GEANT4, and a public installation of CLHEP.

### CLHEP & GEANT4
While it is assumed that you have GEANT4 installed, you may not have CLHEP configured properly to work with BDSIM. GEANT4 can handle installing a local version of CLHEP that it works with if you don't have it already installed for GEANT4 to reference. However, this won't work with BDSIM, so you need to have CLHEP installed on its own and GEANT4 configured to use that one so BDSIM and GEANT4 are on the same page. If that is true for you, you can skip this step. If not, instructions on making the switch are given here.

Installing CLHEP and configuring with GEANT4:
Begin by navigating to whatever parent directory you'd like this install to go in.
```
mkdir clhep_install && cd clhep_install
git clone https://gitlab.cern.ch/CLHEP/CLHEP.git
mkdir CLHEP-build && cd CLHEP-build
cmake ../CLHEP
make
sudo make install
```
Navigate now to your GEANT4 installation, once inside:
```
cd build
ccmake ..
```
Change the settings to have -DGEANT4_USE_SYSTEM_CLHEP=ON, then press `c`, then `g`.
```
cmake .
make
make install
```
This may take some time, but GEANT4 will work with BDSIM as we install it when you're done.

### Dependencies
BDSIM needs a system parser (`flex bison`) and python bridge (`pybdsim`, `pymadx`) for converting Twiss output files to BDSIM-readable geometry files (`.gmad`). We install those here.
```
sudo apt-get update
sudo apt-get install flex bison cmake build-essential
pip install pybdsim pymadx
```

### BDSIM
Installing BDSIM relies on you having an available version of CLHEP that your GEANT4 is also configured to use and share. If that is not true for you, see step "CLHEP & GEANT4" above.
Begin by navigating to the directory you would like your BDSIM installation to live in
```
git clone --recursive https://github.com/bdsim-collaboration/bdsim.git
mkdir bdsim-build && cd bdsim-build
cmake ../bdsim
make -j$(nproc)
sudo make install
```

### Editing PYBDSIM
BDSIM is designed to work with modern colliders, which, famously, do not shoot muons. Therefore, PYBDSIM only knows natively what "protons", "electrons", and "positrons" are. Therefore, if it tries to do your Twiss parameter conversions and sees that you set the magnets to be calibrated for this mysterious "MUON" particle, it will break. This is solved by making a small edit to the conversion file.
```
nano /home/$USER/.local/lib/python3.10/site-packages/pybdsim/Convert/_MadxTfs2Gmad.py
```
We will be editing the definition of `MadxTfs2GmadBeam`. I use nano here because I know that I can then type `ctrl+/ 736` to go to approximately the correct line to edit, but you may do this in any text editor you like. Locate the block that converts particle names as text to symbolic particle names.
```
    if particle == 'ELECTRON':
        particle = 'e-'
    elif particle == 'POSITRON':
        particle = 'e+'
    elif particle == 'PROTON':
        particle = 'proton'
    else:
        raise ValueError("Unsupported particle " + particle)
```
NOTE THAT THIS FILE IS SPACE IDENTED, so your additions will also need to use spaces rather than tabs, even in VS Code, in my case. We add our muon definitions in a purposely parallel manner like so:
```
    if particle == 'ELECTRON':
        particle = 'e-'
    elif particle == 'POSITRON':
        particle = 'e+'
    elif particle == 'PROTON':
        particle = 'proton'
    elif particle == "ANTIMUON":
        particle = "mu+"
    elif particle == "MUON":
        particle = "mu-"
    else:
        raise ValueError("Unsupported particle " + particle)
```
### MAD-X
Begin by navigating to whatever directory you'd like your MAD-X install to live in
```
mkdir madx_install && cd madx_install
wget https://madx.web.cern.ch/madx/releases/last-rel/madx-linux64-gnu
chmod +x madx-linux64-gnu
./madx-linux64-gnu
```
And then, if you'd like to be able to call MAD-X from anywhere, I recommend putting an alias in your `.bashrc`. I added `export MADX=/PATH/TO/YOUR/madx_install/madx-linux64-gnu` to my `.bashrc` and sourced it, `source ~/.bashrc` to set it.

### Acquiring Accelerator Geometry
Note that this code is NOT future-proofed and does rely on some hardcoded values for the 3 TeV and 10 TeV CoM Muon Collider rings as provided by the IMCC. **It is known that the version this script is written for it v0.6. Work is being done to source v0.8, and the script will be adapted for those files ASAP.** To be able to generate flux using these rings, you will need the accelerator geometries. You are HIGHLY RECOMMENDED to navigate to the top directory of this repository you've cloned (or wherever you are placing `generate_nu_flux.py`) and clone the the IMCC accelerator repo to the same directory. Otherwise, the python script will likely break because it cannot find the geometries.

Once in the same directory as `generate_nu_flux.py`, clone the repository `git clone https://gitlab.cern.ch/acc-models/acc-models-mc.git`.

## Generating Flux
## NOTE, BEFORE YOU CAN USE THE PYTHON WRAPPER, YOU **MUST** CHANGE THE MADX PATH NAME AT THE TOP OF THE PYTHON FILE TO YOUR SPECIFIC MAD-X PATH
```
# SET THIS ON A PER USER BASIS!!!!
madx_path = os.environ.get("MADX", "/home/jrositas/MuC_Neutrinos/GEANT4/madx_install/madx-linux64-gnu")
# SET THIS ON A PER USER BASIS!!!!
```
Once you have changed that line to map to your `$MADX`, you are able to run the simulation using the interactive Python wrapper script.
```
python3 generate_nu_flux
```
You wil be asked a series of questions that will determine the specifics of your flux file:

`Select Geometry [3 / 10] (TeV CoM):` Pick if you want to use the 3 TeV CoM collider geometry or the 10 TeV CoM collider geometry (Default: 10)

`Select Particle [muon / antimuon]:` Pick your particle, muon or antimuon (Default: muon)

`Enter Max Neutrino Energy to Save (GeV) [blank for no cap]:` Pick the maximum neutrino energy you would like to save into your `.root` outputs. Since GENIE (at time of writing) has no cross-section information above 1 TeV, this allows users to cap the neutrino energies saved in the output files to a range of their choosing, with a cap of `1000` used to work with (presently) extant GENIE splines.

`Enter target distance from IP (meters) [e.g., 200]:` Enter how much of the beamline you'd actually like to propagate particles through, measured up to the interaction point (IP) at the center of the detector. Since a neutrino experiment only cares about the neutrino flux incident on the detector, one need not simulate the entire ring to generate an authentic neutrino flux. This parameter allows one to select that relevant range for your investigation

`Enter number of particles to fire [e.g., 1000]:` Enter how many muons you would like to simulate in your specific selected region.

`Use default bias (lifetime = 4.70e-11 s)? [Y/N]:` Select if you would like to use the recommended, default bias provided (Default: Yes). The script contains a calculator which selects a decay lifetime that is optimized around your input distance to simulate. It aims for 63.2% of muons to decay by the time they hit the target to get many neutrinos without the need to simulate a large quantity of muons. Since the actual simulated distance may be slightly different due to the start point snapping to the nearest element, this number may be slightly off, but it is generally quite useful.
If `N` to previous: `Enter preferred muon lifetime (s) (naturally 2.2e-6 s):` Enter the muon lifetime you would like to use instead of the recommended

`Sample after all elements? [Y/N]:` Select if you would like to place samplers after all simulated elements in your section of accelerator (Default: No). This is useful for debugging or extended investigations of fluxes elsewhere but the interaction point, but it is essentially useless for studies at the interaction point as only the sampling plane right before the interaction point is particularly important.

`Delete intermediate files when finished? [Y/N]:` Select if you would like to keep or destroy all of the intermediate files produced when the script runs (Default: Yes). The script generates many intermediate files with quite long file names for unique identification, so it is recommended to remove them all when done to reduce clutter, but they are useful for debugging or peeking at what is happening under the hood.

After you respond to these questions, the script will run automatically. It will first use MAD-X to perform a full Twiss parameter calculation for the whole beam using the emittance defined in the [IMCC 2026 Report](https://indico.cern.ch/event/1513450/attachments/3042022/5374015/ESPPU_Muon_Collider_Backup.pdf) in Table 1.1.1 (more math is contained within the Python script for the intrepid) where the Normalized RMS Transverse Emittance of 25 micrometers is used to find the geometric emittance, which is passed to the simulation scripts. With the output of this full Twiss parameter calculation, the script will locate the detector element closest to your requested distance and record the specific beam parameters there. It will then create a new, shortened Twiss file using MAD-X starting at that specific element and running to the interaction point (IP), using those input beam parameters at that element to ensure an authentic beam profile. It then calls `pybdsim`'s converter to convert this shortened Twiss parameter file to a series of `.gmad` files for BDSIM to use. The script creates a file containing the necessary information for firing your requested particle with its specific beam parameters and inserting a sampler at the penultimate element, in both cases 6 meters from the IP (or it will insert many samplers, if you told it to). Using that file, it will call BDSIM with the number of particles you wished to fire with the appropriately biased lifetime, and you will see the BDSIM/GEANT4 run information display in the output. This generates a `.root` output with all of the particle information. The script opens and reads this output, saving only information for neutrinos at the sampler plane in the penultimate element. It writes the output to two `.root` flux files, one simple one for GEANT4 to use, and one more complex `gsimple` formatted flux file that GENIE can read. Note that the biasing of the muon lifetime is done so that the statistical weights associated with these biased decays are authentically saved to these final files. Unless told otherwise, the script will then delete all of the intermediate files it generated in this process and leave the user with the output flux files.

NB: This script was written for this specific task of generating flux files for these geometries. It was not written with the intention of being used outside of this scope or for edge cases. While much work has been put into it doing its job well and intelligently within the scope of this investigation, little has been done to make it totally resistant to unlikely or unknown errors (like negative distances and similar requests). It does not robustly handle errors. Please do not try to break it, for you will likely succeed.
