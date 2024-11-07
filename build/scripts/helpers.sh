# This shell script is intended to be source'd.

FIRST_VENDOR_PATCH_REGEX='/CalyxOS.*[Bb]randing/'
VENDOR_PATCHES_MARKER=

n() {
  git diff --name-only --diff-filter=U | xargs --open-tty nano '+/<<<<<<<'
}

a() {
  git diff --name-only --diff-filter=U | xargs git add
}

c() {
  git cherry-pick --continue "$@"
}

output_patches() {
  find_chromium_src_path || return $?
  local upstream_branch=$(git rev-parse --abbrev-ref --symbolic-full-name @{u})
  [ -n "$upstream_branch" ] || upstream_branch="${V:-}"
  [ -n "$upstream_branch" ] || { echo "Upstream branch expected. Set one or something!"; return 1; }
  local left_right=$(git rev-list --left-right --count "$upstream_branch"...HEAD)
  [ -n "$left_right" ] || { echo "Error getting commits ahead and behind."; return 1; }
  local behind=$(printf "%s\n" "$left_right" | cut -d$'\t' -f1)
  [ "$behind" == "0" ] || { echo "Expected not to be behind upstream, but behind by $behind commits"; return 1; }
  local ahead=$(printf "%s\n" "$left_right" | cut -d$'\t' -f2)
  for patchfile in 0*.patch; do
    [ -e "$patchfile" ] || continue
    echo "Please ensure that there are no numbered .patch files in $CHROMIUM_SRC_PATH" >&2
    return 1
  done
  git format-patch --full-index -N -k -P --zero-commit -"$ahead" || return $?
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
    return 1
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
  find_chromium_buildtools_path || return $?
  ls -1 *.patch | cut -d - -f 2- | sed -n "$FIRST_VENDOR_PATCH_REGEX"'q;p' > "$CHROMIUM_BUILDTOOLS_PATH/cromite_patches_list.txt"
  ls -1 *.patch | cut -d - -f 2- | sed -n "$FIRST_VENDOR_PATCH_REGEX"',$p' > "$CHROMIUM_BUILDTOOLS_PATH/calyx_patches_list.txt"
}

copy_existing_change_ids() {
  find_chromium_buildtools_path || return $?
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
  done < <(grep -m1 'Change-Id' "$CHROMIUM_BUILDTOOLS_PATH/build/patches/"*.patch)
}

rename_all_patches() {
  local patchfile
  for patchfile in *.patch; do
    mv "$patchfile" "$(printf "%s\n" "$patchfile" | cut -d - -f 2-)"
  done
}

move_all_patches() {
  find_chromium_buildtools_path || return $?
  mv "$CHROMIUM_BUILDTOOLS_PATH/patches/FIRST-Add-git-review-configuration.patch"{,.2}
  rm "$CHROMIUM_BUILDTOOLS_PATH/patches/"*.patch
  mv "$CHROMIUM_BUILDTOOLS_PATH/patches/FIRST-Add-git-review-configuration.patch"{.2,}
  local patchfile
  for patchfile in 0*.patch; do
    mv "${patchfile}" "$(printf "%s\n" "$patchfile" | cut -d - -f 2-)"
  done
  mv *.patch "$CHROMIUM_BUILDTOOLS_PATH/patches/"
}

find_chromium_buildtools_path() {
  [ -z "${CHROMIUM_BUILDTOOLS_PATH:-}" ] || return 0
  local path="$(realpath "$(dirname "$0")/..")"
  case "$path" in
    */build)
      ;;
    *)
      echo "Could not find Chromium build tools path. Expected it to be our parent directory!" >&2
      return 1
  esac
  if [ ! -d "$path/patches" ]; then
    echo "Missing patches folder in Chromium build tools path '$path'" >&2
    return 1
  fi
  CHROMIUM_BUILDTOOLS_PATH="$path"
}

find_chromium_src_path() {
  echo "NOT YET IMPLEMENTED"
  return 1
}

find_chromium_buildtools_path
find_chromium_src_path

### CHROMIUM VERSION QUERYING ###
CHROMIUM_STABLE_RELEASES_TO_FETCH=6
CHROMIUM_STABLE_RELEASES_JSON_URL="https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Android&num=$CHROMIUM_STABLE_RELEASES_TO_FETCH&offset=0"
CHROMIUM_STABLE_RELEASES_JQ='[.[] | select(.channel == "Stable")] | sort_by(.version|split(".")|map(tonumber))'

query_latest_chromium_stable() {
  CHROMIUM_STABLE_RELEASES_JSON="$(wget -qO- "$CHROMIUM_STABLE_RELEASES_JSON_URL")"
}

show_chromium_stable() {
  local count="${1:-2}"
  case "$count" in
    *[!0-9]*) # not a number
      echo "usage: show_chromium_stable [count]"
      echo
      echo "Lists the [count] most recent chromium stable versions, defaulting to 2 most recent."
      echo "The releases are cached in the CHROMIUM_STABLE_RELEASES_JSON environment variable;"
      echo "they can be refreshed by running query_latest_chromium_stable or clearing the variable."
      case "$count" in
        -h|--help)
          return 0
          ;;
      esac
      return 1
      ;;
  esac
  if [ "$count" -gt "$CHROMIUM_STABLE_RELEASES_TO_FETCH" ]; then
    echo "Warning: Cannot list $count versions of Chromium" \
      "as we only fetch $CHROMIUM_STABLE_RELEASES_TO_FETCH" >&2
  fi
  [ -n "${CHROMIUM_STABLE_RELEASES_JSON:-}" ] || query_latest_chromium_stable
  printf "%s\n" "$CHROMIUM_STABLE_RELEASES_JSON" \
    | jq -r "$CHROMIUM_STABLE_RELEASES_JQ | .[-$count:]"
}
