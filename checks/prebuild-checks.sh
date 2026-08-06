#!/bin/bash
# prebuild_network_check.sh
#
# Before launching the multi-hour from-source build (nuflux.def), confirm the
# machine can reach everything the build fetches: the ubuntu:22.04 base from
# Docker Hub, the CLHEP/GEANT4/BDSIM/geometry git repos, the ROOT and MAD-X
# downloads, and PyPI. Catches a blocked network before you wait on a build
# that would only fail partway through.
#
# Fast, read-only: HEAD requests / ls-remote / a tiny Docker Hub manifest
# fetch. Downloads nothing large. Run before `apptainer build ... nuflux.def`.
#
# Usage:
#   chmod +x prebuild_network_check.sh
#   ./prebuild_network_check.sh
#
# Exit 0 if all reachable, 1 if any critical fetch is blocked.

set -uo pipefail
FAILED=0
ok ()   { echo "  OK:    $*"; }
fail () { echo "  FAIL:  $*"; FAILED=$((FAILED+1)); }
sec ()  { echo; echo "== $* =="; }

# HTTP reachability via HEAD; treats any HTTP response (even 403/404) as
# "network reached" vs. a connection/DNS failure which means blocked.
http_reach () {  # $1 = url, $2 = label
    local code
    code="$(curl -s -o /dev/null -I -w '%{http_code}' --connect-timeout 15 "$1" 2>/dev/null)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        ok "$2 reachable (HTTP $code)"
    else
        fail "$2 UNREACHABLE (no HTTP response — DNS/connection blocked)"
    fi
}

# -----------------------------------------------------------------------------
sec "1. Docker Hub — nuflux.def's ubuntu:22.04 BASE comes from here"
# This is the load-bearing one: if Docker Hub is broadly blocked, the
# from-source build fails at bootstrap (its ubuntu:22.04 base won't pull).
if command -v apptainer &>/dev/null; then
    TMPSIF="$(mktemp --suffix=.sif)"; rm -f "$TMPSIF"
    if timeout 120 apptainer pull "$TMPSIF" docker://ubuntu:22.04 >/dev/null 2>&1; then
        ok "docker://ubuntu:22.04 pulled — Docker Hub reachable; the base image is fetchable."
        rm -f "$TMPSIF"
    else
        fail "docker://ubuntu:22.04 did NOT pull — Docker Hub is blocked for you."
        echo "         => nuflux.def (Bootstrap: docker / From: ubuntu:22.04) will ALSO fail"
        echo "            at bootstrap. See 'If Docker Hub is blocked' at the end."
        rm -f "$TMPSIF"
    fi
else
    fail "apptainer not found — can't test the base image pull."
fi

# -----------------------------------------------------------------------------
sec "2. Source repos cloned during the build (git)"
# --depth 1 ls-remote is a metadata-only reachability test, no checkout.
git_reach () {  # $1 = repo, $2 = ref, $3 = label
    if timeout 60 git ls-remote --heads --tags "$1" "$2" >/dev/null 2>&1; then
        ok "$3 — $1 ($2) reachable"
    else
        fail "$3 — $1 ($2) UNREACHABLE"
    fi
}
git_reach https://gitlab.cern.ch/CLHEP/CLHEP.git           CLHEP_2_4_7_1 "CLHEP (CERN GitLab)"
git_reach https://github.com/Geant4/geant4.git            v11.2.1       "GEANT4 (GitHub)"
git_reach https://github.com/bdsim-collaboration/bdsim.git develop      "BDSIM (GitHub)"
git_reach https://gitlab.cern.ch/acc-models/acc-models-mc.git HEAD      "acc-models-mc geometry (CERN GitLab)"
git_reach https://github.com/headunderheels/NuFlux.git    HEAD          "NuFlux script (GitHub)"

