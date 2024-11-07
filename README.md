Building CalyxOS Chromium

This guide is a work in progress! Please see our website for the latest official guide:
https://calyxos.org/docs/development/build/chromium/

The following is presented in the form of comments and instructions followed by commands.

Do not copy and paste entire segments of commands directly into a terminal!

Please read the comments and instructions before running the commands. Often, manual steps
are required. Where a manual step is required, `# MANUAL:` will be shown.

Where script enhancements are warranted, `# FIXME:` is listed to indicate a potential area
for improvement by a maintainer. Until such a fix, require manual intervention may be required.

# Prerequisites
This guide assumes that all of the Chromium-related repos are present in ~/chromium, such that
~/chromium/src is the primary source directory, and the CalyxOS Chromium build files repo is
available at ~/chromium/platform_external_calyx_chromium. If this is not desirable, please
adapt such paths if necessary.

## Required
### CalyxOS Chromium build files
If you do not already have a checkout of the CalyxOS Chromium build files,
please follow these steps:

```bash
mkdir -p ~/chromium
cd ~/chromium
# MANUAL: Replace `main` with whatever the current CalyxOS branch is, if not `main`.
git clone https://gitlab.com/CalyxOS/platform_external_calyx_chromium.git -b main
```

### Chromium
If you do not already have a Chromium checkout, please follow Chromium's howto:
https://www.chromium.org/developers/how-tos/get-the-code/

## Optional
### Brave (if porting to a newer major version)
Repo: https://github.com/brave/brave-core

Check out to ~/chromium/brave-core.

### Cromite (if porting to a newer major version)
Repo: https://github.com/uazo/cromite

Check out to ~/chromium/cromite.

### Wiggle (if porting to a newer version, major or otherwise)
Repo: https://github.com/neilbrown/wiggle

Build and place somewhere in PATH (e.g. ~/bin) so that it can be executed as `wiggle`.

# Common steps
```bash
# Manually update the CalyxOS Chromium build files to the latest available version.
# MANUAL: Replace `main` with whatever the current CalyxOS branch is, if not `main`.
cd ~/chromium/platform_external_calyx_chromium
git pull origin main

# Include the CalyxOS Chromium build helper functions.
# (Yes, this file path follows the same scheme as AOSP's build/envsetup.sh, but this is ours.)
source build/envsetup.sh

# Change to the existing Chromium checkout.
cd ~/chromium/src

# List the latest stable Chromium releases.
# Note: If the version you are targeting is not listed, try `show_chromium_beta_releases`
# or wait for it to hit early stable.
show_chromium_stable_releases

# MANUAL: Set the desired version to V. Exporting is not necessary.
# W.X.Y.Z is only an example. You must change it.
V='W.X.Y.Z'
```

