import os
import glob
import subprocess
import pybdsim
import uproot
import ROOT
import sys
import numpy as np
import awkward as ak

# SET THIS ON A PER USER BASIS!!!!
madx_path = os.environ.get("MADX", "/home/jrositas/MuC_Neutrinos/GEANT4/madx_install/madx-linux64-gnu")
# SET THIS ON A PER USER BASIS!!!!

# Constants
m_mu = 0.1056583755  # Muon mass in GeV/c^2
c = 299792458        # Speed of light in m/s
tau_0 = 2.19698e-6   # Natural muon rest lifetime in seconds

def calc_muon_lifetime(energy_GeV, distance_meters, target_decay_fraction=0.632):
    """
    Calculates the optimal biased muon lifetime to maximize decays within a specific distance.
    
    Parameters:
    energy_GeV            : Muon energy in GeV
    distance_meters       : Distance to the sampler/IP in meters
    target_decay_fraction : Fraction of muons you want to decay before reaching the distance.
                            (Default is 0.632, which sets the mean decay length to exactly the distance)
    """
    
    # Kinematics
    gamma = energy_GeV / m_mu
    beta = np.sqrt(1.0 - (1.0 / gamma**2))
    
    # Biased Calculations
    # We want: target_decay_fraction = 1 - exp(-distance / biased_decay_length)
    # Therefore: biased_decay_length = -distance / ln(1 - target_decay_fraction)
    biased_decay_length = -distance_meters / np.log(1.0 - target_decay_fraction)
    
    # biased_decay_length = beta * gamma * c * biased_tau, so
    biased_tau = biased_decay_length / (beta * gamma * c)
    scale_factor = tau_0 / biased_tau # needed later for proper reweighting
    
    # Optimal lifetime for the selected percentage of decays
    return biased_tau, scale_factor

def create_reference_tfs(geom, collider_dir, ring_file, full_twiss_name, energy):
    print(f"Generating reference Twiss file: {full_twiss_name}...")

    output_tfs_path = os.path.abspath(full_twiss_name)
    temp_gen_path = os.path.abspath(f"IMCC{geom}_{energy}GeV_ref_gen.madx")

    madx_script = f"""
    call, file = "{ring_file}";
    beam, particle=muon, mass={m_mu}, charge=-1, energy={energy};
    use, sequence=ring_b1;
    twiss, file="{output_tfs_path}";
    stop;
    """
    # recall that MAD-X doesn't care if you use a muon or antimuon
    with open(f"IMCC{geom}_{energy}GeV_ref_gen.madx", "w") as f:
        f.write(madx_script)
    
    # Run MAD-X silently to generate the reference file
    subprocess.run([madx_path, temp_gen_path], cwd=collider_dir, stdout=subprocess.DEVNULL, 
        stderr=subprocess.DEVNULL)
    os.remove(temp_gen_path)
    print("-> Reference file generated successfully.")

