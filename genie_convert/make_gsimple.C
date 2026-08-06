// make_gsimple.C
//
// STAGE 2 of the two-stage NuFlux workflow: convert the GEANT4-format neutrino
// flux file (written by generate_nu_flux.py in the physics container) into the
// GENIE "gsimple" format, INSIDE the GENIE container.
//
// WHY THIS IS A C++ ROOT MACRO (not Python): the GENIE image's ROOT 6.28 was
// built WITHOUT PyROOT, so `import ROOT` is unavailable there. But the GENIE
// classes (genie::flux::GSimpleNtpEntry/Meta) are C++ and reachable through
// ROOT's C++ interpreter directly. Running as a ROOT macro needs no PyROOT.
// (The original script even used gInterpreter.ProcessLine for the meta tree,
// noting "PyROOT binding failures" — doing the whole thing in C++ is cleaner.)
//
// This reproduces the exact field mapping and unit conversions from
// generate_nu_flux.py's GENIE block, reading them back out of the GEANT4 file:
//   GENIE field   <- GEANT4 branch        conversion
//   pdg           <- PDG
//   wgt           <- weight
//   E             <- Energy_GeV
//   vtxx, vtxy    <- x_mm, y_mm            / 1000  (mm -> m)
//   vtxz          <- (constant -6 m; the script sets nu_z_m = -6 for all)
//   vtxt          <- t_ns                  * 1e-9  (matches script's `*1e-9`)
//   px, py, pz    <- px, py, pz (normed)   * Energy_GeV  (norm -> raw)
//   dist          <- 0.0
//   metakey       <- 0
// meta tree: protons = <shots>, maxEnergy = max(E over all entries).
//
// USAGE (inside the GENIE container):
//   root -l -b -q 'make_gsimple.C("/work/output/IMCC10_..._flux.root", <shots>)'
// or let the wrapper (run_gsimple.sh) fill in the arguments. Output filename is
// derived from the input by replacing a trailing "_flux"/"" with "_gsimple".
//
// NOTE: libGTlFlx must be loadable (the GENIE image provides it on its
// LD_LIBRARY_PATH). If ROOT can't find it, check the container's env.

#include <string>
#include <iostream>
#include <algorithm>

void make_gsimple(const char* in_path, double shots, const char* out_path = "") {
    // --- Load GENIE's flux library (provides genie::flux::GSimpleNtp*) -------
    if (gSystem->Load("libGTlFlx") < 0) {
        std::cerr << "ERROR: could not load libGTlFlx. Is this running inside "
                     "the GENIE container with its LD_LIBRARY_PATH?" << std::endl;
        gApplication->Terminate(1);
        return;
    }

    // --- Open the stage-1 GEANT4 file and its NeutrinoFlux tree --------------
    TFile* fin = TFile::Open(in_path, "READ");
    if (!fin || fin->IsZombie()) {
        std::cerr << "ERROR: cannot open input file: " << in_path << std::endl;
        gApplication->Terminate(1);
        return;
    }
    TTree* t = dynamic_cast<TTree*>(fin->Get("NeutrinoFlux"));
    if (!t) {
        std::cerr << "ERROR: no 'NeutrinoFlux' tree in " << in_path
                  << " — is this the GEANT4 output from stage 1?" << std::endl;
        gApplication->Terminate(1);
        return;
    }

    // Branch buffers — types match how generate_nu_flux.py wrote them
    // (PDG as Int_t; everything else Double_t).
    Int_t    b_PDG;
    Double_t b_E, b_px, b_py, b_pz, b_x_mm, b_y_mm, b_weight, b_t_ns;
    t->SetBranchAddress("PDG",        &b_PDG);
    t->SetBranchAddress("Energy_GeV", &b_E);
    t->SetBranchAddress("px",         &b_px);     // normalized in the G4 file
    t->SetBranchAddress("py",         &b_py);
    t->SetBranchAddress("pz",         &b_pz);
    t->SetBranchAddress("x_mm",       &b_x_mm);
    t->SetBranchAddress("y_mm",       &b_y_mm);
    t->SetBranchAddress("weight",     &b_weight);
    t->SetBranchAddress("t_ns",       &b_t_ns);

    const Long64_t n = t->GetEntries();
    if (n == 0) {
        std::cerr << "WARNING: input NeutrinoFlux tree has 0 entries — writing "
                     "an empty gsimple file." << std::endl;
    }

    // --- Derive output filename if not given --------------------------------
    std::string outname = out_path;
    if (outname.empty()) {
        outname = in_path;
        // strip directory for a local output, then swap suffix
        auto slash = outname.find_last_of('/');
        if (slash != std::string::npos) outname = outname.substr(slash + 1);
        auto pos = outname.rfind("_G4flux.root");
        if (pos != std::string::npos) outname.replace(pos, std::string::npos, "_gsimple.root");
        else {
            pos = outname.rfind(".root");
            if (pos != std::string::npos) outname.replace(pos, std::string::npos, "_gsimple.root");
            else outname += "_gsimple.root";
        }
    }

    // --- Create the gsimple output ------------------------------------------
    TFile* fout = TFile::Open(outname.c_str(), "RECREATE");
    TTree* flux_tree = new TTree("flux", "GENIE GSimple flux tree");
    TTree* meta_tree = new TTree("meta", "GENIE GSimple meta tree");

    genie::flux::GSimpleNtpEntry* entry = new genie::flux::GSimpleNtpEntry();
    flux_tree->Branch("entry", &entry);

    double max_e = 0.0;

    for (Long64_t i = 0; i < n; ++i) {
        t->GetEntry(i);

        entry->pdg   = b_PDG;
        entry->wgt   = b_weight;
        entry->vtxx  = b_x_mm / 1000.0;      // mm -> m
        entry->vtxy  = b_y_mm / 1000.0;      // mm -> m
        entry->vtxz  = -6.0;                 // script sets nu_z_m = -6 for all
        entry->vtxt  = b_t_ns * 1e-9;        // mirrors the script's `*1e-9`
        entry->dist  = 0.0;
        entry->px    = b_px * b_E;           // normalized -> raw momentum
        entry->py    = b_py * b_E;
        entry->pz    = b_pz * b_E;
        entry->E     = b_E;
        entry->metakey = 0;

        if (b_E > max_e) max_e = b_E;

        flux_tree->Fill();
    }

    // --- Meta tree (same fields the script set) -----------------------------
    genie::flux::GSimpleNtpMeta* m_entry = new genie::flux::GSimpleNtpMeta();
    meta_tree->Branch("meta", &m_entry);
    m_entry->metakey   = 0;
    m_entry->protons   = shots;
    m_entry->maxEnergy = max_e;
    meta_tree->Fill();

    fout->Write();
    fout->Close();
    fin->Close();

    std::cout << "Success! Wrote " << n << " neutrinos to " << outname
              << " (gsimple format)." << std::endl;
}
