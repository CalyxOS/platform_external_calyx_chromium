# This shell script is intended to be source'd.
# We expect bash.

FIRST_VENDOR_PATCH_REGEX='/CalyxOS.*[Bb]randing/'
CHROMIUM_SRC_REMOTE="${CHROMIUM_SRC_REMOTE:-origin}"
CHROMIUM_SRC_REMOTE_URI="${CHROMIUM_SRC_REMOTE_URI:-https://chromium.googlesource.com/chromium/src}"
BRAVE_REMOTE="${BRAVE_REMOTE:-origin}"
BRAVE_REMOTE_URI="${BRAVE_REMOTE_URI:-https://github.com/brave/brave-core}"
CROMITE_REMOTE="${CROMITE_REMOTE:-origin}"
CROMITE_REMOTE_URI="${CROMITE_REMOTE_URI:-https://github.com/uazo/cromite}"
CHROMIUM_CUSTOM_BUILDFILES_REMOTE="${CHROMIUM_CUSTOM_BUIDFILES_REMOTE:-origin}"
USE_WIGGLE="${USE_WIGGLE:-y}"
EXPORT_APPLIED_PATCHES="${EXPORT_APPLIED_PATCHES:-y}"
CHROMIUM_TARGET_CPU="${CHROMIUM_TARGET_CPU:-arm64}"
# CHROMIUM_SRC_PATH defaults to an educated guess
# CHROMIUM_CUSTOM_BUILDFILES_PATH defaults to an educated guess (typically representing the build subdir of the platform_external_calyx_chromium repo)
# CHROMIUM_CUSTOM_BUILDFILES_PATCHLIST_PATH defaults to CHROMIUM_CUSTOM_BUILDFILES_PATH
# CHROMIUM_CUSTOM_BUILDFILES_STATUS_PATH defaults to status subdir of CHROMIUM_CUSTOM_BUILDFILES_PATH
# CHROMIUM_CUSTOM_BUILDFILES_PATCHES_PATH defaults to patches subdir of CHROMIUM_CUSTOM_BUILDFILES_PATH
# BRAVE_PATH defaults to an educated guess; see find_brave_path()
# CROMITE_PATH defaults to an educated guess; see find_cromite_path()
[ -n "${BRAVE_RELEVANT_CHANGE_COMMITMSG_REGEX:-}" ] \
  || BRAVE_RELEVANT_CHANGE_COMMITMSG_REGEX='priv\(acy\)\?/\?sec\(urity\)\?\|sec\(urity\)\?/\?priv\(acy\)\?\|\(privacy\|priv\|priv\?sec\|sec\?priv\|sec\|security\) \?team'

# This regex is supplied to `git log -G` and does not need certain escaping; unlike above, use | instead of \|.
[ -n "${BRAVE_RELEVANT_CHANGE_FEATURES_REGEX:-}" ] \
  || BRAVE_RELEVANT_CHANGE_FEATURES_REGEX='FEATURE_DISABLED_BY_DEFAULT|FEATURE_ENABLED_BY_DEFAULT'

git_chromium() {
  find_chromium_src_path || return $?
  git -C "$CHROMIUM_SRC_PATH" "$@" || return $?
}

git_custom_buildfiles() {
  find_chromium_custom_buildfiles_path || return $?
  git -C "$CHROMIUM_CUSTOM_BUILDFILES_PATH" "$@" || return $?
}

git_brave() {
  find_brave_path || return $?
  git -C "$BRAVE_PATH" "$@" || return $?
}

git_cromite() {
  find_cromite_path || return $?
  git -C "$CROMITE_PATH" "$@" || return $?
}

edit() {
  # edit files that are marked as unmerged or modified
  local files="$(git_chromium diff --name-only --diff-filter=UM)" || return $?
  if [ -z "$files" ]; then
    echo "Nothing to edit" >&2
    return 0
  fi
  if [ "${EDITOR:-nano}" = "nano" ]; then
    printf "%s\n" "$files" | xargs --open-tty nano '+/<<<<<<<'
  else
    printf "%s\n" "$files" | xargs --open-tty "$EDITOR"
  fi
}

add() {
  # add files that are marked as unmerged or modified
  local files="$(git_chromium diff --name-only --diff-filter=UM)"
  if [ -z "$files" ]; then
    echo "Nothing to add" >&2
    return 0
  fi
  printf "%s\n" "$files" | xargs git -C "$CHROMIUM_SRC_PATH" add
}

resume() {
  find_chromium_src_path || return $?
  git_chromium am --continue "$@" || return $?
  export_single_patch || return $?
  apply_patches_resume || return $?
}

show() {
  git_chromium am --show-current-patch "$@" || return $?
}

find_chromium_out_path() {
  find_chromium_src_path || return $?
  _maybe_error_about_unset_chromium_version || return $?
  if [ -z "$OUT" ]; then
    OUT="${CHROMIUM_SRC_PATH}/out/calyx-$V-${CHROMIUM_TARGET_CPU}"
    [ -d "$OUT" ] || mkdir "$OUT" || return $?
    if [ -e "$OUT/args.gn" ]; then
      diff "${CHROMIUM_SRC_PATH}/args.gn" "$OUT/args.gn" || err=$?
      if [ $err -ne 0 ]; then
        echo 'Different args.gn in $OUT vs source. Please investigate and/or copy manually.' >&2
        return 2
      fi
    else
      cp "${CHROMIUM_SRC_PATH}/args.gn" "$OUT/args.gn" || return $?
    fi
  fi
}