def create_madx_template(geom, collider_dir, ring_file, energy, charge, particle_type, emittance, requested_dist, clean_bool=False):
    # Check if there arlready exists a twiss file for the full ring at your energy
    full_twiss_name = f"{geom}TeV_twiss_{energy}_full.tfs"
    if not os.path.exists(full_twiss_name): # if there isn't make one at your energy
        create_reference_tfs(geom, collider_dir, ring_file, full_twiss_name, energy)

    matter_flag = "M"
    if particle_type == "antimuon":
        matter_flag = "A"
    
    closest_element, actual_dist = find_closest_element(geom, full_twiss_name, requested_dist)
    if clean_bool:
        try:
            os.remove(full_twiss_name)
        except FileNotFoundError:
            print(f"Could not find {full_twiss_name}.")
        except PermissionError:
            print(f"You do not have permission to delete {full_twiss_name}.")
        except IsADirectoryError:
            print("Cannot delete a directory (???)")


    abs_entrance_s = closest_element['s'] - closest_element['l']
    """have to manually calculate where to place the start marker for the simulation
    because sometimes BDSIM gets confused with certain elements being nonphysical
    and/or having zero length. We just do the math ourselves and tell it where to put
    the start marker we want"""

    print(f"\n--- ELEMENT SNAP ---")
    print(f"Requested Distance: {requested_dist:.0f} m")
    print(f"Snapped Distance:   {actual_dist:.3f} m")
    print(f"Start Element:      {closest_element['madx_name']}")
    print(f"Element Exit (S):   {closest_element['s']:.3f} m")
    print(f"Marker Placed At:   {abs_entrance_s:.3f} m")
    print(f"--------------------\n")

    IP_name = "IP2"
    if geom == "3":
        IP_name = "IP[2]" # I don't know why they're named differently like this

    script_path = os.path.abspath(f"IMCC{geom}_{matter_flag}_{energy}GeV_{requested_dist:.0f}m_sim_beam.madx")
    output_tfs_path = os.path.abspath(f"IMCC{geom}_{matter_flag}_{energy}GeV_{requested_dist:.0f}m_twiss.tfs")


    madx_template = f"""! ====================================================================
! MAD-X Script: Extracting {energy} GeV {particle_type.capitalize()} Beam Twiss Parameters
! ====================================================================

! Load the official IMCC {geom} TeV sequence file
call, file = "{ring_file}"; 

! Define the primary beam properties
! ex and ey require GEOMETRIC emittance (m*rad)
beam, particle={particle_type}, mass={m_mu}, charge={charge}, energy={energy}, ex={emittance}, ey={emittance};

! Inject a zero-length marker to capture entrance optics wherever you need them, rather than after
seqedit, sequence=ring_b1;
! Install a marker exactly at the calculated absolute entrance position since sometimes bdsim gets confused
  install, element=START_MARKER, class=marker, at={abs_entrance_s};
! from= dictates the element you begin at. Need to tell at= the name as well so it can put the marker at the beginning
! of the element rather than in the middle as it default to if you say at=0

flatten;
endedit;

! Luckily, it's called ring_b1 in both cases
use, sequence=ring_b1; 

! Save the stable beam optics exactly at the start of our straightaway
savebeta, label=start_optics, place=START_MARKER;

! Calculate the physics for the whole ring silently to populate those saved values
twiss;

! Extract our 200m straightaway, injecting the correct optics at the start
twiss, range=START_MARKER/{IP_name}, beta0=start_optics, file="{output_tfs_path}";

stop;
    """

    # Write the script to disk
    with open(script_path, "w") as f:
        f.write(madx_template)
        
    print(f"\n-> Success: Generated '{script_path}' configured for a {energy} GeV {particle_type}.")
    return script_path, output_tfs_path


def make_element_dict(twiss_name):
    # Read the TFS file
    with open(twiss_name, 'r') as f:
        lines = f.readlines()
        
    # Find column headers
    header_line = next(line for line in lines if line.startswith('*'))
    headers = header_line.split()[1:] # Skip the '*'
    
    name_idx = headers.index('NAME')
    s_idx = headers.index('S')
    l_idx = headers.index('L')
    
    elements = []
    name_counts = {}
    
    # Parse data rows
    for line in lines:
        if line.startswith('@') or line.startswith('*') or line.startswith('$'):
            continue
            
        parts = line.split()
        if len(parts) < max(name_idx, s_idx, l_idx):
            continue
            
        base_name = parts[name_idx].strip('"')
        s_val = float(parts[s_idx])
        l_val = float(parts[l_idx])
        
        # Track occurrences for MAD-X indexing
        name_counts[base_name] = name_counts.get(base_name, 0) + 1
        madx_name = f"{base_name}[{name_counts[base_name]}]"
        
        elements.append({
            'base_name': base_name,
            'madx_name': madx_name,
            's': s_val,
            'l': l_val
        })
    return elements


def find_closest_element(geom, full_twiss_name, requested_dist):
    
    elements = make_element_dict(full_twiss_name)

        
    # Find the IP (default to 10 TeV case, else 3 TeV case)
    # I just took these values from the twiss files, it's not like they're gonna change
    IP_distance = 4334.4 # I could probably do this more dynamically
    if geom == "3": # but it's probably easier to just handle new cases as they arise
        IP_distance = 2169.088539 # rather than trying to preempt them here
    target_s = IP_distance - requested_dist
    
    # Find element closest to target_s
    closest_element = min(elements, key=lambda e: abs(e['s'] - target_s))
    actual_distance = IP_distance - closest_element['s']
    
    return closest_element, actual_distance


