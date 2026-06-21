-- TRIAZ RS5k Browser
-- Browse TRIAZ library, assign samples to RS5k instances on a track
-- Accessible via screen reader (native REAPER dialogs only)

local TRIAZ_BASE = "X:\\samplers\\TRIAZ\\Samples\\TRIAZ - Factory Collection\\"


-- Drum types in folder order
local DRUM_TYPES = {
  "Kick Electronic",
  "Kick Acoustic",
  "Snare Electronic",
  "Snare Acoustic",
  "Claps & Snaps",
  "Hihat Closed",
  "HiHat Open",
  "Crash",
  "Ride",
  "Tom",
  "Shakers",
  "Perc Acoustic",
  "Perc Electronic",
  "Perc Glitch",
  "Layer",
  "Noise",
  "Foley",
}

-- Noise WAVs that have embedded loop points — must disable loop in RS5k
local NOISE_LOOP_FILES = {
  ["wa-triaz-noise-amp_hum.wav"] = true,
  ["wa-triaz-noise-cassette_lofi.wav"] = true,
  ["wa-triaz-noise-hiss_synth.wav"] = true,
  ["wa-triaz-noise-lofi_gear.wav"] = true,
  ["wa-triaz-noise-static_synth.wav"] = true,
  ["wa-triaz-noise-tape_hiss.wav"] = true,
  ["wa-triaz-noise-vinyl_1.wav"] = true,
  ["wa-triaz-noise-vinyl_2.wav"] = true,
  ["wa-triaz-noise-vinyl_3.wav"] = true,
  ["wa-triaz-noise-water.wav"] = true,
}

-- GM note suggestions per drum type
local GM_SUGGESTIONS = {
  ["Kick Electronic"]  = {36},
  ["Kick Acoustic"]    = {35},
  ["Snare Electronic"] = {40},
  ["Snare Acoustic"]   = {38},
  ["Claps & Snaps"]    = {39},
  ["Hihat Closed"]     = {42},
  ["HiHat Open"]       = {46},
  ["Tom"]              = {45},
  ["Crash"]            = {49},
  ["Ride"]             = {51},
  ["Shakers"]          = {82},
  ["Perc Acoustic"]    = {60},
  ["Perc Electronic"]  = {56},
  ["Perc Glitch"]      = {29},
  ["Layer"]            = {26},
  ["Noise"]            = {31},
  ["Foley"]            = {33},
}

-- Note name helpers
local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

local function note_name(midi)
  local oct = math.floor(midi / 12) - 2
  local name = NOTE_NAMES[(midi % 12) + 1]
  return name .. oct
end

local function note_from_name(s)
  s = s:upper():gsub("%s+", "")
  local name, oct = s:match("^([A-G]#?)(-?%d+)$")
  if not name then return nil end
  local idx = nil
  for i, n in ipairs(NOTE_NAMES) do
    if n == name then idx = i - 1; break end
  end
  if not idx then return nil end
  return (tonumber(oct) + 2) * 12 + idx
end

-- ── File system helpers ──────────────────────────────────────────────────────

local _dir_cache = {}

