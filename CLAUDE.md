# TRIAZ RS5k — Project Notes

Working directory: `C:\inProgress\docs\triaz utility\triazrs5k\`
Sample library: `X:\samplers\TRIAZ\`
User: techno producer, blind / screen reader workflow, REAPER.

---

## Goal

Lua script for REAPER that lets user browse TRIAZ library and assign samples
to specific notes via ReaSamplomatic5000 (RS5k), fully accessible via screen reader.
Replaces the need to hand-edit SFZ files when swapping individual sounds.

Script: `triaz_browser.lua`
Deployed to: `C:\Users\juanp\AppData\Roaming\REAPER\Scripts\triaz_browser.lua`
Run via REAPER Actions list.

---

## Accessibility constraints

- **No GFX canvas** — drawn UIs are not screen reader accessible.
- Use only native Windows dialogs: `reaper.GetUserInputs()`, `reaper.MB()`, `reaper.ShowPopupMenu()`.
- Prefer sequential dialogs over complex layouts.
- ReaImGui IS installed (`reaper_imgui-x64.dll`) but canvas is inaccessible — do not use.

---

## Installed REAPER extensions

- **SWS/S&M 2.14.0.7** (`reaper_sws-x64.dll`) — CF_Preview, CF_LocateInExplorer, etc.
- **js_ReaScriptAPI** (`reaper_js_ReaScriptAPI64.dll`) — JS_ window/file functions
- **ReaImGui** (`reaper_imgui-x64.dll`) — ImGui GUI (NOT for screen reader use)
- **OSARA** (`reaper_osara64.dll`) — screen reader accessibility layer

---

## REAPER API key points

### Preview (SWS 2.14 API)

SWS 2.14 **removed** `CF_Preview_CreateFromFile`. New flow:

```lua
-- Create PCM source (caller must destroy)
local src = reaper.PCM_Source_CreateFromFile(path)
-- Wrap in CF_Preview object
local preview = reaper.CF_CreatePreview(src)
-- Configure
reaper.CF_Preview_SetValue(preview, "D_VOLUME", 1.0)
reaper.CF_Preview_SetValue(preview, "B_LOOP",   0.0)
reaper.CF_Preview_SetValue(preview, "I_OUTCHAN", 0)  -- direct hardware out; REQUIRED
-- Play
reaper.CF_Preview_Play(preview)

