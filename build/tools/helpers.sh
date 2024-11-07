# This shell script is intended to be source'd.
# We expect bash.

FIRST_VENDOR_PATCH_REGEX='/CalyxOS.*[Bb]randing/'
CHROMIUM_SRC_REMOTE="${CHROMIUM_SRC_REMOTE:-origin}"
CHROMIUM_CUSTOM_BUILDFILES_REMOTE="${CHROMIUM_CUSTOM_BUIDFILES_REMOTE:-origin}"
USE_WIGGLE="${USE_WIGGLE:-y}"
# CHROMIUM_SRC_PATH defaults to an educated guess
# CHROMIUM_CUSTOM_BUILDFILES_PATH defaults to an educated guess (typically representing the build subdir of the platform_external_calyx_chromium repo)
# CHROMIUM_CUSTOM_BUILDFILES_PATCHLIST_PATH defaults to CHROMIUM_CUSTOM_BUILDFILES_PATH
# CHROMIUM_CUSTOM_BUILDFILES_STATUS_PATH defaults to status subdir of CHROMIUM_CUSTOM_BUILDFILES_PATH
# CHROMIUM_CUSTOM_BUILDFILES_PATCHES_PATH defaults to patches subdir of CHROMIUM_CUSTOM_BUILDFILES_PATH

git_chromium() {
  git -C "$CHROMIUM_SRC_PATH" "$@" || return $?
}

git_custom_buildfiles() {
  git -C "$CHROMIUM_CUSTOM_BUILDFILES_PATH" "$@" || return $?
}