build() {
  local err=0
  find_chromium_out_path || return $?
  if ! grep -q "^\s*target_cpu\s*=\s*"'"'"${CHROMIUM_TARGET_CPU}"'"'"\s*" "${CHROMIUM_SRC_PATH}/args.gn"; then
    echo "target_cpu in args.gn does not match \$CHROMIUM_TARGET_CPU ($CHROMIUM_TARGET_CPU); please update one or the other" >&2
    return 3
  fi
  if ! grep -q "^\s*android_default_version_name\s*=\s*"'"'"$V"'"'"\s*" "${CHROMIUM_SRC_PATH}/args.gn"; then
    echo "android_default_version_name in args.gn does not match \$V ($V); please update one or the other" >&2
    echo "(Don't forget to update android_default_version_code too!)" >&2
    return 3
  fi
  (cd "$CHROMIUM_SRC_PATH" && gn gen "$OUT") || return $?
  # retain one prior build log
  [ ! -e "$OUT/build.log" ] || mv "$OUT/build.log" "$OUT/build.log.0"
  (cd "$CHROMIUM_SRC_PATH" && time autoninja -k 0 -C "$OUT" trichrome_chrome_64_32_bundle trichrome_library_64_32_apk trichrome_webview_64_32_apk system_webview_shell_apk > >(tee "$OUT/build.log") && \
    cd "$OUT/apks"     && \
    rm -f universal.apk     && \
    java -jar "${CHROMIUM_SRC_PATH}/third_party/android_build_tools/bundletool/cipd/bundletool.jar" build-apks --mode universal --bundle TrichromeChrome6432.aab --output . --output-format DIRECTORY
  ) || {
    err=$?
    echo >&2
    echo "Something went wrong. Type 'errors' to see lines with 'error: '," >&2
    echo "or type 'showlog' to see the build log." >&2
    return $err
  }
}

showlog() {
  find_chromium_out_path || return $?
  "${PAGER:-more}" "$OUT/build.log"
}

errors() {
  find_chromium_out_path || return $?
  cat "$OUT/build.log" | grep 'error: ' | sort -u
}

find_chromium_custom_buildfiles_path() {
  # TODO: Refactor to share code with other path-finding functions, if possible...
  [ -z "${CHROMIUM_CUSTOM_BUILDFILES_PATH:-}" ] || return 0
  local path="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
  case "$path" in
    */build)
      ;;
    *)
      echo "Could not find Chromium custom buildfiles path. Expected it to be our parent directory!" >&2
      echo "Please resolve this or set CHROMIUM_CUSTOM_BUILDFILES_PATH." >&2
      return 2
  esac
  if [ ! -d "$path/patches" ]; then
    echo "Missing patches folder in Chromium custom buildfiles path '$path'" >&2
    return 2
  fi
  CHROMIUM_CUSTOM_BUILDFILES_PATH="$path"
}

find_chromium_src_path() {
  # TODO: Refactor to share code with other path-finding functions.
  [ -z "${CHROMIUM_SRC_PATH:-}" ] || return 0
  local possible_paths=(
    "$HOME/chromium/src"
    "$(pwd)"
  )
  local possible_path
  for possible_path in "${possible_paths[@]}"; do
    ([ -n "$possible_path" ] && [ -d "$possible_path" ]) || continue
    local resolved_path
    resolved_path="$(cd "$possible_path"; pwd)" || continue
    case "$(git -C "$resolved_path" remote get-url "$CHROMIUM_SRC_REMOTE")" in
      "$CHROMIUM_SRC_REMOTE_URI"*)
        CHROMIUM_SRC_PATH="$resolved_path"
        return 0
        ;;
    esac
  done
  echo "Could not find chromium src directory." >&2
  echo "Please chdir to the src directory or set CHROMIUM_SRC_PATH." >&2
  return 2
}

find_brave_path() {
  # TODO: Refactor to share code with other path-finding functions.
  [ -z "${BRAVE_PATH:-}" ] || return 0
  local possible_paths=(
    "$HOME/chromium/brave-core"
  )
  if find_chromium_src_path 2>/dev/null; then
    possible_paths+=("$CHROMIUM_SRC_PATH/../brave-core")
  fi
  possible_paths+=("$(pwd)")

  local possible_path
  for possible_path in "${possible_paths[@]}"; do
    ([ -n "$possible_path" ] && [ -d "$possible_path" ]) || continue
    local resolved_path
    resolved_path="$(cd "$possible_path"; pwd)" || continue
    case "$(git -C "$resolved_path" remote get-url "$BRAVE_REMOTE")" in
      "$BRAVE_REMOTE_URI"*)
        BRAVE_PATH="$resolved_path"
        return 0
        ;;
    esac
  done
  echo "Could not find brave-core directory." >&2
  echo "Please chdir to the brave-core directory or set BRAVE_PATH." >&2
  return 2
}

find_cromite_path() {
  # TODO: Refactor to share code with other path-finding functions.
  [ -z "${CROMITE_PATH:-}" ] || return 0
  local possible_paths=(
    "$HOME/chromium/cromite"
  )
  if find_chromium_src_path 2>/dev/null; then
    possible_paths+=("$CHROMIUM_SRC_PATH/../brave-core")
  fi
  possible_paths+=("$(pwd)")

  local possible_path
  for possible_path in "${possible_paths[@]}"; do
    ([ -n "$possible_path" ] && [ -d "$possible_path" ]) || continue
    local resolved_path
    resolved_path="$(cd "$possible_path"; pwd)" || continue
    case "$(git -C "$resolved_path" remote get-url "$CROMITE_REMOTE")" in
      "$CROMITE_REMOTE_URI"*)
        CROMITE_PATH="$resolved_path"
        return 0
        ;;
    esac
  done
  echo "Could not find cromite directory." >&2
  echo "Please chdir to the cromite directory or set CROMITE_PATH." >&2
  return 2
}

### CHROMIUM VERSION QUERYING ###
[ -n "${CHROMIUM_STABLE_RELEASES_TO_FETCH:-}" ] \
  || CHROMIUM_STABLE_RELEASES_TO_FETCH=6