-- Stop + cleanup
reaper.CF_Preview_Stop(preview)
reaper.PCM_Source_Destroy(src)
```

**Key:** `I_OUTCHAN=0` (direct hardware output) is required. `CF_Preview_SetOutputTrack`
routes through REAPER mixer which requires active playback — Play returns false when
project is stopped. Hardware out bypasses mixer and always works.

`CF_Preview_SetOutputTrack(preview, ReaProject, MediaTrack)` — takes 3 args (project + track).
Returns true but CF_Preview_Play then returns false when project is stopped.

### RS5k params (full dump, 33 params total)

```
[0]  Volume                        0..1 linear gain
[1]  Pan                           0=L 0.5=C 1=R
[2]  Gain for minimum velocity     0=silent at vel0 (velocity sensitive), 1=flat
[3]  Note range start              note/127
[4]  Note range end                note/127
[5]  Pitch for start note          pitch at note_lo (range-based pitch scaling)
[6]  Pitch for end note            pitch at note_hi
[7]  MIDI channel                  0=all
[8]  Max voices                    0.1111≈1 voice; limits polyphony per instance
[9]  Attack                        ADSR attack time
[10] Release                       ADSR release time
[11] Obey note-offs                0=one-shot, 1=stop on note-off
[12] Loop (requires note-offs)     0=no loop, 1=loop
[13] Sample start offset           0..1
[14] Sample end offset             0..1
[15] Pitch adjust                  (semitones+24)/48, 0.5=0st
[16] Pitchbend range
[17] Minimum velocity              0..1
[18] Maximum velocity              0..1
[19] Probability of hitting        1.0=always; <1 randomly skips hits
[20] Round-robin mode              cycles FILE0/FILE1/etc on retrigger
[21] Filter played notes
[22] Crossfade loop length
[23] Loop start offset
[24] Decay                         ADSR decay
[25] Sustain                       ADSR sustain level
[26] Release (note-off)            release time after note-off (needs param 27 enabled)
[27] Use note-off release override 0=off, 1=use param 26 for note-off release
[28] Legacy voice re-use mode
[29] Portamento
[30] Bypass
```

Currently mapped in `RS5K_PARAM`: volume=0, pan=1, gain_min_vel=2, note_lo=3, note_hi=4,
pitch_note_lo=5, pitch_note_hi=6, loop=12, obey_note_off=11, pitch_st=15,
release_note_off=26, use_note_off_rel=27.

Normalization: `note/127` for note params, `(semitones+24)/48` for pitch.

Load sample: `reaper.TrackFX_SetNamedConfigParm(track, fx_idx, "FILE0", path)`
Loop off (Noise WAVs): `TrackFX_SetParamNormalized(track, fx_idx, 12, 0)`

### RS5k MODE named config param

Set via `TrackFX_SetNamedConfigParm(track, fx_idx, "MODE", value)` (string value).

| Value | Name | Behavior |
|-------|------|----------|
| `"0"` | FreelyConfigurableShifted | Params 5+6 define pitch at note_lo and note_hi; interpolates between them |
| `"1"` | Sample (drum mode) | **Default.** Ignores MIDI note — plays at fixed pitch regardless of note played |
| `"2"` | NoteSemitoneShifted | Chromatic: 1 semitone per key, anchored by param 5 (pitch at note_lo) |

Source: jamesWalker55/reaper-scripting-5-index rs5k-tools/0.0.1/lua_modules/reaper-api/rs5k.lua

**Pitch zones use MODE="0"** (freely configurable) with params 5+6 set directly in semitones
(`zone_lo_st` / `zone_hi_st`, default -7 / +10). RS5k interpolates linearly between them.
Drums use MODE="1" (default, no need to set explicitly — but set anyway for safety).

### Finding/adding RS5k on track

```lua
reaper.TrackFX_AddByName(track, "reasamplomatic5000", false, -1)
```

### Useful SWS CF_ functions

- `reaper.CF_CreatePreview(PCM_source)` → CF_Preview object
- `reaper.CF_LocateInExplorer(path)` — reveal file in Windows Explorer
- `reaper.CF_GetSWSVersion()` — returns loaded SWS version string
- `reaper.CF_GetFocusedFXChain()` — get focused FX chain window handle
- `reaper.CF_ExportMediaSource(source, path)` — export audio to file

---

## Script architecture (triaz_browser.lua)

Main entry: `main()` → select/create track → `show_main_menu(track)` loop.

`show_main_menu` builds a structured gfx.showmenu with submenus and returns `(continue, track)`.
Main menu items:
1. **Add / assign sample** — `pick_source()` → `run_assign_dialog()` (10-field dialog)
2. **Quick assign** — `pick_source()` → 2-field dialog (note + layer only)
3. **Import selected (N)** — flat item; calls `import_selected_items_flow()` for batch
4. **Load kit** — submenu: all 15 kits directly selectable
5. **Tweak** — submenu with two top-level items + per-instance sub-submenus:
   - Assign to pitch zone (play note)
   - Cycle samples
   - Per-instance: Swap / Edit parameters / Preview / Dump / Remove
6. **Randomize**
7. **Exit**

**gfx.showmenu submenu indexing:** `>header` opens a submenu (not counted in return value); bare `<` closes one (also not counted). `open_sub`/`close_sub` only append to `parts[]`, never increment `gfx_idx`. **CRITICAL:** any menu item whose text starts with `>` is treated as a submenu opener, swallowing all subsequent items into it. Never use `>` or `<` at the start of a label string (e.g. `"> Next"` breaks everything — use `"Next"` instead). `#item` = disabled, `!item` = checkmark — these ARE counted in return index.

**pick_from_list:** always prepends `#title` as disabled header item (screen reader announces it). Return value adjusted by -1 since header occupies index 1.

**pick_source():** when timeline items selected, offers submenu "Browse file | From selected item"; otherwise goes straight to `browse_sample()`. Used by add, quick assign, swap, and retry loop in `run_assign_dialog`.

**run_assign_dialog():** shared 10-field assign dialog + preview + keep/retry/discard loop.
Fields: note, layer, zone_n, vol_db, pan_pct, pitch_st, zone_lo_st, zone_hi_st, attack, max_voices.
`defs` table pre-populates any field. `force_new=true` skips existing-instance reuse in `assign_sample`.
When zone_n>0: applies pitch zone (MODE=0, pitch_note_lo=zone_lo_st, pitch_note_hi=zone_hi_st).

**Metadata:** stored via `SetProjExtState` keyed by FX GUID (`note|layer|drum_type|tag`).
Scan: `scan_triaz_instances(track)` reads all RS5k metadata on track.
Zone instances: metadata `note` = zone.mid (91/98/105); detected by matching PITCH_ZONES midpoints.

