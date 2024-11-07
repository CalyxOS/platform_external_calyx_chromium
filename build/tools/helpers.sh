# This shell script is intended to be source'd.
# We expect bash.

FIRST_VENDOR_PATCH_REGEX='/CalyxOS.*[Bb]randing/'

git_chromium() {
  git -C "$CHROMIUM_SRC_PATH" "$@"
}

git_custom_buildfiles() {
  git -C "$CHROMIUM_CUSTOM_BUILDFILES_PATH" "$@"
}

n() {
  git_chromium diff --name-only --diff-filter=U | xargs --open-tty nano '+/<<<<<<<'
}

a() {
  git_chromium diff --name-only --diff-filter=U | xargs git -C "$CHROMIUM_SRC_PATH" add
}

c() {
  git_chromium cherry-pick --continue "$@"
}

output_patches() {
  find_chromium_src_path || return $?
  local upstream_branch=$(git_chromium rev-parse --abbrev-ref --symbolic-full-name @{u})
  [ -n "$upstream_branch" ] || upstream_branch="${V:-}"
  [ -n "$upstream_branch" ] || { echo "Upstream branch expected. Set one or something!"; return 2; }
  local left_right=$(git_chromium rev-list --left-right --count "$upstream_branch"...HEAD)
  [ -n "$left_right" ] || { echo "Error getting commits ahead and behind."; return 1; }
  local behind=$(printf "%s\n" "$left_right" | cut -d$'\t' -f1)
  [ "$behind" == "0" ] || { echo "Expected not to be behind upstream, but behind by $behind commits"; return 1; }
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
  move_all_patches || return $?
}

build() {
  find_chromium_src_path || return $?
  if [ -z "$topdir" ] || [ -z "$OUT" ]; then
    echo "please set topdir and OUT"
    return 2
  fi
  time autoninja -k 0 -C "$OUT" trichrome_chrome_64_32_bundle trichrome_library_64_32_apk trichrome_webview_64_32_apk system_webview_shell_apk && \
    pushd "$OUT/apks"     && \
    rm -f universal.apk     && \
    java -jar "$topdir/third_party/android_build_tools/bundletool/cipd/bundletool.jar" build-apks --mode universal --bundle TrichromeChrome6432.aab --output . --output-format DIRECTORY     && \
    popd
}

tweak_patches_format() {
  sed -i '/From 0000000000000000000000000000000000000000/d' *.patch
  sed -i -z -E 's/\nindex [a-f0-9]{40}\.\.[a-f0-9]{40}( [0-9]+)?\n---/\n---/g' *.patch
  sed -i -E '/^[0-9]+\.[0-9]+\.[0-9]+$/d' *.patch
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
    file="$(echo "$line" | cut -d':' -f1)"
    file="$(basename "$file")"
    echo "$file"
    change="$(echo "$line" | cut -d':' -f2-)"
    echo "$change"
    local f
    for f in 0*-$file; do
      [ -f "$f" ] || break
      grep -Fq Change-Id "$f" || { sed -r -i -e "s/^---\$/\n$change\n---/" "$f"; }
      break
    done
  done < <(grep -m1 'Change-Id' "$CHROMIUM_CUSTOM_BUILDFILES_PATH/build/patches/"*.patch)
}

rename_all_patches() {
  local patchfile
  for patchfile in *.patch; do
    mv "$patchfile" "$(printf "%s\n" "$patchfile" | cut -d - -f 2-)"
  done
}