[ -n "${CHROMIUM_STABLE_RELEASES_JSON_URL:-}" ] \
  || CHROMIUM_STABLE_RELEASES_JSON_URL="https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Android&num=$CHROMIUM_STABLE_RELEASES_TO_FETCH&offset=0"
[ -n "${CHROMIUM_STABLE_RELEASES_QUERY:-}" ] \
  || CHROMIUM_STABLE_RELEASES_QUERY='[.[] | select(.channel == "Stable")] | sort_by(.version|split(".")|map(tonumber))'

# TODO: Refactor to share code with stable release handling
[ -n "${CHROMIUM_BETA_RELEASES_TO_FETCH:-}" ] \
  || CHROMIUM_BETA_RELEASES_TO_FETCH=6
[ -n "${CHROMIUM_BETA_RELEASES_JSON_URL:-}" ] \
  || CHROMIUM_BETA_RELEASES_JSON_URL="https://chromiumdash.appspot.com/fetch_releases?channel=Beta&platform=Android&num=$CHROMIUM_BETA_RELEASES_TO_FETCH&offset=0"
[ -n "${CHROMIUM_BETA_RELEASES_QUERY:-}" ] \
  || CHROMIUM_BETA_RELEASES_QUERY='[.[] | select(.channel == "Beta")] | sort_by(.version|split(".")|map(tonumber))'

query_calyx_chromium_releases() {
  CALYX_CHROMIUM_RELEASES="$(git_custom_buildfiles ls-remote "$CHROMIUM_CUSTOM_BUILDFILES_REMOTE" --refs --tags 'refs/tags/*-calyx')"
}

query_brave_releases() {
  BRAVE_RELEASES="$(git_brave ls-remote "$BRAVE_REMOTE" --refs --tags 'refs/tags/*')"
}

query_cromite_releases() {
  CROMITE_RELEASES="$(git_cromite ls-remote "$CROMITE_REMOTE" --refs --tags 'refs/tags/*')"
}

query_chromium_stable_releases() {
  CHROMIUM_STABLE_RELEASES_JSON="$(wget -qO- "$CHROMIUM_STABLE_RELEASES_JSON_URL")"
}

query_chromium_beta_releases() {
  # TODO: Refactor to share code with stable release handling
  CHROMIUM_BETA_RELEASES_JSON="$(wget -qO- "$CHROMIUM_BETA_RELEASES_JSON_URL")"
}

show_chromium_stable_releases() {
  local count="${1:-2}"
  case "$count" in
    *[!0-9]*) # not a number
      echo "usage: show_chromium_stable_releases [count]" >&2
      echo >&2
      echo "Lists the [count] most recent chromium stable versions, defaulting to 2 most recent." >&2
      echo "The releases are cached in the CHROMIUM_STABLE_RELEASES_JSON environment variable;" >&2
      echo "they can be refreshed by running query_chromium_stable_releases or clearing the variable." >&2
      case "$count" in
        -h|--help)
          return 0
          ;;
      esac
      return 2
      ;;
  esac
  if [ "$count" -gt "$CHROMIUM_STABLE_RELEASES_TO_FETCH" ]; then
    echo "Warning: Cannot list $count versions of Chromium" \
      "as we only fetch $CHROMIUM_STABLE_RELEASES_TO_FETCH" >&2
  fi
  [ -n "${CHROMIUM_STABLE_RELEASES_JSON:-}" ] || query_chromium_stable_releases || return $?
  printf "%s\n" "$CHROMIUM_STABLE_RELEASES_JSON" \
    | jq -r "$CHROMIUM_STABLE_RELEASES_QUERY | .[-$count:]"
}

show_chromium_beta_releases() {
  # TODO: Refactor to share code with stable release handling
  local count="${1:-2}"
  case "$count" in
    *[!0-9]*) # not a number
      echo "usage: show_chromium_beta_releases [count]" >&2
      echo >&2
      echo "Lists the [count] most recent chromium beta versions, defaulting to 2 most recent." >&2
      echo "The releases are cached in the CHROMIUM_BETA_RELEASES_JSON environment variable;" >&2
      echo "they can be refreshed by running query_chromium_beta_releases or clearing the variable." >&2
      case "$count" in
        -h|--help)
          return 0
          ;;
      esac
      return 2
      ;;
  esac
  if [ "$count" -gt "$CHROMIUM_BETA_RELEASES_TO_FETCH" ]; then
    echo "Warning: Cannot list $count versions of Chromium" \
      "as we only fetch $CHROMIUM_BETA_RELEASES_TO_FETCH" >&2
  fi
  [ -n "${CHROMIUM_BETA_RELEASES_JSON:-}" ] || query_chromium_beta_releases || return $?
  printf "%s\n" "$CHROMIUM_BETA_RELEASES_JSON" \
    | jq -r "$CHROMIUM_BETA_RELEASES_QUERY | .[-$count:]"
}

process_calyx_chromium_releases() {
  cut -d$'\t' -f2- \
    | sed -e 's:^refs/tags/::' -e 's:-calyx$::' \
    | sort -V
}

show_calyx_chromium_releases() {
  local count="${1:-2}"
  case "$count" in
    *[!0-9]*) # not a number
      echo "usage: show_calyx_chromium_releases [count]" >&2
      echo >&2
      echo "Lists the [count] highest Calyx Chromium version numbers, defaulting to 2." >&2
      echo "The releases are cached in the CALYX_CHROMIUM_RELEASES environment variable;" >&2
      echo "they can be refreshed by running query_calyx_chromium_releases or clearing the variable." >&2
      case "$count" in
        -h|--help)
          return 0
          ;;
      esac
      return 2
      ;;
  esac
  find_chromium_custom_buildfiles_path || return $?
  [ -n "${CALYX_CHROMIUM_RELEASES:-}" ] || query_calyx_chromium_releases || return $?
  printf "%s\n" "$CALYX_CHROMIUM_RELEASES" \
    | process_calyx_chromium_releases \
    | tail -n"$count"
}