local function list_dirs(path)
  local key = "d:" .. path
  if _dir_cache[key] then return _dir_cache[key] end
  local dirs = {}
  local iter = io.popen('dir /b /ad "' .. path .. '" 2>nul')
  if iter then
    for line in iter:lines() do dirs[#dirs + 1] = line end
    iter:close()
  end
  _dir_cache[key] = dirs
  return dirs
end

local function list_wavs(path)
  local key = "w:" .. path
  if _dir_cache[key] then return _dir_cache[key] end
  local files = {}
  local iter = io.popen('dir /b /o:n "' .. path .. '\\*.wav" 2>nul')
  if iter then
    for line in iter:lines() do files[#files + 1] = line end
    iter:close()
  end
  _dir_cache[key] = files
  return files
end

-- Find tag folder by partial hint match, fall back to first tag
local function find_tag(drum_type, hint)
  local tags = list_dirs(TRIAZ_BASE .. drum_type)
  if #tags == 0 then return nil end
  local h = hint:lower()
  for _, t in ipairs(tags) do
    if t:lower():find(h, 1, true) then return t end
  end
  return tags[1]  -- fallback
end

-- Pick WAV at midpoint of sorted list (variety without cycling)
-- tag="" means WAVs are in the drum type root folder (e.g. Noise)
local function pick_kit_wav(drum_type, tag)
  local path = (tag and tag ~= "")
    and (TRIAZ_BASE .. drum_type .. "\\" .. tag)
    or  (TRIAZ_BASE .. drum_type)
  local wavs = list_wavs(path)
  if #wavs == 0 then return nil, nil end
  local idx = math.floor(#wavs / 2) + 1
  local wav = wavs[idx]
  return wav, path .. "\\" .. wav
end

-- ── Kit definitions ──────────────────────────────────────────────────────────
-- Mirrored from generate_kits.py. Each kit: voice_key = {drum_type, tag}.
-- Rimshot (note 37) fixed across all kits via RIMSHOT_DEFAULT.
-- Tom voices (notes 41,43,45,47,48,50) are pitched relative to TOM_PITCH_CENTER.

local KITS = {
  { name="01 Techno Dark",
    kick={"Kick Electronic","Deep"},       kick_alt={"Kick Electronic","Sub"},
    snare={"Snare Electronic","Noise"},    snare_alt={"Snare Electronic","Synthetic"},
    clap={"Claps & Snaps","Noise"},
    hh_c={"Hihat Closed","Metallic"},      hh_pedal={"Hihat Closed","Acoustic"},
    hh_o={"HiHat Open","Metallic"},
    tom={"Tom","Deep"},
    crash={"Crash","Noise"},               ride={"Ride","Synthetic"},
    perc={"Perc Electronic","Metallic"},
  },
  { name="02 Techno Punchy",
    kick={"Kick Electronic","Punchy"},     kick_alt={"Kick Electronic","Tight"},
    snare={"Snare Electronic","Tight"},    snare_alt={"Snare Electronic","Bright"},
    clap={"Claps & Snaps","Snap"},
    hh_c={"Hihat Closed","Synthetic"},     hh_pedal={"Hihat Closed","Metallic"},
    hh_o={"HiHat Open","Synthetic"},
    tom={"Tom","Punchy"},
    crash={"Crash","Synthetic"},           ride={"Ride","Synthetic"},
    perc={"Perc Electronic","Blips & Pops"},
  },
  { name="03 Techno 808",
    kick={"Kick Electronic","808"},        kick_alt={"Kick Electronic","Sub"},
    snare={"Snare Electronic","808"},      snare_alt={"Snare Electronic","Drum Machine"},
    clap={"Claps & Snaps","808"},
    hh_c={"Hihat Closed","808"},           hh_pedal={"Hihat Closed","Synthetic"},
    hh_o={"HiHat Open","808"},
    tom={"Tom","808"},
    crash={"Crash","Synthetic"},           ride={"Ride","Synthetic"},
    perc={"Perc Electronic","Snap"},
  },
  { name="04 House Classic",
    kick={"Kick Electronic","Deep"},       kick_alt={"Kick Electronic","Room"},
    snare={"Snare Electronic","Room"},     snare_alt={"Snare Acoustic","Bright"},
    clap={"Claps & Snaps","Room"},
    hh_c={"Hihat Closed","Acoustic"},      hh_pedal={"Hihat Closed","Room"},
    hh_o={"HiHat Open","Acoustic"},
    tom={"Tom","Room"},
    crash={"Crash","Acoustic"},            ride={"Ride","Acoustic"},
    perc={"Shakers","Acoustic"},
  },
  { name="05 House Electronic",
    kick={"Kick Electronic","Organic"},    kick_alt={"Kick Electronic","Layered"},
    snare={"Snare Electronic","Organic"},  snare_alt={"Snare Electronic","Layered"},
    clap={"Claps & Snaps","Layered"},
    hh_c={"Hihat Closed","Synthetic"},     hh_pedal={"Hihat Closed","Acoustic"},
    hh_o={"HiHat Open","Synthetic"},
    tom={"Tom","Organic"},
    crash={"Crash","Creative"},            ride={"Ride","Creative"},
    perc={"Perc Electronic","Hand Drum"},
  },
  { name="06 Lo-Fi Acoustic",
    kick={"Kick Acoustic","Deep"},         kick_alt={"Kick Acoustic","Room"},
    snare={"Snare Acoustic","Room"},       snare_alt={"Snare Acoustic","Lo-Fi"},
    clap={"Claps & Snaps","Acoustic"},
    hh_c={"Hihat Closed","Lo-Fi"},         hh_pedal={"Hihat Closed","Acoustic"},
    hh_o={"HiHat Open","Lo-Fi"},
    tom={"Tom","Acoustic"},
    crash={"Crash","Room"},                ride={"Ride","Room"},
    perc={"Perc Acoustic","Small Perc"},
  },
  { name="07 Lo-Fi Tape",
    kick={"Kick Electronic","Tape & Vinyl"}, kick_alt={"Kick Acoustic","Deep"},
    snare={"Snare Acoustic","Tape & Vinyl"}, snare_alt={"Snare Electronic","Lo-Fi"},
    clap={"Claps & Snaps","Tape & Vinyl"},
    hh_c={"Hihat Closed","Tape & Vinyl"},  hh_pedal={"Hihat Closed","Lo-Fi"},
    hh_o={"HiHat Open","Tape & Vinyl"},
    tom={"Tom","Tape & Vinyl"},
    crash={"Crash","Organic"},             ride={"Ride","Acoustic"},
    perc={"Foley","Sticks & Clicks"},
  },
  { name="08 Rap/Trap",
    kick={"Kick Electronic","808"},        kick_alt={"Kick Electronic","Sub"},
    snare={"Snare Electronic","Heavy"},    snare_alt={"Snare Electronic","808"},
    clap={"Claps & Snaps","Heavy"},
    hh_c={"Hihat Closed","Noise"},         hh_pedal={"Hihat Closed","Synthetic"},
    hh_o={"HiHat Open","Noise"},
    tom={"Tom","Heavy"},
    crash={"Crash","Synthetic"},           ride={"Ride","Synthetic"},
    perc={"Perc Electronic","Snap"},
  },
  { name="09 Acoustic Studio",
    kick={"Kick Acoustic","Punchy"},       kick_alt={"Kick Acoustic","Bright"},
    snare={"Snare Acoustic","Bright"},     snare_alt={"Snare Acoustic","Room"},
    clap={"Claps & Snaps","Acoustic"},
    hh_c={"Hihat Closed","Acoustic"},      hh_pedal={"Hihat Closed","Room"},
    hh_o={"HiHat Open","Acoustic"},
    tom={"Tom","Acoustic"},
    crash={"Crash","Acoustic"},            ride={"Ride","Acoustic"},
    perc={"Perc Acoustic","Hand Drum"},
  },
  { name="10 Acoustic Room",
    kick={"Kick Acoustic","Room"},         kick_alt={"Kick Acoustic","Heavy"},
    snare={"Snare Acoustic","Room"},       snare_alt={"Snare Acoustic","Organic"},
    clap={"Claps & Snaps","Room"},
    hh_c={"Hihat Closed","Room"},          hh_pedal={"Hihat Closed","Acoustic"},
    hh_o={"HiHat Open","Room"},
    tom={"Tom","Room"},
    crash={"Crash","Room"},                ride={"Ride","Room"},
    perc={"Perc Acoustic","Room"},
  },
  { name="11 Drum Machine",
    kick={"Kick Electronic","Drum Machine"},     kick_alt={"Kick Electronic","Synthetic"},
    snare={"Snare Electronic","Drum Machine"},   snare_alt={"Snare Electronic","808"},
    clap={"Claps & Snaps","Drum Machine"},
    hh_c={"Hihat Closed","Drum Machine"},        hh_pedal={"Hihat Closed","Synthetic"},
    hh_o={"HiHat Open","Drum Machine"},
    tom={"Tom","Drum Machine"},
    crash={"Crash","Drum Machine"},              ride={"Ride","Drum Machine"},
    perc={"Perc Electronic","Drum Machine"},
  },
  { name="12 Electronica/IDM",
    kick={"Kick Electronic","Layered"},    kick_alt={"Kick Electronic","Creative"},
    snare={"Snare Electronic","Layered"},  snare_alt={"Snare Electronic","Creative"},
    clap={"Claps & Snaps","Glitch"},
    hh_c={"Hihat Closed","Noise"},         hh_pedal={"Hihat Closed","808"},
    hh_o={"HiHat Open","Heavy"},
    tom={"Tom","Creative"},
    crash={"Crash","Creative"},            ride={"Ride","Creative"},
    perc={"Perc Glitch","Blips & Pops"},
  },
  { name="13 Organic/World",
    kick={"Kick Acoustic","Heavy"},        kick_alt={"Kick Acoustic","Deep"},
    snare={"Snare Acoustic","Organic"},    snare_alt={"Snare Acoustic","Metallic"},
    clap={"Claps & Snaps","Organic"},
    hh_c={"Hihat Closed","Metallic"},      hh_pedal={"Hihat Closed","Acoustic"},
    hh_o={"HiHat Open","Acoustic"},
    tom={"Tom","Organic"},
    crash={"Crash","Organic"},             ride={"Ride","Acoustic"},
    perc={"Perc Acoustic","Bongo"},
  },
  { name="14 Heavy/Industrial",
    kick={"Kick Electronic","Heavy"},      kick_alt={"Kick Electronic","Sub"},
    snare={"Snare Electronic","Heavy"},    snare_alt={"Snare Electronic","Noise"},
    clap={"Claps & Snaps","Heavy"},
    hh_c={"Hihat Closed","Metallic"},      hh_pedal={"Hihat Closed","Noise"},
    hh_o={"HiHat Open","Heavy"},
    tom={"Tom","Heavy"},
    crash={"Crash","Noise"},               ride={"Ride","Bright"},
    perc={"Perc Electronic","Metallic"},
  },
  { name="15 Pop/Disco",
    kick={"Kick Electronic","Punchy"},     kick_alt={"Kick Acoustic","Bright"},
    snare={"Snare Acoustic","Bright"},     snare_alt={"Snare Electronic","Tight"},
    clap={"Claps & Snaps","Bright"},
    hh_c={"Hihat Closed","Bright"},        hh_pedal={"Hihat Closed","Acoustic"},
    hh_o={"HiHat Open","Bright"},
    tom={"Tom","Punchy"},
    crash={"Crash","Bright"},              ride={"Ride","Bright"},
    perc={"Shakers","Acoustic"},
  },
}

-- Voice key → GM notes (order matters for loading)
local KIT_VOICE_ORDER = {"kick","kick_alt","snare","snare_alt","clap","hh_c","hh_pedal","hh_o","crash","ride","perc"}
local KIT_VOICE_NOTES = {
  kick={36}, kick_alt={35},
  snare={38}, snare_alt={40},
  clap={39},
  hh_c={42}, hh_pedal={44},
  hh_o={46},
  crash={49,57}, ride={51,59},
  perc={54},
}
local RIMSHOT_DEFAULT  = {"Perc Acoustic", "Rimshot"}
local TOM_NOTES        = {41,43,45,47,48,50}
local TOM_PITCH_CENTER = 45
local TOM_PITCH_SCALE  = 0.5   -- compress semitone spread (full = 1.0)
local TOM_PAN_LOW      = 0.25  -- lowest tom (41) pan — left
local TOM_PAN_HIGH     = 0.75  -- highest tom (50) pan — right

-- HH Open release: param 27 enables note-off release override; param 26 = release time.
-- Normalized 0.05 ≈ 50ms estimated — adjust HH_OPEN_RELEASE_NORM after testing.
local HH_OPEN_RELEASE_NORM = 0.05

-- Fixed voices: same across all kits, GM range
local KIT_FIXED_VOICES = {
  {notes={52},    type="Crash",           tag="Creative"},
  {notes={55},    type="Crash",           tag="Bright"},
  {notes={53},    type="Ride",            tag="Bright"},
  {notes={56},    type="Perc Electronic", tag="Blocks & Bells"},
  {notes={69},    type="Shakers",         tag="Metallic"},
  {notes={70},    type="Shakers",         tag="Synthetic"},
  {notes={60,61}, type="Perc Acoustic",   tag="Bongo"},
  {notes={62,63}, type="Perc Acoustic",   tag="Conga"},
  {notes={64},    type="Perc Acoustic",   tag="Tumba"},
  {notes={65,66}, type="Perc Acoustic",   tag="Timbale"},
  {notes={75},    type="Perc Acoustic",   tag="Sticks & Clicks"},
  {notes={76,77}, type="Perc Acoustic",   tag="Blocks & Bells"},
  {notes={82},    type="Shakers",         tag="Organic"},
  {notes={86,87}, type="Tom",             tag="Deep"},
}

-- Lower extras: notes 21-34, same across all kits
local KIT_LOWER_VOICES = {
  {notes={21}, type="Perc Glitch", tag="Blips & Pops"},
  {notes={22}, type="Perc Glitch", tag="Creative"},
  {notes={23}, type="Perc Glitch", tag="Metallic"},
  {notes={24}, type="Perc Glitch", tag="Synthetic"},
  {notes={25}, type="Perc Glitch", tag="Deep"},
  {notes={26}, type="Layer",       tag="Sub"},
  {notes={27}, type="Layer",       tag="Bright"},
  {notes={28}, type="Layer",       tag="Creative"},
  {notes={29}, type="Layer",       tag="Noise"},
  {notes={30}, type="Layer",       tag="Snap"},
  {notes={31}, type="Noise",       tag=""},
  {notes={32}, type="Foley",       tag="Blips & Pops"},
  {notes={33}, type="Foley",       tag="Metallic"},
  {notes={34}, type="Foley",       tag="Organic"},
}

-- Upper pitch zones: 3 × 7-note empty RS5k slots (MIDI 88-108, E5-C7)
-- User assigns any TRIAZ sample via tweak mode; pitch shifts per played note.
local KIT_UPPER_ZONES = {
  {lo=88,  hi=94,  label="zone 1 (E5-A#5)"},
  {lo=95,  hi=101, label="zone 2 (B5-F6)"},
  {lo=102, hi=108, label="zone 3 (F#6-C7)"},
}

-- ── FX name parsing / formatting ────────────────────────────────────────────

-- FX name format: "TRIAZ | note:NN | LN | DrumType/Tag"
local function make_fx_name(note, layer, drum_type, tag)
  return string.format("TRIAZ | note:%d | L%d | %s/%s", note, layer, drum_type, tag)
end

local function parse_fx_name(name)
  local note, layer, dtype, tag = name:match(
    "^TRIAZ | note:(%d+) | L(%d+) | (.+)/(.+)$"
  )
  if note then
    return {note=tonumber(note), layer=tonumber(layer), drum_type=dtype, tag=tag}
  end
  return nil
end

-- ── RS5k parameter indices (0-based) ────────────────────────────────────────
-- Param indices verified via TrackFX_GetParamName dump on RS5k (total 33 params)
local RS5K_PARAM = {
  volume        = 0,   -- 0..1 (linear gain)
  pan           = 1,   -- 0..1 (0=L, 0.5=C, 1=R)
  gain_min_vel  = 2,   -- Gain at velocity 0: 0=silent (velocity sensitive), 1=full (flat)
  note_lo       = 3,   -- Note range start: 0..1 mapped from MIDI 0..127
  note_hi       = 4,   -- Note range end:   0..1 mapped from MIDI 0..127
  pitch_note_lo = 5,   -- Pitch at note_lo: same normalization as pitch_st
  pitch_note_hi = 6,   -- Pitch at note_hi: same normalization as pitch_st
  loop             = 12,  -- Loop: 0=no loop, 1=loop
  obey_note_off    = 11,  -- 0=one-shot (play to end), 1=stop on note-off
  pitch_st         = 15,  -- Pitch adjust: normalized 0..1 where 0.5 = 0 semitones
  release_note_off = 26,  -- Release time after note-off
  use_note_off_rel = 27,  -- 0=off, 1=use param 26 for note-off release
}

local function midi_to_param(midi) return midi / 127.0 end
local function param_to_midi(p)   return math.floor(p * 127 + 0.5) end

-- pitch semitones → normalized param (range is -24..+24 → 0..1 in RS5k)
local function pitch_to_param(st) return (st + 24) / 48.0 end
local function param_to_pitch(p)  return p * 48.0 - 24 end

-- ── Instance metadata via project extended state ─────────────────────────────
-- Key: "TRIAZ_BROWSER" section, key = track_GUID .. "|" .. fx_guid
-- Value: "note:NN|LN|DrumType|Tag"
-- Survives project save/load; keyed by FX GUID so reorder-safe.

local function track_guid(track)
  local _, g = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
  return g
end

local function fx_guid(track, fx_idx)
  local g = reaper.TrackFX_GetFXGUID(track, fx_idx)
  return g or ("idx_" .. fx_idx)  -- fallback if GUID unavailable
end

local function meta_key(track, fx_idx)
  return track_guid(track) .. "|" .. fx_guid(track, fx_idx)
end

local function save_meta(track, fx_idx, note, layer, drum_type, tag)
  local val = string.format("note:%d|L%d|%s|%s", note, layer, drum_type, tag)
  reaper.SetProjExtState(0, "TRIAZ_BROWSER", meta_key(track, fx_idx), val)
end

local function load_meta(track, fx_idx)
  local ok, val = reaper.GetProjExtState(0, "TRIAZ_BROWSER", meta_key(track, fx_idx))
  if not ok or val == "" then return nil end
  local note, layer, dtype, tag = val:match("^note:(%d+)|L(%d+)|(.+)|(.+)$")
  if not note then return nil end
  return {note=tonumber(note), layer=tonumber(layer), drum_type=dtype, tag=tag}
end

local function delete_meta(track, fx_idx)
  reaper.SetProjExtState(0, "TRIAZ_BROWSER", meta_key(track, fx_idx), "")
end

local function remove_rs5k(track, fx_idx)
  delete_meta(track, fx_idx)
  reaper.TrackFX_Delete(track, fx_idx)
end

-- Scan track for all TRIAZ RS5k instances via project ext state
local function scan_triaz_instances(track)
  local instances = {}
  local count = reaper.TrackFX_GetCount(track)
  for i = 0, count - 1 do
    local info = load_meta(track, i)
    if info then
      instances[#instances + 1] = {fx_idx = i, info = info}
    end
  end
  return instances
end

-- Add a new RS5k instance to track, return fx index
-- Try every known name variant; -1 means not found
local RS5K_NAMES = {
  "ReaSamplOmatic5000",
  "reasamplomatic5000",
  "ReaSamplomatic5000",
  "RS5k",
  "Samplomatic5000",
}
local _rs5k_working_name = nil

local function add_rs5k(track)
  if _rs5k_working_name then
    local idx = reaper.TrackFX_AddByName(track, _rs5k_working_name, false, -1)
    if idx >= 0 then return idx end
  end
  for _, name in ipairs(RS5K_NAMES) do
    local idx = reaper.TrackFX_AddByName(track, name, false, -1)
    if idx >= 0 then _rs5k_working_name = name; return idx end
  end
  local dbg = "RS5k not found. Tried:\n" .. table.concat(RS5K_NAMES, "\n")
    .. "\n\nFX on this track:\n"
  local n = reaper.TrackFX_GetCount(track)
  for i = 0, n - 1 do
    local _, nm = reaper.TrackFX_GetFXName(track, i, "")
    dbg = dbg .. "  " .. nm .. "\n"
  end
  if reaper.CF_SetClipboard then reaper.CF_SetClipboard(dbg) end
  reaper.MB(dbg, "RS5k not found (copied to clipboard)", 0)
  return -1
end

-- ── Configure RS5k instance ──────────────────────────────────────────────────

local function configure_rs5k(track, fx_idx, params)
  -- params: {path, note_lo, note_hi, pitch_st, volume, pan, fx_name, no_loop}

  if params.path then
    reaper.TrackFX_SetNamedConfigParm(track, fx_idx, "FILE0", params.path)
    reaper.TrackFX_SetNamedConfigParm(track, fx_idx, "NUMFILES", "1")
  end

  if params.note_lo then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.note_lo,
      midi_to_param(params.note_lo))
  end
  if params.note_hi then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.note_hi,
      midi_to_param(params.note_hi))
  end

  if params.pitch_st then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_st,
      pitch_to_param(params.pitch_st))
  end
  if params.pitch_note_lo then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_note_lo,
      pitch_to_param(params.pitch_note_lo))
  end
  if params.pitch_note_hi then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_note_hi,
      pitch_to_param(params.pitch_note_hi))
  end
  if params.volume ~= nil then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.volume, params.volume)
  end
  if params.pan ~= nil then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pan, params.pan)
  end
  if params.no_loop then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.loop, 0)
  end
  if params.path then
    -- velocity sensitivity: gain at min velocity = 0 (silent at vel 0, full at vel 127)
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.gain_min_vel, 0)
  end
  if params.obey_note_off ~= nil then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.obey_note_off,
      params.obey_note_off and 1.0 or 0.0)
  end
  if params.hh_open_release then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.use_note_off_rel, 1.0)
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.release_note_off, HH_OPEN_RELEASE_NORM)
  end
  -- fx_name via named config parm (display only, not used for scanning)
  if params.fx_name then
    reaper.TrackFX_SetNamedConfigParm(track, fx_idx, "fx_name", params.fx_name)
  end
  -- Persist metadata via project ext state (survives project save)
  if params.meta then
    local m = params.meta
    save_meta(track, fx_idx, m.note, m.layer, m.drum_type, m.tag)
  end