**Preview flow:** `preview_wav(path)` → MB dialog blocks → `stop_preview()` on close.

**tweak_mode loop:** all actions loop back to the per-instance action picker. Only confirmed remove (action 5 — user answers Yes) exits; cancelled remove loops back. When called with pre-set `action_n` from the menu, `next_action` is set to nil after first iteration so subsequent loops always show the picker. Picker title shows "Edit: &lt;cur_wav&gt;" — filename change after swap is implicit confirmation. After action 1 (Swap), `info.drum_type` and `info.tag` are updated in-place so action 2 (Edit) gets correct defaults. After action 2, `fx_idx` is corrected for the index shift caused by removing the old instance before the new one's index (`fx_idx = new_fx - 1` when `new_fx > old_fx_idx`).

**scan_non_zone_instances(track):** shared helper used by `cycle_samples_flow` and `randomize_flow`; returns all instances where `drum_type ~= "Zone"`.

**cycle_samples_flow:** inside Tweak submenu. Partitions instances into solo, tom group (drum_type=="Tom", cycled together), and zone group (note in PITCH_ZONES mids 91/98/105, sub-picked by zone). Cycle menu inlines full WAV list from current tag after nav items (Previous/Next/Change tag/Done); current WAV marked with `* `. Swaps are live (no keep/discard). `swap_group` loops over all instances in the group.

### Kit loader (load_kit_flow)

Accepts optional `kit_n` (pre-selected index from submenu) to skip internal picker.
Wrapped in `PreventUIRefresh(1/-1)` — eliminates per-FX UI redraws (~15s for 56 instances).
Loads: rimshot → kit voices → toms (pitched+panned) → fixed GM voices → lower extras 21–34 → 3 empty upper zones 88–108.

Tom behavior:
- `TOM_PITCH_SCALE = 0.5` — pitch spread -2 to +3 st from center note A1 (MIDI 45)
- `TOM_PAN_LOW = 0.25` (note 41, left) → `TOM_PAN_HIGH = 0.75` (note 50, right)
- `load_voice()` accepts `opts = {pitch_scale, pan_list}` for per-note overrides

HH Open behavior:
- `obey_note_off = true` + `hh_open_release = true`
- Sets param 27 (use_note_off_rel) = 1, param 26 = `HH_OPEN_RELEASE_NORM` (0.05 ≈ 50ms est.)

