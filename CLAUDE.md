# TRIAZ RS5k — Project Notes

Working directory: `C:\inProgress\docs\triaz utility\triazrs5k\`
Sample library: `X:\samplers\TRIAZ\`
User: techno producer, blind / screen reader workflow, REAPER.

---

## Goal

Lua script for REAPER that lets user browse TRIAZ library and assign samples
to specific notes via ReaSamplomatic5000 (RS5k), fully accessible via screen reader.
Replaces the need to hand-edit SFZ files when swapping individual sounds.

---

## Accessibility constraints

- **No GFX canvas** — drawn UIs are not screen reader accessible.
- Use only native Windows dialogs: `reaper.GetUserInputs()`, `reaper.MB()`, `reaper.ShowPopupMenu()`.
- Prefer sequential dialogs over complex layouts.

---

## REAPER API key points

### Preview
- **SWS CF_Preview** — plays WAV directly without loading into sampler. Requires SWS extension (installed). Use for browsing.
  - `reaper.CF_Preview_Play(source)` after `reaper.CF_Preview_CreateFromFile(path)`
- **StuffMIDIMessage** — fires MIDI note into focused track. Use after loading into RS5k to preview in context.
  - `reaper.StuffMIDIMessage(0, 0x90, note, velocity)` / `0x80` for note-off

### RS5k configuration (via FX params)
RS5k = VST `reasampl5k` (or `reasamplomatic5000`). Key params (0-indexed):
- Param 0: sample file (set via `reaper.TrackFX_SetNamedConfigParm`)
- Use `reaper.TrackFX_SetNamedConfigParm(track, fx_idx, "FILE0", path)` to load sample
- Note range: params for min/max note
- Loop mode: set to no_loop for Noise type WAVs (see looping WAVs below)

### Finding/adding RS5k on track
```lua
reaper.TrackFX_AddByName(track, "reasamplomatic5000", false, -1)
```

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

These have embedded `smpl` loop chunks. Must disable looping in RS5k:
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

All other drum types (9,900 WAVs) verified clean — no embedded loops.

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

## Deployment

REAPER scripts folder: `C:\Users\juanp\AppData\Roaming\REAPER\Scripts\`
Run via REAPER Actions list.

---

## TODO

### Active
- Scaffold main Lua script: browse drum type → tag → WAV → assign to RS5k on note
- SWS preview integration for WAV auditioning while browsing
- Auto-detect and disable loop for Noise type WAVs in RS5k