show_brave_releases() {
  local count="${1:-2}"
  case "$count" in
    *[!0-9]*) # not a number
      # TODO: doc like the others, or not
      echo "expected a number" >&2
      return 2
      ;;
  esac
  [ -n "${BRAVE_RELEASES:-}" ] || query_brave_releases || return $?
  printf "%s\n" "$BRAVE_RELEASES" | process_version_tags | tail -n"$count"
}

show_cromite_releases() {
  local count="${1:-2}"
  case "$count" in
    *[!0-9]*) # not a number
      # TODO: doc like the others, or not
      echo "expected a number" >&2
      return 2
      ;;
  esac
  [ -n "${CROMITE_RELEASES:-}" ] || query_cromite_releases || return $?
  printf "%s\n" "$CROMITE_RELEASES" | process_version_tags | tail -n"$count"
}

process_version_tags() {
  # version tags may or may not start with v, and may or may not include a hash on the end
  sed -n -e 's!.*\trefs/tags/\(v\?[0-9.]\+\)\(-[0-9a-f]\+\)\?$!\1\2!p' \
    | sort -V
}

### CHROMIUM UPDATING ###
update_sources() {
  update_calyx_chromium_sources "$@" || return $?
  update_chromium_sources "$@" || return $?
}

update_chromium_sources() {
  local do_force=
  for arg in "$@"; do
    case "$arg" in
      -f|--force)
        do_force=y
        ;;
      *)
        echo "Unrecognized option: $arg" >&2
        return 1
        ;;
    esac
  done
  find_chromium_src_path || return $?
  _maybe_error_about_unset_chromium_version || return $?
  local err=0
  _maybe_warn_about_branch_already_exists || return $?
  _maybe_warn_about_same_upstream || err=$?
  _maybe_warn_about_dirty_chromium_src || err=$?
  if [ $err -ne 0 ]; then
    if [ -z "$do_force" ]; then
      echo "ERROR: Not proceeding without --force" >&2
      return $err
    else
      echo "WARNING: Proceeding anyway, given --force" >&2
    fi
  fi
  [ -n "$(git_chromium tag -l "$V")" ] || git_chromium fetch "$CHROMIUM_SRC_REMOTE" "refs/tags/$V:refs/tags/$V" || return $?
  git_chromium checkout -b calyxos-$V "$V" || return $?
  (cd "$CHROMIUM_SRC_PATH" && gclient sync -D && gclient runhooks) || return $?
  echo "----" >&2
  echo "Now that your Chromium sources are up-to-date, patches may be applied by running:" >&2
  echo "  apply_patches" >&2
}

update_calyx_chromium_sources() {
  find_chromium_custom_buildfiles_path || return $?
  if [ -z "${V:-}" ]; then
    show_calyx_chromium_releases
    local latest_release="$(printf "%s\n" "$CALYX_CHROMIUM_RELEASES" \
      | process_calyx_chromium_releases \
      | tail -n1)"
    echo "----" >&2
    echo "Please set V to the desired version of Calyx Chromium first. For example:" >&2
    echo "  V=$latest_release" >&2
    echo "See above for the last few tagged releases of Calyx Chromium, if needed." >&2
    return 2
  fi
  git_custom_buildfiles fetch "$CHROMIUM_CUSTOM_BUILDFILES_REMOTE" "refs/tags/$V-calyx:refs/tags/$V-calyx" || return $?
  git_custom_buildfiles checkout "$V-calyx" || return $?
}

get_current_upstream() {
  git_chromium rev-parse --symbolic-full-name 'HEAD@{u}' 2>/dev/null
}

_maybe_error_about_unset_chromium_version() {
  if [ -z "${V:-}" ]; then
    show_chromium_stable_releases
    local latest_stable="$(printf "%s\n" "$CHROMIUM_STABLE_RELEASES_JSON" \
      | jq -r "$CHROMIUM_STABLE_RELEASES_QUERY | .[-1].version")"
    echo "----" >&2
    echo "Please set V to the desired version of Chromium first. For example:" >&2
    echo "  V=$latest_stable" >&2
    echo "See above details for the last few stable versions of Chromium, if needed." >&2
    echo "Or see release info here: https://chromiumdash.appspot.com/releases?platform=Android" >&2
    return 2
  fi
}

_maybe_warn_about_same_upstream() {
  if [ "$(get_current_upstream)" = "refs/tags/$V" ]; then
    echo "WARNING: The current upstream is the same as the desired upstream: $V." >&2
    echo "To proceed may be redundant." >&2
    return 2
  fi
}

_maybe_warn_about_branch_already_exists() {
  local calyx_branch="refs/heads/calyxos-$V"
  if git_chromium rev-parse "$calyx_branch" >/dev/null 2>&1; then
    echo "WARNING: Branch $calyx_branch already exists. It must be deleted to proceed." >&2
    return 2
  fi
}

_maybe_warn_about_dirty_chromium_src() {
  find_chromium_src_path || return $?
  _maybe_warn_about_dirty_git_repo chromium "$CHROMIUM_SRC_PATH" || return $?
}

_maybe_warn_about_dirty_chromium_custom_buildfiles() {
  find_chromium_custom_buildfiles_path || return $?
  _maybe_warn_about_dirty_git_repo chromium_custom_buildfiles "$CHROMIUM_CUSTOM_BUILDFILES_PATH" || return $?
}

_maybe_warn_about_dirty_cromite() {
  find_cromite_path || return $?
  _maybe_warn_about_dirty_git_repo cromite "$CROMITE_PATH" || return $?
}