end

-- ── Preview ──────────────────────────────────────────────────────────────────

local preview_pcm = nil  -- PCM_source (must destroy separately)
local preview_obj = nil  -- CF_Preview handle

local function stop_preview()
  if preview_obj then
    reaper.CF_Preview_Stop(preview_obj)
    preview_obj = nil
  end
  if preview_pcm then
    reaper.PCM_Source_Destroy(preview_pcm)
    preview_pcm = nil
  end
end

local function preview_wav(path)
  stop_preview()
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then src = reaper.PCM_Source_CreateFromFile(path:gsub("\\", "/")) end
  if not src then return end
  local preview = reaper.CF_CreatePreview(src)
  if not preview then reaper.PCM_Source_Destroy(src); return end
  reaper.CF_Preview_SetValue(preview, "D_VOLUME", 1.0)
  reaper.CF_Preview_SetValue(preview, "B_LOOP",   0.0)
  reaper.CF_Preview_SetValue(preview, "I_OUTCHAN", 0)
  reaper.CF_Preview_Play(preview)
  preview_pcm = src
  preview_obj = preview
end


-- ── Dialog helpers ───────────────────────────────────────────────────────────

-- Short lists (≤8): embed numbered items in the window title — screen readers
-- Native context menu via gfx.showmenu — screen reader navigable with arrow keys.
local function pick_from_list(title, items)
  if #items == 0 then reaper.MB("No items found.", title, 0); return nil end
  gfx.init(title, 0, 0, 0, 0, 0)
  gfx.x, gfx.y = 0, 0
  local choice = gfx.showmenu(table.concat(items, "|"))
  gfx.quit()
  return choice ~= 0 and choice or nil
