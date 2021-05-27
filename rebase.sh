#!/usr/bin/env sh

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

REBASE_BASE=${REBASE_BASE:-"busybox:latest"}

REBASE_MANIFEST=${REBASE_MANIFEST:-"manifest.json"}

REBASE_SUFFIX=${REBASE_SUFFIX:-"~"}

parseopts \
  --main \
  --synopsis "$MG_CMDNAME rebase a Docker image on top of another one" \
  --usage "$MG_CMDNAME [options] -- image..." \
  --description "Will rebase the images passed as a parameter on top of the base image. Their names can be changed to segregate them from the original images." \
  --prefix "REBASE" \
  --shift _begin \
  --options \
    b,base OPTION BASE - "Root image to rebase on" \
    s,suffix OPTION SUFFIX - "Suffix to append to rebased image name. When the suffix is the special string ~ (tilda), it will automatically be composed of a dash, followed by the basename of the image to rebase on, e.g. -busybox" \
    h,help FLAG @HELP - "Print this help and exit" \
  -- "$@"

# shellcheck disable=SC2154  # Var is set by parseopts
shift "$_begin"

if ! command -v jq >&2 >/dev/null; then
  die "This script requires an installation of jq"
fi

if ! printf %s\\n "$REBASE_BASE" | grep -qE '^.*:([a-zA-Z0-9_.-]{1,128})$'; then
  die "Root docker image $REBASE_BASE to rebase image(s) on is not fully qualified"
fi

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

rmdup() {
  printf %s\\n "$1" |
    tr ',' '
' |
    uniq |
    paste -sd "," -
}

# Just a handy variable for pattern matching sha256 sums
sha256ptn='[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]'

# Unpack the content of the root image to a temporary directory
root_dir=$(mktemp -d)
log_debug "Saving new root image $REBASE_BASE to $root_dir"
docker image save "$REBASE_BASE" | tar -C "$root_dir" -xf -

if [ "$REBASE_SUFFIX" = "~" ]; then
  root_main=$(  printf %s\\n "$REBASE_BASE" |
                sed -E 's/^(.*):([a-zA-Z0-9_.-]{1,128})$/\1/' )
  REBASE_SUFFIX="-$(basename "$root_main")"
fi

if [ -n "$REBASE_SUFFIX" ]; then
  log_info "Appending $REBASE_SUFFIX to all rebased image names"
fi

for img; do
  # We NEED qualified images, i.e. images with proper tag names.
  if ! printf %s\\n "$img" | grep -qE '^.*:([a-zA-Z0-9_.-]{1,128})$'; then
    log_error "Main docker image $img is not fully qualified"
  else
    # Unpack the content of the main image to a temporary directory
    main_dir=$(mktemp -d)
    log_debug "Saving main image $img to $main_dir"
    docker image save "$img" | tar -C "$main_dir" -xf -

    # Find all existing layers in the root image and copy them into the temporary
    # directory of the main image.
    log_debug "Copy all layers from $REBASE_BASE into $img"
    find "$root_dir" \
      -maxdepth 1 \
      -name "$sha256ptn" \
      -type d \
      -exec cp -a \{\} "$main_dir" \;

    log_debug "Merge layer references into $img"
    # Find the layers references in the manifests
    root_layers=$(unarray '.[].Layers' "${root_dir%/}/$REBASE_MANIFEST")
    main_layers=$(unarray '.[].Layers' "${main_dir%/}/$REBASE_MANIFEST")

    # Replace the layers in the main manifest to the combined list of layers of
    # both images.
    all_layers=$(printf %s,%s\\n "$root_layers" "$main_layers")
    log_trace "List of layers: $all_layers"
    sed -Ei \
      "s~\"Layers\":\[[^]]+\]~\"Layers\":\[$(sed_quote "$all_layers")\]~" \
      "${main_dir%/}/$REBASE_MANIFEST"

    if [ -n "$REBASE_SUFFIX" ]; then
      sed -i \
        "s~\"${img}\"~\"${img}${REBASE_SUFFIX}\"~g" \
        "${main_dir%/}/$REBASE_MANIFEST"
    fi

    # Do the same with the diff_ids, i.e. the sha256 sums of all layers.
    main_config=$(jq -cr '.[].Config' "${main_dir%/}/$REBASE_MANIFEST")
    log_debug "Merge sha256 sums into configuration for $img at $main_config"
    root_config=$(jq -cr '.[].Config' "${root_dir%/}/$REBASE_MANIFEST")
    main_diffs=$(unarray '.rootfs.diff_ids' "${main_dir%/}/$main_config")
    root_diffs=$(unarray '.rootfs.diff_ids' "${root_dir%/}/$root_config")
    all_diffs=$(printf %s,%s\\n "$root_diffs" "$main_diffs")
    log_trace "List of sha256 sums: $all_diffs"
    sed -Ei \
      "s~\"diff_ids\":\[[^]]+\]~\"diff_ids\":\[$(sed_quote "$all_diffs")\]~" \
      "${main_dir%/}/$main_config"

    if [ -n "$REBASE_SUFFIX" ]; then
      log_info "Rebasing $img on top of $REBASE_BASE as ${img}${REBASE_SUFFIX}"
    else
      log_info "Rebasing $img on top of $REBASE_BASE"
    fi
    ( cd "$main_dir" && tar cf - -- * | docker image load )

    rm -rf "$main_dir"
  fi
done

rm -rf "$root_dir"
