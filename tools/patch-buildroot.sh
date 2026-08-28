#!/bin/bash
#
# Install patches/buildroot/* into nerves_system_br's own Buildroot patch
# directory, so that Buildroot is patched wherever and whenever it is extracted.
#
# These patch Buildroot itself rather than a package it builds, so they do not
# go through BR2_GLOBAL_PATCH_DIR, and `mix deps.get` discards them along with
# the nerves_system_br tree it replaces.
#
# The two losses are not equally loud, which is why this is automated:
#
#   0002 (embed out-of-tree firmware) stops the build. The kernel cannot find
#        firmware/panels/*.panel, named by CONFIG_EXTRA_FIRMWARE.
#
#   0001 (mesa3d without target LLVM) says nothing. panfrost depends on
#        MESA3D_LLVM, so without the patch Kconfig drops it and takes GBM, EGL
#        and GLES with it. The build succeeds; the image has no GPU driver.
#
# Why install them rather than patch the extracted tree
# -----------------------------------------------------
# On a first build there is no tree to patch. create-build.sh downloads and
# extracts Buildroot, applies nerves_system_br's patches, and *then* runs
# defconfig -- all inside the build step, after any mix hook has had its turn.
# Patching afterwards is too late: Kconfig has already been read, so a symbol
# added by 0002 is already gone from .config.
#
# create-build.sh applies every *.patch under nerves_system_br/patches/, and
# scripts/buildroot-state.sh hashes that directory to decide whether the tree
# needs re-extracting. Installing into it therefore gets the patches applied at
# the right moment, in the right order, with the re-extraction already handled.
#
# Ours are prefixed 9 so they sort after nerves_system_br's 0001-0016 and are
# recognisable as not belonging to that package. The order matters: these
# patches are written against a tree that already has those applied.
#
# The one thing Buildroot will not do for itself
# ----------------------------------------------
# Its per-package stamps do not treat .config as a dependency, so a package
# configured before these patches existed stays stamped as done and the stale
# build silently wins -- reapplying a patch is not sufficient on its own. When
# the installed set changes and a build tree already exists, this forces the
# affected packages to reconfigure.
#
# Pure shell, no Docker, no network.
#
# Usage:
#   tools/patch-buildroot.sh                       install or refresh
#   tools/patch-buildroot.sh --check               report only; non-zero if out of sync
#   tools/patch-buildroot.sh --reconfigure-stale   also rebuild packages built before them
#   tools/patch-buildroot.sh --br-dir <path>       path to the nerves_system_br package
#
# --br-dir takes the authoritative path, which Mix.Tasks.Compile.BuildrootPatch
# passes from Nerves.Env. Without it both layouts are searched: this project's
# own deps/, and a sibling in an application's deps/ for when this system is
# built as a dependency.
#
set -euo pipefail

cd "$(dirname "$0")/.."

CHECK_ONLY=0
RECONFIGURE=0
BR_PKG_DIR="${NERVES_SYSTEM_BR_PATH:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)              CHECK_ONLY=1; shift ;;
        --reconfigure-stale)  RECONFIGURE=1; shift ;;
        --br-dir)             BR_PKG_DIR="${2:-}"; shift 2 ;;
        *)
            echo "usage: $0 [--check] [--reconfigure-stale] [--br-dir <path>]" >&2
            exit 2
            ;;
    esac
done

# Packages whose *configuration* these patches can change. Buildroot will not
# notice on its own; see above. Only ones with an existing build directory are
# touched, so this is a no-op before the first build.
STALE_PACKAGES="mesa3d host-mesa3d kmscube glmark2 waffle linux"