Upper zones (E5–C7, MIDI 88–108): 3 × 7-note empty RS5k slots. drum_type="Zone". User fills via:
- Add / assign sample (enter zone # 1-3 in dialog; set zone_lo_st / zone_hi_st in semitones)
- Tweak → Assign to pitch zone (play note) — plays a note to find instance, picks zone, sets lo/hi pitch

### assign_to_zone_flow

Top-level item in Tweak submenu. Captures played MIDI note via `MIDI_GetRecentInputEvent`,
finds matching instance(s), picks PITCH_ZONES entry, asks for lo/hi pitch in semitones (default -7/+10),
reconfigures RS5k in-place (note_lo/hi, pitch_note_lo/hi, MODE=0, metadata updated).

### Randomize (randomize_flow)

4 modes (skips Zone instances):
1. **Single voice** — same type/tag, random WAV + preview
2. **Entire kit** — same type/tag, new random WAV each voice
3. **Entire kit + tags** — random tag within same drum type
4. **Full random** — random type/tag/WAV every voice

`math.randomseed(os.time())` per invocation. Updates FILE0 + metadata. Preserves HH Open release params on randomize.

---

## TRIAZ library structure

Base path: `X:\samplers\TRIAZ\Samples\TRIAZ - Factory Collection\` (default).
Hierarchy: **Drum Type → Tag → WAV** (up to 20 tags/type, up to 72 WAVs/tag)
Total: ~9,910 WAVs across 16 Drum Types.

### Library path + cache

`TRIAZ_BASE` loaded from `GetExtState("TRIAZ_BROWSER", "library_path")`, falls back to the hardcoded default. Persists per-user in `reaper.ini` (set via "Change library path" menu item, `SetExtState` persist=true).

Folder listings (`list_dirs`/`list_wavs`) cached in `_dir_cache`, persisted to `<resource path>\Scripts\triaz_browser_cache.lua` (a `return {...}` Lua table). Loaded via `dofile` on startup (`_cache_loaded` flag); written by `save_cache()` on exit only when `_cache_dirty`. First run (no cache) calls `build_cache()` — confirms/edits path, eager-scans all types/tags, saves immediately, ~1 min, window appears frozen. `clear_cache` ("Refresh library cache") + `change_library_path` wipe cache file and rebuild immediately.

### Drum Types (folder names)

| Folder name | Notes |
|---|---|
| Kick Electronic | |
| Kick Acoustic | |
| Snare Electronic | |
| Snare Acoustic | |
| Claps & Snaps | (manual calls it "Clap & Snap") |
| Hihat Closed | (manual calls it "Hat Closed") |
| HiHat Open | (manual calls it "Hat Open") |
| Crash | |
| Ride | |
| Tom | |
| Shakers | |
| Perc Acoustic | |
| Perc Electronic | |
| Perc Glitch | (manual calls it "Glitch") |
| Layer | |
| Noise | all 10 WAVs have embedded loop points — set RS5k loop off |
| Foley | |

### Looping WAVs (Noise type — all 10)

These have embedded `smpl` loop chunks. Must disable looping in RS5k (param 12 = 0):
- `wa-triaz-noise-amp_hum.wav`
- `wa-triaz-noise-cassette_lofi.wav`
- `wa-triaz-noise-hiss_synth.wav`
- `wa-triaz-noise-lofi_gear.wav`
- `wa-triaz-noise-static_synth.wav`
- `wa-triaz-noise-tape_hiss.wav`
- `wa-triaz-noise-vinyl_1.wav`
- `wa-triaz-noise-vinyl_2.wav`
- `wa-triaz-noise-vinyl_3.wav`
- `wa-triaz-noise-water.wav`

All other drum types verified clean — no embedded loops.

### Tag sibling clusters (useful for round-robin / variation browsing)

**Kick Electronic:** Deep+Sub+Organic+Room | Punchy+Tight+Snap+Heavy | Lo-Fi+Tape&Vinyl+Acoustic | 808+Drum Machine+Synthetic+Layered
**Kick Acoustic:** Deep+Room+Heavy | Bright+Punchy
**Snare Electronic:** 808+Drum Machine+Synthetic+Heavy | Punchy+Tight+Room | Lo-Fi+Tape&Vinyl+Acoustic | Layered+Organic+Creative
**Snare Acoustic:** Room+Bright+Organic | Lo-Fi+Tape&Vinyl+Metallic | Punchy+Tight+Deep
**Claps & Snaps:** Acoustic+Room+Organic | 808+Drum Machine+Synthetic | Lo-Fi+Tape&Vinyl+Heavy | Snap+Bright+Layered
**Tom:** Acoustic+Room+Organic+Deep | Punchy+Heavy+Tight | 808+Drum Machine+Synthetic
**Hihat Closed:** Acoustic+Room+Bright | 808+Drum Machine+Synthetic | Lo-Fi+Tape&Vinyl+Metallic
**HiHat Open:** Acoustic+Room+Bright | 808+Drum Machine+Synthetic | Lo-Fi+Tape&Vinyl+Heavy+Metallic
**Crash:** Acoustic+Room+Organic | Bright+Synthetic+Creative | Drum Machine+Noise+Mallet
**Ride:** Acoustic+Room+Bright | Drum Machine+Synthetic+Creative
**Shakers:** Acoustic+Organic+Creative | Drum Machine+Metallic+Synthetic

---

## GM note → suggested Drum Type

| MIDI | GM Name | Drum Type |
|------|---------|-----------|
| 35/36 | Bass Drum | Kick Electronic / Kick Acoustic |
| 38/40 | Snare | Snare Electronic / Snare Acoustic |
| 39 | Hand Clap | Claps & Snaps |
| 42/44 | Hi-Hat Closed | Hihat Closed |
| 46 | Hi-Hat Open | HiHat Open |
| 41/43/45/47/48/50 | Toms | Tom |
| 49/52/55/57 | Crash | Crash |
| 51/53/59 | Ride | Ride |
| 54/69/70/82 | Shaker/Tamb/Maracas | Shakers |
| 60–64 | Bongo/Conga | Perc Acoustic |
| 56 | Cowbell | Perc Electronic |
| 31 | Sticks (lower extra) | Noise — loop off required |

---

## TODO

### Tunable constants (top of script)
- `HH_OPEN_RELEASE_NORM = 0.05` — param 26 range unknown; test and adjust for ~50ms fade
- `TOM_PITCH_SCALE = 0.5` — halves spread; adjust if still too wide/narrow
- `TOM_PAN_LOW / TOM_PAN_HIGH = 0.25 / 0.75` — ±25% pan spread; adjust for preference

### Future