end

local function ask_yes_no(msg, title)
  return reaper.MB(msg, title or "TRIAZ Browser", 4) == 6
end

-- Show a gate dialog, then read the most recent MIDI note-on from input buffer.
-- Returns note name string. Falls back to note_name(gm_note) if no note-on found.
local function pick_note_default(gm_note)
  reaper.MB(
    "Play a MIDI note now, then click OK.\nThe note you play will be pre-filled in the next dialog.",
    "Capture Note from Keyboard", 0
  )
  -- Scan recent events; idx 0 = most recent. Look for a note-on (vel > 0).
  for idx = 0, 31 do
    local retval, buf = reaper.MIDI_GetRecentInputEvent(idx)
    if retval == 0 then break end
    if buf and #buf >= 3 then
      local st  = buf:byte(1)
      local num = buf:byte(2)
      local vel = buf:byte(3)
      if st >= 0x90 and st <= 0x9F and vel > 0 and num >= 0 and num <= 127 then
        return note_name(num)
      end
    end
  end
  return note_name(gm_note)
end

local function ask_string(caption, label, default)
  local ok, val = reaper.GetUserInputs(caption, 1, label .. ":", default or "")
  if not ok or val == "" then return nil end
  return val
end

-- Parse "note,layer" CSV result from a 2-field GetUserInputs dialog.
-- Returns note (0-127), layer (1-3), or nil on invalid note.
local function parse_note_layer(result)
  local parts = {}
  for p in result:gmatch("[^,]+") do parts[#parts + 1] = p:match("^%s*(.-)%s*$") end
  local note = tonumber(parts[1]) or note_from_name(parts[1] or "")
  if not note or note < 0 or note > 127 then return nil end
  return note, math.max(1, math.min(3, tonumber(parts[2]) or 1))
end

-- ── Browse: native Windows file dialog (js_ReaScriptAPI) ────────────────────
-- User navigates TRIAZ_BASE → DrumType → Tag → WAV.wav in the system file picker.
-- Path structure encodes drum_type and tag — no custom list UI needed.

local function parse_triaz_path(full_path)
  -- Extract DrumType and Tag from path under TRIAZ_BASE
  local rel = full_path:sub(#TRIAZ_BASE + 1)  -- e.g. "Kick Electronic\Deep\wa-triaz-kick-deep-01.wav"
  local drum_type, tag, wav = rel:match("^([^\\/]+)[/\\]([^\\/]+)[/\\]([^\\/]+)$")
  return drum_type, tag, wav
end

local _last_browse_path = TRIAZ_BASE  -- remember last location

local function browse_sample()
  if not reaper.JS_Dialog_BrowseForOpenFiles then
    reaper.MB("js_ReaScriptAPI not found. Install via ReaPack.", "Error", 0)
    return nil
  end

  local title    = "Select TRIAZ sample — navigate DrumType / Tag / WAV"
  local ext_list = "WAV files\0*.wav\0All files\0*.*\0\0"

  local ok, paths = reaper.JS_Dialog_BrowseForOpenFiles(
    title, _last_browse_path, "", ext_list, false
  )

  if not ok or not paths or paths == "" then return nil end

  local full_path = paths  -- single file, no multi-select

  -- Validate path is inside TRIAZ_BASE
  if full_path:sub(1, #TRIAZ_BASE):lower() ~= TRIAZ_BASE:lower() then
    reaper.MB(
      "Selected file is outside TRIAZ library:\n" .. full_path ..
      "\n\nNavigate inside:\n" .. TRIAZ_BASE,
      "Wrong folder", 0
    )
    return nil
  end

  local drum_type, tag, wav_name = parse_triaz_path(full_path)
  if not drum_type or not tag or not wav_name then
    reaper.MB(
      "Cannot parse DrumType/Tag from path.\nExpected: DrumType\\Tag\\file.wav\nGot: " .. full_path,
      "Path Error", 0
    )
    return nil
  end

  -- Remember folder for next browse
  _last_browse_path = full_path:match("^(.+)[/\\][^\\/]+$") or TRIAZ_BASE

  return wav_name, full_path, drum_type, tag
end

-- ── Note input ───────────────────────────────────────────────────────────────

local function ask_note(default_note, drum_type)
  local suggestion = ""
  local gm = GM_SUGGESTIONS[drum_type]
  if gm then suggestion = note_name(gm[1]) end

  local default = default_note and note_name(default_note) or suggestion
  local val = ask_string(
    "Target Note",
    string.format("Note (e.g. C2, D#4) [suggested: %s]", suggestion),
    default
  )
  if not val then return nil end

  local n = tonumber(val)
  if not n then
    n = note_from_name(val)
  end
  if not n or n < 0 or n > 127 then
    reaper.MB("Invalid note.", "Error", 0)
    return nil
  end
  return n
end

-- ── Pitch zone helpers ────────────────────────────────────────────────────────

-- Upper range MIDI 88-108 (E5-C7): 3 zones × 7 notes for pitched sample assignment.
-- Lower range (21-34) is occupied by kit loader lower extras.
local PITCH_ZONES = {
  {lo=88,  hi=94,  mid=91},
  {lo=95,  hi=101, mid=98},
  {lo=102, hi=108, mid=105},
}

local function show_pitch_zones()
  local lines = {}
  for i, z in ipairs(PITCH_ZONES) do
    lines[#lines + 1] = string.format(
      "%d: %s–%s (center %s)", i, note_name(z.lo), note_name(z.hi), note_name(z.mid)
    )
  end
  return lines
end

local function ask_pitch_zone()
  local lines = show_pitch_zones()
  local n = pick_from_list("Pitch Zone", lines, "Select pitch zone")
  if not n then return nil end
  return PITCH_ZONES[n]
end

-- ── Track selection ───────────────────────────────────────────────────────────

local function select_track()
  -- Option 1: use selected track
  local sel = reaper.GetSelectedTrack(0, 0)
  if sel then
    local ok, name = reaper.GetTrackName(sel, "")
    if ask_yes_no(
      "Use selected track: " .. (name or "?") .. "\n\nYes = use it, No = create new",
      "Track"
    ) then
      return sel
    end
  end

  -- Option 2: create new track
  local track_name = ask_string("New Track", "Track name", "TRIAZ Drums")
  if not track_name then return nil end

  local track_count = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_count, true)
  local new_track = reaper.GetTrack(0, track_count)
  reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", track_name, true)
  return new_track
end

-- ── RS5k param diagnostic ────────────────────────────────────────────────────

local function dump_rs5k_params(track, fx_idx)
  local count = reaper.TrackFX_GetNumParams(track, fx_idx)
  local lines = {"RS5k params on FX idx " .. fx_idx .. " (total " .. count .. "):"}
  for i = 0, math.min(count - 1, 30) do
    local val = reaper.TrackFX_GetParamNormalized(track, fx_idx, i)
    local _, name = reaper.TrackFX_GetParamName(track, fx_idx, i, "")
    lines[#lines + 1] = string.format("  [%d] %-30s = %.4f", i, name, val)
  end
  local text = table.concat(lines, "\n")
  -- Show in GetUserInputs so screen reader can reach it (read-only field trick)
  reaper.ShowConsoleMsg(text .. "\n")
  reaper.MB(text, "RS5k Param Dump", 0)
end

-- ── Layer vol/pan edit ────────────────────────────────────────────────────────

local function edit_layer_params(track, fx_idx, layer_num)
  local vol_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.volume)
  local pan_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.pan)
  local vol_db  = math.floor(20 * math.log(vol_raw + 1e-9, 10) + 0.5)
  local pan_pct = math.floor((pan_raw - 0.5) * 200 + 0.5)

  local ok, result = reaper.GetUserInputs(
    "Layer " .. layer_num .. " — Vol/Pan",
    2,
    "Volume dB (0 = unity),Pan % (-100 L .. 0 C .. 100 R)",
    tostring(vol_db) .. "," .. tostring(pan_pct)
  )
  if not ok then return end

  local parts = {}
  for p in result:gmatch("[^,]+") do parts[#parts + 1] = p end
  local new_vol_db  = tonumber(parts[1])
  local new_pan_pct = tonumber(parts[2])

  if new_vol_db then
    local lin = 10 ^ (new_vol_db / 20.0)
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.volume,
      math.min(1.0, lin))
  end
  if new_pan_pct then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pan,
      (new_pan_pct / 200.0) + 0.5)
  end
