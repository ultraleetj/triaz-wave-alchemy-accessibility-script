-- TRIAZ RS5k Browser
-- Browse TRIAZ library, assign samples to RS5k instances on a track
-- Accessible via screen reader (native REAPER dialogs only)

local TRIAZ_BASE = "X:\\samplers\\TRIAZ\\Samples\\TRIAZ - Factory Collection\\"
local PITCH_ZONE_SEMITONES = 6  -- each pitch zone spans this many semitones

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
local function pick_kit_wav(drum_type, tag)
  local tag_path = TRIAZ_BASE .. drum_type .. "\\" .. tag
  local wavs = list_wavs(tag_path)
  if #wavs == 0 then return nil, nil end
  local idx = math.floor(#wavs / 2) + 1
  local wav = wavs[idx]
  return wav, tag_path .. "\\" .. wav
end

-- ── Kit definitions ──────────────────────────────────────────────────────────
-- voice fields: note, drum_type (exact folder), tag_hint (partial match OK)
-- rimshot (note 37) is fixed across all kits: Perc Acoustic / Rimshot

local KITS = {
  { name = "01 Techno Dark", voices = {
    {note=36, type="Kick Electronic",  tag="Deep"},
    {note=38, type="Snare Electronic", tag="Noise"},
    {note=39, type="Claps & Snaps",    tag="Noise"},
    {note=42, type="Hihat Closed",     tag="Metallic"},
    {note=46, type="HiHat Open",       tag="Metallic"},
    {note=45, type="Tom",              tag="Deep"},
    {note=49, type="Crash",            tag="Noise"},
    {note=51, type="Ride",             tag="Synthetic"},
    {note=54, type="Perc Electronic",  tag="Metallic"},
  }},
  { name = "02 Techno Punchy", voices = {
    {note=36, type="Kick Electronic",  tag="Punchy"},
    {note=38, type="Snare Electronic", tag="Tight"},
    {note=39, type="Claps & Snaps",    tag="Snap"},
    {note=42, type="Hihat Closed",     tag="Synthetic"},
    {note=46, type="HiHat Open",       tag="Synthetic"},
    {note=45, type="Tom",              tag="Punchy"},
    {note=49, type="Crash",            tag="Synthetic"},
    {note=51, type="Ride",             tag="Synthetic"},
    {note=54, type="Perc Electronic",  tag="Snap"},
  }},
  { name = "03 Techno 808", voices = {
    {note=36, type="Kick Electronic",  tag="808"},
    {note=38, type="Snare Electronic", tag="808"},
    {note=39, type="Claps & Snaps",    tag="808"},
    {note=42, type="Hihat Closed",     tag="808"},
    {note=46, type="HiHat Open",       tag="808"},
    {note=45, type="Tom",              tag="808"},
    {note=49, type="Crash",            tag="Synthetic"},
    {note=51, type="Ride",             tag="Synthetic"},
    {note=54, type="Perc Electronic",  tag="Snap"},
  }},
  { name = "04 House Classic", voices = {
    {note=36, type="Kick Electronic",  tag="Deep"},
    {note=38, type="Snare Electronic", tag="Room"},
    {note=39, type="Claps & Snaps",    tag="Room"},
    {note=42, type="Hihat Closed",     tag="Acoustic"},
    {note=46, type="HiHat Open",       tag="Acoustic"},
    {note=45, type="Tom",              tag="Room"},
    {note=49, type="Crash",            tag="Acoustic"},
    {note=51, type="Ride",             tag="Acoustic"},
    {note=54, type="Shakers",          tag="Acoustic"},
  }},
  { name = "05 House Electronic", voices = {
    {note=36, type="Kick Electronic",  tag="Organic"},
    {note=38, type="Snare Electronic", tag="Organic"},
    {note=39, type="Claps & Snaps",    tag="Layered"},
    {note=42, type="Hihat Closed",     tag="Synthetic"},
    {note=46, type="HiHat Open",       tag="Synthetic"},
    {note=45, type="Tom",              tag="Organic"},
    {note=49, type="Crash",            tag="Creative"},
    {note=51, type="Ride",             tag="Creative"},
    {note=54, type="Perc Electronic",  tag="Hand"},
  }},
  { name = "06 Lo-Fi Acoustic", voices = {
    {note=36, type="Kick Acoustic",    tag="Deep"},
    {note=38, type="Snare Acoustic",   tag="Room"},
    {note=39, type="Claps & Snaps",    tag="Acoustic"},
    {note=42, type="Hihat Closed",     tag="Lo-Fi"},
    {note=46, type="HiHat Open",       tag="Lo-Fi"},
    {note=45, type="Tom",              tag="Acoustic"},
    {note=49, type="Crash",            tag="Room"},
    {note=51, type="Ride",             tag="Room"},
    {note=54, type="Perc Acoustic",    tag="Small"},
  }},
  { name = "07 Lo-Fi Tape", voices = {
    {note=36, type="Kick Electronic",  tag="Tape"},
    {note=38, type="Snare Acoustic",   tag="Tape"},
    {note=39, type="Claps & Snaps",    tag="Tape"},
    {note=42, type="Hihat Closed",     tag="Tape"},
    {note=46, type="HiHat Open",       tag="Tape"},
    {note=45, type="Tom",              tag="Tape"},
    {note=49, type="Crash",            tag="Organic"},
    {note=51, type="Ride",             tag="Acoustic"},
    {note=54, type="Foley",            tag="Sticks"},
  }},
  { name = "08 Rap/Trap", voices = {
    {note=36, type="Kick Electronic",  tag="808"},
    {note=38, type="Snare Electronic", tag="Heavy"},
    {note=39, type="Claps & Snaps",    tag="Heavy"},
    {note=42, type="Hihat Closed",     tag="Noise"},
    {note=46, type="HiHat Open",       tag="Noise"},
    {note=45, type="Tom",              tag="Heavy"},
    {note=49, type="Crash",            tag="Synthetic"},
    {note=51, type="Ride",             tag="Synthetic"},
    {note=54, type="Perc Electronic",  tag="Snap"},
  }},
  { name = "09 Acoustic Studio", voices = {
    {note=36, type="Kick Acoustic",    tag="Punchy"},
    {note=38, type="Snare Acoustic",   tag="Bright"},
    {note=39, type="Claps & Snaps",    tag="Acoustic"},
    {note=42, type="Hihat Closed",     tag="Acoustic"},
    {note=46, type="HiHat Open",       tag="Acoustic"},
    {note=45, type="Tom",              tag="Acoustic"},
    {note=49, type="Crash",            tag="Acoustic"},
    {note=51, type="Ride",             tag="Acoustic"},
    {note=54, type="Perc Acoustic",    tag="Hand"},
  }},
  { name = "10 Acoustic Room", voices = {
    {note=36, type="Kick Acoustic",    tag="Room"},
    {note=38, type="Snare Acoustic",   tag="Room"},
    {note=39, type="Claps & Snaps",    tag="Room"},
    {note=42, type="Hihat Closed",     tag="Room"},
    {note=46, type="HiHat Open",       tag="Room"},
    {note=45, type="Tom",              tag="Room"},
    {note=49, type="Crash",            tag="Room"},
    {note=51, type="Ride",             tag="Room"},
    {note=54, type="Perc Acoustic",    tag="Room"},
  }},
  { name = "11 Drum Machine", voices = {
    {note=36, type="Kick Electronic",  tag="Drum Machine"},
    {note=38, type="Snare Electronic", tag="Drum Machine"},
    {note=39, type="Claps & Snaps",    tag="Drum Machine"},
    {note=42, type="Hihat Closed",     tag="Drum Machine"},
    {note=46, type="HiHat Open",       tag="Drum Machine"},
    {note=45, type="Tom",              tag="Drum Machine"},
    {note=49, type="Crash",            tag="Drum Machine"},
    {note=51, type="Ride",             tag="Drum Machine"},
    {note=54, type="Perc Electronic",  tag="Drum Machine"},
  }},
  { name = "12 Electronica/IDM", voices = {
    {note=36, type="Kick Electronic",  tag="Layered"},
    {note=38, type="Snare Electronic", tag="Layered"},
    {note=39, type="Claps & Snaps",    tag="Glitch"},
    {note=42, type="Hihat Closed",     tag="Noise"},
    {note=46, type="HiHat Open",       tag="Heavy"},
    {note=45, type="Tom",              tag="Creative"},
    {note=49, type="Crash",            tag="Creative"},
    {note=51, type="Ride",             tag="Creative"},
    {note=54, type="Perc Glitch",      tag=""},
  }},
  { name = "13 Organic/World", voices = {
    {note=36, type="Kick Acoustic",    tag="Heavy"},
    {note=38, type="Snare Acoustic",   tag="Organic"},
    {note=39, type="Claps & Snaps",    tag="Organic"},
    {note=42, type="Hihat Closed",     tag="Metallic"},
    {note=46, type="HiHat Open",       tag="Acoustic"},
    {note=45, type="Tom",              tag="Organic"},
    {note=49, type="Crash",            tag="Organic"},
    {note=51, type="Ride",             tag="Acoustic"},
    {note=54, type="Perc Acoustic",    tag="Bongo"},
  }},
  { name = "14 Heavy/Industrial", voices = {
    {note=36, type="Kick Electronic",  tag="Heavy"},
    {note=38, type="Snare Electronic", tag="Heavy"},
    {note=39, type="Claps & Snaps",    tag="Heavy"},
    {note=42, type="Hihat Closed",     tag="Metallic"},
    {note=46, type="HiHat Open",       tag="Heavy"},
    {note=45, type="Tom",              tag="Heavy"},
    {note=49, type="Crash",            tag="Noise"},
    {note=51, type="Ride",             tag="Bright"},
    {note=54, type="Perc Electronic",  tag="Metallic"},
  }},
  { name = "15 Pop/Disco", voices = {
    {note=36, type="Kick Electronic",  tag="Punchy"},
    {note=38, type="Snare Acoustic",   tag="Bright"},
    {note=39, type="Claps & Snaps",    tag="Bright"},
    {note=42, type="Hihat Closed",     tag="Bright"},
    {note=46, type="HiHat Open",       tag="Bright"},
    {note=45, type="Tom",              tag="Punchy"},
    {note=49, type="Crash",            tag="Bright"},
    {note=51, type="Ride",             tag="Bright"},
    {note=54, type="Shakers",          tag="Acoustic"},
  }},
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
-- Discovered from REAPER SDK / community docs
local RS5K_PARAM = {
  volume    = 0,   -- 0..1 (linear)
  pan       = 1,   -- 0..1 (0=L, 0.5=C, 1=R)
  note_lo   = 2,   -- 0..1 mapped from MIDI 0..127
  note_hi   = 3,
  pitch_st  = 4,   -- semitone offset, normalized: 0=center (-24..+24 range)
  loop      = 6,   -- 0=no loop, 1=loop
  note_mid  = 11,  -- "note for normal pitch" 0..1 mapped MIDI 0..127
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
  -- Debug: list what FX are available so user can report correct name
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
  -- params: {path, note_lo, note_hi, note_mid, pitch_st, volume, pan, fx_name, no_loop}

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
  if params.note_mid then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.note_mid,
      midi_to_param(params.note_mid))
  end
  if params.pitch_st then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_st,
      pitch_to_param(params.pitch_st))
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

local preview_source = nil

local function stop_preview()
  if not preview_source then return end
  if reaper.CF_Preview_Stop   then reaper.CF_Preview_Stop(preview_source)   end
  if reaper.CF_Preview_Destroy then reaper.CF_Preview_Destroy(preview_source) end
  preview_source = nil
end

local function preview_wav(path)
  if not reaper.CF_Preview_CreateFromFile then return end
  stop_preview()
  local src = reaper.CF_Preview_CreateFromFile(path)
  if not src then
    src = reaper.CF_Preview_CreateFromFile(path:gsub("\\", "/"))
  end
  if not src then return end
  if reaper.CF_Preview_SetValue then
    reaper.CF_Preview_SetValue(src, "D_VOLUME", 1.0)
    reaper.CF_Preview_SetValue(src, "B_LOOP",   0.0)
  end
  reaper.CF_Preview_Play(src)
  preview_source = src
end


-- ── Dialog helpers ───────────────────────────────────────────────────────────

-- Short lists (≤8): embed numbered items in the window title — screen readers
-- always announce the title, so one GetUserInputs dialog suffices.
-- Longer lists: MB to read list, then GetUserInputs for number.
local function pick_from_list(title, items)
  if #items == 0 then
    reaper.MB("No items found.", title, 0)
    return nil
  end

  local ok, result
  if #items <= 8 then
    -- Single dialog: title carries the list
    local parts = {}
    for i, v in ipairs(items) do parts[#parts + 1] = i .. "=" .. v end
    local compact = table.concat(parts, "  ")
    -- Window title = "TITLE — 1=Foo  2=Bar  ..."
    local dialog_title = title .. " — " .. compact
    ok, result = reaper.GetUserInputs(dialog_title, 1, "Number:", "")
  else
    -- Two dialogs: MB list then number input
    local lines = {}
    for i, v in ipairs(items) do lines[#lines + 1] = i .. ": " .. v end
    reaper.MB(table.concat(lines, "\n"), title, 0)
    ok, result = reaper.GetUserInputs(title, 1, "Number:", "")
  end

  if not ok or result == "" then return nil end
  local n = tonumber(result)
  if not n or n < 1 or n > #items then
    reaper.MB("Invalid number.", "Error", 0)
    return nil
  end
  return n
end

local function ask_yes_no(msg, title)
  return reaper.MB(msg, title or "TRIAZ Browser", 4) == 6
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
  if gm then suggestion = tostring(gm[1]) end

  local default = default_note and tostring(default_note) or suggestion
  local val = ask_string(
    "Target MIDI Note",
    string.format("MIDI note number (0-127) or name (e.g. C2) [%s suggested]", suggestion),
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

-- Available pitch zones outside GM range:
--   Lower: MIDI 21-34  (A0–A#1), 14 notes → 2 zones of 6 + leftover
--   Upper: MIDI 88-108 (E6–C8),  21 notes → 3 zones of 6 + leftover
local PITCH_ZONES = {}
do
  local half = math.floor(PITCH_ZONE_SEMITONES / 2)
  -- lower range
  local lo = 21
  while lo + PITCH_ZONE_SEMITONES - 1 <= 34 do
    local mid = lo + half
    PITCH_ZONES[#PITCH_ZONES + 1] = {lo=lo, hi=lo+PITCH_ZONE_SEMITONES-1, mid=mid}
    lo = lo + PITCH_ZONE_SEMITONES
  end
  -- upper range
  lo = 88
  while lo + PITCH_ZONE_SEMITONES - 1 <= 108 do
    local mid = lo + half
    PITCH_ZONES[#PITCH_ZONES + 1] = {lo=lo, hi=lo+PITCH_ZONE_SEMITONES-1, mid=mid}
    lo = lo + PITCH_ZONE_SEMITONES
  end
end

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

  local note_lo, note_hi, note_mid, pitch_st
  if zone then
    note_lo  = zone.lo
    note_hi  = zone.hi
    note_mid = zone.mid
    pitch_st = 0  -- user decides shift after; start centered
  else
    note_lo  = note
    note_hi  = note
    note_mid = note
    pitch_st = 0
  end

  configure_rs5k(track, fx_idx, {
    path     = full_path,
    note_lo  = note_lo,
    note_hi  = note_hi,
    note_mid = note_mid,
    pitch_st = pitch_st,
    volume   = 0.8,
    pan      = 0.5,
    no_loop  = is_noise,
    fx_name  = fx_name,
    meta     = {note=note, layer=layer, drum_type=drum_type, tag=tag},
  })

  return true, fx_idx
end

-- ── Tweak mode: edit existing instances ──────────────────────────────────────

local function tweak_mode(track)
  local instances = scan_triaz_instances(track)
  if #instances == 0 then
    reaper.MB("No TRIAZ RS5k instances found on this track.", "Tweak", 0)
    return
  end

  -- Build display list
  local labels = {}
  for _, inst in ipairs(instances) do
    local i = inst.info
    labels[#labels + 1] = string.format(
      "L%d note:%d (%s) — %s/%s",
      i.layer, i.note, note_name(i.note), i.drum_type, i.tag
    )
  end

  local n = pick_from_list("TRIAZ Instances", labels, "Select instance to edit")
  if not n then return end

  local inst = instances[n]
  local fx_idx = inst.fx_idx
  local info   = inst.info

  -- Get current sample
  local ok_f, cur_file = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "FILE0")
  local cur_wav = cur_file and cur_file:match("[^\\/]+$") or "?"

  local choices = {
    "Swap sample (re-browse)",
    "Edit volume / pan",
    "Edit pitch semitones",
    "Preview current sample",
    "Dump RS5k params (diagnostic)",
    "Remove this instance",
  }
  local action = pick_from_list(
    "Edit: " .. cur_wav,
    choices,
    "Action"
  )
  if not action then return end

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
    "MIDI note (0-127 or name; suggested=" .. gm_note .. ")",
    "Layer (1-3; 1=new slot)",
    "Pitch zone # (0=none; zones: " .. zone_hint .. ")",
    "Volume dB (0=unity)",
    "Pan % (-100=L  0=C  100=R)",
    "Pitch shift semitones (-24 to +24)",
  }, ",")
  local defaults = gm_note .. ",1,0,0,0,0"

  local ok, result = reaper.GetUserInputs(
    "Assign: " .. wav_name, 6, captions, defaults
  )
  if not ok then return end

  local parts = {}
  for p in result:gmatch("[^,]+") do parts[#parts + 1] = p:match("^%s*(.-)%s*$") end
  while #parts < 6 do parts[#parts + 1] = "0" end

  -- Parse note
  local target_note = tonumber(parts[1])
  if not target_note then target_note = note_from_name(parts[1]) end
  if not target_note or target_note < 0 or target_note > 127 then
    reaper.MB("Invalid note: " .. (parts[1] or ""), "Error", 0); return
  end

  -- Parse layer
  local layer = math.max(1, math.min(3, tonumber(parts[2]) or 1))

  -- Parse pitch zone
  local zone_n = tonumber(parts[3]) or 0
  local zone = (zone_n >= 1 and zone_n <= #PITCH_ZONES) and PITCH_ZONES[zone_n] or nil
  if zone then target_note = zone.mid end

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

local function load_kit_flow(track)
  local kit_names = {}
  for _, k in ipairs(KITS) do kit_names[#kit_names + 1] = k.name end
  local n = pick_from_list("Load Kit", kit_names)
  if not n then return end
  local kit = KITS[n]

  -- Check for existing instances
  local existing = scan_triaz_instances(track)
  if #existing > 0 then
    local choice = reaper.MB(
      #existing .. " existing instance(s) on this track.\n\nYes = overwrite matching notes\nNo = add alongside\nCancel = abort",
      "Kit Load", 3
    )
    if choice == 2 then return end  -- Cancel
    if choice == 6 then             -- Yes: remove existing
      for i = #existing, 1, -1 do
        remove_rs5k(track, existing[i].fx_idx)
      end
    end
    -- No: just add new alongside
  end

  -- Fixed rimshot for all kits
  local rimshot_tag = find_tag("Perc Acoustic", "Rimshot")
  if rimshot_tag then
    local wav, path = pick_kit_wav("Perc Acoustic", rimshot_tag)
    if wav then
      local fx_idx = add_rs5k(track)
      if fx_idx >= 0 then
        configure_rs5k(track, fx_idx, {
          path = path, note_lo = 37, note_hi = 37, note_mid = 37,
          pitch_st = 0, volume = 0.8, pan = 0.5,
          fx_name = make_fx_name(37, 1, "Perc Acoustic", rimshot_tag),
        })
      end
    end
  end

  local loaded, failed = 0, 0
  for _, v in ipairs(kit.voices) do
    local tag_hint = v.tag
    local tag
    if tag_hint ~= "" then tag = find_tag(v.type, tag_hint) end
    if not tag then tag = list_dirs(TRIAZ_BASE .. v.type)[1] end
    if not tag then failed = failed + 1; goto continue end

    local wav, path = pick_kit_wav(v.type, tag)
    if not wav then failed = failed + 1; goto continue end

    local fx_idx = add_rs5k(track)
    if fx_idx < 0 then failed = failed + 1; goto continue end

    local is_noise = (v.type == "Noise") and NOISE_LOOP_FILES[wav]
    configure_rs5k(track, fx_idx, {
      path = path, note_lo = v.note, note_hi = v.note, note_mid = v.note,
      pitch_st = 0, volume = 0.8, pan = 0.5, no_loop = is_noise,
      fx_name = make_fx_name(v.note, 1, v.type, tag),
    })
    loaded = loaded + 1
    ::continue::
  end

  reaper.MB(
    string.format("Kit: %s\nLoaded: %d voices%s\n\nTweak individual voices via option 2.",
      kit.name, loaded,
      failed > 0 and ("\nFailed: " .. failed .. " (tag not found)") or ""
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
  local ok, result = reaper.GetUserInputs(
    "Quick Assign: " .. wav_name, 2,
    "MIDI note (0-127 or name; suggested=" .. gm_note .. "),Layer (1-3)",
    gm_note .. ",1"
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
    local ok, result = reaper.GetUserInputs(
      string.format("Item %d/%d: %s", idx, #items, wav_name), 2,
      "MIDI note (0-127 or name; suggested=" .. gm_note .. "),Layer (1-3)",
      gm_note .. ",1"
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

-- ── Main ──────────────────────────────────────────────────────────────────────

local function main()
  reaper.Undo_BeginBlock()

  -- Track selection
  local track = select_track()
  if not track then
    reaper.Undo_EndBlock("TRIAZ Browser (cancelled)", -1)
    return
  end

  -- Main menu loop
  while true do
    local instances = scan_triaz_instances(track)
    local inst_count = #instances

    local sel_count = reaper.CountSelectedMediaItems(0)
    local menu_items = {
      "Add / assign sample (full params)",
      "Quick assign (browse + note only)",
      string.format("Import selected items (%d selected)", sel_count),
      "Load kit preset (15 kits)",
      string.format("Tweak existing (%d instance%s)", inst_count, inst_count == 1 and "" or "s"),
      "Switch track",
      "Exit",
    }

    local choice = pick_from_list("TRIAZ RS5k Browser", menu_items)
    if not choice or choice == 7 then break end

    if choice == 1 then
      add_assignment_flow(track)
    elseif choice == 2 then
      quick_assign_flow(track)
    elseif choice == 3 then
      import_selected_items_flow(track)
    elseif choice == 4 then
      load_kit_flow(track)
    elseif choice == 5 then
      tweak_mode(track)
    elseif choice == 6 then
      local new_track = select_track()
      if new_track then track = new_track end
    end
  end

  reaper.Undo_EndBlock("TRIAZ Browser", -1)
  stop_preview()
end

main()