def make_run_sim(run_sim_name, beam_file_prefix, sampler_name, sample_all, bias_factor):
    sample_range = "range="+sampler_name if not sample_all else "all"
    
    run_sim_template = f"""! ====================================================================
! BDSIM Simulation Script: Muon Collider Muon Decay & Neutrino Flux
! ====================================================================

! Load the unified lattice files generated by pybdsim
include {beam_file_prefix}.gmad;

! Define Cross-Section Biasing
biasMuMinus: xsecBias, particle="mu-", proc="Decay", xsecfact={bias_factor}, flag=1;
biasMuPlus:  xsecBias, particle="mu+", proc="Decay", xsecfact={bias_factor}, flag=1;

! Set Global Options and Physics Processes
option, physicsList="FTFP_BERT decay",          ! Our standard physics list, also used in GEANT4 detector sim
        storeTrajectoryDepth=2,                 ! Tells simulation to keep the initial particles (1) and decay products
        storeTrajectory=1,                      ! Enables track recording for visual verification
        samplerDiameter = 14.0 * m,             ! Makes our sampler diameter(!) large enough for our detector
        beampipeRadius = 100.0 * mm;            ! Opens the aperture to be wide enough for focusing near the IP.
        ! NB: The size of the beampipe in this region is dynamic and complex. Naïveté is fine for neutrino decay studies

! Establish the active tracking sequence
use,period=lattice;                             ! This tells the simulation that this isn't a ring
sample, {sample_range};                                    ! This places sampling planes AT THE EXIT of each element
    """

    # Write the run_sim.gmad file
    with open(run_sim_name, "w") as f:
        f.write(run_sim_template)


def inject_biasing_to_components(components_filepath):
    """
    Structurally parses the GMAD file and forces biasVacuum into every
    defined component. This should eliminate the risk for encountering an
    unrecognized element and failing to properly attach biasing to it.
    """
    if not os.path.exists(components_filepath):
        raise FileNotFoundError(f"Could not find components file: {components_filepath}")
        
    with open(components_filepath, "r") as f:
        lines = f.readlines()
        
    new_lines = []
    
    # The only things we skip are abstract layout syntax blocks, NOT physical elements
    abstract_keywords = {"line", "sequence", "bunch", "beam", "options"}
    
    for line in lines:
        stripped = line.strip()
        
        # Match standard GMAD component definition structure: "my_element: element_type, ...;"
        if ":" in stripped and stripped.endswith(";") and not stripped.startswith("!"):
            parts = stripped.split(":", 1)
            definition = parts[1].strip()
            
            # Isolate the element type (the word immediately following the colon)
            element_type = definition.replace(";", ",").split(",")[0].strip().lower()
            
            # Inject biasing to everything that isn't an abstract container
            if element_type not in abstract_keywords:
                if "biasVacuum" not in definition:
                    # Snip the closing semicolon, append the bias attribute, and seal it back up
                    idx = line.rfind(";")
                    line = line[:idx] + ', biasVacuum="biasMuMinus biasMuPlus"' + line[idx:]
                    
        new_lines.append(line)
        
    with open(components_filepath, "w") as f:
        f.writelines(new_lines)
    
    print(f"Successfully injected native Geant4 biasing into {components_filepath}!")


def run_sim(madx_file, collider_dir):
    subprocess.run([madx_path, madx_file], cwd=collider_dir, stdout=subprocess.DEVNULL, 
        stderr=subprocess.DEVNULL)
    return