end

-- ── Assign sample to RS5k ────────────────────────────────────────────────────

-- Find or create RS5k for note+layer, configure it
local function assign_sample(track, note, layer, drum_type, tag, wav_name, full_path, zone)
  local fx_name = make_fx_name(note, layer, drum_type, tag)

  local fx_idx
  for _, inst in ipairs(scan_triaz_instances(track)) do
    if inst.info.note == note and inst.info.layer == layer then
      fx_idx = inst.fx_idx; break
    end
  end

  if not fx_idx then
    fx_idx = add_rs5k(track)
    if fx_idx < 0 then
      reaper.MB("Failed to add RS5k. Is reasamplomatic5000 installed?", "Error", 0)
      return false
    end
  end

  local is_noise = (drum_type == "Noise") and NOISE_LOOP_FILES[wav_name]

  local note_lo, note_hi, pitch_st, pitch_note_lo, pitch_note_hi
  if zone then
    note_lo       = zone.lo
    note_hi       = zone.hi
    pitch_st      = 0
    pitch_note_lo = zone.lo - zone.mid  -- semitones below center at lowest note
    pitch_note_hi = zone.hi - zone.mid  -- semitones above center at highest note
  else
    note_lo  = note
    note_hi  = note
    pitch_st = 0
  end

  configure_rs5k(track, fx_idx, {
    path          = full_path,
    note_lo       = note_lo,
    note_hi       = note_hi,
    pitch_st      = pitch_st,
    pitch_note_lo = pitch_note_lo,
    pitch_note_hi = pitch_note_hi,
    volume        = 0.8,
    pan           = 0.5,
    no_loop       = is_noise,
    fx_name       = fx_name,
    meta          = {note=note, layer=layer, drum_type=drum_type, tag=tag},
  })

  return true, fx_idx
end

-- ── Tweak mode: edit existing instances ──────────────────────────────────────

-- inst_n:   pre-selected instance index; nil = show picker dialog
-- action_n: pre-selected action (1-6);   nil = show action picker dialog
local function tweak_mode(track, inst_n, action_n)
  local instances = scan_triaz_instances(track)
  if #instances == 0 then
    reaper.MB("No TRIAZ RS5k instances found on this track.", "Tweak", 0)
    return
  end

  local n = inst_n
  if not n then
    local labels = {}
    for _, inst in ipairs(instances) do
      local i = inst.info
      labels[#labels + 1] = string.format(
        "L%d %s — %s/%s",
        i.layer, note_name(i.note), i.drum_type, i.tag
      )
    end
    n = pick_from_list("TRIAZ Instances", labels)
    if not n then return end
  end

  local inst = instances[n]
  local fx_idx = inst.fx_idx
  local info   = inst.info

  -- Get current sample
  local ok_f, cur_file = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "FILE0")
  local cur_wav = cur_file and cur_file:match("[^\\/]+$") or "?"

  local action = action_n
  if not action then
    local choices = {
      "Swap sample (re-browse)",
      "Edit volume / pan",
      "Edit pitch semitones",
      "Preview current sample",
      "Dump RS5k params (diagnostic)",
      "Remove this instance",
    }
    action = pick_from_list("Edit: " .. cur_wav, choices)
    if not action then return end
  end

  if action == 1 then
    -- swap sample via native file dialog
    local new_wav, new_path, new_type, new_tag = browse_sample()
    if not new_wav then return end

    local is_noise = (new_type == "Noise") and NOISE_LOOP_FILES[new_wav]
    local new_fx_name = make_fx_name(info.note, info.layer, new_type, new_tag)

    configure_rs5k(track, fx_idx, {
      path    = new_path,
      no_loop = is_noise,
      fx_name = new_fx_name,
    })
    reaper.MB("Sample updated.", "Done", 0)

  elseif action == 2 then
    edit_layer_params(track, fx_idx, info.layer)

  elseif action == 3 then
    local cur_p  = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_st)
    local cur_st = math.floor(param_to_pitch(cur_p) + 0.5)
    local val = ask_string("Pitch Shift", "Semitones (-24..+24)", tostring(cur_st))
    if val then
      local st = tonumber(val)
      if st and st >= -24 and st <= 24 then
        reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_st,
          pitch_to_param(st))
      else
        reaper.MB("Out of range.", "Error", 0)
      end
    end

  elseif action == 4 then
    if ok_f and cur_file ~= "" then
      preview_wav(cur_file)
      reaper.MB("Playing preview. Close to stop.", "Preview", 0)
      stop_preview()
    else
      reaper.MB("No sample loaded.", "Preview", 0)
    end

  elseif action == 5 then
    dump_rs5k_params(track, fx_idx)

  elseif action == 6 then
    if ask_yes_no("Remove this RS5k instance?", "Confirm Remove") then
      remove_rs5k(track, fx_idx)
      reaper.MB("Removed.", "Done", 0)
    end
  end
end

-- ── Add new assignment flow ───────────────────────────────────────────────────

local function add_assignment_flow(track)
  local wav_name, full_path, drum_type, tag = browse_sample()
  if not wav_name then return end

  -- 2. All assignment params in ONE dialog
  -- Pitch zone hint
  local zone_hint = ""
  for i, z in ipairs(PITCH_ZONES) do
    zone_hint = zone_hint .. i .. "=" .. note_name(z.lo) .. "-" .. note_name(z.hi) .. " "
  end
  local gm_note = (GM_SUGGESTIONS[drum_type] or {36})[1]

  local captions = table.concat({
    "Note (e.g. C2  D#4; suggested=" .. note_name(gm_note) .. ")",
    "Layer (1-3; 1=new slot)",
    "Pitch zone # (0=none; zones: " .. zone_hint .. ")",
    "Volume dB (0=unity)",
    "Pan % (-100=L  0=C  100=R)",
    "Pitch shift semitones (-24 to +24)",
  }, ",")
  local defaults = pick_note_default(gm_note) .. ",1,0,0,0,0"

  local ok, result = reaper.GetUserInputs(
    "Assign: " .. wav_name, 6, captions, defaults
  )
  if not ok then return end

  local parts = {}
  for p in result:gmatch("[^,]+") do parts[#parts + 1] = p:match("^%s*(.-)%s*$") end
  while #parts < 6 do parts[#parts + 1] = "0" end

  -- Parse pitch zone first — if zone is selected, note field is ignored entirely
  local zone_n = tonumber(parts[3]) or 0
  local zone = (zone_n >= 1 and zone_n <= #PITCH_ZONES) and PITCH_ZONES[zone_n] or nil

  -- Parse note (skipped when zone is selected)
  local target_note
  if zone then
    target_note = zone.mid
  else
    target_note = tonumber(parts[1]) or note_from_name(parts[1] or "")
    if not target_note or target_note < 0 or target_note > 127 then
      reaper.MB("Invalid note: " .. (parts[1] or ""), "Error", 0); return
    end
  end

  -- Parse layer
  local layer = math.max(1, math.min(3, tonumber(parts[2]) or 1))

  -- Parse vol/pan/pitch
  local vol_db  = tonumber(parts[4]) or 0
  local pan_pct = tonumber(parts[5]) or 0
  local pitch_st = math.max(-24, math.min(24, tonumber(parts[6]) or 0))

  -- Check layer count
  local instances = scan_triaz_instances(track)
  local layer_count = 0
  for _, inst in ipairs(instances) do
    if inst.info.note == target_note then layer_count = layer_count + 1 end
  end
  if layer_count >= 3 then
    if not ask_yes_no(
      "3 layers already on note " .. note_name(target_note) .. ". Add anyway?",
      "Max Layers"
    ) then return end
  end

  -- Assign → preview → keep or retry
  while true do
    local assign_ok, fx_idx = assign_sample(
      track, target_note, layer, drum_type, tag, wav_name, full_path, zone
    )
    if not assign_ok then return end

    -- Apply vol/pan/pitch
    local lin_vol = math.min(1.0, 10 ^ (vol_db / 20.0))
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.volume, lin_vol)
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pan, (pan_pct / 200.0) + 0.5)
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_st, pitch_to_param(pitch_st))

    preview_wav(full_path)

    -- Keep / try another / cancel
    -- MB type 3 = Yes / No / Cancel
    local choice = reaper.MB(
      string.format(
        "%s / %s / %s\nNote: %s%s  L%d  Vol:%ddB  Pan:%d%%  Pitch:%dst\n\nYes = keep\nNo = try another sample\nCancel = discard",
        drum_type, tag, wav_name,
        note_name(target_note),
        zone and (" zone " .. note_name(zone.lo) .. "-" .. note_name(zone.hi)) or "",
        layer, vol_db, pan_pct, pitch_st
      ),
      "Keep this sample?", 3
    )

    if choice == 6 then  -- Yes: keep
      break
    elseif choice == 7 then  -- No: try another
      remove_rs5k(track, fx_idx)
      local new_wav, new_path, new_type, new_tag = browse_sample()
      if not new_wav then stop_preview(); return end
      wav_name, full_path, drum_type, tag = new_wav, new_path, new_type, new_tag
    else  -- Cancel: discard
      remove_rs5k(track, fx_idx)
      return
    end
  end