# -----------------------------------------------------------------------------
sec "3. Binary downloads (wget targets)"
# Read the ROOT URL straight out of nuflux.def so this check can't drift out
# of sync with what the build actually fetches (respects an APPTAINERENV_ROOT_URL
# / ROOT_URL override if you've set one). Falls back to the def's default.
ROOT_URL_CHECK="${APPTAINERENV_ROOT_URL:-${ROOT_URL:-}}"
if [ -z "$ROOT_URL_CHECK" ]; then
    ROOT_URL_CHECK="$(sed -n 's/.*ROOT_URL="${ROOT_URL:-\(https[^}]*\)}".*/\1/p' nuflux.def 2>/dev/null | head -1)"
fi
if [ -n "$ROOT_URL_CHECK" ]; then
    http_reach "$ROOT_URL_CHECK" "ROOT binary (root.cern) [from nuflux.def]"
else
    fail "could not read ROOT URL from nuflux.def — check it manually."
fi
http_reach "https://madx.web.cern.ch/madx/releases/last-rel/madx-linux64-gnu"              "MAD-X binary (madx.web.cern.ch)"

# -----------------------------------------------------------------------------
sec "4. PyPI (pip install pybdsim pymadx uproot numpy awkward)"
http_reach "https://pypi.org/simple/pybdsim/" "PyPI"

# -----------------------------------------------------------------------------
sec "Summary"
echo "  FAIL: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    echo
    echo "  Some fetches are blocked. Building will fail at whichever step hits a"
    echo "  blocked host. Options:"
    echo "    - If ONLY Docker Hub (section 1) failed: ask your admins whether an"
    echo "      internal mirror/proxy exists, or build the .sif on a machine with"
    echo "      open network and copy the portable .sif to the cluster to RUN."
    echo "    - If CERN GitLab / GitHub / root.cern / PyPI are blocked: same fix —"
    echo "      the cluster likely requires a proxy (set http_proxy/https_proxy) or"
    echo "      an internal mirror. Check with your cluster admins; the network"
    echo "      settings are theirs to change, not something the build can work"
    echo "      around."
    exit 1
fi
echo
echo "  All fetches reachable. The from-source build has a clear network path:"
echo "    apptainer build --fakeroot nuflux.sif nuflux.def"
echo "  Expect a long GEANT4 compile. A %post failure late in the build restarts"
echo "  from the failed section (Apptainer doesn't cache %post like Docker layers),"
echo "  so consider building on a node you won't lose to a timeout."
exit 0

#!/bin/bash
# prebuild_checks_apptainer.sh
#
# Fast, LOCAL pre-build checks — run before `apptainer build ... nuflux.def`.
# None of these compile anything; they catch the cheap, common failures
# (missing files, no build privilege, no disk) before you spend time on the
# long from-source build.
#
# Run from the repo root (so it finds nuflux.def and patches/). The optional
# argument is the two-stage run's work dir, only used by the informational
# §5 check — the build itself does not need it.
#
# Usage:
#   chmod +x checks/prebuild_checks_apptainer.sh
#   ./checks/prebuild_checks_apptainer.sh
#   ./checks/prebuild_checks_apptainer.sh /path/to/work   # if work dir isn't ./work
#
# Exit status: 0 if all hard checks pass, 1 if any FAIL. WARNs don't fail.

set -uo pipefail

DEF="${DEF:-nuflux.def}"           # override: DEF=other.def ./checks/prebuild_checks_apptainer.sh
WORKDIR="${1:-./work}"             # two-stage run work dir (informational only)
FAILED=0
WARNED=0

ok ()   { echo "  OK:   $*"; }
warn () { echo "  WARN: $*"; WARNED=$((WARNED+1)); }
fail () { echo "  FAIL: $*"; FAILED=$((FAILED+1)); }
sec ()  { echo; echo "== $* =="; }

# -----------------------------------------------------------------------------
sec "1. Apptainer present"
if command -v apptainer &>/dev/null; then
    ok "$(apptainer --version)"
elif command -v singularity &>/dev/null; then
    warn "found 'singularity', not 'apptainer' — commands below use 'apptainer';"
    warn "either alias it, or substitute 'singularity' throughout."
