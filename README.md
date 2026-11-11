# Fish Tales on modern Windows and Linux (QindieGL + display-list proxy)

Fish Tales (PC) runs fine on Windows XP and 7, but won't start on Windows 10/11, and it refuses to launch under Wine/Proton on Linux. This repo documents a working fix and provides a small proxy DLL that makes in-game text render.

The fix has three parts:

1. **[QindieGL](https://github.com/crystice-softworks/QindieGL)**, an OpenGL 1.x to Direct3D 9 wrapper, used as the game's `opengl32.dll`.
2. **A registry file** that configures QindieGL.
3. **A tiny proxy `opengl32.dll`** (this repo, ~300 lines of C) that adds the one thing QindieGL lacks and Fish Tales needs: **OpenGL display lists**. Without it the game runs but draws no text.

> The QindieGL-plus-registry approach comes from a YouTube comment about getting *Airstrike 3D* running on Windows 10. I'm grateful to whoever wrote it. This repo extends it to Fish Tales and fixes the missing text.

---

## Status

| | |
|---|---|
| Linux (Wine, via Lutris) | Works, including text. Needs the Wine virtual desktop (see [Known issues](#known-issues)). |
| Windows 10/11 | **Untested with the proxy.** QindieGL alone reportedly gets the game launching, but the text problem should be the same, so the proxy should apply. |

Tested configuration:

- OS / distro: cachyOS
- Wine / Proton version: wine-11.21-amd64-wow64
- Lutris version: 0.5.22

---

## Quick start (prebuilt or self-built DLL)

You need three things in the game folder:

```
Fish Tales/
├── FishTales.exe
├── opengl32.dll              <- the proxy from this repo
└── qindiegl/
    └── opengl32.dll          <- the ORIGINAL QindieGL DLL, same name, untouched
```

The original QindieGL DLL **must keep the name `opengl32.dll`**. It is sensitive to its filename, which is why it lives in a subfolder instead of being renamed.

### 1. Get QindieGL

Use the `opengl32.dll` from the QindieGL project: <https://github.com/crystice-softworks/QindieGL>. The source is there. I don't redistribute the QindieGL binary here; check its license before bundling it anywhere.

### 2. Build the proxy

You need a **32-bit** mingw-w64 cross compiler (the game is a 32-bit executable):

| Distro | Package |
|---|---|
| Arch | `mingw-w64-gcc` |
| Fedora | `mingw32-gcc` |
| Debian/Ubuntu | `gcc-mingw-w64-i686` |

Then:

```bash
./build.sh "/path/to/QindieGL/opengl32.dll"
```

`build.sh` reads the export table of the QindieGL DLL you give it, generates a jump stub for every function except the display-list ones, and compiles `opengl32.dll`. It writes `exports.txt`, `passthru.txt`, `stubs.c` and `opengl32.def` next to it, and these are generated files that don't need to be committed.

Copy the resulting `opengl32.dll` into the game folder, and put the original QindieGL DLL in `qindiegl/`.

### 3. Import the registry settings

QindieGL reads its configuration from the registry. Without these keys it advertises few or no GL extensions, and the game doesn't start. Import `QindieGL-setup.reg` (included here, full contents [below](#registry-settings)).

- **Windows:** double-click the `.reg` file.
- **Linux/Wine:** import into the same prefix the game uses:
  ```bash
  WINEPREFIX=/path/to/prefix wine regedit QindieGL-setup.reg
  ```
  In Lutris, you can also use *Wine configuration → Run EXE inside Wine prefix* and launch `regedit`.

### 4. Make Wine use the native DLL (Linux only)

Wine prefers its builtin `opengl32`, so tell it to prefer the one in the game folder:

```bash
WINEDLLOVERRIDES="opengl32=n,b" wine FishTales.exe
```

In Lutris: *Configure → Runner options → DLL overrides*, add `opengl32` = `n,b`.

Use a **32-bit-capable prefix**. If you use DXVK, make sure the 32-bit DXVK DLLs are installed in the prefix, because QindieGL's Direct3D 9 calls go through DXVK (or wined3d). Enabling the **Wine virtual desktop** also fixes the mouse issue below.

### Expected result

Launch the game: menus and in-game text should appear. If you set `WINEDEBUG=+loaddll`, you should see **two** `opengl32.dll` loads, one from the game folder and one from `qindiegl\`.

QindieGL also writes its own log. Before the proxy, it listed lines like `WARNING: glCallLists: lists are not supported`. With the proxy, those warnings should be gone.

---

## What was wrong (and why this works)

### The symptom

With QindieGL and the registry settings, the game ran, but **no text appeared**. The rest of the 2D HUD, menus and sprites rendered correctly. Only text was missing.

### Finding the cause

The game's import table (`winedump -j import FishTales.exe`) shows how it draws text:

- It imports **no** `wglUseFontBitmaps`/`wglUseFontOutlines`, **no** `glBitmap`/`glRasterPos`/`glDrawPixels`, and no GDI font functions.
- It imports the display list API: `glGenLists`, `glNewList`, `glEndList`, `glListBase`, `glCallLists`, `glCallList`, `glDeleteLists`.

`strings FishTales.exe` shows font files (`font/small.font`, `big.font`, …) with `locations`, `activeletters` and `scale` blocks, and font textures such as `gfx/2d/smallFont`. So text is a **texture atlas drawn through display lists**.

QindieGL's own log said it directly: `glGenLists`, `glNewList`, `glEndList`, `glCallList`, `glCallLists` and `glListBase` are all "not supported". They are no-ops, so no glyph is ever drawn.

### What the game does

Disassembling around the `glNewList`/`glEndList` calls (`objdump -d -M intel FishTales.exe`) shows only **six** GL calls are used inside lists:

```
glNewList(base + i, GL_COMPILE)
  glBegin(GL_QUADS)
    glTexCoord2f(u, v); glVertex3i(x, y, 0)    x4
  glEnd()
  glTranslated(advance, 0, 0)
glEndList()
```

Strings are drawn with `glListBase(...)` and `glCallLists(strlen(s), GL_BYTE, s)`.

A second list is a fullscreen 640×480 textured quad (`glVertex2f`), which probably makes backgrounds or fades work too.

### The fix

`gl_list_proxy.c` implements display lists by **record and replay** and sits in front of QindieGL:

- `glGenLists`, `glNewList`, `glEndList`, `glCallList`, `glCallLists`, `glListBase`, `glDeleteLists`, `glIsList` are implemented in the proxy.
- While a list is compiling, `glBegin`, `glEnd`, `glTexCoord2f`, `glVertex2f`, `glVertex3i` and `glTranslated` are recorded instead of executed. `glCallList` replays them through QindieGL's real functions.
- **Every other export** is passed straight through to the original QindieGL DLL via generated jump stubs. That matters because the game's `glu32.dll` also imports from `opengl32.dll`, so the proxy must export everything QindieGL does.

### Why the registry file

The registry doesn't redirect anything. The DLL redirects, because Windows loads `opengl32.dll` from the application folder before System32. The registry is QindieGL's config file: `Settings` holds behavior toggles and `Extensions` is the list of GL extensions it reports to the game.

### What I don't know

I did not determine why the native Windows 10/11 or Wine OpenGL path fails to start this game; the wrapper simply bypasses it. A `materials/` message seen in earlier logs is a normal startup stage and is probably unrelated.

---

## Registry settings

<details>
<summary><code>QindieGL-setup.reg</code> (click to expand)</summary>

```reg
REGEDIT4

[HKEY_CURRENT_USER\SOFTWARE\Crystice Softworks\QindieGL\Settings]
"MultiSample"=dword:00000000
"ProjectionFix"=dword:00000001
"TexCoordFix"=dword:00000001
"UseSSE"=dword:00000001

[HKEY_CURRENT_USER\SOFTWARE\Crystice Softworks\QindieGL\Extensions]
"GL_ARB_multitexture"=dword:00000001
"GL_ARB_texture_border_clamp"=dword:00000001
"GL_ARB_texture_cube_map"=dword:00000001
"GL_ARB_texture_env_add"=dword:00000001
"GL_ARB_texture_env_combine"=dword:00000001
"GL_ARB_texture_env_dot3"=dword:00000001
"GL_ARB_texture_mirrored_repeat"=dword:00000001
"GL_ARB_texture_non_power_of_two"=dword:00000001
"GL_ARB_texture_compression"=dword:00000001
"GL_ARB_transpose_matrix"=dword:00000001
"GL_ATI_texture_mirror_once"=dword:00000001
"GL_CHS_mipmap_texture3D"=dword:00000000
"GL_EXT_abgr"=dword:00000001
"GL_EXT_bgra"=dword:00000001
"GL_EXT_blend_color"=dword:00000001
"GL_EXT_blend_minmax"=dword:00000001
"GL_EXT_blend_subtract"=dword:00000001
"GL_EXT_compiled_vertex_array"=dword:00000001
"GL_EXT_draw_range_elements"=dword:00000001
"GL_EXT_multi_draw_arrays"=dword:00000001
"GL_EXT_fog_coord"=dword:00000001
"GL_EXT_packed_pixels"=dword:00000001
"GL_EXT_secondary_color"=dword:00000001
"GL_EXT_texture3D"=dword:00000001
"GL_EXT_texture_compression_s3tc"=dword:00000001
"GL_EXT_texture_cube_map"=dword:00000001
"GL_EXT_texture_env_add"=dword:00000001
"GL_EXT_texture_env_combine"=dword:00000001
"GL_EXT_texture_env_dot3"=dword:00000001
"GL_EXT_texture_filter_anisotropic"=dword:00000001
"GL_EXT_texture_lod"=dword:00000001
"GL_EXT_texture_lod_bias"=dword:00000001
"GL_EXT_texture_object"=dword:00000001
"GL_EXT_stencil_two_side"=dword:00000000
"GL_EXT_stencil_wrap"=dword:00000001
"GL_IBM_texture_mirrored_repeat"=dword:00000001
"GL_NV_blend_square"=dword:00000001
"GL_NV_texgen_reflection"=dword:00000001
"GL_SGIS_multitexture"=dword:00000001
"GL_SUN_multi_draw_arrays"=dword:00000001
"WGL_EXT_swap_control"=dword:00000001
"WGL_ARB_extensions_string"=dword:00000001
```

</details>

---

## Known issues

- **Mouse cursor stuck at the far left of the screen** without the Wine virtual desktop. The game imports `ClipCursor`, `SetCursorPos` and `GetCursorPos`, which suggests it recenters the cursor every frame; Wine handles this badly in fullscreen. **Workaround:** enable the Wine virtual desktop (Lutris: *Runner options → Windowed (virtual desktop)*).
- Alt+Tab behavior may be unreliable on Linux. This is probably the Direct3D 9 fullscreen device (QindieGL via DXVK or wined3d) rather than the proxy, but I haven't isolated it.
- Only the six GL calls listed above are recorded inside display lists. This matches what Fish Tales does, but **this proxy is not a general display-list implementation** and won't suit other games unmodified. A game that calls other GL functions between `glNewList` and `glEndList` would have those calls run immediately instead of being recorded.
- `glCallLists` supports the byte, short, int, float and `GL_2_BYTES` types, but not `GL_3_BYTES`/`GL_4_BYTES`.

## Troubleshooting

| Symptom | Likely cause / what to check |
|---|---|
| Message box: *could not load qindiegl\opengl32.dll* | The original QindieGL DLL isn't at `<game folder>/qindiegl/opengl32.dll`. |
| Message box: *QindieGL DLL is missing a needed export* | You pointed `build.sh` at the wrong DLL, or an incompatible QindieGL build. |
| Game doesn't start at all | Registry file not imported into the *same* prefix; missing `WINEDLLOVERRIDES="opengl32=n,b"`; 64-bit-only prefix or missing 32-bit DXVK. Use `WINEDEBUG=+loaddll` to see what loads. |
| Game runs, no text | The proxy isn't being used (check `+loaddll` for two `opengl32.dll` loads), or QindieGL's log still shows "lists are not supported". |
| Text appears but looks wrong | Texture alpha or blending path rather than display lists; open an issue with a screenshot and QindieGL's log. |
| Build can't find `i686-w64-mingw32-gcc` | Install a 32-bit mingw-w64 toolchain (see table above). |

## Reproducing the analysis on another game

If another old OpenGL game misbehaves under QindieGL, these steps are how this one was diagnosed:

```bash
winedump -j import Game.exe          # which GL/WGL/GDI functions does it use?
strings Game.exe | grep -i -E "font|\.tga|gl[A-Z]"
objdump -d -M intel Game.exe | grep -n -E "call.*<thunk address of glNewList>"
```

Then check QindieGL's log for `WARNING: ... not supported` lines. Those name exactly the calls that are missing.

## Verification

The proxy was tested under Wine 9.0 with a stand-in QindieGL that logged every call it received, plus a small test program that builds two glyph lists and draws `"AB"` via `glListBase` and `glCallLists(…, GL_BYTE, …)`. Pass-through calls, replay order and arguments were all correct, and two DLLs named `opengl32.dll` (one in the game folder, one in `qindiegl\`) loaded fine. It was then confirmed working in the actual game.

## Repository contents

```
README.md             this file
gl_list_proxy.c       the proxy (display list record/replay)
build.sh              generates pass-through stubs and compiles the proxy
QindieGL-setup.reg    QindieGL configuration for the registry
```

No game files and no QindieGL binaries are included.

## Credits

- **QindieGL** by Crystice Softworks: <https://github.com/crystice-softworks/QindieGL>
- Whoever shared the *Airstrike 3D* QindieGL-plus-registry fix in a YouTube comment, which started all this.
- Proxy and analysis by `<your name>`.

## License

The proxy code in this repo: MIT. QindieGL, the game, and any other third-party files remain under their own licenses and copyrights.