end

-- ── Kit loader ───────────────────────────────────────────────────────────────

-- Load one voice group: resolve tag, pick WAV, create RS5k per note.
-- pitch_center: if set, pitch_st = (note - pitch_center) per note (pitched toms).
-- tag="" means WAVs live in the drum type root folder (Noise).
-- opts (optional): { pitch_scale=number, pan_list=table }
-- pitch_scale compresses the semitone spread (1.0 = full, 0.5 = half).
-- pan_list[i] overrides pan for the i-th note in the notes array.
local function load_voice(track, drum_type, tag, notes, pitch_center, stats, opts)
  local resolved_tag
  if tag == "" then
    resolved_tag = ""
  else
    resolved_tag = find_tag(drum_type, tag)
    if not resolved_tag then stats.failed = stats.failed + 1; return end
  end

  local wav, path = pick_kit_wav(drum_type, resolved_tag)
  if not wav then stats.failed = stats.failed + 1; return end

  local is_noise    = (drum_type == "Noise") and NOISE_LOOP_FILES[wav]
  local is_hh_open  = (drum_type == "HiHat Open")
  local display_tag = (resolved_tag ~= "") and resolved_tag or "(root)"
  local pitch_scale = (opts and opts.pitch_scale) or 1.0
  local pan_list    = opts and opts.pan_list

  for k, note in ipairs(notes) do
    local fx_idx = add_rs5k(track)
    if fx_idx < 0 then stats.failed = stats.failed + 1 else
      local pitch_st = 0
      if pitch_center then
        pitch_st = math.floor((note - pitch_center) * pitch_scale + 0.5)
      end
      configure_rs5k(track, fx_idx, {
        path             = path,
        note_lo          = note,
        note_hi          = note,
        pitch_st         = pitch_st,
        volume           = 0.8,
        pan              = pan_list and pan_list[k] or 0.5,
        no_loop          = is_noise,
        obey_note_off    = is_noise or is_hh_open,
        hh_open_release  = is_hh_open,
        fx_name          = make_fx_name(note, 1, drum_type, display_tag),
        meta             = {note=note, layer=1, drum_type=drum_type, tag=display_tag},
      })
      stats.loaded = stats.loaded + 1
    end
  end
end