else
    fail "neither apptainer nor singularity on PATH — nothing can build."
fi

# -----------------------------------------------------------------------------
sec "2. Build files in the expected layout"
# nuflux.def + patches/patch_pybdsim.py (the %files path is relative to the
# build dir, so it must resolve from wherever you run `apptainer build`).
if [ -f "$DEF" ]; then
    ok "$DEF present"
else
    fail "$DEF not found in $(pwd) — run this from the repo root, or set DEF=."
fi
if [ -f patches/patch_pybdsim.py ]; then
    ok "patches/patch_pybdsim.py present"
else
    fail "patches/patch_pybdsim.py missing — the %files section will fail to copy it."
fi

# -----------------------------------------------------------------------------
sec "3. Definition file sanity"
if [ -f "$DEF" ]; then
    # Cheap structural checks — not a real parser, but catches obvious breakage.
    grep -q '^Bootstrap:' "$DEF" && ok "has Bootstrap header" \
        || fail "no 'Bootstrap:' line — not a valid .def"
    grep -q '^From:' "$DEF" && ok "has From line" \
        || fail "no 'From:' line."
    for s in '%post' '%runscript'; do
        grep -q "^$s" "$DEF" && ok "has $s section" || warn "no $s section in $DEF"
    done
    # The patch script must be parseable Python before it's baked in.
    if command -v python3 &>/dev/null; then
        if python3 -c "import ast,sys; ast.parse(open('patches/patch_pybdsim.py').read())" 2>/dev/null; then
            ok "patch_pybdsim.py parses as Python"
        else
            fail "patch_pybdsim.py has a syntax error — fix before building."
        fi
    fi
fi

# -----------------------------------------------------------------------------
sec "4. Build privilege — decides your build command"
# Building a .sif needs fakeroot, real sudo, or a remote builder (NOT Docker).
# Probe fakeroot with a trivial throwaway build.
PROBE_DEF="$(mktemp --suffix=.def)"
PROBE_SIF="$(mktemp --suffix=.sif)"; rm -f "$PROBE_SIF"
cat > "$PROBE_DEF" <<'EOF'
Bootstrap: docker
From: alpine:latest
%post
    echo FAKEROOT_PROBE_OK
EOF
if command -v apptainer &>/dev/null; then
    if apptainer build --fakeroot "$PROBE_SIF" "$PROBE_DEF" >/dev/null 2>&1; then
        ok "--fakeroot works -> build with:  apptainer build --fakeroot nuflux.sif $DEF"
    else
        warn "--fakeroot did NOT work. Your options, in order:"
        warn "  a) sudo:    sudo apptainer build nuflux.sif $DEF   (if you have sudo)"
        warn "  b) remote:  apptainer remote login && apptainer build --remote nuflux.sif $DEF"
        warn "  c) build on any machine where (a) or (b) works, copy the .sif over."
        if apptainer remote list >/dev/null 2>&1; then
            warn "  (a remote endpoint IS configured — option (b) is likely available.)"
        fi
    fi
fi
rm -f "$PROBE_DEF" "$PROBE_SIF"