def main():
    print("=== MUON COLLIDER INTERACTIVE NEUTRINO FLUX GENERATION ===")
    no_list = ["N", "n", "no", "No", "NO"]
    yes_list = ["Y", "y", "yes", "YES", "Yes"]
    # User inputs
    geom = input("Select Geometry [3 / 10] (TeV CoM): ").strip()
    energy = 1500 if geom == "3" else 5000

    particle_type = input("Select Particle [muon / antimuon]: ").strip().lower()
    matter_flag = "M"
    if particle_type == "antimuon":
        matter_flag = "A"

    energy_input = input("Enter Max Neutrino Energy to Save (GeV) [blank for no cap]: ").strip()
    energy_cap = float(energy_input) if energy_input else energy

    requested_dist = float(input("Enter target distance from IP (meters) [e.g., 200]: ").strip())

    shots = input("Enter number of particles to fire [e.g., 1000]: ").strip()

    # uses lifetime calculator to automatically generate an optimal lifetime
    mu_life, bias_factor = calc_muon_lifetime(float(energy), float(requested_dist))

    bias_ans = input(f"Use default bias (lifetime = {mu_life:.2e} s)? [Y/N]: ").strip()

    if bias_ans in no_list:
        mu_life = input("Enter preferred muon lifetime (s) (naturally 2.2e-6 s): ").strip()

    sample_ans = input("Sample after all elements? [Y/N]: ")
    sample_bool = True if sample_ans in yes_list else False

    clean = input("Delete intermediate files when finished? [Y/N]: ").strip()
    clean_bool = False if clean in no_list else  True

    norm_emittance = 25e-6 # in meters, taken from Table 1.1.1 of the 2026 IMCC Report
    def calc_emittance(E: float, e_n: float, mass: float = m_mu * 1e9) -> float:
        """
        Calculate Geometric Emittance from IMCC Report
        Table 1.1.1 of IMCC 2026 report: normalized RMS Transverse emittance = 25 micrometers for both cases
        MAD-X needs just geometric emittance.
        """
        gamma: float = E/mass
        beta: float = (1-1/(gamma**2))**0.5
        e_g: float = e_n/(beta * gamma)
        return e_g
    emittance = calc_emittance(float(energy)*10**9, norm_emittance)
    
    # Assign paths to the directories and relevant files for each detector case
    collider_dir = "acc-models-mc/collider/10_TeV/"
    ring_file = "ring_v06.madx"
    if geom == "3":
        collider_dir = "acc-models-mc/collider/3_TeV/"
        ring_file = "MC3.0TeV_v1.2.madx" 
    elif geom != "10":
        print("Warning: Unknown geometry selected. Defaulting to 10 TeV parameters.")

    # Assign particle info baseed on input
    if particle_type == "antimuon":
        charge = 1
    else:
        particle_type = "muon" # Catch typos
        charge = -1
        
    # Define the MAD-X Script 
    sim_template, twiss_output = create_madx_template(geom, collider_dir, ring_file, energy, charge, particle_type, emittance, requested_dist, clean_bool)

    # Run the simulation to generate the twiss file
    run_sim(sim_template, collider_dir)

    beam_file_prefix = f"IMCC{geom}_{matter_flag}_{energy}GeV_{requested_dist:.0f}m_ir"

    # convert the lattice
    pybdsim.Convert.MadxTfs2Gmad(f"{twiss_output}", beam_file_prefix)

    # Construct the output filename prefix
    # Format: {energy}_{M/A}_{shots}_{distance}m
    bdsim_out_prefix = f"IMCC{geom}_{matter_flag}_{energy}GeV_{shots}_{requested_dist:.0f}m_mu"

    # Define the BDSIM command
    print(f"\n-> Launching BDSIM simulation ({shots} events)...")
    print(f"-> Output will be saved to: {bdsim_out_prefix}.root")

    run_sim_name = f"{beam_file_prefix}_run_sim.gmad"

    """
    Below is what happens when root and madx index their elements differently from one another
    """

    elements = make_element_dict(twiss_output) # gets info for all elements
    # The final sampler is always the 6th to last in the 3 TeV case and 4th for 10 TeV
    full_sampler_info = elements[-6] if geom =="3" else elements[-4] # gets info for elements that will be our samplers
    if full_sampler_info["madx_name"][-2] != "0": # if it's the only one in the twiss file
        # our sampler is named uniquely as just its base name
        sampler_name = full_sampler_info["base_name"]
        # and the root file has the period added
        root_sampler_name = sampler_name+"."
    else: # otherwise, it isn't the only one, and we have to handle it more carefully
        # our sampler in the simulation now needs to be identified with its index, the madx name
        sampler_name = full_sampler_info["madx_name"]
        # but its root file handles indexing differently with underscores, and it has a period at the end
        root_sampler_name = sampler_name.translate(str.maketrans({"[" : "_", "]" : "."}))

    make_run_sim(run_sim_name, beam_file_prefix, sampler_name, sample_bool, bias_factor)

    inject_biasing_to_components(f"{beam_file_prefix}_components.gmad")
    
    bdsim_cmd = [
        "bdsim",
        f"--file={run_sim_name}", 
        "--batch",
        f"--ngenerate={shots}",
        f"--outfile={bdsim_out_prefix}"
    ]
    
    # Run BDSIM
    # We don't suppress stdout here so the user can see the Geant4 initialization and progress
    subprocess.run(bdsim_cmd)
    
    print(f"\n=== SIMULATION COMPLETE ===")
    print(f"Simulation output: {bdsim_out_prefix}.root")

    print(f"\n=== CONVERTING TO NEUTRINO FLUX FILE ===")

    # Load the raw BDSIM ROOT file
    file = uproot.open(f"{bdsim_out_prefix}.root")
    tree = file["Event"]

    # Extract the final sampler right before the interaction point
    sampler = tree[root_sampler_name].array()

    # Flatten the jagged arrays
    partID = ak.flatten(sampler.partID)
    part_energy = ak.flatten(sampler.energy)
    x = ak.flatten(sampler.x)
    y = ak.flatten(sampler.y)
    xp = ak.flatten(sampler.xp) # Direction cosine X
    yp = ak.flatten(sampler.yp) # Direction cosine Y
    zp = ak.flatten(sampler.zp) # Direction cosine Z
    t = ak.flatten(sampler.T)   # Global time in seconds (s)
    weight = ak.flatten(sampler.weight)

    # Filter for neutrinos. Can add nu_taus later if you want with 16
    is_neutrino = (abs(partID) == 12) | (abs(partID) == 14)
    # need an energy cap on our neutrinos until we can get GENIE splines over 1 TeV
    is_valid_energy = part_energy <= energy_cap
    nu_mask = is_neutrino & is_valid_energy

    nu_PDG = partID[nu_mask]
    nu_Energy = part_energy[nu_mask]
    nu_weight = weight[nu_mask]
    nu_time_s = t[nu_mask] # save time in nanoseconds. This is time since the
    # beam was fired.

    # Save positions for GENIE in meters ...
    nu_x_m = x[nu_mask]
    nu_y_m = y[nu_mask]
    # Shift Z coordinate to match IP at origin, so we're 6 meters away
    nu_z_m = np.full_like(nu_Energy, -6)

    # ... and convert to millimeters for GEANT4
    nu_x_mm = x[nu_mask] * 1000.0
    nu_y_mm = y[nu_mask] * 1000.0

    # Assign unit momentum information to define the direction of the particle for GEANT4
    nu_px_norm = xp[nu_mask]
    nu_py_norm = yp[nu_mask]
    nu_pz_norm = zp[nu_mask]

    # And assign the full values for GENIE
    nu_px = nu_px_norm * nu_Energy
    nu_py = nu_py_norm * nu_Energy
    nu_pz = nu_pz_norm * nu_Energy

    # Extract information and write to a root file for flux
    g4_output_filename = f"IMCC{geom}_{matter_flag}_{energy_cap:.0f}GeV_{shots}_{requested_dist:.0f}m_G4flux.root"

    with uproot.recreate(g4_output_filename) as out_file:
        # Create the NeutrinoFlux TTree and assign the arrays to branches
        out_file["NeutrinoFlux"] = {
            "PDG": np.asarray(nu_PDG, dtype=np.int32),             # C++ Int_t
            "Energy_GeV": np.asarray(nu_Energy, dtype=np.float64), # C++ Double_t
            "px": np.asarray(nu_px_norm, dtype=np.float64),             # C++ Double_t
            "py": np.asarray(nu_py_norm, dtype=np.float64),             # C++ Double_t
            "pz": np.asarray(nu_pz_norm, dtype=np.float64),             # C++ Double_t
            "x_mm": np.asarray(nu_x_mm, dtype=np.float64),         # C++ Double_t
            "y_mm": np.asarray(nu_y_mm, dtype=np.float64),         # C++ Double_t
            "weight": np.asarray(nu_weight, dtype=np.float64),      # C++ Double_t
            "t_ns": np.asarray(nu_time_s, dtype=np.float64)       # C++ Double_t

        }

    print(f"Success! Exported {len(nu_PDG)} neutrinos to {g4_output_filename} in the NeutrinoFlux tree.")

    # Below is the process for formatting these data to work with GENIE's highly
    # specific and picky gsimple format of root flux files.
    genie_output_filename = f"IMCC{geom}_{matter_flag}_{energy_cap:.0f}GeV_{shots}_{requested_dist:.0f}m_gsimple.root"
    status = ROOT.gSystem.Load("libGTlFlx")
    if status < 0:
        print("Error: Could not load GENIE's libGTlFlx. Check your LD_LIBRARY_PATH!")
        sys.exit(1)

    # Open the file and create the required trees
    f = ROOT.TFile(genie_output_filename, "RECREATE")
    flux_tree = ROOT.TTree("flux", "GENIE GSimple flux tree")
    meta_tree = ROOT.TTree("meta", "GENIE GSimple meta tree")

    # Instantiate the objects 
    entry = ROOT.genie.flux.GSimpleNtpEntry()

    # Create object branches
    flux_tree.Branch("entry", entry)

    # Fill the flux tree
    for i in range(len(nu_PDG)):
        entry.pdg = int(nu_PDG[i])
        entry.wgt = float(nu_weight[i])
        entry.vtxx = float(nu_x_m[i])
        entry.vtxy = float(nu_y_m[i])
        entry.vtxz = float(nu_z_m[i])
        entry.vtxt = float(nu_time_s[i]) *1e-9 # GENIE wants it in seconds
        entry.dist = 0.0   
        entry.px = float(nu_px[i])
        entry.py = float(nu_py[i])
        entry.pz = float(nu_pz[i])
        entry.E = float(nu_Energy[i])
        entry.metakey = 0  
        
        flux_tree.Fill()

    # Fill the meta tree using C++ directly to avoid PyROOT binding failures
    ROOT.gInterpreter.ProcessLine(f"""
    void SetupAndFillMeta(TTree* mtree, double shots, double max_e) {{
        genie::flux::GSimpleNtpMeta* m_entry = new genie::flux::GSimpleNtpMeta();
        mtree->Branch("meta", &m_entry);
        m_entry->metakey = 0;
        m_entry->protons = shots;
        m_entry->maxEnergy = max_e;
        mtree->Fill();
    }}
    """)
    
    # Call the C++ function we just defined, passing the tree and values
    ROOT.SetupAndFillMeta(meta_tree, float(shots), float(max(nu_Energy))) 

    # Write and close
    f.Write()
    f.Close()

    # Clean up the temporary header
    if os.path.exists("gsimple_structs.h"):
        os.remove("gsimple_structs.h")

    print(f"Success! Exported {len(nu_PDG)} neutrinos for GENIE to {genie_output_filename}.")

    if clean_bool:
        for file in glob.glob(f"{beam_file_prefix}*") + glob.glob("AutoDict*")\
        + [sim_template, twiss_output, f"{bdsim_out_prefix}.root"]:
            try:
                os.remove(file)
            except FileNotFoundError:
                print(f"Could not find {file}.")
            except PermissionError:
                print(f"You do not have permission to delete {file}.")
            except IsADirectoryError:
                print("Cannot delete a directory (???)")

    print(f"\nThank you for using Rositas Soft(TM)!")

    
if __name__ == "__main__":
    main()