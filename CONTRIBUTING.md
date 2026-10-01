# Contributing to DiskSweep

Thanks for helping make DiskSweep better!

## Reporting bugs and ideas

[Open an issue](https://github.com/kamb205/DiskSweep/issues/new/choose) and pick **Bug report** or **Feature request**. Include your macOS version and Mac model. If you add screenshots, hide any file names you'd rather keep private.

## Making changes

1. Fork the repo and create a branch.
2. Build with `./build.sh` (macOS 26 + Xcode Command Line Tools).
3. Check your change in the running app. `Scripts/make_readme_screenshots.sh` shows how to run DiskSweep against a made-up demo folder, so you never need to test on real files.
4. Open a pull request that explains what changed and why.

## Ground rules

DiskSweep is trusted with people's files, so a few rules never change:

- **Nothing is deleted outright.** Removals go to the Trash. Only the Trash Bins page erases, after confirmation.
- **Only true junk is marked Safe.** If an item might matter to someone, mark it Review or Careful.
- **Keep the protected locations protected** (`AppModel.isDeletable`) and the Scanner's tool/program filters.
- **Don't change the bundle identifier or the signing rule** in `build.sh`. macOS ties Full Disk Access to them.
- **No tracking, analytics or uploads.** DiskSweep works entirely on the Mac.
- Be honest in the UI about what a feature can and can't do.
