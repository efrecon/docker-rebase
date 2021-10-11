#!/usr/bin/env sh

set -eu

# Find out where dependent modules are and load them at once before doing
# anything. This is to be able to use their services as soon as possible.


# This is a readlink -f implementation so this script can run on MacOS
abspath() {
  if [ -d "$1" ]; then
    ( cd -P -- "$1" && pwd -P )
  elif [ -L "$1" ]; then
    abspath "$(dirname "$1")/$(stat -c %N "$1" | awk -F ' -> ' '{print $2}' | cut -c 2- | rev | cut -c 2- | rev)"
  else
    printf %s\\n "$(abspath "$(dirname "$1")")/$(basename "$1")"
  fi
}

# Build a default colon separated REBASE_LIBPATH using the root directory to
# look for modules that we depend on. REBASE_LIBPATH can be set from the outside
# to facilitate location.
REBASE_ROOTDIR=$( cd -P -- "$(dirname -- "$(command -v -- "$(abspath "$0")")")" && pwd -P )
REBASE_LIBPATH=${REBASE_LIBPATH:-${REBASE_ROOTDIR}/lib/mg.sh}
# shellcheck source=./lib/mg.sh/bootstrap.sh disable=SC1091
. "${REBASE_LIBPATH%/}/bootstrap.sh"

# Source in all relevant modules. This is where most of the "stuff" will occur.
module log locals options

# This is the image that all images passed as an argument will be rebased on.
REBASE_BASE=${REBASE_BASE:-"busybox:latest"}

# This is the (relative) path of the manifest inside images. It is very unlikely
# that you will ever have to change that!
REBASE_MANIFEST=${REBASE_MANIFEST:-"manifest.json"}

# Do not output the name of the rebased images, one per line, once done.
REBASE_QUIET=${REBASE_QUIET:-0}

# Do not rebase, just show what would be done and output the names of the images
# that would be rebased, if relevant.
REBASE_DRYRUN=${REBASE_DRYRUN:-0}

# The suffix will be appended to the name of the images that are being rebased
# to easily segragate them from their original version. By default, it is a ~. ~
# is a special character and will automatically be replaced by a - followed by
# the basename of the $REBASE_BASE image name, e.g. busybox. It is possible to
# set the suffix to an empty string, in which case the rebased image will
# replace the original image on your host.
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
    s,suffix OPTION SUFFIX - "Suffix to append to rebased image name. When the suffix is the special string ~ (tilde), it will automatically be composed of a dash, followed by the basename of the image to rebase on, e.g. -busybox" \
    q,quiet,silent FLAG QUIET - "Do not output list of rebased images" \
    n,dryrun,dry-run FLAG DRYRUN - "Do not rebase, just output the list of images that would be rebased" \
    h,help FLAG @HELP - "Print this help and exit" \
  -- "$@"

# shellcheck disable=SC2154  # Var is set by parseopts
shift "$_begin"

if ! command -v jq >&2 >/dev/null; then
  die "This script requires an installation of jq"
fi

# Perform the jq query at $1 on the file at $2 to find an array and remove the
# leading and trailing [ and ].
unarray() {
  jq -cr "$1" "$2" |
    cut -c 2- |
    rev |
    cut -c 2- |
    rev
}

# Quote a string so that it can be used as a sed expression
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

# Pull the docker image passed as a parameter if it does not already exist on
# the host. Output the name of the image whenever it is present (before or after
# the pull).
pull_if() {
  if docker image inspect "${1}" >/dev/null 2>&1; then
    printf %s\\n "${1}"
  else
    log_info "${1} not present locally, pulling"
    docker image pull --quiet "${1}"; # Outputs the name of the image
  fi
}

# Remove mentions of the docker registry and default library from the name of an
# image.
undocker() {
  sed -E \
    -e 's~^docker.(io|com)/(library|_)/~~' \
    -e 's~^docker.(io|com)/~~'
}

# Automatically add :latest as a tag whenever necessary and try making the image
# available at the host. Outputs the name of the image in its short form, i.e.
# with the default docker servers and library removed.
resolve_img() {
  if printf %s\\n "$1" | grep -qE '@sha256:[a-f0-9]{64}$'; then
    pull_if "$1" | undocker
  elif printf %s\\n "$1" | grep -qE ':([a-zA-Z0-9_.-]{1,128})$'; then
    pull_if "$1" | undocker
  else
    log_debug "Image $1 has nor a tag, nor a digest. Trying ${1}:latest."
    pull_if "${1}:latest" | undocker
  fi
}

# Just a handy variable for pattern matching sha256 sums
sha256ptn='[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]'

REBASE_BASE=$(resolve_img "$REBASE_BASE")
[ -z "$REBASE_BASE" ] && die "Base image does not exist!"

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
  img=$(resolve_img "$img")
  if [ -n "$img" ]; then
    if [ "$REBASE_DRYRUN" = "1" ]; then
      if [ -n "$REBASE_SUFFIX" ]; then
        log_info "Would rebase $img on top of $REBASE_BASE as ${img}${REBASE_SUFFIX}"
      else
        log_info "Would rebase $img on top of $REBASE_BASE"
      fi
      printf %s%s\\n "$img" "$REBASE_SUFFIX"
    else
      # Unpack the content of the main image to a temporary directory
      main_dir=$(mktemp -d)
      log_debug "Saving image $img to $main_dir"
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

      # Replace the layers in the main manifest to the combined list of layers
      # of both images.
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

      if [ "$REBASE_QUIET" = "0" ]; then
        ( cd "$main_dir" && tar cf - -- * | docker image load | sed 's/[Ll]oaded image: //g')
      else
        ( cd "$main_dir" && tar cf - -- * | docker image load | sed 's/[Ll]oaded image: //g') > /dev/null
      fi

      rm -rf "$main_dir"
    fi
  else
    log_error "Skipping image, does not exist"
  fi
done

rm -rf "$root_dir"