-- kit_n: pre-selected kit index (from submenu); nil = show picker dialog
local function load_kit_flow(track, kit_n)
  local n = kit_n
  if not n then
    local kit_names = {}
    for _, k in ipairs(KITS) do kit_names[#kit_names + 1] = k.name end
    n = pick_from_list("Load Kit", kit_names)
    if not n then return end
  end
  local kit = KITS[n]

  local existing = scan_triaz_instances(track)
  if #existing > 0 then
    local choice = reaper.MB(
      #existing .. " existing instance(s) on this track.\n\nYes = overwrite all\nNo = add alongside\nCancel = abort",
      "Kit Load", 3
    )
    if choice == 2 then return end
    if choice == 6 then
      for i = #existing, 1, -1 do remove_rs5k(track, existing[i].fx_idx) end
    end
  end

  local stats = {loaded=0, failed=0}
  local t_start = reaper.time_precise()

  reaper.PreventUIRefresh(1)

  -- Rimshot: fixed across all kits
  load_voice(track, RIMSHOT_DEFAULT[1], RIMSHOT_DEFAULT[2], {37}, nil, stats)

  -- Kit-specific voices
  for _, vkey in ipairs(KIT_VOICE_ORDER) do
    if kit[vkey] then
      load_voice(track, kit[vkey][1], kit[vkey][2], KIT_VOICE_NOTES[vkey], nil, stats)
    end
  end

  -- Toms: pitched (compressed) + panned right-to-left (low=right, high=left)
  if kit.tom then
    local pan_list = {}
    for i = 1, #TOM_NOTES do
      pan_list[i] = TOM_PAN_LOW + (i - 1) / (#TOM_NOTES - 1) * (TOM_PAN_HIGH - TOM_PAN_LOW)
    end
    load_voice(track, kit.tom[1], kit.tom[2], TOM_NOTES, TOM_PITCH_CENTER, stats,
      {pitch_scale = TOM_PITCH_SCALE, pan_list = pan_list})
  end

  -- Fixed voices: same every kit
  for _, v in ipairs(KIT_FIXED_VOICES) do
    load_voice(track, v.type, v.tag, v.notes, nil, stats)
  end

  -- Lower extras: notes 21-34 (Perc Glitch / Layer / Noise / Foley)
  for _, v in ipairs(KIT_LOWER_VOICES) do
    load_voice(track, v.type, v.tag, v.notes, nil, stats)
  end

  -- Upper zones: 3 empty RS5k slots (E5-C7) for user-assigned pitched samples
  for _, z in ipairs(KIT_UPPER_ZONES) do
    local fx_idx = add_rs5k(track)
    if fx_idx >= 0 then
      configure_rs5k(track, fx_idx, {
        note_lo = z.lo,
        note_hi = z.hi,
        pitch_st = 0,
        volume   = 0.8,
        pan      = 0.5,
        fx_name  = z.label,
        meta     = {note=z.lo, layer=1, drum_type="Zone", tag=z.label},
      })
      stats.loaded = stats.loaded + 1
    else
      stats.failed = stats.failed + 1
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)

  local elapsed = reaper.time_precise() - t_start
  reaper.MB(
    string.format("Kit: %s\nLoaded: %d  Failed: %d  (%.1fs)\n\nToms: pitched -2 to +3 st from %s, panned R→L.\nHH Open: ~50ms note-off release.\nUpper zones E5-C7 empty — assign via Add sample.",
      kit.name, stats.loaded, stats.failed, elapsed,
      note_name(TOM_PITCH_CENTER)
    ),
    "Kit Loaded", 0
  )
end

-- ── Quick assign ─────────────────────────────────────────────────────────────
-- Browse file → minimal 2-field dialog (note + layer) → assign → preview

local function quick_assign_flow(track)
  local wav_name, full_path, drum_type, tag = browse_sample()
  if not wav_name then return end

  local gm_note = (GM_SUGGESTIONS[drum_type] or {36})[1]
  local note_default = pick_note_default(gm_note)
  local ok, result = reaper.GetUserInputs(
    "Quick Assign: " .. wav_name, 2,
    "Note (e.g. C2  D#4; suggested=" .. note_name(gm_note) .. "),Layer (1-3)",
    note_default .. ",1"
  )
  if not ok then return end

  local note, layer = parse_note_layer(result)
  if not note then reaper.MB("Invalid note.", "Error", 0); return end

  while true do
    local assign_ok, fx_idx = assign_sample(track, note, layer, drum_type, tag, wav_name, full_path, nil)
    if not assign_ok then return end

    preview_wav(full_path)
    local res = reaper.MB(
      string.format("%s / %s / %s\nNote: %s  L%d\n\nYes = keep   No = browse again   Cancel = discard",
        drum_type, tag, wav_name, note_name(note), layer),
      "Keep?", 3
    )
    stop_preview()

    if res == 6 then return end  -- Yes: keep

    remove_rs5k(track, fx_idx)

    if res == 7 then  -- No: browse again
      local new_wav, new_path, new_type, new_tag = browse_sample()
      if not new_wav then return end
      wav_name, full_path, drum_type, tag = new_wav, new_path, new_type, new_tag
    else  -- Cancel: discard
      return
    end
  end
end

-- ── Import selected items ─────────────────────────────────────────────────────
-- For each selected media item on the timeline, ask note+layer, assign to RS5k.

local function import_selected_items_flow(track)
  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then
    reaper.MB("No media items selected in project.", "Import", 0)
    return
  end

  local items = {}
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take  = item and reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local src  = reaper.GetMediaItemTake_Source(take)
      local path = src and reaper.GetMediaSourceFileName(src, "")
      if path and path ~= "" then
        items[#items + 1] = path
      end
    end
  end

  if #items == 0 then
    reaper.MB("No audio items found in selection (MIDI items ignored).", "Import", 0)
    return
  end

  reaper.MB(
    string.format("%d audio item%s found.\nFor each: set note + layer, preview, keep or skip.",
      #items, #items == 1 and "" or "s"),
    "Import Selected Items", 0
  )

  for idx, full_path in ipairs(items) do
    stop_preview()  -- ensure previous item's audio is dead before next dialog

    local wav_name = full_path:match("[^\\/]+$") or full_path
    local drum_type, tag = parse_triaz_path(full_path)
    drum_type = drum_type or "Unknown"
    tag       = tag       or ""

    local gm_note = (GM_SUGGESTIONS[drum_type] or {36})[1]
    local note_default = pick_note_default(gm_note)
    local ok, result = reaper.GetUserInputs(
      string.format("Item %d/%d: %s", idx, #items, wav_name), 2,
      "Note (e.g. C2  D#4; suggested=" .. note_name(gm_note) .. "),Layer (1-3)",
      note_default .. ",1"
    )
    if not ok then break end

    local note, layer = parse_note_layer(result)
    if not note then
      reaper.MB("Invalid note — skipping this item.", "Error", 0)
      goto continue
    end

    local assign_ok, fx_idx = assign_sample(track, note, layer, drum_type, tag, wav_name, full_path, nil)
    if not assign_ok then goto continue end

    preview_wav(full_path)
    local res = reaper.MB(
      string.format("%s\nNote: %s  L%d\n\nYes = keep   No = skip",
        wav_name, note_name(note), layer),
      string.format("Keep? (%d/%d)", idx, #items), 4
    )
    stop_preview()

    if res ~= 6 then remove_rs5k(track, fx_idx) end

    ::continue::
  end
end

-- ── Import single item (used by main menu import submenu) ────────────────────

local function import_item_flow(track, full_path)
  local wav_name = full_path:match("[^\\/]+$") or full_path
  local drum_type, tag = parse_triaz_path(full_path)
  drum_type = drum_type or "Unknown"
  tag       = tag       or ""

  local gm_note = (GM_SUGGESTIONS[drum_type] or {36})[1]
  local note_default = pick_note_default(gm_note)
  local ok, result = reaper.GetUserInputs(
    wav_name, 2,
    "Note (e.g. C2  D#4; suggested=" .. note_name(gm_note) .. "),Layer (1-3)",
    note_default .. ",1"
  )
  if not ok then return end

  local note, layer = parse_note_layer(result)
  if not note then reaper.MB("Invalid note.", "Error", 0); return end

  local assign_ok, fx_idx = assign_sample(track, note, layer, drum_type, tag, wav_name, full_path, nil)
  if not assign_ok then return end

  preview_wav(full_path)
  local res = reaper.MB(
    string.format("%s\nNote: %s  L%d\n\nYes = keep   No = discard",
      wav_name, note_name(note), layer),
    "Keep?", 4
  )
  stop_preview()
  if res ~= 6 then remove_rs5k(track, fx_idx) end
end

-- ── Randomize ────────────────────────────────────────────────────────────────

local function random_wav_from(drum_type, tag)
  local path = (tag and tag ~= "" and tag ~= "(root)")
    and (TRIAZ_BASE .. drum_type .. "\\" .. tag)
    or  (TRIAZ_BASE .. drum_type)
  local wavs = list_wavs(path)
  if #wavs == 0 then return nil, nil end
  local wav = wavs[math.random(#wavs)]
  return wav, path .. "\\" .. wav
end

local function random_tag_for(drum_type)
  if drum_type == "Noise" then return "" end
  local tags = list_dirs(TRIAZ_BASE .. drum_type)
  if #tags == 0 then return "" end
  return tags[math.random(#tags)]
end

local function apply_random_wav(track, inst, new_type, new_tag)
  local info = inst.info
  local dtype = new_type or info.drum_type
  local tag   = new_tag  or info.tag
  local wav, path = random_wav_from(dtype, tag)
  if not wav then return false end
  local is_noise   = (dtype == "Noise") and NOISE_LOOP_FILES[wav]
  local is_hh_open = (dtype == "HiHat Open")
  local disp_tag   = (tag ~= "" and tag ~= "(root)") and tag or "(root)"
  configure_rs5k(track, inst.fx_idx, {
    path            = path,
    no_loop         = is_noise,
    obey_note_off   = is_noise or is_hh_open,
    hh_open_release = is_hh_open,
    fx_name         = make_fx_name(info.note, info.layer, dtype, disp_tag),
    meta            = {note=info.note, layer=info.layer, drum_type=dtype, tag=disp_tag},
  })
  return true, wav, path
end

local function randomize_flow(track)
  math.randomseed(os.time())

  local all = scan_triaz_instances(track)
  local voices = {}
  for _, inst in ipairs(all) do
    if inst.info.drum_type ~= "Zone" then voices[#voices + 1] = inst end
  end

  if #voices == 0 then
    reaper.MB("No voice instances on track. Load a kit first.", "Randomize", 0)
    return
  end

  local modes = {
    "1  Single voice — same type/tag, new random WAV",
    "2  Entire kit  — same type/tag, new random WAV each voice",
    "3  Entire kit  — random tag within same drum type",
    "4  Full random — random type/tag/WAV every voice",
  }
  local mode = pick_from_list("Randomize", modes)
  if not mode then return end

  if mode == 1 then
    local labels = {}
    for _, inst in ipairs(voices) do
      local i = inst.info
      labels[#labels + 1] = string.format("%s — %s/%s",
        note_name(i.note), i.drum_type, i.tag)
    end
    local n = pick_from_list("Pick Voice", labels)
    if not n then return end

    local inst = voices[n]
    local ok, wav, path = apply_random_wav(track, inst, nil, nil)
    if not ok then
      reaper.MB("No WAVs found for " .. inst.info.drum_type .. "/" .. inst.info.tag, "Error", 0)
      return
    end
    preview_wav(path)
    reaper.MB(wav .. "\n" .. note_name(inst.info.note) .. " — " .. inst.info.drum_type .. "/" .. inst.info.tag,
      "Randomized", 0)
    stop_preview()

  elseif mode == 2 then
    local changed, failed = 0, 0
    for _, inst in ipairs(voices) do
      if apply_random_wav(track, inst, nil, nil) then changed = changed + 1
      else failed = failed + 1 end
    end
    reaper.MB(string.format("Randomized %d voices. Failed: %d.", changed, failed), "Done", 0)

  elseif mode == 3 then
    local changed, failed = 0, 0
    for _, inst in ipairs(voices) do
      local new_tag = random_tag_for(inst.info.drum_type)
      if apply_random_wav(track, inst, nil, new_tag) then changed = changed + 1
      else failed = failed + 1 end
    end
    reaper.MB(string.format("Randomized %d voices (new tags). Failed: %d.", changed, failed), "Done", 0)

  elseif mode == 4 then
    local changed, failed = 0, 0
    for _, inst in ipairs(voices) do
      local new_type = DRUM_TYPES[math.random(#DRUM_TYPES)]
      local new_tag  = random_tag_for(new_type)
      if apply_random_wav(track, inst, new_type, new_tag) then changed = changed + 1
      else failed = failed + 1 end
    end
    reaper.MB(string.format("Full random: %d voices. Failed: %d.", changed, failed), "Done", 0)
  end
end

-- ── Help ─────────────────────────────────────────────────────────────────────

local function show_help()
  local pages = {
    {
      title = "TRIAZ RS5k Browser — Help (1/4): Overview",
      text = [[
WHAT THIS SCRIPT DOES
---------------------
This script lets you browse the TRIAZ sample library and load samples into
ReaSamplOmatic5000 (RS5k) on a REAPER track. Each sample gets its own RS5k
instance, assigned to a specific MIDI note. When you play that note on your
keyboard or in a MIDI item, that sample plays.

Everything works through standard REAPER dialogs — no drawn windows — so it
is fully accessible with a screen reader.

TIP: To read this help text in full, use your screen reader's object
navigation feature to explore the dialog. This lets you move through
individual elements of the window and have their content read aloud.

HOW THE LIBRARY IS ORGANIZED
-----------------------------
The TRIAZ library is organized in three levels:

  Drum Type  (e.g. "Kick Electronic", "Snare Acoustic", "HiHat Closed")
    └── Tag  (e.g. "Deep", "Punchy", "808", "Lo-Fi")
          └── WAV files  (the actual samples)

When you browse for a sample, you navigate into
  X:\samplers\TRIAZ\Samples\TRIAZ - Factory Collection\
then into a Drum Type folder, then a Tag folder, then pick a WAV.

NOTES AND LAYERS
----------------
Every RS5k instance is assigned to a MIDI note (like C2, D#4).
  - Note C2 = MIDI 36 = Kick in General MIDI (GM) layout.
  - The script suggests a GM note for each drum type automatically.
  - You can stack up to 3 samples on the same note (called layers 1, 2, 3).
    All three will play at once when that note is triggered.
]]
    },
    {
      title = "TRIAZ RS5k Browser — Help (2/4): Main Menu Items",
      text = [[
MAIN MENU — WHAT EACH ITEM DOES
---------------------------------

ADD / ASSIGN SAMPLE
  Opens the file browser so you can pick any WAV from the TRIAZ library.
  Then asks for note, layer, pitch zone, volume, pan, and pitch shift in
  one dialog. After assigning, it previews the sample and asks if you want
  to keep it, try another, or discard.

QUICK ASSIGN
  Same as above but only asks for note and layer — skips vol/pan/pitch.
  Faster for simple assignments.

IMPORT SELECTED
  If you have audio items selected on the REAPER timeline, this menu lets
  you assign each one to RS5k. Each file gets its own note + layer dialog,
  then a preview. Only appears when items are selected.

LOAD KIT
  Loads a full drum kit in one shot — 15 preset kits to choose from.
  Each kit fills notes 21–108 with kicks, snares, hats, toms, perc, and more.
  Toms are pitched and panned across the stereo field automatically.
  Three empty "zones" at notes 88–108 (E5–C7) are left for you to fill with
  pitched samples via Add/assign.

TWEAK
  Lists all RS5k instances on the track. Pick one, then choose:
    - Swap sample      Replace with a different WAV
    - Edit volume/pan  Adjust gain (dB) and stereo position
    - Edit pitch       Shift pitch in semitones (-24 to +24)
    - Preview          Play the current sample
    - Dump RS5k params Show all internal parameter values (diagnostic)
    - Remove           Delete this RS5k instance

RANDOMIZE
  Four modes:
    1. Single voice    Pick one instance; randomizes its WAV (same drum type/tag)
    2. Entire kit      All instances get a new random WAV (same type/tag)
    3. Entire kit + tags  Each instance also gets a random tag (same drum type)
    4. Full random     Every instance gets a completely random type/tag/WAV
]]
    },
    {
      title = "TRIAZ RS5k Browser — Help (3/4): Kits and Zones",
      text = [[
THE 15 PRESET KITS
------------------
  01 Techno Dark        02 Techno Punchy      03 Techno 808
  04 House Classic      05 House Electronic   06 Lo-Fi Acoustic
  07 Lo-Fi Tape         08 Rap/Trap           09 Acoustic Studio
  10 Acoustic Room      11 Drum Machine       12 Electronica/IDM
  13 Organic/World      14 Heavy/Industrial   15 Pop/Disco

Each kit assigns voices to these GM notes:
  35/36 Kick (two timbres)   38/40 Snare (two timbres)   37 Rimshot (fixed)
  39 Clap   42/44 Hi-Hat Closed   46 Hi-Hat Open
  41/43/45/47/48/50 Toms (6 toms, pitched and panned L to R)
  49/57 Crash   51/59 Ride   54 Perc/Shaker

Fixed voices (same in all kits):
  52 Chinese cymbal   55 Splash   53 Ride bell   56 Cowbell
  60-64 Bongo/Conga/Tumba   65-66 Timbale
  75 Claves   76-77 Woodblock   82 Shaker   86-87 Surdo

Lower extras (notes 21-34): Perc Glitch, Layer, Noise, and Foley sounds.

UPPER PITCH ZONES (notes 88-108)
---------------------------------
Three empty RS5k slots are created at:
  Zone 1: E5-A#5  (notes 88-94)
  Zone 2: B5-F6   (notes 95-101)
  Zone 3: F#6-C7  (notes 102-108)

These are for pitched samples. Assign any TRIAZ WAV to one of these zones
via "Add / assign sample", then choose the zone number in the dialog.
The sample will pitch-shift automatically as you play different notes
within the zone.

NOISE SAMPLES AND LOOPING
--------------------------
The 10 Noise type WAVs have embedded loop points — they would play forever.
The script automatically disables looping for them in RS5k so they play
once and stop. Hi-Hat Open samples use a short note-off release (~50ms)
so they fade out cleanly when you release the key.
]]
    },
    {
      title = "TRIAZ RS5k Browser — Help (4/4): Tips and Troubleshooting",
      text = [[
TIPS FOR SCREEN READER USERS
-----------------------------
- All menus are native context menus. Navigate with arrow keys.
- All data entry uses standard REAPER input dialogs (Tab between fields).
- Preview dialogs are standard message boxes — press Enter or Space to close
  (this also stops playback).
- The "Dump RS5k params" option in Tweak shows all parameter values in a
  message box and also in the ReaScript console output window
  (open it via the Actions list — search "ReaScript console output").

TRACK SETUP
-----------
When the script starts, it asks which track to use:
  - Yes = use the currently selected track
  - No  = create a new track (you name it)
"Switch track" in the menu lets you move to a different track mid-session.

OVERWRITING A KIT
-----------------
When you Load kit and the track already has instances:
  - Yes     = remove all existing instances, load fresh kit
  - No      = add kit voices alongside existing ones (stacks on top)
  - Cancel  = abort, do nothing

COMMON ISSUES
-------------
"RS5k not found"
  ReaSamplOmatic5000 is built into REAPER. If it cannot be found, check that
  the plugin is not disabled in REAPER preferences.

"Cannot parse DrumType/Tag from path"
  The selected file is not inside the expected library structure. Navigate
  into X:\samplers\TRIAZ\Samples\TRIAZ - Factory Collection\ first.

"No WAVs found"
  The tag folder may be empty or the path does not exist. Try a different tag.
]]
    },
  }

  for _, page in ipairs(pages) do
    reaper.MB(page.text, page.title, 0)
  end
end

-- ── Main menu (structured with submenus) ─────────────────────────────────────

-- Builds menu string + parallel action list, shows it, runs chosen action.
-- Returns: continue (bool), track (possibly updated by Switch track).
local function show_main_menu(track)
  local instances  = scan_triaz_instances(track)
  local inst_count = #instances

  -- Collect selectable media items for import submenu
  local sel_paths = {}
  local sel_count = reaper.CountSelectedMediaItems(0)
  for i = 0, sel_count - 1 do
    local mi   = reaper.GetSelectedMediaItem(0, i)
    local take = mi and reaper.GetActiveTake(mi)
    if take and not reaper.TakeIsMIDI(take) then
      local src  = reaper.GetMediaItemTake_Source(take)
      local path = src and reaper.GetMediaSourceFileName(src, "")
      if path and path ~= "" then sel_paths[#sel_paths + 1] = path end
    end
  end

  local parts   = {}   -- all tokens in the menu string (including > and <)
  local actions = {}   -- indexed by gfx return value; > and < are NOT counted by gfx
  local gfx_idx = 0    -- tracks what gfx.showmenu will return for the next real item

  -- Real selectable item: increments gfx_idx, records action, returns gfx index.
  local function add(label, fn)
    parts[#parts + 1] = label
    gfx_idx = gfx_idx + 1
    actions[gfx_idx] = fn or false
    return gfx_idx
  end
  -- Submenu header/closer: structural only — gfx does NOT count these in return value.
  local function open_sub(label)
    parts[#parts + 1] = ">" .. label
  end
  local function close_sub()
    parts[#parts + 1] = "<"
  end

  add("Add / assign sample", function() add_assignment_flow(track) end)
  add("Quick assign",        function() quick_assign_flow(track) end)

  -- Import submenu
  if #sel_paths > 0 then
    open_sub(string.format("Import selected (%d)", #sel_paths))
    if #sel_paths > 1 then
      add("Import all (sequential)", function() import_selected_items_flow(track) end)
    end
    for _, path in ipairs(sel_paths) do
      local name = path:match("[^\\/]+$") or path
      local p    = path
      add(name, function() import_item_flow(track, p) end)
    end
    close_sub()
  else
    add("#Import selected (0)")
  end

  -- Load kit submenu
  open_sub("Load kit")
  for i, k in ipairs(KITS) do
    local idx = i
    add(k.name, function() load_kit_flow(track, idx) end)
  end
  close_sub()

  -- Tweak submenu: each instance expands to its 6 actions
  if inst_count > 0 then
    open_sub(string.format("Tweak (%d)", inst_count))
    for i, inst in ipairs(instances) do
      local info  = inst.info
      local idx   = i
      local label = string.format("L%d %s — %s/%s", info.layer, note_name(info.note), info.drum_type, info.tag)
      open_sub(label)
      add("Swap sample",          function() tweak_mode(track, idx, 1) end)
      add("Edit volume / pan",    function() tweak_mode(track, idx, 2) end)
      add("Edit pitch",           function() tweak_mode(track, idx, 3) end)
      add("Preview",              function() tweak_mode(track, idx, 4) end)
      add("Dump RS5k params",     function() tweak_mode(track, idx, 5) end)
      add("Remove",               function() tweak_mode(track, idx, 6) end)
      close_sub()
    end
    close_sub()
  else
    add("#Tweak (0 instances)")
  end

  add("Randomize", function() randomize_flow(track) end)
  add("Help",      function() show_help() end)
  local switch_pos = add("Switch track")
  local exit_pos   = add("Close menu")

  gfx.init("TRIAZ RS5k Browser", 0, 0, 0, 0, 0)
  gfx.x, gfx.y = 0, 0
  local choice = gfx.showmenu(table.concat(parts, "|"))
  gfx.quit()

  if choice == 0       then return true,  track end
  if choice == exit_pos   then return false, track end
  if choice == switch_pos then
    local new_track = select_track()
    return true, new_track or track
  end

  local fn = actions[choice]
  if fn then fn() end
  return true, track
end

-- ── Main ──────────────────────────────────────────────────────────────────────

local function main()
  reaper.Undo_BeginBlock()

  local track = select_track()
  if not track then
    reaper.Undo_EndBlock("TRIAZ Browser (cancelled)", -1)
    return
  end

  local keep_going = true
  while keep_going do
    keep_going, track = show_main_menu(track)
  end

  reaper.Undo_EndBlock("TRIAZ Browser", -1)
  stop_preview()
end

main()
