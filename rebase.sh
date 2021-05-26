#!/usr/bin/env sh

# If editing from Windows. Choose LF as line-ending

set -eu

# Find out where dependent modules are and load them at once before doing
# anything. This is to be able to use their services as soon as possible.

# Build a default colon separated REBASE_LIBPATH using the root directory to
# look for modules that we depend on. REBASE_LIBPATH can be set from the outside
# to facilitate location. Note that this only works when there is support for
# readlink -f, see https://github.com/ko1nksm/readlinkf for a POSIX alternative.
REBASE_ROOTDIR=$( cd -P -- "$(dirname -- "$(command -v -- "$(readlink -f "$0")")")" && pwd -P )
REBASE_LIBPATH=${REBASE_LIBPATH:-${REBASE_ROOTDIR}/lib/mg.sh}

# Look for modules passed as parameters in the REBASE_LIBPATH and source them.
# Modules are required so fail as soon as it was not possible to load a module
module() {
  for module in "$@"; do
    OIFS=$IFS
    IFS=:
    for d in $REBASE_LIBPATH; do
      if [ -f "${d}/${module}.sh" ]; then
        # shellcheck disable=SC1090
        . "${d}/${module}.sh"
        IFS=$OIFS
        break
      fi
    done
    if [ "$IFS" = ":" ]; then
      echo "Cannot find module $module in $REBASE_LIBPATH !" >& 2
      exit 1
    fi
  done
}

# Source in all relevant modules. This is where most of the "stuff" will occur.
module log locals options

REBASE_ROOTIMAGE=${REBASE_ROOTIMAGE:-"busybox:latest"}

REBASE_MANIFEST=${REBASE_MANIFEST:-"manifest.json"}

parseopts \
  --main \
  --synopsis "$MG_CMDNAME rebase a Docker image on top of another one" \
  --usage "$MG_CMDNAME [options] -- main (root)" \
  --description "Will rebase the main image on top of the root image. Whenever the root image is not specified, it will be $REBASE_ROOTIMAGE" \
  --prefix "REBASE" \
  --shift _begin \
  --options \
    root-image OPTION ROOTIMAGE - "Default root image to rebase on when none given" \
    h,help FLAG @HELP - "Print this help and exit" \
  -- "$@"

# shellcheck disable=SC2154  # Var is set by parseopts
shift "$_begin"

if ! command -v jq >&2 >/dev/null; then
  die "This script requires an installation of jq"
fi

# Just a handy variable for pattern matching sha256 sums
sha256ptn='[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]'

# When 2 or more arguments are given, we use the second argument as the root
# image instead of the default one.
[ $# -gt 1 ] && REBASE_ROOTIMAGE=$2

# We NEED qualified images, i.e. images with proper tag names.
if ! printf %s\\n "$1" | grep -qE '^.*:([a-zA-Z0-9_.-]{1,128})$'; then
  die "Main docker image $1 is not fully qualified"
fi
if ! printf %s\\n "$REBASE_ROOTIMAGE" | grep -qE '^.*:([a-zA-Z0-9_.-]{1,128})$'; then
  die "Root docker image $REBASE_ROOTIMAGE to rebase $1 on is not fully qualified"
fi

# Unpack the content of the main image to a temporary directory
main_dir=$(mktemp -d)
log_debug "Saving main image $1 to $main_dir"
docker image save "$1" | tar -C "$main_dir" -xf -

# Unpack the content of the root image to a temporary directory
root_dir=$(mktemp -d)
log_debug "Saving new root image $REBASE_ROOTIMAGE to $root_dir"
docker image save "$REBASE_ROOTIMAGE" | tar -C "$root_dir" -xf -

# Find all existing layers in the root image and copy them into the temporary
# directory of the main image.
log_debug "Copy all layers from $REBASE_ROOTIMAGE into $1"
find "$root_dir" \
  -name "$sha256ptn" \
  -type d \
  -maxdepth 1 \
  -exec mv \{\} "$main_dir" \;

unarray() {
  jq -cr "$1" "$2" |
    cut -c 2- |
    rev |
    cut -c 2- |
    rev
}

sed_quote() {
  printf %s\\n "$1" | sed -e 's/"/\\"/g' -e 's/\./\\\./g'
}

# TODO: Prevent rebasing several times by ensuring that the list of layers and of diff_ids actually contain unique entries.

# TODO: Support renaming of the main image.

log_debug "Merge layer references into $1"
# Find the layers references in the manifests
root_layers=$(unarray '.[].Layers' "${root_dir%/}/$REBASE_MANIFEST")
main_layers=$(unarray '.[].Layers' "${main_dir%/}/$REBASE_MANIFEST")

# Replace the layers in the main manifest to the combined list of layers of both
# images.
all_layers=$(printf %s,%s\\n "$root_layers" "$main_layers")
log_trace "List of layers: $all_layers"
sed -Ei \
  "s~\"Layers\":\[[^]]+\]~\"Layers\":\[$(sed_quote "$all_layers")\]~" \
  "${main_dir%/}/$REBASE_MANIFEST"

# Do the same with the diff_ids, i.e. the sha256 sums of all layers.
main_config=$(jq -cr '.[].Config' "${main_dir%/}/$REBASE_MANIFEST")
log_debug "Merge sha256 sums into configuration for $1 at $main_config"
root_config=$(jq -cr '.[].Config' "${root_dir%/}/$REBASE_MANIFEST")
main_diffs=$(unarray '.rootfs.diff_ids' "${main_dir%/}/$main_config")
root_diffs=$(unarray '.rootfs.diff_ids' "${root_dir%/}/$root_config")
all_diffs=$(printf %s,%s\\n "$root_diffs" "$main_diffs")
log_trace "List of sha256 sums: $all_diffs"
sed -Ei \
  "s~\"diff_ids\":\[[^]]+\]~\"diff_ids\":\[$(sed_quote "$all_diffs")\]~" \
  "${main_dir%/}/$main_config"

log_info "Rebasing $1 on top of $REBASE_ROOTIMAGE"
( cd "$main_dir" && tar cf - -- * | docker image load )

rm -rf "$main_dir"
rm -rf "$root_dir"