# -----------------------------------------------------------------------------
sec "5. Host working set for the two-stage run (informational)"
# NOT needed to BUILD nuflux.sif — only to RUN via genie_convert/. The wrapper
# bind-mounts $WORKDIR to /work; generate_nu_flux.py resolves geometry via
# CWD-relative paths, so the script + acc-models-mc must sit together there.
if [ -d "$WORKDIR" ]; then
    ok "work dir exists: $WORKDIR"
    [ -f "$WORKDIR/generate_nu_flux.py" ] \
        && ok "generate_nu_flux.py present" \
        || warn "generate_nu_flux.py not in $WORKDIR — clone NuFlux into it (only needed at RUN time, not build)."
    if [ -d "$WORKDIR/acc-models-mc" ]; then
        ok "acc-models-mc/ present"
        # The upstream README warns the script targets IMCC geometry v0.6 and
        # names these exact lattice files. If either is missing, the geometry
        # repo has moved on — pin a commit/tag before running.
        G10="$WORKDIR/acc-models-mc/collider/10_TeV/ring_v06.madx"
        G3="$WORKDIR/acc-models-mc/collider/3_TeV/MC3.0TeV_v1.2.madx"
        [ -f "$G10" ] && ok "10 TeV lattice ring_v06.madx present" \
            || warn "MISSING $G10 — acc-models-mc may have moved past v0.6 (upstream warns of this). Pin a commit/tag."
        [ -f "$G3" ] && ok "3 TeV lattice MC3.0TeV_v1.2.madx present" \
            || warn "MISSING $G3 — check the 3 TeV path/filename against your acc-models-mc checkout."
    else
        warn "acc-models-mc/ not in $WORKDIR — clone it INSIDE the work dir, beside the script (only needed at RUN time)."
    fi
    [ -d "$WORKDIR/output" ] \
        && ok "output/ dir present (single --bind ./work:/work covers writes)" \
        || warn "no $WORKDIR/output — create it so results have somewhere to land: mkdir -p $WORKDIR/output"
else
    warn "no work dir at $WORKDIR yet. It's only needed at RUN time, not to build. Set it up with:"
    warn "  git clone https://github.com/headunderheels/NuFlux.git $WORKDIR"
    warn "  cd $WORKDIR && git clone https://gitlab.cern.ch/acc-models/acc-models-mc.git && mkdir -p output"
fi

# -----------------------------------------------------------------------------
sec "6. Disk / cache headroom"
# A .sif for this stack is a few GB; the base-image pull + build cache adds
# more. Apptainer caches under APPTAINER_CACHEDIR (default ~/.apptainer/cache).
# On clusters $HOME is often quota'd — point the cache at scratch if so.
AVAIL_KB="$(df -Pk . 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${AVAIL_KB:-}" ]; then
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
    if [ "$AVAIL_GB" -ge 15 ]; then
        ok "~${AVAIL_GB} GB free where the .sif will be written."
    else
        warn "only ~${AVAIL_GB} GB free here — the .sif output may not fit."
    fi
fi
# The build cache can be on a different filesystem than the output .sif.
CACHE_DIR="${APPTAINER_CACHEDIR:-$HOME/.apptainer/cache}"
CACHE_PARENT="$CACHE_DIR"; while [ ! -d "$CACHE_PARENT" ] && [ "$CACHE_PARENT" != "/" ]; do CACHE_PARENT="$(dirname "$CACHE_PARENT")"; done
CACHE_KB="$(df -Pk "$CACHE_PARENT" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${CACHE_KB:-}" ]; then
    CACHE_GB=$(( CACHE_KB / 1024 / 1024 ))
    if [ "$CACHE_GB" -ge 15 ]; then
        ok "~${CACHE_GB} GB free on the cache filesystem ($CACHE_PARENT)."
    else
        warn "only ~${CACHE_GB} GB free on the cache filesystem ($CACHE_PARENT) — the base-image pull caches here and may not fit."
    fi
fi
echo "  note: APPTAINER_CACHEDIR=${APPTAINER_CACHEDIR:-\$HOME/.apptainer/cache}"
echo "  If \$HOME is quota'd (common on HPC), redirect the cache to scratch:"
echo "      export APPTAINER_CACHEDIR=/scratch/\$USER/apptainer-cache"

# -----------------------------------------------------------------------------
sec "Summary"
echo "  FAIL: $FAILED    WARN: $WARNED"
if [ "$FAILED" -gt 0 ]; then
    echo
    echo "  Fix the FAILs above before building — they will stop the build."
    exit 1
fi
echo
echo "  Pre-build checks passed. Next steps:"
echo "    1) apptainer build --fakeroot nuflux.sif $DEF   (long: from-source GEANT4+BDSIM)"
echo "    2) run the pipeline via the two-stage wrapper:"
echo "         ./genie_convert/run_nuflux_2stage.sh"
echo "  WARNs above are worth reading but don't block a build."
exit 0