# Building
Complete the [common steps](#common-steps). Then, continue below.

```bash
# Update the sources.
# See PORTING if you receive a "fatal: couldn't find remote ref" error, as that means Chromium
# is not currently ported to the specific version you specified, so you may have some work to do.
# If you receive "chromium repo is not clean or is in the middle of something"
# or a warning that it's not on a branch, and you know you don't have uncommitted code,
# or you're simply not concerned, you can add the ` --force` argument to the end.
# This command will automatically create a branch in the calyxos-$V pattern and switch you to it.
update_sources

# Apply patches.
apply_patches

# Build CalyxOS Chromium.
build

# The output can be found in the "$OUT/apks" directory.
# MANUAL: Typically, you'll want to copy "$OUT/apks/"*.apk (all .apk files) to the CalyxOS Chromium
# prebuilts repo (prebuilts_calyx_chromium).
```

# Porting
## Minor version
For a minor version update, e.g. the old version is 135.x.y.z and the new version's major component
is also 135, follow these instructions.

Complete the [common steps](#common-steps) if not already completed this session. Then, continue below.

```bash
# Update Chromium sources. CalyxOS Chromium sources for the version chosen are not available,
# so we do not pull those. If they *are* available, the BUILDING steps should be followed instead.
# You may need to add the `--force` argument if the current src repo is not in a state that this
# script considers clean / safe to overwrite.
# This command will automatically create a branch in the calyxos-$V pattern and switch you to it.
update_chromium_sources

# Apply patches, using the wiggle tool if found.
USE_WIGGLE=auto apply_patches

# Update the version code.
# Edit args.gn to adapt the version code according to the value of $V.
# Be sure to edit android_default_version_code, too. For example, for Chromium 12.0.3456.789:
# android_default_version_code = "345678900"
# android_default_version_name = "12.0.3456.789"
# (Note that the major version is not part of the version code.)
# (If '789' were only two digits, e.g. '78', you would use '078' in the part of the version code.)
# FIXME: Perhaps this could be automated.
echo $V
nano args.gn

# Amend the LAST args commit. No need to alter the commit message.
git commit -a --amend

# Try to build, fix any issues, and repeat.
# FIXME: Consider talking about how issues are fixed.
build
```

## Major version
If this is a major version update, e.g. the old version is 135.x.y.z and the new version's major
component is different than 135 (e.g. 136 or greater), follow these steps.

Complete the [common steps](#common-steps) if not already completed this session. Then, continue below.

```bash
# Update Chromium sources. CalyxOS Chromium sources for the version chosen are not available,
# so we do not pull those. If they *are* available, the BUILDING steps should be followed instead.
# This command will automatically create a branch in the calyxos-$V pattern and switch you to it.
update_chromium_sources

# Sync cromite's sources if available.
# First, view available Cromite release versions.
show_cromite_releases

# MANUAL: Choose the latest Cromite version that matches our major release, and set it to
# CROMITE_VERSION. Or, if none match, check `show_cromite_wip_branches` and potentially set to
# the commit hash of one of those, if any, in order to benefit from Cromite's work-in-progress
# porting.
CROMITE_VERSION='vW.X.Y.Z-hash'
# or CROMITE_VERSION='hash'   # where hash comes from the output of show_cromite_wip_branches

# Synchronize our patches with Cromite's patches and apply them all.
# You will be placed into a sync_cromite shell that guides you through what to do next.
sync_cromite

# If something goes wrong with a patch, fix it, and then run:
apply_patches_resume

# When all is complete, ...
# Update the version code.
# Edit args.gn to adapt the version code according to the value of $V.
# Be sure to edit android_default_version_code, too. For example, for Chromium 12.0.3456.789:
# android_default_version_code = "345678900"
# android_default_version_name = "12.0.3456.789"
# (Note that the major version is not part of the version code.)
# (If '789' were only two digits, e.g. '78', you would use '078' in the part of the version code.)
# FIXME: Perhaps this could be automated.
echo $V
nano args.gn

# Amend the LAST args commit. No need to alter the commit message.
git commit -a --amend

# If you are still in a sync_cromite shell, type `exit`.
exit

# Try to build, fix any issues, and repeat.
# FIXME: Consider talking about how issues are fixed.
build
```

## Reducing followup build times
Building can take a very long time, and rebasing means a lot needs to be rebuilt! You may prefer
to rebase in a separate working directory. For example:

```bash
cd ~/chromium/src
git checkout --detach HEAD
git worktree add ~/chromium/src2 HEAD   # only needs to be done once, ever
cd ~/chromium/src2
git checkout calyxos-$V

# Do rebase work and/or other code edits in src2.
git rebase -i $V

cd ~/chromium/src
git checkout --detach calyxos-$V
build

# If still not done...
cd ~/chromium/src2

# Do more work here in src2.

cd ~/chromium/src
git checkout --detach calyxos-$V
build
# Rinse and repeat until done.

# Update patches.
CHROMIUM_SRC_PATH=~/chromium/src2 update_patches
```

This workflow has you doing most code edits in a secondary src2 repo, then resetting the main
src repo to your src2 work, which changes fewer files and mitigates excessive followup build times.