shopt -s nullglob
PATCHES=(patches/buildroot/*.patch)
shopt -u nullglob
if [[ ${#PATCHES[@]} -eq 0 ]]; then
    exit 0
fi

if [[ -z $BR_PKG_DIR ]]; then
    for candidate in deps/nerves_system_br ../nerves_system_br; do
        if [[ -d $candidate ]]; then
            BR_PKG_DIR=$candidate
            break
        fi
    done
fi

# Nothing to install into until the dependency has been fetched. Not an error:
# this runs ahead of every mix task, including in a fresh clone.
if [[ -z $BR_PKG_DIR ]] || [[ ! -d $BR_PKG_DIR ]]; then
    exit 0
fi

TARGET="$BR_PKG_DIR/patches/buildroot"
if [[ ! -d $TARGET ]]; then
    echo "ERROR: $TARGET does not exist." >&2
    echo "       nerves_system_br keeps its Buildroot patches there; this" >&2
    echo "       version may have moved them. Check create-build.sh." >&2
    exit 1
fi

# What should be there, and under what name.
installed_name() { echo "9$(basename "$1")"; }

changed=()
for patch in "${PATCHES[@]}"; do
    dest="$TARGET/$(installed_name "$patch")"
    if [[ ! -f $dest ]] || ! cmp -s "$patch" "$dest"; then
        changed+=("$patch")
    fi
done

# Ours that should no longer be there -- a patch renamed or dropped since the
# last run. Left behind, it would keep being applied.
expected_names=()
for patch in "${PATCHES[@]}"; do
    expected_names+=("$(installed_name "$patch")")
done

stale=()
shopt -s nullglob
for existing in "$TARGET"/9*.patch; do
    name=$(basename "$existing")
    keep=0
    for expected in "${expected_names[@]}"; do
        [[ $name == "$expected" ]] && keep=1 && break
    done
    [[ $keep -eq 0 ]] && stale+=("$existing")
done
shopt -u nullglob

if [[ ${#changed[@]} -eq 0 ]] && [[ ${#stale[@]} -eq 0 ]]; then
    exit 0
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "Buildroot patches are not installed in $TARGET."
    echo "Run tools/patch-buildroot.sh to fix."
    exit 1
fi

echo "  installing Buildroot patches into $TARGET"
for patch in "${changed[@]}"; do
    echo "    $(basename "$patch") -> $(installed_name "$patch")"
    cp "$patch" "$TARGET/$(installed_name "$patch")"
done
for existing in "${stale[@]}"; do
    echo "    removing $(basename "$existing"), no longer ours"
    rm -f "$existing"
done

# create-build.sh compares scripts/buildroot-state.sh against the tree's recorded
# state and re-extracts when they differ, so the patches above are applied on the
# next build without anything further here. Packages already built are a
# different matter: Buildroot's stamps do not treat .config as a dependency, so
# one configured under the old answers stays stamped as done.
#
# Rebuilding them is gated behind --reconfigure-stale, and deliberately. This
# script runs from mix.exs's loadconfig alias, which every mix task runs, and a
# `mix format` that quietly starts a forty-minute Mesa rebuild is not acceptable
# behaviour. Mix.Tasks.Compile.BuildrootPatch passes the flag, because a compiler
# only runs when something is being built.
stale_pkgs=()
for build_dir in .nerves/artifacts/*/; do
    [[ -f "$build_dir/Makefile" ]] || continue

    for pkg in $STALE_PACKAGES; do
        for existing in "$build_dir"build/"$pkg"-*; do
            [[ -d $existing ]] || continue
            stale_pkgs+=("$pkg")
            if [[ $RECONFIGURE -eq 1 ]]; then
                echo "  reconfiguring $pkg, built before these patches"
                make -C "$build_dir" "$pkg-reconfigure" >/dev/null
            fi
            break
        done
    done
done

if [[ ${#stale_pkgs[@]} -gt 0 ]] && [[ $RECONFIGURE -eq 0 ]]; then
    echo
    echo "  NOTE: these packages were configured before the patches above and"
    echo "        Buildroot will not notice. The next build reconfigures them;"
    echo "        to do it now:"
    echo
    for pkg in "${stale_pkgs[@]}"; do
        echo "          make -C .nerves/artifacts/*/ $pkg-reconfigure"
    done
    echo
fi
