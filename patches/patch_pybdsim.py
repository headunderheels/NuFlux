#!/usr/bin/env python3
"""
Applies the muon/antimuon patch to pybdsim's _MadxTfs2Gmad.py, as described
in the NuFlux README. pybdsim only knows electron/positron/proton natively;
this adds MUON -> mu- and ANTIMUON -> mu+.

Run after `pip install pybdsim`. Finds the installed package location rather
than hardcoding a Python version/path, and matches the particle-name
if/elif chain with a regex rather than an exact string, since pybdsim's
formatting could shift between releases.
"""
import importlib.util
import re
import sys

spec = importlib.util.find_spec("pybdsim")
if spec is None or not spec.submodule_search_locations:
    sys.exit("pybdsim is not installed — run `pip install pybdsim` first.")

pkg_dir = list(spec.submodule_search_locations)[0]
target = f"{pkg_dir}/Convert/_MadxTfs2Gmad.py"

with open(target, "r") as f:
    content = f.read()

if "ANTIMUON" in content:
    print(f"Muon patch already present in {target}, skipping.")
    sys.exit(0)

# Match the final `elif particle == 'PROTON': particle = 'proton'` branch
# and the `else: raise ValueError(...)` that follows it, tolerant of
# quote style and exact whitespace.
pattern = re.compile(
    r"(?P<proton_branch>elif\s+particle\s*==\s*['\"]PROTON['\"]\s*:\s*\n"
    r"\s*particle\s*=\s*['\"]proton['\"]\s*\n)"
    r"(?P<indent>\s*)else\s*:\s*\n"
    r"\s*raise\s+ValueError\(",
)

match = pattern.search(content)
if not match:
    sys.exit(
        f"Could not locate the expected particle-name if/elif chain in {target}.\n"
        "pybdsim's internals may have changed since this patch was written — "
        "open the file and apply the README's edit by hand:\n"
        "https://github.com/headunderheels/NuFlux#editing-pybdsim"
    )

indent = match.group("indent")
insertion = (
    f"{indent}elif particle == \"ANTIMUON\":\n"
    f"{indent}    particle = \"mu+\"\n"
    f"{indent}elif particle == \"MUON\":\n"
    f"{indent}    particle = \"mu-\"\n"
)

patched = content[: match.end("proton_branch")] + insertion + content[match.end("proton_branch"):]

with open(target, "w") as f:
    f.write(patched)

print(f"Patched {target} for MUON/ANTIMUON support.")