_maybe_warn_about_dirty_git_repo() {
  # TODO: Is there a more comprehensive way to determine if git is in the middle of something?
  # Right now we just check a couple of things.
  if [ -n "$(git -C "$2" status --porcelain 2>&1)" ] \
      || git -C "$2" am --show-current-patch >/dev/null 2>&1 \
      || git -C "$2" show CHERRY_PICK_HEAD >/dev/null 2>&1 \
      || git -C "$2" show REBASE_HEAD >/dev/null 2>&1; then
    echo "WARNING: $1 repo is not clean or is in the middle of something." >&2
    git -C "$2" status || true
    return 2
  elif [ -z "$(git -C "$2" branch --show-current 2>/dev/null)" ]; then
    # TODO: Fix the below hack that stops this check for cromite
    [ "$1" != "cromite" ] || return 0
    echo "WARNING: $1 repo is not on a branch. Work may be lost if you proceed." >&2
    return 2
  fi
}

### APPLYING PATCHES ###
_get_status_dir() {
  if [ -n "${CHROMIUM_CUSTOM_BUILDFILES_STATUS_PATH:-}" ]; then
    printf "%s\n" "$CHROMIUM_CUSTOM_BUILDFILES_STATUS_PATH"
  fi
  printf "%s/status\n" "$CHROMIUM_CUSTOM_BUILDFILES_PATH"
}

_get_patchlist_dir() {
  if [ -n "${CHROMIUM_CUSTOM_BUILDFILES_PATCHLIST_PATH:-}" ]; then
    printf "%s\n" "$CHROMIUM_CUSTOM_BUILDFILES_PATCHLIST_PATH"
  fi
  printf "%s\n" "$CHROMIUM_CUSTOM_BUILDFILES_PATH"
}

_get_patches_dir() {
  if [ -n "${CHROMIUM_CUSTOM_BUILDFILES_PATCHES_PATH:-}" ]; then
    printf "%s\n" "$CHROMIUM_CUSTOM_BUILDFILES_PATCHES_PATH"
  fi
  printf "%s/patches\n" "$CHROMIUM_CUSTOM_BUILDFILES_PATH"
}

_get_apply_patches_todo_path() {
  printf "%s/apply_patches_todo.txt\n" "$(_get_status_dir)"
}

_should_use_wiggle() {
  is_var_true USE_WIGGLE && which wiggle >/dev/null 2>&1
}

is_apply_patches_active() {
  find_chromium_custom_buildfiles_path || return $?
  [ -e "$(_get_apply_patches_todo_path)" ]
}