move_all_patches() {
  find_chromium_custom_buildfiles_path || return $?
  mv "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/FIRST-Add-git-review-configuration.patch"{,.2}
  rm "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/"*.patch
  mv "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/FIRST-Add-git-review-configuration.patch"{.2,}
  local patchfile
  for patchfile in 0*.patch; do
    mv "${patchfile}" "$(printf "%s\n" "$patchfile" | cut -d - -f 2-)"
  done
  mv *.patch "$CHROMIUM_CUSTOM_BUILDFILES_PATH/patches/"
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
    case "$(git -C "$curpath" remote get-url origin)" in
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

find_chromium_custom_buildfiles_path
find_chromium_src_path

### CHROMIUM VERSION QUERYING ###
[ -n "${CHROMIUM_STABLE_RELEASES_TO_FETCH:-}" ] \
  || CHROMIUM_STABLE_RELEASES_TO_FETCH=6
[ -n "${CHROMIUM_STABLE_RELEASES_JSON_URL:-}" ] \
  || CHROMIUM_STABLE_RELEASES_JSON_URL="https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Android&num=$CHROMIUM_STABLE_RELEASES_TO_FETCH&offset=0"
[ -n "${CHROMIUM_STABLE_RELEASES_QUERY:-}" ] \
  || CHROMIUM_STABLE_RELEASES_QUERY='[.[] | select(.channel == "Stable")] | sort_by(.version|split(".")|map(tonumber))'

query_calyx_chromium_releases() {
  CALYX_CHROMIUM_RELEASES="$(git_custom_buildfiles ls-remote origin --refs --tags 'refs/tags/*-calyx')"
}

query_chromium_stable_releases() {
  CHROMIUM_STABLE_RELEASES_JSON="$(wget -qO- "$CHROMIUM_STABLE_RELEASES_JSON_URL")"
}

show_chromium_stable_releases() {
  local count="${1:-2}"
  case "$count" in
    *[!0-9]*) # not a number
      echo "usage: show_chromium_stable_releases [count]"
      echo
      echo "Lists the [count] most recent chromium stable versions, defaulting to 2 most recent."
      echo "The releases are cached in the CHROMIUM_STABLE_RELEASES_JSON environment variable;"
      echo "they can be refreshed by running query_chromium_stable_releases or clearing the variable."
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
      echo "usage: show_calyx_chromium_releases [count]"
      echo
      echo "Lists the [count] highest Calyx Chromium version numbers, defaulting to 2."
      echo "The releases are cached in the CALYX_CHROMIUM_RELEASES environment variable;"
      echo "they can be refreshed by running query_calyx_chromium_releases or clearing the variable."
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
  update_calyx_chromium_sources || return $?
  update_chromium_sources || return $?
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
    echo "----"
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
  git_chromium fetch origin "refs/tags/$V:refs/tags/$V" || return $?
  git_chromium checkout -b calyxos-$V "$V" || return $?
  (cd "$CHROMIUM_SRC_PATH" && gclient sync -D && gclient runhooks) || return $?
}

update_calyx_chromium_sources() {
  find_chromium_custom_buildfiles_path || return $?
  if [ -z "${V:-}" ]; then
    show_calyx_chromium_releases
    local latest_release="$(printf "%s\n" "$CALYX_CHROMIUM_RELEASES" \
      | process_calyx_chromium_releases \
      | tail -n1)"
    echo "----"
    echo "Please set V to the desired version of Calyx Chromium first. For example:" >&2
    echo "  V=$latest_release" >&2
    echo "See above details for the last few releases of Calyx Chromium, if needed." >&2
    echo "Note that this represents releases on the $(git_custom_buildfiles branch --show-current) branch;" >&2
    echo "if there are newer branches, they may have newer versions." >&2
    return 2
  fi
  git_custom_buildfiles fetch origin "refs/tags/$V-calyx:refs/tags/$V-calyx" || return $?
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
  if [ -n "$(git_chromium status --porcelain 2>&1)" ]; then
    echo "WARNING: chromium repo is not clean." >&2
    git_chromium status || true
    return 2
  elif [ -z "$(git_chromium branch --show-current >/dev/null 2>&1)" ]; then
    echo "WARNING: chromium repo is not on a branch. Work may be lost if you proceed." >&2
    return 2
  fi
}