e() {
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

a() {
  # add files that are marked as unmerged or modified
  local files="$(git_chromium diff --name-only --diff-filter=UM)"
  if [ -z "$files" ]; then
    echo "Nothing to add" >&2
    return 0
  fi
  printf "%s\n" "$files" | xargs git -C "$CHROMIUM_SRC_PATH" add
}

c() {
  find_chromium_src_path || return $?
  git_chromium am --continue "$@" || return $?
  export_single_patch || return $?
  apply_patches_resume || return $?
}

build() {
  find_chromium_src_path || return $?
  if [ -z "$topdir" ] || [ -z "$OUT" ]; then
    echo "please set topdir and OUT" >&2
    return 2
  fi
  time autoninja -k 0 -C "$OUT" trichrome_chrome_64_32_bundle trichrome_library_64_32_apk trichrome_webview_64_32_apk system_webview_shell_apk && \
    pushd "$OUT/apks"     && \
    rm -f universal.apk     && \
    java -jar "$topdir/third_party/android_build_tools/bundletool/cipd/bundletool.jar" build-apks --mode universal --bundle TrichromeChrome6432.aab --output . --output-format DIRECTORY     && \
    popd
}

find_chromium_custom_buildfiles_path() {
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
  [ -z "${CHROMIUM_SRC_PATH:-}" ] || return 0
  local possible_path
  for possible_path in "$(pwd)" "$HOME/chromium/src"; do
    [ -n "$possible_path" ] || continue
    local curdir="$(pwd)"
    case "$(git -C "$curpath" remote get-url "$CHROMIUM_SRC_REMOTE")" in
      https://chromium.googlesource.com/chromium/src*)
        CHROMIUM_SRC_PATH="$curdir"
        return 0
        ;;
    esac
  done
  echo "Could not find chromium src directory." >&2
  echo "Please chdir to the src directory or set CHROMIUM_SRC_PATH." >&2
  return 2
}

### CHROMIUM VERSION QUERYING ###
[ -n "${CHROMIUM_STABLE_RELEASES_TO_FETCH:-}" ] \
  || CHROMIUM_STABLE_RELEASES_TO_FETCH=6
[ -n "${CHROMIUM_STABLE_RELEASES_JSON_URL:-}" ] \
  || CHROMIUM_STABLE_RELEASES_JSON_URL="https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Android&num=$CHROMIUM_STABLE_RELEASES_TO_FETCH&offset=0"
[ -n "${CHROMIUM_STABLE_RELEASES_QUERY:-}" ] \
  || CHROMIUM_STABLE_RELEASES_QUERY='[.[] | select(.channel == "Stable")] | sort_by(.version|split(".")|map(tonumber))'

query_calyx_chromium_releases() {
  CALYX_CHROMIUM_RELEASES="$(git_custom_buildfiles ls-remote "$CHROMIUM_CUSTOM_BUILDFILES_REMOTE" --refs --tags 'refs/tags/*-calyx')"
}

query_chromium_stable_releases() {
  CHROMIUM_STABLE_RELEASES_JSON="$(wget -qO- "$CHROMIUM_STABLE_RELEASES_JSON_URL")"
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
  local err=0
  maybe_warn_about_branch_already_exists || return $?
  maybe_warn_about_same_upstream || err=$?
  maybe_warn_about_dirty_src || err=$?
  if [ $err -ne 0 ]; then
    if [ -z "$do_force" ]; then
      echo "ERROR: Not proceeding without --force" >&2
      return $err
    else
      echo "WARNING: Proceeding anyway, given --force" >&2
    fi
  fi
  git_chromium fetch "$CHROMIUM_SRC_REMOTE" "refs/tags/$V:refs/tags/$V" || return $?
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

maybe_warn_about_same_upstream() {
  if [ "$(get_current_upstream)" = "refs/tags/$V" ]; then
    echo "WARNING: The current upstream is the same as the desired upstream: $V." >&2
    echo "To proceed may be redundant." >&2
    return 2
  fi
}

maybe_warn_about_branch_already_exists() {
  local calyx_branch="refs/heads/calyxos-$V"
  if git_chromium rev-parse "$calyx_branch" >/dev/null 2>&1; then
    echo "WARNING: Branch $calyx_branch already exists. It must be deleted to proceed." >&2
    return 2
  fi
}

maybe_warn_about_dirty_src() {
  # TODO: Is there a more comprehensive way to determine if git is in the middle of something?
  # Right now we just check a couple of things.
  if [ -n "$(git_chromium status --porcelain 2>&1)" ] \
      || git_chromium am --show-current-patch >/dev/null 2>&1 \
      || git_chromium show CHERRY_PICK_HEAD >/dev/null 2>&1 \
      || git_chromium show REBASE_HEAD >/dev/null 2>&1; then
    echo "WARNING: chromium repo is not clean or is in the middle of something." >&2
    git_chromium status || true
    return 2
  elif [ -z "$(git_chromium branch --show-current 2>/dev/null)" ]; then
    echo "WARNING: chromium repo is not on a branch. Work may be lost if you proceed." >&2
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
  maybe_warn_about_dirty_src || return $?
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
  maybe_warn_about_dirty_src || return $?
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
        echo "Please review and apply the patch manually." >&2
        echo "You can then use 'a' to check in your changes, and 'c' to continue." >&2
      else
        echo "Please resolve conflicts manually." >&2
        echo "You can use the 'e' command to edit all unmerged/modified files." >&2
        echo "You can then use 'a' to check them in, and 'c' to continue." >&2
      fi
    fi
  fi
  if [ $err -eq 0 ]; then
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
  for patchfile in "$CHROMIUM_SRC_PATH"/*.patch; do
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
  local upstream_branch=$(git_chromium rev-parse --abbrev-ref --symbolic-full-name @{u})
  [ -n "$upstream_branch" ] || upstream_branch="${V:-}"
  [ -n "$upstream_branch" ] || { echo "Upstream branch expected. Set one or something!" >&2; return 2; }
  local left_right=$(git_chromium rev-list --left-right --count "$upstream_branch"...HEAD)
  [ -n "$left_right" ] || { echo "Error getting commits ahead and behind." >&2; return 1; }
  local behind=$(printf "%s\n" "$left_right" | cut -d$'\t' -f1)
  [ "$behind" == "0" ] || { echo "Expected not to be behind upstream, but behind by $behind commits" >&2; return 1; }
  local ahead=$(printf "%s\n" "$left_right" | cut -d$'\t' -f2)
  for patchfile in "$CHROMIUM_SRC_PATH/0"*.patch; do
    [ -e "$patchfile" ] || continue
    echo "Please ensure that there are no numbered .patch files in $CHROMIUM_SRC_PATH" >&2
    return 2
  done
  git_chromium format-patch --full-index -N -k -P --zero-commit -"$ahead" || return $?
  tweak_patches_format || return $?
}

update_patches() {
  output_patches || return $?
  update_patches_lists || return $?
  remove_old_patches || return $?
  move_all_patches || return $?
}

update_patches_lists() {
  find_chromium_custom_buildfiles_path || return $?
  ls -1 *.patch | cut -d - -f 2- | sed -n "$FIRST_VENDOR_PATCH_REGEX"'q;p' > "$CHROMIUM_CUSTOM_BUILDFILES_PATH/cromite_patches_list.txt"
  ls -1 *.patch | cut -d - -f 2- | sed -n "$FIRST_VENDOR_PATCH_REGEX"',$p' > "$CHROMIUM_CUSTOM_BUILDFILES_PATH/calyx_patches_list.txt"
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
  for patchfile in 0*.patch; do
    mv "${patchfile}" "$(printf "%s\n" "$patchfile" | cut -d - -f 2-)"
  done
  mv *.patch "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/"
}

### UTILITIES ###
remove_comments() {
  # currently only support comments that make up a full line
  grep -v '^\s*#'
}

is_var_true() {
  is_true "${!1}" "$1"
}

is_true() {
  case "${1,,}" in
    true|yes|y|on|1)
      return 0
      ;;
    *)
      if ! is_false "$1"; then
        echo "warning: variable $2 with value $1 is not false or true; treating as false" >&2
        return 1
      fi
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