apply_patches() {
  find_chromium_custom_buildfiles_path || return $?
  find_chromium_src_path || return $?
  if is_apply_patches_active; then
    echo "You are in the middle of applying patches." >&2
    echo "To resume, run: apply_patches_resume" >&2
    echo "To stop, run: apply_patches_stop" >&2
    echo '(Note that stopping does not undo any patches already applied.)' >&2
    return 3
  fi
  _maybe_warn_about_dirty_chromium_src || return $?
  local statusdir="$(_get_status_dir)"
  local todofile="$(_get_apply_patches_todo_path)"
  if [ -e "$todofile" ]; then
    echo "wtf: is_apply_patches_active is false, but todofile exists at $todofile" >&2
    echo "This helper script needs to be fixed." >&2
    return 200
  fi
  [ -d "$statusdir" ] || mkdir "$statusdir" || return $?
  local patchlist
  # TODO: Make the *_patches_list.txt pattern a constant somewhere.
  for patchlist in "$(_get_patchlist_dir)"/*_patches_list.txt; do
    if [ ! -e "$patchlist" ]; then
      echo "Could not find patch list: $patchlist" >&2
      return 1
    fi
    cat "$patchlist" | remove_comments >> "$todofile" || return $?
  done
  apply_patches_resume || return $?
}

apply_patches_resume() {
  find_chromium_custom_buildfiles_path || return $?
  find_chromium_src_path || return $?
  if ! is_apply_patches_active; then
    echo "Nothing to resume." >&2
    return 3
  fi
  _maybe_warn_about_dirty_chromium_src || return $?
  local todofile="$(_get_apply_patches_todo_path)"
  local patchesdir="$(_get_patches_dir)"
  while [ -s "$todofile" ]; do
    # Read and remove the top line as we go to allow resuming from interruptions.
    local patchfile="$(cat "$todofile" | remove_comments | head -n1)"
    sed -i '1d' "$todofile" || return $?
    if [ -n "$patchfile" ]; then
      printf "processing patch file: %s\n" "$patchfile"
      apply_patch "$patchesdir/$patchfile" || return $?
    fi
  done
  rm -f "$todofile"
}

apply_patch() {
  find_chromium_src_path || return $?
  local err=0
  local patchfile="$(realpath "$1")" || return $?
  local reject_arg=
  if _should_use_wiggle; then
    reject_arg=--reject
  fi
  local am_output # declaration must be on separate line to get exit code - see https://stackoverflow.com/a/2556122
  am_output="$(git_chromium am $reject_arg "$patchfile" 2>&1)" || err=$?
  printf "%s\n" "$am_output"
  if [ $err -ne 0 ]; then
    local error_lines="$(printf "%s\n" "$am_output" | grep '^error: ')"
    if [ -z "$error_lines" ]; then
      echo "Encountered errors applying patch, but no lines started with 'error: '." >&2
      echo "Please examine the situation yourself." >&2
      return $err
    fi
    local missing_from_index
    if [ -n "$reject_arg" ]; then
      mapfile -t missing_from_index < <(printf "%s\n" "$error_lines" | sed -n -e 's/^error: \(.*\): does not exist in index$/\1/p')
      if [ "${#missing_from_index[@]}" -eq 0 ]; then
        # wiggle can fix everything else... I think?
        err=0
      fi
      # apply wiggle, but if files are missing from the index, do not have wiggle --continue the patch
      NO_CONTINUE="$err" \
        apply_wiggle || err=$?
    fi
    [ $err -eq 0 ] || echo '----' # separator for our messsages vs other errors
    if [ "${#missing_from_index[@]}" -gt 0 ]; then
      local missing_file
      for missing_file in "${missing_from_index[@]}"; do
        _make_missing_file "$missing_file"
      done
      echo "The following files are missing from the index and must be dealt with manually:" >&2
      printf "  %s\n" "${missing_from_index[@]}" >&2
    fi
    if [ $err -ne 0 ]; then
      if [ -n "$reject_arg" ]; then
        echo "Please resolve conflicts manually." >&2
        echo "You can use the 'edit' command to edit unmerged/modified files." >&2
        echo "You can then use 'add' to check in your changes, and 'resume' to continue." >&2
      else
        echo "Please review and apply the patch manually." >&2
        echo "Use the 'show' command as a shortcut to view the patch." >&2
        echo "You can then use 'add' to check them in, and 'resume' to continue." >&2
      fi
    fi
  fi
  if [ $err -eq 0 ] && is_var_true EXPORT_APPLIED_PATCHES; then
    export_single_patch || return $?
  fi
  return $err
}

apply_patches_stop() {
  find_chromium_custom_buildfiles_path || return $?
  if ! is_apply_patches_active; then
    echo "Nothing to stop." >&2
    return 0
  fi
  rm -fv "$(_get_apply_patches_todo_path)"
}

apply_wiggle() {
  find_chromium_custom_buildfiles_path || return $?
  local rejects
  mapfile -t rejects < <(git_chromium ls-files --others --exclude-standard '*.rej')
  git_chromium add -A ':!*.rej'
  local reject
  local stillfailed=()
  local err=
  for reject in "${rejects[@]}"; do
    local thiserr=
    wiggle --no-backup --no-ignore --replace "${reject%.rej}" "$reject" || thiserr=$?
    if [ -n "$thiserr" ]; then
      err=$?
      stillfailed+=("${reject%.rej}")
    else
      git_chromium add "${reject%.rej}"
    fi
    rm -fv "$reject"
  done
  if [ -n "$err" ]; then
    echo "Could not resolve all conflicts with wiggle." >&2
    echo "Please examine the following files:" >&2
    printf "  %s\n" "${stillfailed[@]}" >&2
    return 1
  elif [ "${NO_CONTINUE:-0}" = "0" ]; then
    echo "Continuing with wiggled patch..." >&2
    git_chromium am --continue || return $?
  fi
}

apply_patches_status() {
  find_chromium_custom_buildfiles_path || return $?
  if ! is_apply_patches_active; then
    echo "Not active" >&2
    return 0
  fi
  "${PAGER:-more}" "$(_get_apply_patches_todo_path)"
}

_make_missing_file() {
  [ ! -e "$1" ] || return 0
  local dir="$(dirname "$1")"
  mkdir -p "$dir"
  echo 'FIXME! FILE TO BE PATCHED WAS MISSING; DO NOT MERGE THIS.' >> "$1"
}

### PATCH MANAGEMENT ###
export_single_patch() {
  find_chromium_custom_buildfiles_path || return $?
  find_chromium_src_path || return $?
  local patchfile=$(git_chromium format-patch --full-index -N -k -P --zero-commit -1 --no-numbered \
    --output-directory "$(_get_patches_dir)" "$@") || return $?
  tweak_patch_format "$patchfile" || return $?
  local renamed_patchfile="$(printf "%s\n" "$patchfile" | sed -e 's!/[0-9]\+\-\([^/]\+\)$!/\1!')" || return $?
  mv "$patchfile" "$renamed_patchfile" || return $?
}

tweak_patches_format() {
  find_chromium_src_path || return $?
  local patchfile
  for patchfile in "${1:-$CHROMIUM_SRC_PATH}"/0*.patch; do
    tweak_patch_format "$patchfile" || return $?
  done
}

tweak_patch_format() {
  # TODO: can (some of) these be combined into a single sed invocation with multiple expressions?
  sed -i '/From 0000000000000000000000000000000000000000/d' "$1"
  sed -i -z -E 's/\nindex [a-f0-9]{40}\.\.[a-f0-9]{40}( [0-9]+)?\n---/\n---/g' "$1"
  sed -i -E '/^[0-9]+\.[0-9]+\.[0-9]+$/d' "$1"
}

output_patches() {
  find_chromium_src_path || return $?
  local upstream_branch
  upstream_branch="$(git -C "${1:-$CHROMIUM_SRC_PATH}" rev-parse --abbrev-ref --symbolic-full-name @{u})" || return $?
  [ -n "$upstream_branch" ] || upstream_branch="${V:-}"
  [ -n "$upstream_branch" ] || { echo "Upstream branch expected. Set one or something!" >&2; return 2; }
  local left_right
  left_right="$(git -C "${1:-$CHROMIUM_SRC_PATH}" rev-list --left-right --count "$upstream_branch"...HEAD)" || return $?
  [ -n "$left_right" ] || { echo "Error getting commits ahead and behind." >&2; return 1; }
  local behind=$(printf "%s\n" "$left_right" | cut -d$'\t' -f1)
  [ "$behind" == "0" ] || { echo "Expected not to be behind upstream, but behind by $behind commits" >&2; return 1; }
  local ahead=$(printf "%s\n" "$left_right" | cut -d$'\t' -f2)
  for patchfile in "$CHROMIUM_SRC_PATH/0"*.patch; do
    [ -e "$patchfile" ] || continue
    echo "Please ensure that there are no numbered .patch files in $CHROMIUM_SRC_PATH" >&2
    return 2
  done
  git -C "${1:-$CHROMIUM_SRC_PATH}" format-patch --full-index -N -k -P --zero-commit -"$ahead" || return $?
  tweak_patches_format "$@" || return $?
}

update_patches() {
  output_patches "$@" || return $?
  update_patches_lists "$@" || return $?
  remove_old_patches "$@" || return $?
  move_all_patches "$@" || return $?
}

update_patches_lists() {
  find_chromium_custom_buildfiles_path || return $?
  (cd "${1:-$CHROMIUM_SRC_PATH}" && ls -1 0*.patch | cut -d - -f 2- | sed -n "$FIRST_VENDOR_PATCH_REGEX"'q;p' > "$CHROMIUM_CUSTOM_BUILDFILES_PATH/01-cromite_patches_list.txt") || return $?
  (cd "${1:-$CHROMIUM_SRC_PATH}" && ls -1 0*.patch | cut -d - -f 2- | sed -n "$FIRST_VENDOR_PATCH_REGEX"',$p' > "$CHROMIUM_CUSTOM_BUILDFILES_PATH/02-calyx_patches_list.txt")
}

copy_existing_change_ids() {
  find_chromium_custom_buildfiles_path || return $?
  local line
  local file
  while read line; do
    file="$(printf "%s\n" "$line" | cut -d':' -f1)"
    file="$(basename "$file")"
    echo "$file"
    change="$(printf "%s\n" "$line" | cut -d':' -f2-)"
    echo "$change"
    local f
    for f in 0*-$file; do
      [ -f "$f" ] || break
      grep -Fq Change-Id "$f" || { sed -r -i -e "s/^---\$/\n$change\n---/" "$f"; }
      break
    done
  done < <(grep -m1 'Change-Id' "$(_get_patches_dir)/"*.patch)
}

rename_all_patches() {
  local patchfile
  for patchfile in *.patch; do
    mv "$patchfile" "$(printf "%s\n" "$patchfile" | cut -d - -f 2-)"
  done
}

remove_old_patches() {
  find_chromium_custom_buildfiles_path || return $?
  mv "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/FIRST-Add-git-review-configuration.patch"{,.2}
  rm "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/"*.patch
  mv "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/FIRST-Add-git-review-configuration.patch"{.2,}
}

move_all_patches() {
  find_chromium_custom_buildfiles_path || return $?
  local patchfile
  for patchfile in "${1:-$CHROMIUM_SRC_PATH}"/0*.patch; do
    mv "${patchfile}" "$(printf "%s\n" "$patchfile" | cut -d - -f 2-)"
  done
  mv *.patch "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/"
}

### CROMITE SYNCING ###
sync_cromite() {
  _maybe_warn_about_dirty_cromite || return $?
  _maybe_warn_about_dirty_chromium_src || return $?
  _maybe_warn_about_dirty_chromium_custom_buildfiles || return $?
  if is_apply_patches_active; then
    echo "You are already in the middle of applying patches!" >&2
    echo "To resume, run: apply_patches_resume" >&2
    echo "To stop, run: apply_patches_stop" >&2
    echo '(Note that stopping does not undo any patches already applied.)' >&2
    return 1
  fi
  _maybe_error_about_unset_chromium_version || return $?
  local calyx_branch="refs/heads/calyxos-$V"
  if ! git_chromium rev-parse "$calyx_branch"; then
    echo "Please run update_chromium_sources before trying to use version $V with sync_cromite." >&2
    return 1
  fi
  update_cromite_sources || return $?
  local err=0
  local our_patches
  our_patches="$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches"
  local their_patches
  their_patches="$CROMITE_PATH/build/patches"
  (cd "$our_patches" && cat ../01-cromite_patches_list.txt | xargs -d'\n' rm) || return $?
  cp "$their_patches/"*.patch "$our_patches/" || return $?

  # rename the usual suspects
  (
    cd "$our_patches"
    mv Disable-ranker-url-fetcher.patch Disable-ranker_url_fetcher.patch
    mv Revert-remove-allowscript-content-setting-secondary-url.patch Revert-remove-AllowScript-content-settings-per-secon.patch
    mv Multiple-fingerprinting-mitigations.patch PARTIAL-Multiple-fingerprinting-mitigations.patch
  ) || { err=$?; echo "error: Failed to rename a patch. Please examine the situation manually and perhaps update $0" >&2; return $err; }

  # review differences with PARTIAL-Multiple-fingerprinting-mitigations.patch and adapt it
  # if it hasn't really changed, just check out the partial
  echo "1. Please use 'git status | grep deleted' and deal with any deletions/renames." >&2
  echo "2. Please use 'git diff -- PARTIAL-Multiple-fingerprinting-mitigations.patch' to see if much has changed." >&2
  echo "   If it has not, type: git checkout -- PARTIAL-Multiple-fingerprinting-mitigations.patch" >&2
  echo "   Otherwise, figure it out!" >&2
  echo "   When done, type 'exit'." >&2
  drop_to_shell "sync_cromite" "$our_patches"

  #git_custom_buildfiles checkout -- PARTIAL-Multiple-fingerprinting-mitigations.patch

  git_custom_buildfiles clean -f || return $?
  git_custom_buildfiles commit -a -m "WIP Sync with Cromite $CROMITE_VERSION" || err=$?
  if [ $err -ne 0 ]; then
    echo >&2
    echo "error: Failed to commit WIP sync! Maybe there are no changes...?" >&2
    return $err
  fi

  ### in src! (needs wip helpers.sh)
  git_chromium checkout --detach HEAD
  git_chromium branch -D tmp 2>/dev/null || true
  git_chromium checkout "$V" -b tmp || return $?

  drop_to_shell "sync_cromite" "$CHROMIUM_SRC_PATH" \
    "EXPORT_APPLIED_PATCHES=n; if apply_patches; then exit; else echo 'Once all patches are completely applied, type: exit'; fi"

  output_patches || return $?

  ### back here (not src)
  git_custom_buildfiles revert HEAD --no-edit || return $?

  ### in src
  copy_existing_change_ids || return $?

  ### back here (not src)
  git_custom_buildfiles reset --hard HEAD~1 || return $?

  ### in src again
  update_patches_lists || return $?
  rename_all_patches || return $?
  move_all_patches || return $?

  ### back here
  git_custom_buildfiles commit -a --amend # writing this commit msg now
}

update_cromite_sources() {
  find_cromite_path || return $?
  if [ -z "${CROMITE_VERSION:-}" ]; then
    show_cromite_releases
    local latest_release="$(printf "%s\n" "$CROMITE_RELEASES" \
      | process_version_tags \
      | tail -n1)"
    echo "----" >&2
    echo "Please set CROMITE_VERSION to the desired version of Cromite first. For example:" >&2
    echo "  CROMITE_VERSION=$latest_release" >&2
    echo "See above for the last few tagged releases of Cromite, if needed." >&2
    return 2
  fi
  # TODO: Fix this hacky way of dealing with CROMITE_VERSION, maybe.
  case "$CROMITE_VERSION" in
    next*)
      git_cromite fetch "$CROMITE_REMOTE" "refs/heads/$CROMITE_VERSION" || return $?
      git_cromite checkout "$CROMITE_REMOTE/$CROMITE_VERSION" || return $?
      ;;
    *)
      git_cromite fetch "$CROMITE_REMOTE" "refs/tags/$CROMITE_VERSION:refs/tags/$CROMITE_VERSION" || return $?
      git_cromite checkout "$CROMITE_VERSION" || return $?
      ;;
  esac
}

### BRAVE HANDLING ###
find_brave_versions() {
  local err=0
  if [ -z "${BOV:-}" ]; then
    BOV="$(get_previous_brave_version)" || err=$?
    if [ $err -ne 0 ]; then
      echo "Could not deduce \$BOV; please set it manually" >&2
      return $err
    fi
    echo "\$BOV (brave-core old version) was not specified; deduced from patch, now set to $BOV"
  fi
  if [ -z "${BV:-}" ]; then
    BV="$(get_latest_brave_version)" || err=$?
    if [ $err -ne 0 ]; then
      echo "Could not deduce \$BV; please set it manually" >&2
      return $err
    fi
    echo "\$BV (brave-core new version) not specified; now set to latest version tag, $BV"
  fi
}

_maybe_fetch_brave_tags() {
  local v
  for v in "$BOV" "$BV"; do
    [ -n "$(git_brave tag -l "$v")" ] || git_brave fetch "$BRAVE_REMOTE" "refs/tags/$v:refs/tags/$v" || return $?
  done
}

show_brave_changes() {
  show_brave_changes_full --oneline --reverse "$@"
}

show_brave_changes_full() {
  find_brave_versions || return $?
  _maybe_fetch_brave_tags || return $?
  git_brave log "$BOV".."$BV" "$@"
}

show_brave_relevant_changes() {
  show_brave_relevant_changes_full --oneline --reverse "$@"
}

show_brave_relevant_changes_full() {
  # populate brave versions now; otherwise it may only happen in the subshell later.
  find_brave_versions || return $?
  # also do this now so that it doesn't interrupt clean git output later.
  _maybe_fetch_brave_tags || return $?
  # we want to show the output of multiple git commands in a single pager (when a pager would be used)
  local pager
  local pagerargs
  local color
  if [[ $- == *i* ]]; then
    # interactive
    color=--color=always
    pager="${GIT_PAGER:-${PAGER:-}}"
    if [ "$(basename "$pager")" = "less" ]; then
      # preserve color codes, quit if one screen, and keep on screen on quit
      # seems to match git behavior
      pagerargs="-R -F -X"
    fi
  else
    # non-interactive
    color=
    pager=cat
  fi
  (
    echo '###'
    echo '### PRIVACY/SECURITY-RELEVANT CHANGES (by regex):'
    echo '###'
    show_brave_changes_full $color -i --grep "$BRAVE_RELEVANT_CHANGE_COMMITMSG_REGEX" "$@"
    echo
    echo '###'
    echo '### FEATURE UNITTEST CHANGES:'
    echo '###'
    show_brave_changes_full $color --full-diff "$@" -- app/feature_defaults_unittest.cc
    echo
    echo '###'
    echo '### OTHER FEATURE-INVOLVED CHANGES:'
    echo '###'
    show_brave_changes_full $color -G "$BRAVE_RELEVANT_CHANGE_FEATURES_REGEX" "$@"
  ) | "$pager" $pagerargs
}

get_previous_brave_version() {
  # TODO: Maybe use a metadata file in our custom_buildfiles repo for BOV instead of guessing.
  find_chromium_custom_buildfiles_path || return $?
  head -n 10 "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/Bring-in-Brave-feature-states-for-privacy-security.patch" \
    | sed -n -e 's/.*brave-core tag \(v[0-9a-f.\-]\+\).*/\1/p' | head -n 1 || return $?
}

get_latest_brave_version() {
  find_brave_path || return $?
  show_brave_releases 1 || return $?
}

### UTILITIES ###
drop_to_shell() {
  # arg1: prompt
  # arg2: working dir
  # arg3: additional commands to run
  local this_path="$(realpath "${BASH_SOURCE[0]}")"
  bash --init-file <(printf "PS1=%q; source %q; cd %q; %s\n"   "${1:-fixme}"'$'" "   "$this_path"   "${2:-.}" "${3:-}")
}

remove_comments() {
  # currently only support comments that make up a full line
  grep -v '^\s*#'
}

is_var_true() {
  is_true "${!1}" "$1" || return $?
}

is_true() {
  case "${1,,}" in
    true|yes|y|on|1)
      return 0
      ;;
    *)
      if ! is_false "$1"; then
        echo "warning: variable $2 with value $1 is not false or true; treating as false" >&2
      fi
      return 1
      ;;
  esac
}

is_false() {
  case "${1,,}" in
    false|no|n|off|0)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
