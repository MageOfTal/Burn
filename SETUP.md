# Burn Royale — Setup

This repo contains two things:

- **`ProjectFiles/`** — the Godot game project.
- **`Engine/`** — a **custom-compiled Godot 4.6** editor. The game depends on engine
  changes (custom C++ modules + physics patches), so it will **not** run correctly on
  a stock Godot download.

There are two ways to get up and running. Pick one.

---

## Get the code

```bash
git clone https://github.com/MageOfTal/Burn.git
cd Burn
```

The engine binaries are **not** in the repo — they're published on the
[Releases page](https://github.com/MageOfTal/Burn/releases). Pick a path below.

---

## Path A — Just run the prebuilt engine (no compiler needed)

1. Download the latest engine zip from the
   [Releases page](https://github.com/MageOfTal/Burn/releases)
   (e.g. `BurnRoyale-Engine-Godot4.6-win64.zip`).
2. Extract the two `.exe` files into the repo's `Engine/` folder:
   - `Engine/Godot_v4.6-stable_win64.exe` — the editor (use this)
   - `Engine/Godot_v4.6-stable_win64_console.exe` — same editor with a console window
3. Open the project:

```powershell
.\Engine\Godot_v4.6-stable_win64.exe --path .\ProjectFiles
```

(or launch the `.exe` and import `ProjectFiles/project.godot`). Press F5 to play.

> Windows x86_64 only. On other platforms, use Path B.

---

## Path B — Build the engine from source

The repo stores **only our engine changes**, not the full Godot source tree:

- Custom modules (fully ours): `Engine/godot-source/modules/block_mesh/`,
  `Engine/godot-source/modules/terrain_fill/`
- Patched stock files: `modules/jolt_physics/`, `modules/godot_physics_3d/`,
  `servers/physics_3d/`

So building means: lay our files on top of a clean Godot 4.6 checkout, then compile.

### 1. Tools

- **Visual Studio 2022** with the "Desktop development with C++" workload (MSVC x64).
  `build.bat` finds it automatically via `vswhere`.
- **Python 3.8+** and **SCons** (`pip install scons`), on your PATH.
  (A bundled `Engine/python/` is used automatically if present, but it is not committed.)

### 2. Populate the full Godot source

Fetch stock Godot 4.6 and fill in everything that isn't in this repo, **without**
overwriting our patched/custom files (`cp -n` = don't clobber existing):

```bash
# from the repo root, using Git Bash
git clone --depth 1 --branch 4.6-stable https://github.com/godotengine/godot.git /tmp/godot
cp -rn /tmp/godot/* Engine/godot-source/
```

This leaves our committed files in place and adds the ~thousands of stock source
files Git ignores. (`block_mesh` / `terrain_fill` don't exist upstream, so they're
untouched.)

### 3. Build

```powershell
.\Engine\build.bat
```

`build.bat` derives all paths from its own location, auto-locates Visual Studio,
runs SCons, and copies the resulting binaries up into `Engine/`. Full output goes to
`Engine/build_log.txt`. Then follow **Path A** to run.

---

## Notes

- **Why binaries aren't committed:** each engine build is ~157 MB and changes on
  every rebuild. Keeping them out of git history (and off Git LFS) keeps clones fast.
  Shareable builds are published on the Releases page instead.
- **Publishing a new engine build (maintainers):** build with `Engine/build.bat`, then
  zip the two `.exe` files and attach them to a new GitHub Release, e.g.
  `gh release create engine-YYYY.MM.DD ./Engine/dist/BurnRoyale-Engine-Godot4.6-win64.zip`.
- **Terrain bake caches** (`ProjectFiles/terrain/*.bin`) are git-ignored and
  regenerated at runtime if missing.
