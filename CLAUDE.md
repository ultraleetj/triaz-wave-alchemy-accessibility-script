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
loop=12, obey_note_off=11, pitch_st=15.

Normalization: `note/127` for note params, `(semitones+24)/48` for pitch.

Load sample: `reaper.TrackFX_SetNamedConfigParm(track, fx_idx, "FILE0", path)`
Loop off (Noise WAVs): `TrackFX_SetParamNormalized(track, fx_idx, 12, 0)`

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

Main entry: `main()` → select/create track → action loop:
1. Add assignment (full: note, layer, pitch zone, vol, pan, pitch)
2. Quick assign (minimal: note + layer only)
3. Import selected media items → assign to notes
4. Load kit (15 preset kits)
5. Tweak mode (edit existing RS5k instances)
6. Randomize
7. Switch track

**Metadata:** stored via `SetProjExtState` keyed by FX name (`note|layer|drum_type|tag`).
Scan: `scan_triaz_instances(track)` reads all RS5k FX names + metadata on track.

**Preview flow:** `preview_wav(path)` → MB dialog blocks → `stop_preview()` on close.

### Kit loader (load_kit_flow)

Loads voices in order: rimshot (fixed) → kit voices (KIT_VOICE_ORDER) → toms (pitched) → fixed GM voices (KIT_FIXED_VOICES) → lower extras 21–34 (KIT_LOWER_VOICES) → 3 empty upper zones 88–108 (KIT_UPPER_ZONES).

Kit definitions mirror `generate_kits.py` exactly (primary + alt voices per kit).
Tom notes {41,43,45,47,48,50} pitched via `pitch_st = note - 45` (Low Tom = center, 0 st).
Upper zones (E5–C7, MIDI 88–108): 3 × 7-note empty RS5k slots, labeled "zone N (E5-A#5)" etc.
Zones show in tweak mode as drum_type="Zone"; user fills via Add assignment flow.

### Randomize (randomize_flow)

4 modes (skips Zone instances):
1. **Single voice** — pick one instance, same drum_type/tag, random WAV + preview
2. **Entire kit** — all voices, same drum_type/tag each, random WAV
3. **Entire kit + tags** — all voices, random tag within same drum_type, random WAV
4. **Full random** — all voices, random drum_type + tag + WAV

`math.randomseed(os.time())` called per invocation. Updates RS5k FILE0 + metadata.

---

## TRIAZ library structure

Base path: `X:\samplers\TRIAZ\Samples\TRIAZ - Factory Collection\`
Hierarchy: **Drum Type → Tag → WAV** (up to 20 tags/type, up to 72 WAVs/tag)
Total: ~9,910 WAVs across 16 Drum Types.

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

### Pending
- **HH Open smooth note-off release** — set param 27 (Use note-off release override) = 1 and param 26 (Release note-off) ≈ 50ms normalized value for HiHat Open instances in kit loader. Currently hard-cuts on note-off. Need to determine normalized value for ~50ms (unknown range — requires test). Also add `release_note_off` and `use_note_off_rel` to RS5K_PARAM table and handle in `configure_rs5k`.
