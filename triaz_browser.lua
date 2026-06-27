-- TRIAZ RS5k Browser
-- Browse TRIAZ library, assign samples to RS5k instances on a track
-- Accessible via screen reader (native REAPER dialogs only)

local _default_triaz_base = "X:\\samplers\\TRIAZ\\Samples\\TRIAZ - Factory Collection\\"
local _stored_path        = reaper.GetExtState("TRIAZ_BROWSER", "library_path")
local TRIAZ_BASE          = (_stored_path ~= "") and _stored_path or _default_triaz_base
local CACHE_PATH          = reaper.GetResourcePath() .. "\\Scripts\\triaz_browser_cache.lua"


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

local _cache_dirty = false
local _dir_cache   = {}

-- Load persistent cache from disk (survives REAPER restart)
local _cache_loaded = false
do
  local ok, cached = pcall(dofile, CACHE_PATH)
  if ok and type(cached) == "table" then
    if cached._no_library then
      _cache_loaded = true   -- user previously chose no-library mode
    else
      _dir_cache    = cached
      _cache_loaded = true
    end
  end
end

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
  _cache_dirty = true
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
  _cache_dirty = true
  return files
end

local function save_cache()
  if not _cache_dirty then return end
  local f = io.open(CACHE_PATH, "w")
  if not f then return end
  f:write("return {\n")
  for k, v in pairs(_dir_cache) do
    f:write(string.format("  [%q] = {", k))
    for i, s in ipairs(v) do
      if i > 1 then f:write(", ") end
      f:write(string.format("%q", s))
    end
    f:write("},\n")
  end
  f:write("}\n")
  f:close()
  _cache_dirty = false
end

-- Prompt user to select a folder path — browse (JS_ReaScriptAPI) or type manually.
-- Returns normalised path ending with \, or nil if cancelled.
local function pick_folder(caption, current)
  if reaper.JS_Dialog_BrowseForFolder then
    local res = reaper.MB(
      "Yes = browse for folder\nNo = type path manually",
      caption, 3)
    if res == 2 then return nil end  -- Cancel
    if res == 6 then
      local retval, folder = reaper.JS_Dialog_BrowseForFolder(caption, current or "")
      if retval ~= 1 or not folder or folder == "" then return nil end
      return folder:gsub("[\\/]+$", "") .. "\\"
    end
  end
  -- Type manually (fallback when JS_ReaScriptAPI unavailable, or user chose No)
  local ok, fields = reaper.GetUserInputs(caption, 1, "Samples folder,extrawidth=400", current or "")
  if not ok or fields == "" then return nil end
  return fields:gsub("[\\/]+$", "") .. "\\"
end

local function build_cache()
  -- Confirm or correct library path before scanning
  local new_path = pick_folder("TRIAZ Library Path", TRIAZ_BASE)
  if not new_path then
    reaper.MB("Cancelled — no cache built.", "TRIAZ Browser", 0)
    return false
  end
  if new_path ~= TRIAZ_BASE then
    TRIAZ_BASE = new_path
    reaper.SetExtState("TRIAZ_BROWSER", "library_path", TRIAZ_BASE, true)
    _dir_cache = {}
  end

  reaper.MB(
    "Scanning " .. #DRUM_TYPES .. " drum types across:\n" ..
    TRIAZ_BASE .. "\n\n" ..
    "This can take up to a minute. The window will appear frozen /\n" ..
    "unresponsive while it scans — this is expected. Wait for it to\n" ..
    "finish. Click OK to start.",
    "TRIAZ Browser — Building Cache", 0)

  local total_wavs, total_tags = 0, 0
  for _, drum_type in ipairs(DRUM_TYPES) do
    local tags = list_dirs(TRIAZ_BASE .. drum_type)
    if #tags == 0 then
      local wavs = list_wavs(TRIAZ_BASE .. drum_type)
      total_wavs = total_wavs + #wavs
    else
      total_tags = total_tags + #tags
      for _, tag in ipairs(tags) do
        local wavs = list_wavs(TRIAZ_BASE .. drum_type .. "\\" .. tag)
        total_wavs = total_wavs + #wavs
      end
    end
  end

  save_cache()
  reaper.MB(
    string.format("Done: %d tags, %d WAV files indexed.", total_tags, total_wavs),
    "TRIAZ Browser — Ready", 0)
  return true
end

local function clear_cache()
  _dir_cache   = {}
  _cache_dirty = false
  os.remove(CACHE_PATH)
  build_cache()
end

local function change_library_path()
  local new_path = pick_folder("TRIAZ Library Path", TRIAZ_BASE)
  if not new_path then return end
  if new_path == TRIAZ_BASE then return end
  TRIAZ_BASE = new_path
  reaper.SetExtState("TRIAZ_BROWSER", "library_path", TRIAZ_BASE, true)
  _dir_cache   = {}
  _cache_dirty = false
  os.remove(CACHE_PATH)
  build_cache()
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

-- ── Keyword-based WAV selection ──────────────────────────────────────────────

-- Score tag+wav against keyword list. Tag match = 2pts, filename match = 1pt.
local function score_wav_kw(tag, wav_name, kw)
  local score = 0
  local tl = tag:lower()
  local wl = wav_name:lower()
  for _, w in ipairs(kw) do
    if tl:find(w, 1, true) then score = score + 2 end
    if wl:find(w, 1, true) then score = score + 1 end
  end
  return score
end

-- Pick best WAV for drum_type by scoring all tags+wavs against kw list.
-- used_wavs (optional table path→true): skip already-chosen paths to avoid duplicates.
-- Falls back to best overall if every WAV is already used.
local function pick_by_keywords(drum_type, kw, used_wavs)
  local tags = list_dirs(TRIAZ_BASE .. drum_type)
  local best_score, best_wav, best_path = -1, nil, nil  -- best unused
  local any_score,  any_wav,  any_path  = -1, nil, nil  -- best overall (fallback)
  local function try_dir(tag, dir)
    local wavs = list_wavs(dir)
    for _, wav in ipairs(wavs) do
      local s    = score_wav_kw(tag, wav, kw)
      local path = dir .. "\\" .. wav
      if s > any_score then
        any_score, any_wav, any_path = s, wav, path
      end
      if not (used_wavs and used_wavs[path]) then
        if s > best_score then
          best_score, best_wav, best_path = s, wav, path
        end
      end
    end
  end
  if #tags == 0 then
    try_dir("", TRIAZ_BASE .. drum_type)
  else
    for _, tag in ipairs(tags) do
      try_dir(tag, TRIAZ_BASE .. drum_type .. "\\" .. tag)
    end
  end
  return best_wav or any_wav, best_path or any_path
end

-- ── Vibe Kit definitions ─────────────────────────────────────────────────────
-- VIBE_GENRES[i] = {name, variants={...}}
-- variant: {name, default_kw, voices={key={type,kw},...}}
--   voice keys: kick kick_alt snare snare_alt clap hh_c hh_pedal hh_o
--               crash ride perc tom
--   default_kw: used for rimshot, fixed voices, lower extras, upper zones

local VIBE_GENRES = {
  -- ── Techno ────────────────────────────────────────────────────────────────
  { name="Techno", variants={
    { name="Dark", default_kw={"dark","metal","hard","grit","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","dark","sub","metal","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","noise","dirty","grit"}},
        snare    ={type="Snare Electronic", kw={"dark","noise","metal","hard","grit"}},
        snare_alt={type="Snare Electronic", kw={"noise","dirty","heavy","industrial"}},
        clap     ={type="Claps & Snaps",    kw={"noise","heavy","dark","hard"}},
        hh_c     ={type="Hihat Closed",     kw={"metal","tight","dark","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"metal","noise","tight"}},
        hh_o     ={type="HiHat Open",       kw={"metal","heavy","dark","noise"}},
        crash    ={type="Crash",            kw={"noise","dark","metal","trash"}},
        ride     ={type="Ride",             kw={"metal","dark","noise"}},
        perc     ={type="Perc Electronic",  kw={"metal","dark","noise","industrial"}},
        tom      ={type="Tom",              kw={"deep","dark","heavy","hard"}},
      },
    },
    { name="Punchy", default_kw={"punch","snap","tight","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","snap","tight","knock","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","sub","punch","snap"}},
        snare    ={type="Snare Electronic", kw={"punch","snap","tight","smack","hard"}},
        snare_alt={type="Snare Electronic", kw={"tight","crack","bright","snap"}},
        clap     ={type="Claps & Snaps",    kw={"snap","punch","tight","hard"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","snap","synth","metal"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","snap","metal"}},
        hh_o     ={type="HiHat Open",       kw={"synth","bright","tight","snap"}},
        crash    ={type="Crash",            kw={"synth","bright","snap","punch"}},
        ride     ={type="Ride",             kw={"synth","bright","tight"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","punch","tight"}},
        tom      ={type="Tom",              kw={"punch","tight","snap","hard"}},
      },
    },
    { name="Classic 909", default_kw={"909","classic","drum","machine"},
      voices={
        kick     ={type="Kick Electronic",  kw={"909","drum","classic","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"909","sub","deep","drum"}},
        snare    ={type="Snare Electronic", kw={"909","drum","classic","machine"}},
        snare_alt={type="Snare Electronic", kw={"909","bright","snap","drum"}},
        clap     ={type="Claps & Snaps",    kw={"909","drum","classic","machine"}},
        hh_c     ={type="Hihat Closed",     kw={"909","drum","classic","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"909","drum","machine"}},
        hh_o     ={type="HiHat Open",       kw={"909","drum","classic","machine"}},
        crash    ={type="Crash",            kw={"909","drum","machine","synth"}},
        ride     ={type="Ride",             kw={"909","drum","machine"}},
        perc     ={type="Perc Electronic",  kw={"drum","machine","classic","909"}},
        tom      ={type="Tom",              kw={"909","drum","classic","machine"}},
      },
    },
    { name="808 Sub", default_kw={"808","sub","bass","deep"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","sub","bass","deep","boom"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","bass"}},
        snare    ={type="Snare Electronic", kw={"808","drum","machine","heavy"}},
        snare_alt={type="Snare Electronic", kw={"808","snap","heavy","drum"}},
        clap     ={type="Claps & Snaps",    kw={"808","snap","synth","drum"}},
        hh_c     ={type="Hihat Closed",     kw={"808","drum","synth","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"808","synth","drum"}},
        hh_o     ={type="HiHat Open",       kw={"808","synth","drum"}},
        crash    ={type="Crash",            kw={"synth","808","drum","machine"}},
        ride     ={type="Ride",             kw={"synth","808","drum"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","blip","drum"}},
        tom      ={type="Tom",              kw={"808","deep","sub","heavy"}},
      },
    },
    { name="Industrial", default_kw={"crunch","crush","stomp","noise","hard","metal"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","stomp","crunch","heavy","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","crush","dirty","grit"}},
        snare    ={type="Snare Electronic", kw={"metal","hard","crunch","noise","grit"}},
        snare_alt={type="Snare Electronic", kw={"crush","noise","industrial","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"noise","heavy","hard","crush"}},
        hh_c     ={type="Hihat Closed",     kw={"metal","noise","hard","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"metal","noise","hard"}},
        hh_o     ={type="HiHat Open",       kw={"metal","noise","heavy","hard"}},
        crash    ={type="Crash",            kw={"noise","metal","trash","crush","dark"}},
        ride     ={type="Ride",             kw={"metal","noise","dark"}},
        perc     ={type="Perc Electronic",  kw={"metal","noise","industrial","hard"}},
        tom      ={type="Tom",              kw={"heavy","hard","stomp","deep"}},
      },
    },
    { name="Detroit", default_kw={"808","deep","sub","machine","organic","dark"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","deep","sub","punch","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","deep","808","heavy"}},
        snare    ={type="Snare Electronic", kw={"organic","layered","dark","808","machine"}},
        snare_alt={type="Snare Electronic", kw={"machine","dark","organic","layered"}},
        clap     ={type="Claps & Snaps",    kw={"organic","layered","808","machine","dark"}},
        hh_c     ={type="Hihat Closed",     kw={"808","machine","metallic","dark","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"808","machine","metallic","dark"}},
        hh_o     ={type="HiHat Open",       kw={"808","machine","metallic","heavy","dark"}},
        crash    ={type="Crash",            kw={"organic","dark","machine","noise"}},
        ride     ={type="Ride",             kw={"metallic","dark","machine","808"}},
        perc     ={type="Perc Electronic",  kw={"808","machine","organic","dark"}},
        tom      ={type="Tom",              kw={"deep","808","sub","organic","heavy"}},
      },
    },
    { name="Minimal", default_kw={"tight","synthetic","acoustic","bright","click","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tight","punch","sub","bright","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","synthetic","bright","machine"}},
        snare    ={type="Snare Electronic", kw={"tight","bright","snap","synthetic","organic"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","tight","organic"}},
        clap     ={type="Claps & Snaps",    kw={"tight","bright","snap","organic","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","acoustic","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","tight","synthetic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","synthetic","organic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","synthetic","tight"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","bright","tight"}},
        tom      ={type="Tom",              kw={"tight","punch","bright","organic"}},
      },
    },
    { name="Hypnotic", default_kw={"dark","deep","layered","organic","sub","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","dark","sub","layered","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","dark","organic","layered"}},
        snare    ={type="Snare Electronic", kw={"dark","layered","organic","synthetic","noise"}},
        snare_alt={type="Snare Electronic", kw={"layered","dark","synthetic","noise"}},
        clap     ={type="Claps & Snaps",    kw={"dark","layered","organic","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","dark","synthetic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","dark","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","dark","heavy","synthetic"}},
        crash    ={type="Crash",            kw={"dark","noise","metallic","organic"}},
        ride     ={type="Ride",             kw={"metallic","dark","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"dark","blip","synthetic","metallic"}},
        tom      ={type="Tom",              kw={"deep","dark","layered","organic","sub"}},
      },
    },
    { name="Acid", default_kw={"tight","synthetic","noise","hard","snap","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","punch","tight","sub","noise"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","synthetic","hard","heavy"}},
        snare    ={type="Snare Electronic", kw={"noise","hard","tight","synthetic","snap"}},
        snare_alt={type="Snare Electronic", kw={"tight","noise","synthetic","hard"}},
        clap     ={type="Claps & Snaps",    kw={"noise","hard","tight","synthetic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","noise","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","noise"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","noise","heavy","metallic"}},
        crash    ={type="Crash",            kw={"noise","synthetic","hard","metallic"}},
        ride     ={type="Ride",             kw={"synthetic","noise","metallic"}},
        perc     ={type="Perc Electronic",  kw={"noise","synthetic","blip","hard"}},
        tom      ={type="Tom",              kw={"hard","noise","deep","synthetic"}},
      },
    },
    { name="Hard", default_kw={"hard","stomp","heavy","crunch","punch","metal"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","stomp","heavy","punch","crunch"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","crunch","hard","noise"}},
        snare    ={type="Snare Electronic", kw={"hard","heavy","crunch","metal","punch"}},
        snare_alt={type="Snare Electronic", kw={"heavy","metal","hard","noise"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","hard","noise","crunch","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"metal","hard","noise","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"metal","hard","noise"}},
        hh_o     ={type="HiHat Open",       kw={"metal","heavy","hard","noise"}},
        crash    ={type="Crash",            kw={"noise","metal","hard","heavy"}},
        ride     ={type="Ride",             kw={"metal","hard","noise"}},
        perc     ={type="Perc Electronic",  kw={"metal","hard","noise","industrial"}},
        tom      ={type="Tom",              kw={"heavy","hard","stomp","deep"}},
      },
    },
    { name="Ambient Techno", default_kw={"soft","deep","organic","sub","room","lush"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","deep","sub","organic","room"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","organic","sub","layered"}},
        snare    ={type="Snare Electronic", kw={"soft","organic","layered","room","lush"}},
        snare_alt={type="Snare Electronic", kw={"organic","soft","room","layered"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","room","acoustic","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","acoustic","organic","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"soft","organic","room","mallet"}},
        ride     ={type="Ride",             kw={"soft","acoustic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","soft","acoustic","lush"}},
        tom      ={type="Tom",              kw={"deep","soft","organic","sub","room"}},
      },
    },
    { name="EBM", default_kw={"synthetic","industrial","machine","hard","dark","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"synthetic","industrial","hard","heavy","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"machine","heavy","hard","dark"}},
        snare    ={type="Snare Electronic", kw={"synthetic","machine","hard","industrial","heavy"}},
        snare_alt={type="Snare Electronic", kw={"industrial","hard","machine","dark"}},
        clap     ={type="Claps & Snaps",    kw={"synthetic","machine","hard","industrial","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"synthetic","machine","tight","industrial","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"synthetic","machine","tight","industrial"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","machine","heavy","industrial"}},
        crash    ={type="Crash",            kw={"metallic","industrial","hard","noise"}},
        ride     ={type="Ride",             kw={"metallic","machine","synthetic","dark"}},
        perc     ={type="Perc Electronic",  kw={"machine","industrial","synthetic","snap"}},
        tom      ={type="Tom",              kw={"heavy","machine","industrial","dark","deep"}},
      },
    },
    { name="Gabber", default_kw={"hard","heavy","crunch","stomp","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","stomp","heavy","crunch","noise"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","crunch","heavy","stomp"}},
        snare    ={type="Snare Electronic", kw={"hard","noise","heavy","crunch"}},
        snare_alt={type="Snare Electronic", kw={"noise","hard","crunch","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"hard","noise","heavy","crunch"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","metallic","hard","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","metallic","hard"}},
        hh_o     ={type="HiHat Open",       kw={"noise","metallic","heavy","hard"}},
        crash    ={type="Crash",            kw={"noise","metallic","hard","heavy"}},
        ride     ={type="Ride",             kw={"noise","metallic","hard"}},
        perc     ={type="Perc Electronic",  kw={"noise","hard","snap","metal"}},
        tom      ={type="Tom",              kw={"hard","heavy","noise","stomp"}},
      },
    },
    { name="Doomcore", default_kw={"deep","heavy","dark","sub","crushing"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","heavy","sub","dark","crunch"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","sub","heavy","dark"}},
        snare    ={type="Snare Electronic", kw={"heavy","dark","noise","deep","layered"}},
        snare_alt={type="Snare Electronic", kw={"dark","heavy","noise","deep"}},
        clap     ={type="Claps & Snaps",    kw={"dark","heavy","noise","organic","deep"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","metallic","heavy","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","metallic","heavy"}},
        hh_o     ={type="HiHat Open",       kw={"dark","heavy","metallic","noise"}},
        crash    ={type="Crash",            kw={"dark","noise","heavy","metallic"}},
        ride     ={type="Ride",             kw={"dark","metallic","heavy","noise"}},
        perc     ={type="Perc Electronic",  kw={"dark","noise","metal","heavy"}},
        tom      ={type="Tom",              kw={"deep","dark","heavy","sub","crushing"}},
      },
    },
    { name="Schranz", default_kw={"hard","industrial","noise","tight","punch","crunch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","industrial","punch","tight","noise"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","tight","noise","punch"}},
        snare    ={type="Snare Electronic", kw={"hard","industrial","noise","tight","punch"}},
        snare_alt={type="Snare Electronic", kw={"noise","hard","tight","industrial"}},
        clap     ={type="Claps & Snaps",    kw={"hard","noise","tight","industrial","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","noise","metallic","hard","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","noise","metallic","hard"}},
        hh_o     ={type="HiHat Open",       kw={"noise","metallic","heavy","hard"}},
        crash    ={type="Crash",            kw={"noise","metallic","hard","industrial"}},
        ride     ={type="Ride",             kw={"noise","metallic","hard","industrial"}},
        perc     ={type="Perc Electronic",  kw={"noise","snap","hard","industrial"}},
        tom      ={type="Tom",              kw={"hard","noise","industrial","deep","punch"}},
      },
    },
    { name="Bleep / UK Rave", default_kw={"blip","bright","synthetic","808","machine","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","sub","punch","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","machine","bright"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","machine","synthetic","808"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","machine","808"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","machine","808","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","machine","tight","synthetic","808"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","machine","tight","808"}},
        hh_o     ={type="HiHat Open",       kw={"bright","machine","synthetic","808"}},
        crash    ={type="Crash",            kw={"bright","synthetic","808","machine"}},
        ride     ={type="Ride",             kw={"bright","machine","808","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"blip","bright","808","snap","machine"}},
        tom      ={type="Tom",              kw={"808","machine","bright","deep","synthetic"}},
      },
    },
    { name="Drone", default_kw={"dark","sub","deep","layered","heavy","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","sub","heavy","dark","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","organic","dark","layered","deep"}},
        snare    ={type="Snare Electronic", kw={"dark","layered","organic","heavy","noise"}},
        snare_alt={type="Snare Electronic", kw={"layered","dark","heavy","noise"}},
        clap     ={type="Claps & Snaps",    kw={"dark","heavy","organic","layered","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","metallic","soft","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","metallic","soft"}},
        hh_o     ={type="HiHat Open",       kw={"dark","metallic","heavy","organic"}},
        crash    ={type="Crash",            kw={"dark","organic","mallet","heavy","noise"}},
        ride     ={type="Ride",             kw={"dark","metallic","organic","soft"}},
        perc     ={type="Perc Electronic",  kw={"dark","noise","metallic","synthetic"}},
        tom      ={type="Tom",              kw={"deep","sub","dark","heavy","layered"}},
      },
    },
    { name="Berlin School", default_kw={"dark","tight","synthetic","metallic","machine","precise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tight","dark","sub","machine","synthetic"}},
        kick_alt ={type="Kick Electronic",  kw={"dark","sub","tight","heavy"}},
        snare    ={type="Snare Electronic", kw={"tight","dark","metallic","machine","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"dark","tight","metallic","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"dark","tight","synthetic","machine","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","metallic","synthetic","dark","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","metallic","machine","dark"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","synthetic","dark","heavy"}},
        crash    ={type="Crash",            kw={"metallic","dark","synthetic","noise"}},
        ride     ={type="Ride",             kw={"metallic","dark","machine","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"metallic","synthetic","dark","tight","machine"}},
        tom      ={type="Tom",              kw={"dark","tight","synthetic","heavy","machine"}},
      },
    },
    { name="Modular", default_kw={"noise","creative","synthetic","dark","metallic","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"synthetic","noise","deep","creative","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","creative","synthetic","dark"}},
        snare    ={type="Snare Electronic", kw={"noise","creative","synthetic","metallic","dark"}},
        snare_alt={type="Snare Electronic", kw={"creative","noise","metallic","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"noise","creative","synthetic","dark","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","synthetic","metallic","creative"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","synthetic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"noise","synthetic","heavy","metallic"}},
        crash    ={type="Crash",            kw={"noise","creative","metallic","synthetic","dark"}},
        ride     ={type="Ride",             kw={"noise","metallic","synthetic","creative"}},
        perc     ={type="Perc Glitch",      kw={"noise","creative","synthetic","metallic"}},
        tom      ={type="Tom",              kw={"synthetic","noise","creative","deep","dark"}},
      },
    },
    { name="Oldskool Rave", default_kw={"punch","bright","hard","synthetic","wide","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","hard","wide","bright","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","heavy","punch","sub"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","hard","snap","wide"}},
        snare_alt={type="Snare Electronic", kw={"hard","bright","snap","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"bright","hard","punch","snap","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","hard","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","hard"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","hard","heavy"}},
        crash    ={type="Crash",            kw={"bright","hard","synthetic","wide","heavy"}},
        ride     ={type="Ride",             kw={"bright","synthetic","hard","metallic"}},
        perc     ={type="Perc Electronic",  kw={"bright","snap","hard","synthetic","wide"}},
        tom      ={type="Tom",              kw={"heavy","punch","hard","bright","wide"}},
      },
    },
  }},
  -- ── House ─────────────────────────────────────────────────────────────────
  { name="House", variants={
    { name="Classic", default_kw={"room","live","acoustic","bright","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","room","organic","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"room","organic","layered"}},
        snare    ={type="Snare Electronic", kw={"room","organic","bright","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","snap","organic"}},
        clap     ={type="Claps & Snaps",    kw={"room","acoustic","bright","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","room","bright","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","room","bright"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","room","bright","organic"}},
        crash    ={type="Crash",            kw={"acoustic","room","bright","organic"}},
        ride     ={type="Ride",             kw={"acoustic","room","bright"}},
        perc     ={type="Shakers",          kw={"acoustic","organic","room"}},
        tom      ={type="Tom",              kw={"room","organic","acoustic","punch"}},
      },
    },
    { name="Electronic", default_kw={"synth","organic","layered","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"organic","layered","punch","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"organic","synthetic","layered"}},
        snare    ={type="Snare Electronic", kw={"organic","layered","bright","room"}},
        snare_alt={type="Snare Electronic", kw={"organic","bright","snap","layered"}},
        clap     ={type="Claps & Snaps",    kw={"layered","bright","organic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"synth","bright","organic","layered"}},
        hh_pedal ={type="Hihat Closed",     kw={"synth","bright","organic"}},
        hh_o     ={type="HiHat Open",       kw={"synth","bright","organic","layered"}},
        crash    ={type="Crash",            kw={"creative","bright","synth","organic"}},
        ride     ={type="Ride",             kw={"creative","synth","bright"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","organic","bright"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","layered"}},
      },
    },
    { name="Deep", default_kw={"lush","deep","soft","warm","room"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","sub","soft","lush","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","organic","room","layered"}},
        snare    ={type="Snare Electronic", kw={"room","soft","lush","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"room","soft","organic","bright"}},
        clap     ={type="Claps & Snaps",    kw={"soft","room","lush","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","soft","room","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","soft","lush","room"}},
        crash    ={type="Crash",            kw={"soft","room","lush","organic"}},
        ride     ={type="Ride",             kw={"acoustic","room","soft","bright"}},
        perc     ={type="Shakers",          kw={"organic","soft","acoustic","lush"}},
        tom      ={type="Tom",              kw={"deep","soft","room","organic"}},
      },
    },
    { name="Disco", default_kw={"disco","gold","bright","lush","pop"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","disco","bright","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"bright","punch","room","pop"}},
        snare    ={type="Snare Acoustic",   kw={"bright","pop","disco","room"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","disco"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","gold","disco"}},
        crash    ={type="Crash",            kw={"bright","acoustic","gold","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","gold","disco"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","bright","lush"}},
        tom      ={type="Tom",              kw={"bright","punch","disco","room"}},
      },
    },
    { name="Afro", default_kw={"djembe","organic","bright","acoustic","room","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","organic","deep","bright","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","punch","flam"}},
        snare_alt={type="Snare Electronic", kw={"organic","bright","punch","layered","room"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","balafon"}},
        tom      ={type="Tom",              kw={"organic","punch","room","bright","deep"}},
      },
    },
    { name="Chicago", default_kw={"punch","organic","room","bright","deep","layered"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","punch","sub","organic","room"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","organic","room","layered"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","room","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","snap","organic"}},
        clap     ={type="Claps & Snaps",    kw={"organic","room","bright","layered","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","room","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","bright","room"}},
        tom      ={type="Tom",              kw={"organic","room","punch","deep"}},
      },
    },
    { name="Micro", default_kw={"tight","acoustic","bright","organic","synthetic","click"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tight","punch","organic","bright","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","synthetic","organic","bright"}},
        snare    ={type="Snare Electronic", kw={"tight","bright","organic","synthetic","snap"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","tight","organic"}},
        clap     ={type="Claps & Snaps",    kw={"tight","bright","organic","acoustic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","acoustic","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","tight","organic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","soft"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","tight"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","bright","tight"}},
        tom      ={type="Tom",              kw={"tight","organic","bright","room"}},
      },
    },
    { name="Tech House", default_kw={"tight","punch","organic","synthetic","room","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","tight","sub","organic","room"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","synthetic","punch","deep"}},
        snare    ={type="Snare Electronic", kw={"tight","punch","organic","room","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","snap","organic"}},
        clap     ={type="Claps & Snaps",    kw={"tight","punch","organic","snap","room"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","organic","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","bright","tight","organic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","organic","room"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","organic","tight"}},
        tom      ={type="Tom",              kw={"tight","punch","organic","room","sub"}},
      },
    },
    { name="Progressive", default_kw={"wide","bright","layered","organic","room","lush"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","organic","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"wide","layered","organic","bright"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","layered","organic","room"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","organic","layered","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","wide"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"bright","wide","punch","organic","room"}},
      },
    },
    { name="Soulful", default_kw={"warm","lush","organic","room","vintage","soft"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","organic","room","lush","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","deep","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"room","organic","bright","lush","soft"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","warm","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","room","bright","lush","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","room","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","gold","room"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","organic","room","gold"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","soft"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"organic","room","bright","lush","deep"}},
      },
    },
    { name="Jackin", default_kw={"punch","snap","tight","organic","room","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","tight","sub","bright","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","tight","sub"}},
        snare    ={type="Snare Electronic", kw={"snap","punch","bright","tight","organic"}},
        snare_alt={type="Snare Acoustic",   kw={"snap","bright","punch","room"}},
        clap     ={type="Claps & Snaps",    kw={"snap","punch","bright","tight","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","acoustic","snap","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","tight","snap"}},
        crash    ={type="Crash",            kw={"bright","acoustic","snap","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","snap","tight"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","snap"}},
        tom      ={type="Tom",              kw={"punch","bright","tight","organic"}},
      },
    },
    { name="Jersey Club", default_kw={"tight","punch","bright","snap","synthetic","machine"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","tight","sub","bright","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","tight","sub","machine"}},
        snare    ={type="Snare Electronic", kw={"snap","tight","bright","punch","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","tight","punch"}},
        clap     ={type="Claps & Snaps",    kw={"snap","tight","bright","punch","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","snap","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","synthetic","snap"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","tight","snap"}},
        crash    ={type="Crash",            kw={"bright","synthetic","machine","snap"}},
        ride     ={type="Ride",             kw={"bright","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","bright","tight"}},
        tom      ={type="Tom",              kw={"tight","punch","bright","synthetic"}},
      },
    },
    { name="Ambient House", default_kw={"soft","lush","wide","organic","room","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","organic","sub","lush","room"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","room","organic","deep"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","wide"}},
        snare_alt={type="Snare Electronic", kw={"soft","organic","lush","layered"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","room","bright","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","wide","room"}},
        crash    ={type="Crash",            kw={"soft","wide","mallet","organic","room"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","acoustic","wide"}},
        tom      ={type="Tom",              kw={"soft","organic","wide","room","lush"}},
      },
    },
    { name="Funky House", default_kw={"bright","organic","snap","punch","lush","funk"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","organic","lush","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","bright","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","organic","room","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"snap","bright","room","organic","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","room","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","gold"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","lush"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","snap"}},
        tom      ={type="Tom",              kw={"organic","bright","room","punch","lush"}},
      },
    },
    { name="UK Garage", default_kw={"tight","sub","punch","bright","synthetic","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","tight","sub","bright","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","sub","punch","synthetic"}},
        snare    ={type="Snare Electronic", kw={"snap","tight","bright","synthetic","punch"}},
        snare_alt={type="Snare Electronic", kw={"tight","snap","bright","punch","organic"}},
        clap     ={type="Claps & Snaps",    kw={"snap","tight","bright","organic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","tight","organic"}},
        crash    ={type="Crash",            kw={"bright","synthetic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","synthetic","tight"}},
        tom      ={type="Tom",              kw={"tight","sub","bright","punch","organic"}},
      },
    },
    { name="Future House", default_kw={"wide","bright","synthetic","snap","layered","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","wide","bright","sub","synthetic"}},
        kick_alt ={type="Kick Electronic",  kw={"wide","bright","sub","layered"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","snap","synthetic","layered"}},
        snare_alt={type="Snare Electronic", kw={"wide","bright","snap","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","snap","synthetic","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","heavy"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","layered"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","bright","wide","synthetic"}},
        tom      ={type="Tom",              kw={"bright","wide","punch","synthetic","sub"}},
      },
    },
    { name="Acid House", default_kw={"synthetic","tight","noise","bright","machine","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","punch","organic","bright","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","punch","sub","organic"}},
        snare    ={type="Snare Electronic", kw={"bright","synthetic","noise","tight","snap"}},
        snare_alt={type="Snare Electronic", kw={"tight","bright","noise","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","noise","snap","synthetic","tight"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","bright","machine","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","bright","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","noise","tight"}},
        crash    ={type="Crash",            kw={"bright","synthetic","noise","organic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","machine","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","noise","synthetic","bright","machine"}},
        tom      ={type="Tom",              kw={"organic","bright","punch","noise","deep"}},
      },
    },
    { name="Piano House", default_kw={"bright","lush","warm","organic","layered","room"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","deep","bright","organic","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","lush","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","warm","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","lush","room","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","gold"}},
        crash    ={type="Crash",            kw={"bright","room","organic","lush","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush","warm"}},
        tom      ={type="Tom",              kw={"organic","bright","room","lush","deep"}},
      },
    },
    { name="Balearic", default_kw={"wide","soft","organic","lush","bright","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","deep","wide"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","organic","sub","deep","lush"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","soft","room","organic","lush"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","bright","wide","room"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","wide","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","wide","room"}},
        crash    ={type="Crash",            kw={"soft","wide","organic","room","bright"}},
        ride     ={type="Ride",             kw={"bright","soft","acoustic","organic","wide"}},
        perc     ={type="Shakers",          kw={"organic","soft","acoustic","wide","lush"}},
        tom      ={type="Tom",              kw={"soft","organic","wide","room","deep"}},
      },
    },
    { name="Warehouse", default_kw={"heavy","dark","room","organic","deep","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","heavy","dark","sub","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","dark","sub","organic","room"}},
        snare    ={type="Snare Electronic", kw={"dark","heavy","room","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"dark","room","heavy","organic"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","dark","organic","room","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","metallic","tight","machine","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","metallic","tight","machine"}},
        hh_o     ={type="HiHat Open",       kw={"dark","metallic","heavy","noise"}},
        crash    ={type="Crash",            kw={"dark","noise","organic","room","heavy"}},
        ride     ={type="Ride",             kw={"dark","metallic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","dark","room","heavy"}},
        tom      ={type="Tom",              kw={"heavy","dark","deep","room","organic"}},
      },
    },
  }},
  -- ── Drum & Bass ───────────────────────────────────────────────────────────
  { name="Drum & Bass", variants={
    { name="Dark", default_kw={"hard","dark","metal","grit","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","dark","punch","sub","tight"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","deep","hard","heavy"}},
        snare    ={type="Snare Electronic", kw={"hard","punch","snap","tight","metal"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","hard","tight"}},
        clap     ={type="Claps & Snaps",    kw={"snap","hard","punch","tight"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","metal","noise","hard"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","metal","hard"}},
        hh_o     ={type="HiHat Open",       kw={"metal","heavy","noise","hard"}},
        crash    ={type="Crash",            kw={"noise","metal","dark","trash"}},
        ride     ={type="Ride",             kw={"metal","dark","noise"}},
        perc     ={type="Perc Electronic",  kw={"metal","snap","punch","hard"}},
        tom      ={type="Tom",              kw={"hard","deep","punch","heavy"}},
      },
    },
    { name="Liquid", default_kw={"bright","room","organic","soft","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","organic","tight"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","bright","punch","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","snap","organic"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","organic","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","acoustic","snap","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","room","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","room","organic"}},
        crash    ={type="Crash",            kw={"bright","room","organic","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"bright","punch","room","organic"}},
      },
    },
    { name="Jungle", default_kw={"noise","heavy","punch","snap","metallic","tight"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","sub","punch","deep","noise"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","punch","room","organic"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","noise","punch","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"snap","punch","noise","heavy","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","tight","noise","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","tight","noise"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","heavy","noise","bright"}},
        crash    ={type="Crash",            kw={"noise","metallic","bright","heavy"}},
        ride     ={type="Ride",             kw={"metallic","noise","bright"}},
        perc     ={type="Perc Electronic",  kw={"snap","noise","punch","metal"}},
        tom      ={type="Tom",              kw={"heavy","punch","deep","noise"}},
      },
    },
    { name="Roller", default_kw={"punch","bright","sub","deep","organic","room"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","sub","deep","bright","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","deep","punch","organic"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","room","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","snap","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","punch","organic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","tight","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic"}},
        tom      ={type="Tom",              kw={"punch","bright","deep","organic"}},
      },
    },
    { name="Neurofunk", default_kw={"noise","heavy","creative","layered","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","sub","deep","noise","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","layered","noise","creative"}},
        snare    ={type="Snare Electronic", kw={"heavy","noise","creative","layered","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"noise","creative","heavy","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"noise","heavy","creative","synthetic","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","synthetic","tight","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","synthetic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"noise","heavy","synthetic","metallic"}},
        crash    ={type="Crash",            kw={"noise","creative","heavy","synthetic"}},
        ride     ={type="Ride",             kw={"noise","synthetic","creative"}},
        perc     ={type="Perc Glitch",      kw={"blip","creative","noise"}},
        tom      ={type="Tom",              kw={"heavy","noise","deep","creative"}},
      },
    },
    { name="Jump Up", default_kw={"punch","heavy","bright","sub","snap","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","sub","deep","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","punch","sub","bright"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","snap","heavy","hard"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","snap","punch","room"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","punch","heavy","hard"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","metallic","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","heavy","snap"}},
        crash    ={type="Crash",            kw={"bright","heavy","noise","metallic"}},
        ride     ={type="Ride",             kw={"bright","metallic","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","punch","bright","hard"}},
        tom      ={type="Tom",              kw={"heavy","punch","bright","sub"}},
      },
    },
    { name="Atmospheric", default_kw={"soft","lush","organic","room","bright","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","organic","sub","lush","room"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","soft","deep"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","lush"}},
        snare_alt={type="Snare Electronic", kw={"soft","organic","layered","lush"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","room","bright","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","organic"}},
        crash    ={type="Crash",            kw={"soft","bright","mallet","organic","room"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","bright","acoustic"}},
        tom      ={type="Tom",              kw={"soft","organic","room","deep","lush"}},
      },
    },
    { name="Halftime", default_kw={"heavy","deep","sub","wide","layered","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","deep","sub","wide","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","sub","heavy","organic"}},
        snare    ={type="Snare Electronic", kw={"heavy","wide","layered","organic","room"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","heavy","room","organic"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","wide","organic","room","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","organic","acoustic","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","organic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"heavy","wide","organic","room"}},
        ride     ={type="Ride",             kw={"soft","acoustic","organic","wide"}},
        perc     ={type="Shakers",          kw={"organic","soft","wide","acoustic"}},
        tom      ={type="Tom",              kw={"heavy","deep","sub","wide","layered"}},
      },
    },
    { name="Hardstep", default_kw={"hard","heavy","punch","industrial","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","heavy","punch","sub","noise"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","punch","heavy","crunch"}},
        snare    ={type="Snare Electronic", kw={"hard","heavy","punch","noise","industrial"}},
        snare_alt={type="Snare Electronic", kw={"hard","punch","noise","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"hard","heavy","noise","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","metallic","hard","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","metallic","hard"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","heavy","hard","noise"}},
        crash    ={type="Crash",            kw={"noise","metallic","hard","heavy"}},
        ride     ={type="Ride",             kw={"noise","metallic","hard"}},
        perc     ={type="Perc Electronic",  kw={"noise","hard","snap","metal"}},
        tom      ={type="Tom",              kw={"hard","heavy","punch","deep"}},
      },
    },
    { name="Techstep", default_kw={"metallic","synthetic","heavy","machine","industrial","tight"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","sub","punch","metallic","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"machine","heavy","metallic","synthetic"}},
        snare    ={type="Snare Electronic", kw={"metallic","machine","heavy","synthetic","industrial"}},
        snare_alt={type="Snare Electronic", kw={"machine","metallic","heavy","industrial"}},
        clap     ={type="Claps & Snaps",    kw={"metallic","machine","heavy","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","machine","tight","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","machine","tight"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","machine","heavy","synthetic"}},
        crash    ={type="Crash",            kw={"metallic","machine","industrial","noise"}},
        ride     ={type="Ride",             kw={"metallic","machine","synthetic","industrial"}},
        perc     ={type="Perc Electronic",  kw={"metallic","snap","machine","synthetic"}},
        tom      ={type="Tom",              kw={"metallic","heavy","machine","deep"}},
      },
    },
    { name="Minimal DnB", default_kw={"tight","soft","synthetic","sub","bright","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","sub","tight","organic","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","sub","soft","synthetic"}},
        snare    ={type="Snare Electronic", kw={"tight","soft","bright","synthetic","organic"}},
        snare_alt={type="Snare Electronic", kw={"soft","tight","bright","organic"}},
        clap     ={type="Claps & Snaps",    kw={"soft","tight","bright","organic","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","soft","bright","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","soft","bright"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","tight","organic"}},
        crash    ={type="Crash",            kw={"soft","bright","organic","room"}},
        ride     ={type="Ride",             kw={"soft","bright","organic","acoustic"}},
        perc     ={type="Shakers",          kw={"organic","soft","bright","acoustic"}},
        tom      ={type="Tom",              kw={"tight","soft","sub","organic","bright"}},
      },
    },
    { name="Soulful DnB", default_kw={"bright","lush","organic","room","wide","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","organic","sub","lush"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","lush","wide"}},
        snare_alt={type="Snare Electronic", kw={"bright","organic","layered","room","lush"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","room","lush","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","wide"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"bright","organic","lush","wide","room"}},
      },
    },
    { name="Ragga", default_kw={"heavy","bright","punch","synthetic","machine","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","punch","bright","sub","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","bright","sub","punch"}},
        snare    ={type="Snare Electronic", kw={"bright","heavy","punch","synthetic","snap"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","heavy","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","heavy","snap","punch","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","heavy","machine"}},
        crash    ={type="Crash",            kw={"bright","synthetic","heavy","wide"}},
        ride     ={type="Ride",             kw={"bright","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"bright","snap","machine","synthetic"}},
        tom      ={type="Tom",              kw={"heavy","punch","bright","wide","deep"}},
      },
    },
    { name="Drumfunk", default_kw={"organic","lofi","tape","punch","creative","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","lofi","vintage"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","room","lofi"}},
        snare    ={type="Snare Acoustic",   kw={"punch","organic","room","lofi","bright"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","punch","tape"}},
        clap     ={type="Claps & Snaps",    kw={"organic","room","bright","lofi","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","organic","lofi"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","organic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","organic","room"}},
        crash    ={type="Crash",            kw={"organic","room","bright","acoustic"}},
        ride     ={type="Ride",             kw={"acoustic","bright","organic"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","bright","room"}},
        tom      ={type="Tom",              kw={"punch","organic","lofi","room","deep"}},
      },
    },
    { name="Vintage Jungle", default_kw={"lofi","tape","vinyl","punch","heavy","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","lofi","tape","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","lofi","organic","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"bright","punch","lofi","tape","heavy"}},
        snare_alt={type="Snare Electronic", kw={"heavy","lofi","snap","punch"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","heavy","snap","punch","tape"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","bright","metallic","tape"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","metallic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","bright","metallic","heavy"}},
        crash    ={type="Crash",            kw={"lofi","bright","metallic","heavy"}},
        ride     ={type="Ride",             kw={"lofi","metallic","bright"}},
        perc     ={type="Shakers",          kw={"organic","lofi","bright","tape"}},
        tom      ={type="Tom",              kw={"heavy","lofi","punch","deep","tape"}},
      },
    },
    { name="Crossbreed", default_kw={"hard","heavy","noise","synthetic","industrial","dark"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","heavy","sub","noise","industrial"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","heavy","noise","dark"}},
        snare    ={type="Snare Electronic", kw={"hard","noise","heavy","industrial","snap"}},
        snare_alt={type="Snare Electronic", kw={"noise","hard","heavy","industrial"}},
        clap     ={type="Claps & Snaps",    kw={"hard","noise","heavy","industrial","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","hard","noise","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","noise","hard"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","noise","heavy","hard"}},
        crash    ={type="Crash",            kw={"noise","metallic","hard","industrial"}},
        ride     ={type="Ride",             kw={"metallic","noise","hard"}},
        perc     ={type="Perc Electronic",  kw={"noise","hard","metallic","industrial"}},
        tom      ={type="Tom",              kw={"hard","heavy","noise","industrial","deep"}},
      },
    },
    { name="Jazz Step", default_kw={"organic","bright","room","soft","gold","acoustic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","organic","bright","room","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","soft","gold"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","soft","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","room","soft","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","gold"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","soft"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","soft"}},
        tom      ={type="Tom",              kw={"organic","room","bright","soft","deep"}},
      },
    },
    { name="Cinematic", default_kw={"wide","lush","organic","room","layered","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"wide","deep","sub","organic","layered"}},
        kick_alt ={type="Kick Acoustic",    kw={"wide","room","organic","heavy","deep"}},
        snare    ={type="Snare Acoustic",   kw={"wide","bright","room","organic","layered"}},
        snare_alt={type="Snare Electronic", kw={"wide","layered","bright","organic"}},
        clap     ={type="Claps & Snaps",    kw={"wide","bright","organic","room","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","wide","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","wide","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","wide","organic","room"}},
        crash    ={type="Crash",            kw={"wide","bright","organic","room","mallet"}},
        ride     ={type="Ride",             kw={"bright","acoustic","wide","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","wide","acoustic","lush"}},
        tom      ={type="Tom",              kw={"wide","deep","organic","layered","room"}},
      },
    },
    { name="Dancefloor", default_kw={"punch","bright","wide","synthetic","machine","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","sub","wide","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","heavy","sub","bright"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","wide","snap","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","wide","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","snap","punch","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","machine","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","machine","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","heavy"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","heavy"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","machine"}},
        perc     ={type="Perc Electronic",  kw={"bright","snap","wide","synthetic","machine"}},
        tom      ={type="Tom",              kw={"punch","wide","bright","heavy","deep"}},
      },
    },
    { name="Autonomic", default_kw={"soft","deep","organic","synthetic","wide","layered"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","deep","sub","organic","wide"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","organic","sub","layered"}},
        snare    ={type="Snare Electronic", kw={"soft","organic","layered","synthetic","wide"}},
        snare_alt={type="Snare Electronic", kw={"soft","layered","organic","wide"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","wide","layered","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","synthetic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","synthetic","wide","organic"}},
        crash    ={type="Crash",            kw={"soft","wide","organic","mallet","layered"}},
        ride     ={type="Ride",             kw={"soft","synthetic","organic","wide"}},
        perc     ={type="Shakers",          kw={"organic","soft","wide","acoustic"}},
        tom      ={type="Tom",              kw={"deep","soft","organic","sub","wide"}},
      },
    },
  }},
  -- ── Electronica ───────────────────────────────────────────────────────────
  { name="Electronica", variants={
    { name="IDM", default_kw={"glitch","noise","creative","crunch","grit"},
      voices={
        kick     ={type="Kick Electronic",  kw={"layered","creative","noise","crunch","grit"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","dirty","sub","crunch"}},
        snare    ={type="Snare Electronic", kw={"layered","creative","noise","crunch"}},
        snare_alt={type="Snare Electronic", kw={"glitch","crunch","noise","grit"}},
        clap     ={type="Claps & Snaps",    kw={"glitch","noise","creative","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","synthetic","tight","grit"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","synthetic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"noise","heavy","synthetic","grit"}},
        crash    ={type="Crash",            kw={"creative","noise","mallet","trash"}},
        ride     ={type="Ride",             kw={"creative","noise","synthetic"}},
        perc     ={type="Perc Glitch",      kw={"blip","creative","glitch","noise"}},
        tom      ={type="Tom",              kw={"creative","heavy","organic","noise"}},
      },
    },
    { name="Ambient", default_kw={"soft","lush","room","organic","vintage"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","organic","room","lush"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","soft","organic","vintage"}},
        snare    ={type="Snare Electronic", kw={"soft","organic","room","lush","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"room","soft","organic","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","room","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","acoustic","room","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","room","lush"}},
        crash    ={type="Crash",            kw={"mallet","soft","organic","room"}},
        ride     ={type="Ride",             kw={"soft","organic","room","acoustic"}},
        perc     ={type="Shakers",          kw={"organic","soft","acoustic","lush"}},
        tom      ={type="Tom",              kw={"soft","room","organic","deep"}},
      },
    },
    { name="Trip Hop", default_kw={"lofi","tape","vinyl","organic","heavy","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","sub","punch","lofi","tape"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"room","organic","lofi","tape","vinyl"}},
        snare_alt={type="Snare Electronic", kw={"heavy","lofi","organic","tape","noise"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","tape","organic","heavy","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","lofi","tape","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","lofi","tape"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","lofi","tape","organic"}},
        crash    ={type="Crash",            kw={"acoustic","room","organic","lofi"}},
        ride     ={type="Ride",             kw={"acoustic","tape","organic","lofi"}},
        perc     ={type="Perc Acoustic",    kw={"organic","lofi","acoustic","room"}},
        tom      ={type="Tom",              kw={"heavy","organic","room","lofi","tape"}},
      },
    },
    { name="Glitch Hop", default_kw={"noise","punch","snap","blip","creative"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","noise","sub","creative"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","heavy","creative","punch"}},
        snare    ={type="Snare Electronic", kw={"noise","creative","punch","snap"}},
        snare_alt={type="Snare Electronic", kw={"snap","noise","creative"}},
        clap     ={type="Claps & Snaps",    kw={"noise","creative","snap","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","synthetic","tight","creative"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","synthetic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"noise","heavy","synthetic","creative"}},
        crash    ={type="Crash",            kw={"noise","creative","mallet","synthetic"}},
        ride     ={type="Ride",             kw={"noise","creative","synthetic"}},
        perc     ={type="Perc Glitch",      kw={"blip","creative","noise"}},
        tom      ={type="Tom",              kw={"creative","heavy","noise","organic"}},
      },
    },
    { name="Chillwave", default_kw={"soft","lush","vintage","tape","organic","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","organic","room","lush","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","soft","organic","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","vintage"}},
        snare_alt={type="Snare Electronic", kw={"soft","organic","lush","layered","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","tape","bright","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","acoustic","vintage"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","organic"}},
        crash    ={type="Crash",            kw={"soft","bright","organic","mallet","room"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","acoustic","lush"}},
        tom      ={type="Tom",              kw={"soft","organic","room","lush","vintage"}},
      },
    },
    { name="Downtempo", default_kw={"deep","organic","soft","room","lush","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","sub","organic","soft","room"}},
        kick_alt ={type="Kick Acoustic",    kw={"deep","room","organic","soft"}},
        snare    ={type="Snare Acoustic",   kw={"room","organic","soft","bright","lush"}},
        snare_alt={type="Snare Electronic", kw={"soft","organic","room","layered","lush"}},
        clap     ={type="Claps & Snaps",    kw={"organic","soft","room","acoustic","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","soft","organic","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","soft","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","soft","organic","room"}},
        crash    ={type="Crash",            kw={"soft","organic","mallet","room","acoustic"}},
        ride     ={type="Ride",             kw={"soft","acoustic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","soft","acoustic","lush"}},
        tom      ={type="Tom",              kw={"deep","organic","soft","room","sub"}},
      },
    },
    { name="Electro", default_kw={"808","machine","synthetic","snap","tight","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","sub","machine","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"808","machine","synthetic","deep"}},
        snare    ={type="Snare Electronic", kw={"808","machine","synthetic","snap","hard"}},
        snare_alt={type="Snare Electronic", kw={"machine","snap","synthetic","808"}},
        clap     ={type="Claps & Snaps",    kw={"808","machine","synthetic","snap","hard"}},
        hh_c     ={type="Hihat Closed",     kw={"808","machine","tight","synthetic","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"808","machine","tight","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"808","machine","synthetic","heavy"}},
        crash    ={type="Crash",            kw={"machine","808","synthetic","hard"}},
        ride     ={type="Ride",             kw={"machine","808","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","machine","blip","synthetic"}},
        tom      ={type="Tom",              kw={"808","machine","synthetic","heavy","deep"}},
      },
    },
    { name="Vaporwave", default_kw={"soft","lush","vintage","tape","vinyl","lofi"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","lofi","tape","vintage","lush"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","tape","organic","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"soft","lofi","tape","bright","vintage"}},
        snare_alt={type="Snare Electronic", kw={"soft","vintage","tape","lush","organic"}},
        clap     ={type="Claps & Snaps",    kw={"soft","tape","vintage","organic","lofi"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","tape","vinyl","bright","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","tape","vinyl","bright"}},
        hh_o     ={type="HiHat Open",       kw={"soft","tape","vinyl","bright","organic"}},
        crash    ={type="Crash",            kw={"soft","organic","tape","room","vintage"}},
        ride     ={type="Ride",             kw={"soft","tape","bright","vintage","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","vintage","lush"}},
        tom      ={type="Tom",              kw={"soft","tape","lofi","vintage","organic"}},
      },
    },
    { name="Post-Punk", default_kw={"dark","organic","synthetic","room","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","dark","organic","room","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"heavy","room","dark","organic"}},
        snare    ={type="Snare Acoustic",   kw={"room","dark","organic","heavy","bright"}},
        snare_alt={type="Snare Electronic", kw={"dark","heavy","synthetic","organic","noise"}},
        clap     ={type="Claps & Snaps",    kw={"dark","organic","room","heavy","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","metallic","organic","acoustic","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"dark","metallic","acoustic","organic"}},
        crash    ={type="Crash",            kw={"dark","organic","room","acoustic","noise"}},
        ride     ={type="Ride",             kw={"dark","acoustic","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","room","dark","acoustic"}},
        tom      ={type="Tom",              kw={"dark","heavy","organic","room","deep"}},
      },
    },
    { name="Darkwave", default_kw={"dark","synthetic","soft","organic","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"dark","heavy","sub","synthetic","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"dark","soft","sub","synthetic"}},
        snare    ={type="Snare Electronic", kw={"dark","synthetic","soft","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"dark","organic","room","soft","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"dark","organic","soft","synthetic","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","synthetic","soft","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","synthetic","soft"}},
        hh_o     ={type="HiHat Open",       kw={"dark","synthetic","heavy","metallic"}},
        crash    ={type="Crash",            kw={"dark","soft","organic","metallic","noise"}},
        ride     ={type="Ride",             kw={"dark","metallic","synthetic","soft"}},
        perc     ={type="Perc Electronic",  kw={"dark","synthetic","metal","soft"}},
        tom      ={type="Tom",              kw={"dark","heavy","synthetic","deep","organic"}},
      },
    },
    { name="Hauntology", default_kw={"lofi","tape","vintage","organic","soft","dark"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"tape","lofi","organic","vintage","room"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","tape","lofi","dark","organic"}},
        snare    ={type="Snare Acoustic",   kw={"tape","lofi","organic","bright","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"lofi","tape","vinyl","organic","dark"}},
        clap     ={type="Claps & Snaps",    kw={"tape","lofi","organic","vintage","dark"}},
        hh_c     ={type="Hihat Closed",     kw={"tape","vinyl","lofi","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tape","vinyl","lofi","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"tape","vinyl","lofi","organic","dark"}},
        crash    ={type="Crash",            kw={"tape","organic","room","lofi","dark"}},
        ride     ={type="Ride",             kw={"tape","lofi","metallic","organic","vintage"}},
        perc     ={type="Foley",            kw={"organic","vintage","lofi","tape"}},
        tom      ={type="Tom",              kw={"lofi","tape","dark","organic","vintage"}},
      },
    },
    { name="Industrial", default_kw={"hard","metallic","noise","machine","dark","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","industrial","heavy","noise","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","noise","heavy","dark"}},
        snare    ={type="Snare Electronic", kw={"hard","metallic","noise","machine","heavy"}},
        snare_alt={type="Snare Electronic", kw={"metallic","noise","hard","industrial"}},
        clap     ={type="Claps & Snaps",    kw={"hard","noise","machine","heavy","industrial"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","noise","hard","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","noise","machine"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","noise","heavy","hard"}},
        crash    ={type="Crash",            kw={"noise","metallic","hard","machine","dark"}},
        ride     ={type="Ride",             kw={"metallic","noise","machine","dark"}},
        perc     ={type="Perc Electronic",  kw={"metallic","noise","machine","hard"}},
        tom      ={type="Tom",              kw={"heavy","hard","noise","industrial","dark"}},
      },
    },
    { name="Noise Music", default_kw={"noise","creative","metallic","dark","heavy","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"noise","heavy","dark","synthetic","creative"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","dark","heavy","creative"}},
        snare    ={type="Snare Electronic", kw={"noise","creative","metallic","heavy","dark"}},
        snare_alt={type="Snare Electronic", kw={"noise","creative","metallic","dark"}},
        clap     ={type="Claps & Snaps",    kw={"noise","heavy","creative","dark","metallic"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","metallic","dark","creative"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","metallic","dark"}},
        hh_o     ={type="HiHat Open",       kw={"noise","heavy","metallic","dark"}},
        crash    ={type="Crash",            kw={"noise","creative","metallic","heavy","dark"}},
        ride     ={type="Ride",             kw={"noise","metallic","creative","dark"}},
        perc     ={type="Perc Glitch",      kw={"noise","creative","metallic","dark"}},
        tom      ={type="Tom",              kw={"noise","dark","heavy","creative","deep"}},
      },
    },
    { name="Broken Beat", default_kw={"organic","tight","punch","bright","creative","room"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","organic","bright","tight","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","punch","snap"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","punch","organic","tight"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","tight"}},
        crash    ={type="Crash",            kw={"bright","organic","room","creative","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","tight"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","organic","creative","tight"}},
        tom      ={type="Tom",              kw={"punch","organic","bright","tight","room"}},
      },
    },
    { name="Braindance", default_kw={"creative","synthetic","noise","bright","machine","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"synthetic","punch","creative","bright","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"synthetic","creative","noise","punch"}},
        snare    ={type="Snare Electronic", kw={"creative","synthetic","noise","bright","snap"}},
        snare_alt={type="Snare Electronic", kw={"creative","noise","synthetic","bright"}},
        clap     ={type="Claps & Snaps",    kw={"creative","bright","noise","synthetic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","creative","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","creative"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","creative","noise","bright"}},
        crash    ={type="Crash",            kw={"creative","noise","synthetic","bright","metallic"}},
        ride     ={type="Ride",             kw={"synthetic","creative","noise","bright"}},
        perc     ={type="Perc Glitch",      kw={"creative","noise","synthetic","bright"}},
        tom      ={type="Tom",              kw={"synthetic","creative","noise","deep","punch"}},
      },
    },
    { name="Skweee", default_kw={"bright","synthetic","machine","organic","snap","warm"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","synthetic","machine","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"bright","machine","organic","punch"}},
        snare    ={type="Snare Electronic", kw={"bright","synthetic","snap","machine","organic"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","organic","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","synthetic","organic","machine"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","machine","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","machine","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","machine","organic"}},
        crash    ={type="Crash",            kw={"bright","synthetic","organic","machine"}},
        ride     ={type="Ride",             kw={"bright","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","synthetic","organic","machine"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","synthetic","warm"}},
      },
    },
    { name="Deconstructed", default_kw={"noise","creative","hard","synthetic","dark","metallic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"noise","creative","hard","synthetic","dark"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","dark","hard","creative"}},
        snare    ={type="Snare Electronic", kw={"noise","creative","hard","metallic","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"creative","noise","metallic","hard"}},
        clap     ={type="Claps & Snaps",    kw={"noise","creative","hard","metallic","dark"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","metallic","dark","creative","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","metallic","dark","creative"}},
        hh_o     ={type="HiHat Open",       kw={"noise","metallic","heavy","dark","creative"}},
        crash    ={type="Crash",            kw={"noise","creative","metallic","dark","hard"}},
        ride     ={type="Ride",             kw={"noise","metallic","dark","creative"}},
        perc     ={type="Perc Glitch",      kw={"noise","creative","hard","metallic"}},
        tom      ={type="Tom",              kw={"noise","dark","hard","creative","heavy"}},
      },
    },
    { name="Microsound", default_kw={"soft","tight","organic","synthetic","bright","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","tight","organic","synthetic","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","organic","tight","bright"}},
        snare    ={type="Snare Electronic", kw={"soft","tight","bright","organic","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"soft","bright","tight","organic"}},
        clap     ={type="Claps & Snaps",    kw={"soft","tight","bright","organic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","tight","bright","acoustic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","tight","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","organic"}},
        crash    ={type="Crash",            kw={"soft","bright","organic","mallet","wide"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","organic"}},
        perc     ={type="Perc Electronic",  kw={"soft","snap","bright","tight","organic"}},
        tom      ={type="Tom",              kw={"soft","organic","tight","wide","bright"}},
      },
    },
    { name="Plunderphonics", default_kw={"lofi","tape","vinyl","organic","creative","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"lofi","vintage","organic","punch","tape"}},
        kick_alt ={type="Kick Electronic",  kw={"lofi","organic","vintage","punch"}},
        snare    ={type="Snare Acoustic",   kw={"lofi","organic","room","bright","tape"}},
        snare_alt={type="Snare Acoustic",   kw={"lofi","bright","organic","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","organic","bright","tape","creative"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","acoustic","bright","tape","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","acoustic","vintage"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","acoustic","bright","tape"}},
        crash    ={type="Crash",            kw={"lofi","organic","bright","vintage"}},
        ride     ={type="Ride",             kw={"lofi","acoustic","bright","vintage"}},
        perc     ={type="Shakers",          kw={"organic","lofi","bright","acoustic"}},
        tom      ={type="Tom",              kw={"lofi","organic","vintage","punch","tape"}},
      },
    },
    { name="Electro Industrial", default_kw={"hard","machine","synthetic","noise","metallic","dark"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","machine","synthetic","heavy","noise"}},
        kick_alt ={type="Kick Electronic",  kw={"machine","hard","heavy","noise"}},
        snare    ={type="Snare Electronic", kw={"hard","machine","metallic","synthetic","noise"}},
        snare_alt={type="Snare Electronic", kw={"machine","metallic","hard","noise"}},
        clap     ={type="Claps & Snaps",    kw={"hard","machine","noise","metallic","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","machine","hard","tight","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","machine","hard","noise"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","machine","heavy","noise"}},
        crash    ={type="Crash",            kw={"metallic","noise","machine","hard","dark"}},
        ride     ={type="Ride",             kw={"metallic","machine","noise","dark"}},
        perc     ={type="Perc Electronic",  kw={"machine","metallic","noise","hard","snap"}},
        tom      ={type="Tom",              kw={"heavy","machine","hard","noise","dark"}},
      },
    },
  }},
  -- ── Lo-Fi ─────────────────────────────────────────────────────────────────
  { name="Lo-Fi", variants={
    { name="Tape", default_kw={"tape","vinyl","lofi","old","tube","amp"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tape","vinyl","lofi","old","amp"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","tape","lofi","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"tape","vinyl","lofi","room","old"}},
        snare_alt={type="Snare Electronic", kw={"lofi","tape","dirty","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"tape","vinyl","lofi","old"}},
        hh_c     ={type="Hihat Closed",     kw={"tape","vinyl","lofi","old"}},
        hh_pedal ={type="Hihat Closed",     kw={"tape","lofi","old"}},
        hh_o     ={type="HiHat Open",       kw={"tape","vinyl","lofi","old"}},
        crash    ={type="Crash",            kw={"tape","organic","room","lofi"}},
        ride     ={type="Ride",             kw={"acoustic","tape","room","lofi"}},
        perc     ={type="Foley",            kw={"stick","click","organic","old"}},
        tom      ={type="Tom",              kw={"tape","room","organic","lofi"}},
      },
    },
    { name="Boom Bap", default_kw={"room","vintage","old","punch","grit"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","vintage","hard","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","deep","vintage","old"}},
        snare    ={type="Snare Acoustic",   kw={"room","bright","snap","punch","pop"}},
        snare_alt={type="Snare Acoustic",   kw={"room","vintage","pop","organic"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","old","room","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","vintage","room","old"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","vintage","old"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","vintage","room","old"}},
        crash    ={type="Crash",            kw={"acoustic","room","vintage","organic"}},
        ride     ={type="Ride",             kw={"acoustic","vintage","room","old"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","vintage"}},
        tom      ={type="Tom",              kw={"room","punch","vintage","organic"}},
      },
    },
    { name="SP1200", default_kw={"lofi","punch","vintage","snap","dirty","organic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","lofi","vintage","dirty","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","lofi","sub","dirty","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"punch","snap","lofi","bright","vintage"}},
        snare_alt={type="Snare Electronic", kw={"snap","lofi","punch","dirty","bright"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","snap","punch","vintage","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","bright","acoustic","metallic","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","acoustic","bright","vintage"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","bright","acoustic","metallic"}},
        crash    ={type="Crash",            kw={"acoustic","lofi","organic","room","vintage"}},
        ride     ={type="Ride",             kw={"acoustic","lofi","bright","vintage"}},
        perc     ={type="Perc Acoustic",    kw={"organic","lofi","bright","acoustic"}},
        tom      ={type="Tom",              kw={"punch","lofi","vintage","organic","room"}},
      },
    },
    { name="Jazz Hip Hop", default_kw={"organic","room","soft","bright","acoustic","flam"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","soft","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","deep","soft"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","flam","soft"}},
        snare_alt={type="Snare Acoustic",   kw={"room","organic","bright","flam","snap"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","gold","room","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","gold","room"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","gold","organic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"room","organic","soft","bright","acoustic"}},
      },
    },
    { name="Cassette", default_kw={"tape","vinyl","lofi","dirty","organic","vintage"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tape","lofi","dirty","heavy","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"tape","lofi","organic","room","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"tape","vinyl","lofi","bright","vintage"}},
        snare_alt={type="Snare Electronic", kw={"lofi","dirty","tape","noise","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"tape","vinyl","lofi","organic","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"tape","vinyl","lofi","metallic","acoustic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tape","vinyl","lofi","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"tape","vinyl","lofi","organic"}},
        crash    ={type="Crash",            kw={"tape","organic","room","acoustic","lofi"}},
        ride     ={type="Ride",             kw={"acoustic","tape","vinyl","lofi"}},
        perc     ={type="Foley",            kw={"organic","vintage","lofi","tape"}},
        tom      ={type="Tom",              kw={"tape","lofi","organic","room","vintage"}},
      },
    },
    { name="Chill Beats", default_kw={"soft","lush","organic","room","bright","vintage"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","organic","room","lush","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","room","organic","deep"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","lush"}},
        snare_alt={type="Snare Acoustic",   kw={"room","soft","organic","bright"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","room","bright","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","acoustic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","organic"}},
        crash    ={type="Crash",            kw={"soft","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"soft","acoustic","bright","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","acoustic","lush"}},
        tom      ={type="Tom",              kw={"soft","room","organic","lush","deep"}},
      },
    },
    { name="Dusty 45s", default_kw={"vinyl","lofi","organic","room","vintage","gold"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","vintage","lofi"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","vintage","deep"}},
        snare    ={type="Snare Acoustic",   kw={"room","bright","organic","vintage","lofi"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","vintage","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","room","vintage","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"gold","acoustic","bright","organic","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"gold","acoustic","bright","vintage"}},
        hh_o     ={type="HiHat Open",       kw={"gold","acoustic","organic","bright","vintage"}},
        crash    ={type="Crash",            kw={"acoustic","room","organic","vintage","lofi"}},
        ride     ={type="Ride",             kw={"gold","acoustic","bright","vintage","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","vintage"}},
        tom      ={type="Tom",              kw={"room","organic","vintage","lofi","acoustic"}},
      },
    },
    { name="Chiptune", default_kw={"blip","synthetic","machine","noise","bright","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"synthetic","machine","808","punch","blip"}},
        kick_alt ={type="Kick Electronic",  kw={"machine","synthetic","blip","snap"}},
        snare    ={type="Snare Electronic", kw={"synthetic","snap","noise","machine","bright"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","noise","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"synthetic","snap","machine","noise","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"synthetic","bright","noise","tight","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"synthetic","bright","noise","machine"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","bright","noise","machine"}},
        crash    ={type="Crash",            kw={"synthetic","bright","noise","machine"}},
        ride     ={type="Ride",             kw={"synthetic","bright","machine","noise"}},
        perc     ={type="Perc Glitch",      kw={"blip","noise","synthetic","bright"}},
        tom      ={type="Tom",              kw={"synthetic","machine","noise","blip","bright"}},
      },
    },
    { name="French Lo-Fi", default_kw={"lush","soft","organic","bright","warm","vintage"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","punch","organic","lush","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","soft"}},
        snare    ={type="Snare Acoustic",   kw={"bright","soft","room","organic","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"soft","bright","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"soft","bright","organic","acoustic","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","gold","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","gold","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","organic","lush"}},
        crash    ={type="Crash",            kw={"soft","organic","room","bright","acoustic"}},
        ride     ={type="Ride",             kw={"soft","bright","gold","acoustic","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","bright","acoustic"}},
        tom      ={type="Tom",              kw={"soft","organic","room","bright","lush"}},
      },
    },
    { name="Lo-Fi Soul", default_kw={"organic","room","punch","warm","vintage","lush"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","warm","vintage"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","organic","warm","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","flam","warm"}},
        snare_alt={type="Snare Acoustic",   kw={"room","bright","organic","warm","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","vintage"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"room","organic","punch","warm","vintage"}},
      },
    },
    { name="Lo-Fi RnB", default_kw={"organic","warm","soft","lush","vintage","room"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","organic","warm","deep","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","room","organic","punch"}},
        snare    ={type="Snare Acoustic",   kw={"warm","soft","organic","room","bright"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","warm","organic","room","soft"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","warm","lush","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","acoustic","organic","warm","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","warm","organic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","organic","warm","room"}},
        crash    ={type="Crash",            kw={"soft","organic","room","warm","lush"}},
        ride     ={type="Ride",             kw={"soft","acoustic","warm","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","warm","acoustic","lush"}},
        tom      ={type="Tom",              kw={"soft","organic","warm","room","deep"}},
      },
    },
    { name="Crate Digger", default_kw={"vinyl","dirty","organic","room","bright","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","vintage","dirty"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","vintage","dirty"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","dirty","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","vintage","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","vintage","dirty","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","vintage","organic","lofi"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","vintage","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","vintage","organic"}},
        crash    ={type="Crash",            kw={"organic","bright","vintage","room"}},
        ride     ={type="Ride",             kw={"acoustic","vintage","bright","organic"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","vintage","bright"}},
        tom      ={type="Tom",              kw={"organic","punch","vintage","dirty","room"}},
      },
    },
    { name="City Pop", default_kw={"bright","lush","warm","organic","vintage","disco"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","sub","lush","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","room","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","lush","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","warm","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","lush","warm","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic","warm"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","warm","gold"}},
        crash    ={type="Crash",            kw={"bright","organic","lush","warm","room"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","warm"}},
        perc     ={type="Shakers",          kw={"organic","bright","warm","acoustic","lush"}},
        tom      ={type="Tom",              kw={"bright","organic","warm","lush","room"}},
      },
    },
    { name="Reverb Rap", default_kw={"room","organic","lofi","punch","warm","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","room","organic","sub","lofi"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"room","organic","bright","wide","lofi"}},
        snare_alt={type="Snare Acoustic",   kw={"room","organic","wide","bright","flam"}},
        clap     ={type="Claps & Snaps",    kw={"room","organic","bright","wide","lofi"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","lofi","bright","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","lofi","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","room","bright","organic"}},
        crash    ={type="Crash",            kw={"room","organic","bright","wide"}},
        ride     ={type="Ride",             kw={"acoustic","room","bright","organic"}},
        perc     ={type="Shakers",          kw={"organic","room","bright","acoustic"}},
        tom      ={type="Tom",              kw={"room","organic","wide","punch","lofi"}},
      },
    },
    { name="Woozy", default_kw={"soft","lofi","tape","organic","warm","lush"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","lofi","organic","warm","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","lofi","organic","punch"}},
        snare    ={type="Snare Acoustic",   kw={"soft","lofi","organic","warm","bright"}},
        snare_alt={type="Snare Acoustic",   kw={"soft","organic","warm","lofi","bright"}},
        clap     ={type="Claps & Snaps",    kw={"soft","lofi","organic","warm","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","lofi","acoustic","organic","warm"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","lofi","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","lofi","acoustic","organic"}},
        crash    ={type="Crash",            kw={"soft","organic","lofi","mallet","warm"}},
        ride     ={type="Ride",             kw={"soft","acoustic","lofi","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","lofi","warm"}},
        tom      ={type="Tom",              kw={"soft","lofi","organic","warm","deep"}},
      },
    },
    { name="Underground", default_kw={"dirty","organic","punch","room","heavy","vintage"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","organic","dirty","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","dirty","punch"}},
        snare_alt={type="Snare Electronic", kw={"heavy","punch","organic","dirty"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","punch","dirty","room"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","acoustic","organic","bright","dirty"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","acoustic","bright","organic"}},
        crash    ={type="Crash",            kw={"organic","room","bright","dirty"}},
        ride     ={type="Ride",             kw={"acoustic","organic","bright","lofi"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","bright","dirty"}},
        tom      ={type="Tom",              kw={"heavy","organic","punch","dirty","room"}},
      },
    },
    { name="Beatmaker", default_kw={"punch","organic","room","lofi","vintage","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","organic","lofi","sub","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","punch","lofi","room"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","punch","organic","room","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","punch","snap","lofi"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","acoustic","bright","organic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","acoustic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","acoustic","bright","organic"}},
        crash    ={type="Crash",            kw={"organic","bright","room","lofi"}},
        ride     ={type="Ride",             kw={"acoustic","lofi","bright","organic"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","lofi","bright"}},
        tom      ={type="Tom",              kw={"punch","organic","lofi","room","vintage"}},
      },
    },
    { name="Vintage Synth", default_kw={"synthetic","vintage","lofi","warm","organic","tape"},
      voices={
        kick     ={type="Kick Electronic",  kw={"synthetic","vintage","lofi","warm","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"synthetic","warm","organic","lofi"}},
        snare    ={type="Snare Electronic", kw={"synthetic","vintage","lofi","warm","machine"}},
        snare_alt={type="Snare Electronic", kw={"synthetic","warm","lofi","machine"}},
        clap     ={type="Claps & Snaps",    kw={"synthetic","lofi","warm","organic","machine"}},
        hh_c     ={type="Hihat Closed",     kw={"synthetic","lofi","warm","machine","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"synthetic","lofi","machine"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","lofi","warm","machine"}},
        crash    ={type="Crash",            kw={"synthetic","lofi","warm","organic"}},
        ride     ={type="Ride",             kw={"synthetic","lofi","machine","vintage"}},
        perc     ={type="Perc Electronic",  kw={"synthetic","lofi","warm","machine","snap"}},
        tom      ={type="Tom",              kw={"synthetic","lofi","warm","organic","vintage"}},
      },
    },
    { name="Cozy", default_kw={"soft","warm","organic","lush","acoustic","bright"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","warm","organic","deep","room"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","organic","warm","sub"}},
        snare    ={type="Snare Acoustic",   kw={"soft","warm","organic","bright","room"}},
        snare_alt={type="Snare Acoustic",   kw={"soft","bright","organic","warm","acoustic"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","warm","acoustic","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","acoustic","bright","organic","warm"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","warm"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","organic","warm","bright"}},
        crash    ={type="Crash",            kw={"soft","organic","mallet","warm","room"}},
        ride     ={type="Ride",             kw={"soft","acoustic","warm","bright"}},
        perc     ={type="Shakers",          kw={"organic","soft","warm","acoustic","lush"}},
        tom      ={type="Tom",              kw={"soft","warm","organic","room","deep"}},
      },
    },
    { name="Night Lo-Fi", default_kw={"dark","organic","soft","warm","room","vintage"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","dark","organic","sub","warm"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","organic","dark","room"}},
        snare    ={type="Snare Acoustic",   kw={"soft","dark","organic","room","warm"}},
        snare_alt={type="Snare Acoustic",   kw={"soft","organic","dark","warm","room"}},
        clap     ={type="Claps & Snaps",    kw={"soft","dark","organic","warm","room"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","dark","acoustic","organic","lofi"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","dark","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","dark","organic"}},
        crash    ={type="Crash",            kw={"soft","dark","organic","room","mallet"}},
        ride     ={type="Ride",             kw={"soft","acoustic","dark","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","dark","acoustic"}},
        tom      ={type="Tom",              kw={"soft","dark","organic","warm","room"}},
      },
    },
  }},
  -- ── Pop & Disco ───────────────────────────────────────────────────────────
  { name="Pop & Disco", variants={
    { name="Pop", default_kw={"bright","pop","clean","wide","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","pop","snap","tight"}},
        kick_alt ={type="Kick Acoustic",    kw={"bright","punch","room","pop"}},
        snare    ={type="Snare Acoustic",   kw={"bright","pop","room","wide","snap"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","tight","pop"}},
        clap     ={type="Claps & Snaps",    kw={"bright","pop","snap","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","pop","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","pop"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","pop","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","pop","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","pop"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","pop"}},
        tom      ={type="Tom",              kw={"bright","punch","wide","pop"}},
      },
    },
    { name="Disco", default_kw={"disco","gold","bright","lush","acoustic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","disco","deep","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"bright","punch","room","disco"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","disco","snap","pop"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","disco"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold","disco"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","gold","disco"}},
        crash    ={type="Crash",            kw={"bright","acoustic","gold","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","gold","disco"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","bright","lush"}},
        tom      ={type="Tom",              kw={"bright","punch","disco","room"}},
      },
    },
    { name="80s Pop", default_kw={"linn","707","bright","pop","classic","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"linn","bright","punch","707","classic"}},
        kick_alt ={type="Kick Electronic",  kw={"707","punch","bright","machine"}},
        snare    ={type="Snare Electronic", kw={"linn","bright","wide","classic","707"}},
        snare_alt={type="Snare Electronic", kw={"707","wide","bright","linn","snap"}},
        clap     ={type="Claps & Snaps",    kw={"linn","bright","wide","707","classic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","linn","707","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","linn","707","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","linn","707","machine","wide"}},
        crash    ={type="Crash",            kw={"bright","machine","linn","707"}},
        ride     ={type="Ride",             kw={"bright","machine","linn","707"}},
        perc     ={type="Perc Electronic",  kw={"linn","707","bright","machine","snap"}},
        tom      ={type="Tom",              kw={"linn","707","bright","wide","machine"}},
      },
    },
    { name="Nu Disco", default_kw={"bright","disco","gold","lush","organic","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","disco","deep","lush"}},
        kick_alt ={type="Kick Electronic",  kw={"bright","organic","punch","layered"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","disco","organic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","wide","organic","lush"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","layered","disco","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","disco","lush"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","lush"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","disco","lush"}},
        crash    ={type="Crash",            kw={"bright","acoustic","gold","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","disco"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"bright","punch","disco","lush","room"}},
      },
    },
    { name="Synth Pop", default_kw={"synthetic","linn","707","machine","bright","pop"},
      voices={
        kick     ={type="Kick Electronic",  kw={"synthetic","punch","bright","linn","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"707","synthetic","machine","bright"}},
        snare    ={type="Snare Electronic", kw={"synthetic","linn","bright","snap","machine"}},
        snare_alt={type="Snare Electronic", kw={"707","synthetic","bright","snap","machine"}},
        clap     ={type="Claps & Snaps",    kw={"synthetic","linn","707","snap","machine"}},
        hh_c     ={type="Hihat Closed",     kw={"synthetic","bright","machine","linn"}},
        hh_pedal ={type="Hihat Closed",     kw={"synthetic","bright","machine"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","bright","machine","linn"}},
        crash    ={type="Crash",            kw={"synthetic","bright","machine","707"}},
        ride     ={type="Ride",             kw={"synthetic","bright","machine","linn"}},
        perc     ={type="Perc Electronic",  kw={"synthetic","snap","machine","blip","bright"}},
        tom      ={type="Tom",              kw={"synthetic","linn","707","bright","machine"}},
      },
    },
    { name="R&B", default_kw={"organic","layered","room","bright","lush","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","deep","organic","layered","room"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","deep"}},
        snare    ={type="Snare Electronic", kw={"bright","organic","layered","room","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","snap","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","layered","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","room","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"punch","organic","room","bright","layered"}},
      },
    },
    { name="Dance Pop", default_kw={"bright","punch","synthetic","wide","snap","pop"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","synthetic"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","synthetic","wide"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","snap","punch","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"snap","wide","bright","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","snap","synthetic","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","wide","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","wide"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","snap"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","bright","wide","synthetic"}},
        tom      ={type="Tom",              kw={"bright","wide","punch","synthetic","sub"}},
      },
    },
    { name="Italo Disco", default_kw={"bright","synthetic","machine","wide","lush","disco"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","synthetic","lush","disco"}},
        kick_alt ={type="Kick Electronic",  kw={"bright","synthetic","machine","wide"}},
        snare    ={type="Snare Electronic", kw={"bright","synthetic","wide","machine","snap"}},
        snare_alt={type="Snare Electronic", kw={"wide","bright","synthetic","machine"}},
        clap     ={type="Claps & Snaps",    kw={"bright","synthetic","machine","wide","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","machine","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","machine","wide","lush"}},
        crash    ={type="Crash",            kw={"bright","synthetic","machine","wide"}},
        ride     ={type="Ride",             kw={"bright","synthetic","machine","wide"}},
        perc     ={type="Perc Electronic",  kw={"bright","machine","synthetic","lush","blip"}},
        tom      ={type="Tom",              kw={"bright","synthetic","machine","wide","lush"}},
      },
    },
    { name="Dream Pop", default_kw={"soft","lush","bright","wide","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","organic","sub","lush","wide"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","room","organic","wide"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","wide","lush"}},
        snare_alt={type="Snare Electronic", kw={"soft","organic","layered","wide","bright"}},
        clap     ={type="Claps & Snaps",    kw={"soft","bright","organic","wide","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","acoustic","wide"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","wide","organic"}},
        crash    ={type="Crash",            kw={"soft","bright","wide","organic","mallet"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","wide","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","bright","wide"}},
        tom      ={type="Tom",              kw={"soft","organic","wide","lush","bright"}},
      },
    },
    { name="Europop", default_kw={"bright","synthetic","wide","machine","pop","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","synthetic","wide","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"bright","wide","synthetic","punch"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","synthetic","machine","snap"}},
        snare_alt={type="Snare Electronic", kw={"bright","wide","snap","machine"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","synthetic","machine","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","machine","tight","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","machine","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","machine","wide"}},
        crash    ={type="Crash",            kw={"bright","synthetic","machine","wide"}},
        ride     ={type="Ride",             kw={"bright","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"bright","snap","machine","blip","wide"}},
        tom      ={type="Tom",              kw={"bright","synthetic","machine","wide","punch"}},
      },
    },
    { name="Funk Pop", default_kw={"punch","bright","snap","organic","lush","funk"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","organic","lush","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","room","organic","punch"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","punch","organic","layered"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","punch","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","gold","wide"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room","wide"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","snap"}},
        tom      ={type="Tom",              kw={"bright","punch","organic","room","lush"}},
      },
    },
    { name="Electro Pop", default_kw={"bright","synthetic","machine","wide","snap","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","synthetic","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"bright","punch","wide","machine"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","wide","synthetic","punch"}},
        snare_alt={type="Snare Electronic", kw={"bright","wide","snap","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","wide","synthetic","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","wide","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","machine"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","machine"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","machine"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","synthetic","wide","machine"}},
        tom      ={type="Tom",              kw={"bright","wide","punch","synthetic","machine"}},
      },
    },
    { name="Indie Pop", default_kw={"organic","bright","room","acoustic","wide","lush"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","bright","wide"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","bright","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","wide","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","wide","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","room","wide","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","room","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","wide","room"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","wide"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","wide","lush"}},
        tom      ={type="Tom",              kw={"organic","bright","room","wide","punch"}},
      },
    },
    { name="Cosmic Disco", default_kw={"lush","bright","disco","wide","organic","gold"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","disco","wide","lush"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","room","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","wide","lush"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","wide","organic","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","lush","wide","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","wide","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","gold","wide","organic"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","lush","gold"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","wide","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush","wide"}},
        tom      ={type="Tom",              kw={"bright","wide","organic","lush","punch"}},
      },
    },
    { name="Power Pop", default_kw={"bright","punch","wide","room","organic","hard"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","bright","room","heavy","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","hard","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","punch","room","organic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","organic","room","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","punch","organic","snap","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","room","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","wide"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","wide"}},
        tom      ={type="Tom",              kw={"punch","bright","room","organic","wide"}},
      },
    },
    { name="Soul Pop", default_kw={"organic","warm","bright","room","lush","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","warm","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","warm","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","warm","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","warm","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","warm","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","warm","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","warm","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","warm","gold"}},
        crash    ={type="Crash",            kw={"bright","organic","room","warm","lush"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","warm"}},
        perc     ={type="Shakers",          kw={"organic","bright","warm","acoustic","lush"}},
        tom      ={type="Tom",              kw={"organic","warm","room","punch","bright"}},
      },
    },
    { name="K-Pop", default_kw={"bright","wide","synthetic","machine","punch","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","synthetic"}},
        kick_alt ={type="Kick Electronic",  kw={"bright","wide","punch","machine"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","wide","punch","synthetic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","snap","wide","room","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","wide","punch","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","wide","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","machine","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","organic"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","synthetic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","wide","synthetic"}},
        tom      ={type="Tom",              kw={"bright","wide","punch","organic","synthetic"}},
      },
    },
    { name="Bossa Pop", default_kw={"organic","bright","acoustic","warm","soft","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","organic","room","warm","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","organic","warm","sub"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","organic","room","warm"}},
        snare_alt={type="Snare Acoustic",   kw={"soft","warm","organic","bright","room"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","bright","warm","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic","warm"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","warm"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","organic","warm","bright"}},
        crash    ={type="Crash",            kw={"soft","organic","warm","bright","mallet"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","warm"}},
        perc     ={type="Shakers",          kw={"organic","soft","warm","acoustic","bright"}},
        tom      ={type="Tom",              kw={"soft","organic","warm","room","wide"}},
      },
    },
    { name="Ambient Pop", default_kw={"soft","lush","wide","organic","bright","layered"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","lush","organic","sub","wide"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","organic","room","deep"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","wide"}},
        snare_alt={type="Snare Electronic", kw={"soft","layered","organic","lush"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","bright","wide","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","wide","organic"}},
        crash    ={type="Crash",            kw={"soft","wide","organic","mallet","lush"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","wide"}},
        perc     ={type="Shakers",          kw={"organic","soft","wide","lush","acoustic"}},
        tom      ={type="Tom",              kw={"soft","wide","organic","lush","room"}},
      },
    },
    { name="Hip Hop Pop", default_kw={"punch","bright","organic","synthetic","wide","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","sub","organic","wide"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","bright","organic"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","wide","organic","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","snap","organic","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","wide","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","organic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","organic","wide","room","synthetic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","organic","wide"}},
        perc     ={type="Shakers",          kw={"organic","bright","wide","acoustic"}},
        tom      ={type="Tom",              kw={"punch","bright","organic","wide","sub"}},
      },
    },
  }},
  -- ── Rap ───────────────────────────────────────────────────────────────────
  { name="Rap", variants={
    { name="Trap / 808", default_kw={"808","heavy","snap","hard","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","sub","bass","deep","boom"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","bass","heavy"}},
        snare    ={type="Snare Electronic", kw={"heavy","808","punch","hard","snap"}},
        snare_alt={type="Snare Electronic", kw={"808","snap","heavy","drum"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","snap","808","hard"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","synthetic","808","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","808","synthetic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"noise","heavy","808","synthetic"}},
        crash    ={type="Crash",            kw={"synth","808","noise","heavy"}},
        ride     ={type="Ride",             kw={"synth","808","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","808","hard"}},
        tom      ={type="Tom",              kw={"808","heavy","sub","deep"}},
      },
    },
    { name="Boom Bap", default_kw={"room","punch","vintage","snap","organic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","hard","deep","vintage"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","punch","deep","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"room","bright","snap","punch","pop"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","punch","hard"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","organic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","vintage","room","old"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","vintage","old"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","vintage","room","old"}},
        crash    ={type="Crash",            kw={"acoustic","room","organic","vintage"}},
        ride     ={type="Ride",             kw={"acoustic","room","vintage"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","vintage"}},
        tom      ={type="Tom",              kw={"room","punch","vintage","organic"}},
      },
    },
    { name="UK Drill", default_kw={"808","dark","heavy","synthetic","dirty","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","sub","heavy","dark","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"808","heavy","dark","sub","dirty"}},
        snare    ={type="Snare Electronic", kw={"heavy","dark","noise","808","dirty"}},
        snare_alt={type="Snare Electronic", kw={"dark","heavy","noise","synthetic","dirty"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","dark","noise","808","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"synthetic","dark","noise","tight","808"}},
        hh_pedal ={type="Hihat Closed",     kw={"synthetic","dark","noise","tight"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","dark","noise","heavy"}},
        crash    ={type="Crash",            kw={"synthetic","dark","noise","heavy"}},
        ride     ={type="Ride",             kw={"synthetic","dark","noise"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","dark","noise","synthetic"}},
        tom      ={type="Tom",              kw={"heavy","dark","808","sub","deep"}},
      },
    },
    { name="Cloud Rap", default_kw={"soft","lush","layered","vintage","organic","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"soft","sub","lush","organic","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","soft","deep","layered"}},
        snare    ={type="Snare Electronic", kw={"soft","lush","layered","organic","vintage"}},
        snare_alt={type="Snare Electronic", kw={"layered","soft","lush","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"soft","layered","lush","organic","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","synthetic","bright","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","synthetic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"soft","synthetic","bright","lush"}},
        crash    ={type="Crash",            kw={"soft","mallet","organic","lush"}},
        ride     ={type="Ride",             kw={"soft","synthetic","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","lush","vintage"}},
        tom      ={type="Tom",              kw={"soft","lush","organic","sub","deep"}},
      },
    },
    { name="Southern", default_kw={"heavy","808","punch","snap","hard","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","sub","punch","bass"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","808","sub","boom"}},
        snare    ={type="Snare Electronic", kw={"heavy","snap","punch","808","hard"}},
        snare_alt={type="Snare Electronic", kw={"snap","heavy","hard","punch"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","snap","punch","hard","808"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","snap","synthetic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","snap","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"heavy","synthetic","noise","snap"}},
        crash    ={type="Crash",            kw={"synthetic","heavy","noise","808"}},
        ride     ={type="Ride",             kw={"synthetic","heavy","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","heavy","808","hard"}},
        tom      ={type="Tom",              kw={"heavy","808","sub","deep","hard"}},
      },
    },
    { name="G-Funk", default_kw={"808","sub","organic","soft","lush","vintage"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","sub","deep","organic","soft"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","soft","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","soft","snap"}},
        snare_alt={type="Snare Electronic", kw={"organic","soft","808","bright","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","soft","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","organic","soft","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","gold","soft"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","organic","soft","lush"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","soft"}},
        ride     ={type="Ride",             kw={"bright","acoustic","gold","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","soft"}},
        tom      ={type="Tom",              kw={"808","soft","organic","sub","deep"}},
      },
    },
    { name="Phonk", default_kw={"lofi","dirty","vintage","heavy","tape","808"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","dirty","sub","lofi"}},
        kick_alt ={type="Kick Electronic",  kw={"808","heavy","dirty","lofi","tape"}},
        snare    ={type="Snare Acoustic",   kw={"lofi","dirty","tape","vintage","room"}},
        snare_alt={type="Snare Electronic", kw={"dirty","lofi","heavy","noise","tape"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","dirty","tape","vintage","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","tape","metallic","vintage","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","tape","vintage","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","tape","heavy","metallic","noise"}},
        crash    ={type="Crash",            kw={"lofi","organic","tape","noise","heavy"}},
        ride     ={type="Ride",             kw={"lofi","metallic","tape","vintage"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","dirty","lofi","noise"}},
        tom      ={type="Tom",              kw={"heavy","lofi","808","dirty","sub"}},
      },
    },
    { name="East Coast", default_kw={"organic","punch","room","bright","vintage","jazz"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","organic","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"room","bright","organic","flam","punch"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","gold","room","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","gold","room"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","gold","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","vintage"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","vintage"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"room","organic","punch","bright","acoustic"}},
      },
    },
    { name="Memphis", default_kw={"lofi","dark","dirty","tape","heavy","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","dark","lofi","sub","dirty"}},
        kick_alt ={type="Kick Electronic",  kw={"dark","heavy","lofi","noise"}},
        snare    ={type="Snare Acoustic",   kw={"lofi","dark","tape","dirty","room"}},
        snare_alt={type="Snare Electronic", kw={"dirty","lofi","dark","noise","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","dark","dirty","organic","tape"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","dark","tape","metallic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","dark","tape","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","dark","tape","heavy","noise"}},
        crash    ={type="Crash",            kw={"dark","lofi","organic","noise","tape"}},
        ride     ={type="Ride",             kw={"dark","lofi","metallic","tape"}},
        perc     ={type="Perc Electronic",  kw={"dark","noise","lofi","snap"}},
        tom      ={type="Tom",              kw={"heavy","dark","lofi","tape","deep"}},
      },
    },
    { name="Chopped & Screwed", default_kw={"heavy","lofi","tape","sub","dark"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","sub","deep","lofi","tape"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","heavy","dark","lofi"}},
        snare    ={type="Snare Acoustic",   kw={"room","lofi","tape","organic","heavy"}},
        snare_alt={type="Snare Electronic", kw={"heavy","lofi","dark","tape","sub"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","tape","organic","heavy","dark"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","tape","metallic","dark","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","tape","dark","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","tape","heavy","dark","metallic"}},
        crash    ={type="Crash",            kw={"lofi","organic","tape","dark"}},
        ride     ={type="Ride",             kw={"lofi","dark","metallic","tape"}},
        perc     ={type="Shakers",          kw={"organic","lofi","tape","dark"}},
        tom      ={type="Tom",              kw={"heavy","sub","dark","lofi","deep"}},
      },
    },
    { name="Conscious", default_kw={"organic","bright","room","acoustic","vintage","warm"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","room","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","flam","soft"}},
        snare_alt={type="Snare Acoustic",   kw={"room","bright","organic","flam","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","gold","room","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","gold","room"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","gold","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","vintage"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"room","organic","bright","acoustic","punch"}},
      },
    },
    { name="West Coast", default_kw={"organic","bright","room","soft","808","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","sub","soft","organic","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","snap","soft"}},
        snare_alt={type="Snare Acoustic",   kw={"snap","bright","room","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","room","soft"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","organic","soft","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","gold","soft"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","organic","soft","wide"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room","soft"}},
        ride     ={type="Ride",             kw={"bright","acoustic","gold","organic","soft"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","soft"}},
        tom      ={type="Tom",              kw={"808","soft","organic","room","bright"}},
      },
    },
    { name="Crunk", default_kw={"heavy","punch","808","hard","bright","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","sub","punch","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"808","heavy","sub","dark"}},
        snare    ={type="Snare Electronic", kw={"heavy","punch","snap","hard","bright"}},
        snare_alt={type="Snare Electronic", kw={"heavy","snap","hard","punch"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","snap","hard","punch","808"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","808","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","808","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","808","heavy"}},
        crash    ={type="Crash",            kw={"bright","heavy","synthetic","808"}},
        ride     ={type="Ride",             kw={"synthetic","808","bright"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","bright","hard"}},
        tom      ={type="Tom",              kw={"heavy","808","sub","punch","deep"}},
      },
    },
    { name="Hyphy", default_kw={"bright","punch","snap","machine","sub","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","sub","wide","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","bright","808"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","punch","wide","machine"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","wide","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","wide","punch","machine"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","wide","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","machine"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","machine"}},
        ride     ={type="Ride",             kw={"bright","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","wide","machine"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","sub","machine"}},
      },
    },
    { name="Industrial Hip Hop", default_kw={"heavy","noise","machine","hard","dark","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","hard","noise","sub","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","noise","dark","hard"}},
        snare    ={type="Snare Electronic", kw={"heavy","noise","hard","machine","punch"}},
        snare_alt={type="Snare Electronic", kw={"noise","hard","heavy","machine"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","noise","hard","machine","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","noise","hard","tight","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","noise","hard"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","noise","heavy","hard"}},
        crash    ={type="Crash",            kw={"noise","metallic","hard","heavy","dark"}},
        ride     ={type="Ride",             kw={"metallic","noise","hard","dark"}},
        perc     ={type="Perc Electronic",  kw={"noise","hard","machine","metallic"}},
        tom      ={type="Tom",              kw={"heavy","noise","hard","dark","deep"}},
      },
    },
    { name="Horrorcore", default_kw={"dark","heavy","noise","lofi","dirty","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"dark","heavy","sub","noise","dirty"}},
        kick_alt ={type="Kick Electronic",  kw={"dark","heavy","noise","sub"}},
        snare    ={type="Snare Electronic", kw={"dark","noise","heavy","dirty","hard"}},
        snare_alt={type="Snare Electronic", kw={"dark","heavy","noise","dirty"}},
        clap     ={type="Claps & Snaps",    kw={"dark","noise","heavy","dirty","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","metallic","noise","lofi"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","metallic","noise"}},
        hh_o     ={type="HiHat Open",       kw={"dark","noise","metallic","heavy"}},
        crash    ={type="Crash",            kw={"dark","noise","metallic","heavy"}},
        ride     ={type="Ride",             kw={"dark","metallic","noise"}},
        perc     ={type="Perc Electronic",  kw={"dark","noise","metallic","hard"}},
        tom      ={type="Tom",              kw={"dark","heavy","noise","sub","deep"}},
      },
    },
    { name="Alternative Hip Hop", default_kw={"organic","creative","bright","room","layered","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","organic","bright","sub","layered"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","wide","layered"}},
        snare_alt={type="Snare Electronic", kw={"bright","creative","organic","layered"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","creative","wide","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","creative","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","wide"}},
        crash    ={type="Crash",            kw={"bright","organic","room","creative","wide"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","creative"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","creative"}},
        tom      ={type="Tom",              kw={"organic","bright","room","wide","punch"}},
      },
    },
    { name="Bounce", default_kw={"punch","bright","snap","machine","808","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","punch","sub","heavy","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"808","heavy","sub","punch"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","punch","808","heavy"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","punch","808"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","808","punch","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","808","machine","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","808","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","808","synthetic","heavy"}},
        crash    ={type="Crash",            kw={"bright","808","synthetic","heavy"}},
        ride     ={type="Ride",             kw={"bright","808","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","bright","punch"}},
        tom      ={type="Tom",              kw={"808","heavy","sub","punch","deep"}},
      },
    },
    { name="Midwest", default_kw={"organic","room","bright","punch","vintage","warm"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","organic","bright","sub","room"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","punch","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","room","punch","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","organic","room","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","organic","room"}},
        crash    ={type="Crash",            kw={"bright","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"acoustic","bright","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","bright","warm"}},
        tom      ={type="Tom",              kw={"organic","room","punch","bright","vintage"}},
      },
    },
    { name="Experimental Hip Hop", default_kw={"noise","creative","organic","synthetic","layered","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"synthetic","noise","creative","sub","punch"}},
        kick_alt ={type="Kick Acoustic",    kw={"organic","lofi","creative","punch"}},
        snare    ={type="Snare Electronic", kw={"noise","creative","synthetic","bright","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"creative","organic","lofi","bright"}},
        clap     ={type="Claps & Snaps",    kw={"creative","noise","organic","bright","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"creative","noise","synthetic","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"creative","noise","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"creative","noise","synthetic","wide"}},
        crash    ={type="Crash",            kw={"noise","creative","organic","wide","metallic"}},
        ride     ={type="Ride",             kw={"creative","noise","synthetic","organic"}},
        perc     ={type="Perc Glitch",      kw={"noise","creative","synthetic","organic"}},
        tom      ={type="Tom",              kw={"synthetic","noise","creative","organic","deep"}},
      },
    },
  }},
  -- ── Acoustic ──────────────────────────────────────────────────────────────
  { name="Acoustic", variants={
    { name="Studio", default_kw={"bright","room","acoustic","live","organic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","bright","room","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","deep","acoustic","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","snap","organic"}},
        snare_alt={type="Snare Acoustic",   kw={"room","organic","bright","wide"}},
        clap     ={type="Claps & Snaps",    kw={"acoustic","room","organic","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","room","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","room","bright"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","room","organic"}},
        crash    ={type="Crash",            kw={"acoustic","bright","room","organic"}},
        ride     ={type="Ride",             kw={"acoustic","bright","room","organic"}},
        perc     ={type="Perc Acoustic",    kw={"hand","drum","organic","acoustic"}},
        tom      ={type="Tom",              kw={"acoustic","bright","room","organic"}},
      },
    },
    { name="Live", default_kw={"wide","live","room","organic","flam"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"wide","room","live","heavy","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","live","deep"}},
        snare    ={type="Snare Acoustic",   kw={"room","wide","organic","flam","live"}},
        snare_alt={type="Snare Acoustic",   kw={"room","live","organic","bright"}},
        clap     ={type="Claps & Snaps",    kw={"organic","room","acoustic","live"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","room","live","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","live","room"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","room","live","organic"}},
        crash    ={type="Crash",            kw={"acoustic","room","organic","live"}},
        ride     ={type="Ride",             kw={"acoustic","room","live","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","hand","djembe","live"}},
        tom      ={type="Tom",              kw={"wide","room","organic","skin","live"}},
      },
    },
    { name="Brushed Jazz", default_kw={"soft","organic","room","gold","bright","brush"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","deep","organic","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","soft","organic","deep"}},
        snare    ={type="Snare Acoustic",   kw={"soft","room","organic","bright","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"room","soft","organic","flam"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","gold","acoustic","bright","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","gold","acoustic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"soft","gold","acoustic","bright","room"}},
        crash    ={type="Crash",            kw={"soft","acoustic","room","bright","organic"}},
        ride     ={type="Ride",             kw={"soft","gold","acoustic","bright","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","soft","room","acoustic"}},
        tom      ={type="Tom",              kw={"soft","organic","room","acoustic","deep"}},
      },
    },
    { name="Room Mic", default_kw={"wide","room","organic","heavy","live","flam"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"wide","room","heavy","organic","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","wide","organic","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"wide","room","organic","bright","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"room","wide","organic","flam","live"}},
        clap     ={type="Claps & Snaps",    kw={"organic","wide","room","acoustic","live"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","room","bright","wide","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","room","bright","wide"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","room","bright","wide","organic"}},
        crash    ={type="Crash",            kw={"acoustic","wide","room","organic","bright"}},
        ride     ={type="Ride",             kw={"acoustic","room","bright","wide"}},
        perc     ={type="Perc Acoustic",    kw={"organic","room","wide","acoustic"}},
        tom      ={type="Tom",              kw={"wide","room","organic","heavy","live"}},
      },
    },
    { name="Vintage", default_kw={"tape","vinyl","lofi","room","organic","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"room","organic","vintage","tape","heavy"}},
        kick_alt ={type="Kick Acoustic",    kw={"tape","organic","room","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"room","organic","bright","tape","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"tape","vinyl","organic","room","bright"}},
        clap     ={type="Claps & Snaps",    kw={"tape","vinyl","organic","room","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"tape","vinyl","acoustic","bright","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tape","vinyl","acoustic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"tape","vinyl","acoustic","organic","bright"}},
        crash    ={type="Crash",            kw={"acoustic","tape","room","organic","vintage"}},
        ride     ={type="Ride",             kw={"acoustic","tape","bright","vintage","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","room","vintage","acoustic"}},
        tom      ={type="Tom",              kw={"room","organic","tape","vintage","deep"}},
      },
    },
    { name="Folk / Americana", default_kw={"lofi","tape","organic","room","vintage","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"room","organic","soft","deep","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"organic","room","vintage","deep"}},
        snare    ={type="Snare Acoustic",   kw={"room","organic","bright","tape","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","soft","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","room","bright","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","organic","room","tape"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","organic","vintage"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","organic","room"}},
        crash    ={type="Crash",            kw={"acoustic","room","organic","soft","vintage"}},
        ride     ={type="Ride",             kw={"acoustic","bright","room","organic","vintage"}},
        perc     ={type="Perc Acoustic",    kw={"organic","room","acoustic","sticks","vintage"}},
        tom      ={type="Tom",              kw={"room","organic","soft","deep","vintage"}},
      },
    },
    { name="Gospel", default_kw={"wide","heavy","bright","room","organic","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","room","organic","wide","punch"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","wide","organic","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"wide","room","bright","organic","heavy"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","room","organic","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","wide","bright","room","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","wide","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","wide","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","wide","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","wide","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","wide","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","wide","bright","acoustic"}},
        tom      ={type="Tom",              kw={"wide","room","organic","heavy","bright"}},
      },
    },
    { name="Jazz Combo", default_kw={"organic","bright","room","gold","soft"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","deep","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","soft","organic","deep"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","soft","flam","organic"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","acoustic","room","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","gold","acoustic","bright","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","gold","acoustic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"soft","gold","acoustic","bright","room"}},
        crash    ={type="Crash",            kw={"soft","acoustic","room","bright","organic"}},
        ride     ={type="Ride",             kw={"soft","gold","acoustic","bright","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","soft","room","acoustic","bright"}},
        tom      ={type="Tom",              kw={"soft","organic","room","bright","acoustic"}},
      },
    },
    { name="Afro Cuban", default_kw={"bright","organic","room","bongo","conga","metallic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","bright","room","organic","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","sub","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","flam","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"flam","bright","room","organic","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","snap","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","metallic","organic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room","metallic"}},
        ride     ={type="Ride",             kw={"bright","gold","metallic","acoustic","room"}},
        perc     ={type="Perc Acoustic",    kw={"bongo","conga","bright","organic","acoustic"}},
        tom      ={type="Tom",              kw={"organic","bright","room","punch","acoustic"}},
      },
    },
    { name="Marching", default_kw={"bright","wide","punch","heavy","crisp"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","wide","punch","room","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"wide","heavy","room","punch"}},
        snare    ={type="Snare Acoustic",   kw={"bright","wide","punch","heavy","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","bright","punch","flam","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","organic","snap","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","wide","acoustic","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","wide","acoustic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","wide","acoustic","organic","metallic"}},
        crash    ={type="Crash",            kw={"bright","wide","acoustic","heavy"}},
        ride     ={type="Ride",             kw={"bright","wide","acoustic","metallic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","wide","bright","sticks"}},
        tom      ={type="Tom",              kw={"wide","bright","heavy","punch"}},
      },
    },
    { name="Bluegrass", default_kw={"bright","punch","organic","acoustic","room","snap"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","bright","room","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","organic","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","organic","room","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","snap","room","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","metallic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room","metallic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","room","deep"}},
      },
    },
    { name="Country", default_kw={"organic","bright","room","acoustic","punch","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","bright","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","organic","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","room","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","gold","organic"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","bright","room"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","room","wide"}},
      },
    },
    { name="Celtic", default_kw={"bright","organic","metallic","acoustic","room","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","deep","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","organic","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","wide","metallic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","wide","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","metallic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","metallic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","room","wide"}},
      },
    },
    { name="Bossa Nova", default_kw={"soft","organic","bright","acoustic","room","warm"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","organic","room","punch","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","organic","warm","sub"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","organic","room","warm"}},
        snare_alt={type="Snare Acoustic",   kw={"soft","bright","organic","warm","room"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","bright","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic","warm"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","warm"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","organic","warm","bright"}},
        crash    ={type="Crash",            kw={"soft","organic","bright","room","mallet"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","warm"}},
        perc     ={type="Shakers",          kw={"organic","soft","warm","acoustic","bright"}},
        tom      ={type="Tom",              kw={"soft","organic","warm","room","punch"}},
      },
    },
    { name="Samba", default_kw={"bright","organic","punch","acoustic","room","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","bright","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","punch","organic","room","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","wide","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","metallic"}},
        crash    ={type="Crash",            kw={"bright","metallic","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","metallic","wide"}},
        tom      ={type="Tom",              kw={"punch","organic","bright","room","wide"}},
      },
    },
    { name="Taiko", default_kw={"heavy","punch","deep","organic","wide","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","punch","deep","organic","wide"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","deep","sub","punch","organic"}},
        snare    ={type="Snare Acoustic",   kw={"heavy","punch","bright","organic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"heavy","organic","wide","punch","room"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","organic","punch","wide","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","heavy","organic"}},
        crash    ={type="Crash",            kw={"bright","metallic","heavy","organic","wide"}},
        ride     ={type="Ride",             kw={"bright","metallic","organic","acoustic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","heavy","wide","punch","acoustic"}},
        tom      ={type="Tom",              kw={"heavy","deep","organic","punch","wide"}},
      },
    },
    { name="Steel Drums", default_kw={"bright","metallic","organic","acoustic","wide","warm"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","organic","room","deep","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","organic","sub","warm"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","metallic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","metallic","organic","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","warm","metallic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","acoustic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","acoustic","wide","mallet"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"metallic","bright","organic","acoustic","wide"}},
        tom      ={type="Tom",              kw={"organic","bright","metallic","wide","room"}},
      },
    },
    { name="Big Band", default_kw={"bright","wide","organic","punch","room","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","bright","room","organic","wide"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","sub","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","punch","room","organic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","wide","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","gold","wide","organic"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","wide","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","wide"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","organic","room"}},
      },
    },
    { name="Waltz", default_kw={"soft","bright","organic","acoustic","room","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","organic","room","bright","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","organic","bright","room"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","organic","room","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"soft","organic","bright","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","bright","room","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"soft","bright","organic","room","mallet"}},
        ride     ={type="Ride",             kw={"soft","bright","acoustic","gold","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","bright","acoustic"}},
        tom      ={type="Tom",              kw={"soft","organic","bright","room","wide"}},
      },
    },
    { name="Orchestral", default_kw={"wide","bright","organic","room","lush","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","organic","room","wide","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","wide","sub","organic","layered"}},
        snare    ={type="Snare Acoustic",   kw={"bright","wide","organic","room","heavy"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","wide","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","wide","room","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","wide","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","wide","organic","metallic"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","metallic"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","wide","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","wide","bright","room","metallic"}},
        tom      ={type="Tom",              kw={"heavy","wide","organic","room","bright"}},
      },
    },
  }},
  -- ── World ─────────────────────────────────────────────────────────────────
  { name="World", variants={
    { name="Organic", default_kw={"organic","djembe","skin","hand","wood","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"organic","deep","room","heavy","wide"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","acoustic","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","metallic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","room","live","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","room","live"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","metallic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","organic","room","live"}},
        crash    ={type="Crash",            kw={"organic","acoustic","room","mallet"}},
        ride     ={type="Ride",             kw={"acoustic","organic","room"}},
        perc     ={type="Perc Acoustic",    kw={"bongo","djembe","hand","organic"}},
        tom      ={type="Tom",              kw={"organic","skin","acoustic","deep","wide"}},
      },
    },
    { name="Latin", default_kw={"organic","acoustic","room","bongo","conga","bright"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","deep","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","snap","organic"}},
        snare_alt={type="Snare Acoustic",   kw={"room","organic","metallic","bright"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","bright","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"bongo","conga","organic","bright"}},
        tom      ={type="Tom",              kw={"organic","room","bright","punch"}},
      },
    },
    { name="African", default_kw={"djembe","hand","skin","organic","deep","heavy"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","heavy","organic","wide","room"}},
        kick_alt ={type="Kick Acoustic",    kw={"deep","room","organic","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","wide","heavy"}},
        snare_alt={type="Snare Acoustic",   kw={"room","organic","live","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","hand","live"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","organic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","heavy","organic","metallic"}},
        crash    ={type="Crash",            kw={"organic","mallet","room","acoustic"}},
        ride     ={type="Ride",             kw={"metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","hand","organic","skin"}},
        tom      ={type="Tom",              kw={"deep","heavy","skin","organic","wide"}},
      },
    },
    { name="Tribal", default_kw={"deep","heavy","skin","organic","wood","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","heavy","wide","organic","room"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","sub","heavy","organic"}},
        snare    ={type="Snare Acoustic",   kw={"heavy","wide","organic","room"}},
        snare_alt={type="Snare Acoustic",   kw={"deep","organic","room","metallic"}},
        clap     ={type="Claps & Snaps",    kw={"organic","heavy","hand","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","heavy","organic","acoustic"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","heavy","organic"}},
        hh_o     ={type="HiHat Open",       kw={"heavy","metallic","organic","acoustic"}},
        crash    ={type="Crash",            kw={"heavy","organic","room","mallet"}},
        ride     ={type="Ride",             kw={"metallic","heavy","organic"}},
        perc     ={type="Perc Acoustic",    kw={"hand","skin","organic","deep"}},
        tom      ={type="Tom",              kw={"deep","heavy","wide","skin","organic"}},
      },
    },
    { name="Brazilian", default_kw={"organic","bright","room","bongo","conga","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","deep","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","snap","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","wide"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","snap","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","gold"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","gold","organic","metallic"}},
        perc     ={type="Perc Acoustic",    kw={"bongo","conga","organic","bright","acoustic"}},
        tom      ={type="Tom",              kw={"organic","bright","room","punch","acoustic"}},
      },
    },
    { name="Caribbean", default_kw={"bright","organic","acoustic","metallic","room","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","bright","organic","room","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","wide","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","organic","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","wide","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","metallic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","metallic"}},
        tom      ={type="Tom",              kw={"organic","bright","room","punch","acoustic"}},
      },
    },
    { name="Flamenco", default_kw={"bright","acoustic","snap","flam","organic","wood"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","bright","organic","room","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"bright","room","punch","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","flam","organic","room"}},
        snare_alt={type="Snare Acoustic",   kw={"snap","bright","organic","flam","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","acoustic","flam"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","metallic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","sticks"}},
        tom      ={type="Tom",              kw={"organic","bright","room","punch","acoustic"}},
      },
    },
    { name="Middle Eastern", default_kw={"metallic","bright","organic","acoustic","room","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","deep","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","deep","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","flam","metallic"}},
        snare_alt={type="Snare Acoustic",   kw={"metallic","bright","organic","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","metallic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"metallic","organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"organic","bright","room","metallic","punch"}},
      },
    },
    { name="Indian / Tabla", default_kw={"organic","bright","metallic","acoustic","room","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","deep","organic","room","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","deep","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","punch","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","bright","metallic","room","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","snap","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","metallic","acoustic","organic"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","metallic","punch"}},
        tom      ={type="Tom",              kw={"organic","bright","room","punch","metallic"}},
      },
    },
    { name="Asian / Gamelan", default_kw={"metallic","bright","wide","organic","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"room","organic","soft","deep","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","deep","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","metallic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"metallic","bright","organic","wide","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","metallic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","wide","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic","wide"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","acoustic","wide","organic"}},
        crash    ={type="Crash",            kw={"bright","metallic","wide","acoustic","organic"}},
        ride     ={type="Ride",             kw={"bright","metallic","wide","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"metallic","bright","acoustic","wide","organic"}},
        tom      ={type="Tom",              kw={"bright","metallic","wide","organic","acoustic"}},
      },
    },
    { name="Celtic / Folk", default_kw={"lofi","organic","room","acoustic","bright"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"room","organic","deep","bright","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"organic","room","deep","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","snap","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","flam","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","snap","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","organic","metallic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","metallic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","organic","wide","metallic"}},
        crash    ={type="Crash",            kw={"acoustic","bright","organic","room","wide"}},
        ride     ={type="Ride",             kw={"acoustic","bright","metallic","organic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","sticks","room"}},
        tom      ={type="Tom",              kw={"organic","bright","room","deep","acoustic"}},
      },
    },
    { name="West African", default_kw={"djembe","organic","wide","deep","bright","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","room","organic","wide","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","deep","organic","wide"}},
        snare    ={type="Snare Acoustic",   kw={"bright","wide","organic","room","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","bright","organic","room","punch"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","wide","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic","wide"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","wide","organic","metallic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","wide","organic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","wide","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","wide","acoustic"}},
        tom      ={type="Tom",              kw={"djembe","organic","wide","deep","bright"}},
      },
    },
    { name="Cumbia", default_kw={"bright","organic","punch","wide","acoustic","metallic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","bright","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","punch","wide","room"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","organic","room","metallic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","punch","wide","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","organic","acoustic","wide"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","metallic","wide"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","wide","room"}},
      },
    },
    { name="Gnawa", default_kw={"deep","organic","metallic","punch","dark","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","organic","punch","room","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","organic","sub","dark","punch"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","deep","punch","metallic"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","punch","room","metallic"}},
        clap     ={type="Claps & Snaps",    kw={"organic","punch","metallic","acoustic","dark"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","organic","bright","acoustic"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","organic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","organic","bright","acoustic"}},
        crash    ={type="Crash",            kw={"metallic","organic","bright","acoustic","room"}},
        ride     ={type="Ride",             kw={"metallic","organic","bright","acoustic"}},
        perc     ={type="Perc Acoustic",    kw={"metallic","organic","bright","acoustic","deep"}},
        tom      ={type="Tom",              kw={"deep","organic","punch","dark","room"}},
      },
    },
    { name="Turkish", default_kw={"bright","metallic","organic","acoustic","wide","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","bright","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","metallic","room","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","metallic","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","metallic","snap","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","gold","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","gold","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","organic","wide","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"metallic","organic","bright","acoustic","wide"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","metallic","wide"}},
      },
    },
    { name="Andean", default_kw={"bright","organic","acoustic","soft","wide","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"organic","punch","room","deep","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"organic","punch","bright","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","wide","soft"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","bright","room","soft","wide"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","soft","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","organic","acoustic","wide","mallet"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","metallic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","metallic","wide"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","room","wide"}},
      },
    },
    { name="Balkan", default_kw={"bright","organic","punch","metallic","acoustic","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","heavy","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","punch","organic","metallic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","punch","metallic","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","punch","metallic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","organic","acoustic","wide"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"metallic","organic","bright","acoustic","punch"}},
        tom      ={type="Tom",              kw={"punch","organic","bright","metallic","wide"}},
      },
    },
    { name="Polynesian", default_kw={"bright","organic","soft","wide","acoustic","metallic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"organic","punch","room","deep","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"organic","punch","bright","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","wide","room","soft"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","bright","wide","room"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","wide","soft"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","organic","wide","mallet"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","metallic","wide"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","wide","room"}},
      },
    },
    { name="Northern African", default_kw={"bright","metallic","organic","acoustic","wide","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","bright","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","metallic","wide","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","metallic","organic","wide","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","metallic","snap","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","organic","acoustic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","organic","wide","acoustic"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","djembe","bright","metallic","wide"}},
        tom      ={type="Tom",              kw={"punch","organic","bright","wide","room"}},
      },
    },
    { name="Eastern European", default_kw={"organic","bright","acoustic","metallic","room","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","bright","heavy"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","organic","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","metallic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","metallic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","metallic","snap","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","gold","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","organic","acoustic","wide"}},
        crash    ={type="Crash",            kw={"bright","metallic","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","metallic","gold","organic","acoustic"}},
        perc     ={type="Perc Acoustic",    kw={"metallic","organic","bright","acoustic","wide"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","metallic","room"}},
      },
    },
  }},
  -- ── Funk ─────────────────────────────────────────────────────────────────────
  { name="Funk", variants={
    { name="Classic", default_kw={"funk","punch","snap","bright","linn","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","sub","funk","snap"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","bright","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","punch","room","funk"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","punch","funk","linn"}},
        clap     ={type="Claps & Snaps",    kw={"funk","bright","snap","organic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","funk"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","gold","funk"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","gold","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"punch","bright","room","organic"}},
      },
    },
    { name="80s Linn", default_kw={"linn","707","bright","pop","classic","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"linn","punch","bright","snap","drum"}},
        kick_alt ={type="Kick Electronic",  kw={"707","punch","bright","machine"}},
        snare    ={type="Snare Electronic", kw={"linn","bright","snap","classic","drum"}},
        snare_alt={type="Snare Electronic", kw={"707","snap","bright","machine","classic"}},
        clap     ={type="Claps & Snaps",    kw={"linn","bright","snap","classic","707"}},
        hh_c     ={type="Hihat Closed",     kw={"707","linn","bright","machine","drum"}},
        hh_pedal ={type="Hihat Closed",     kw={"707","linn","machine","bright"}},
        hh_o     ={type="HiHat Open",       kw={"707","linn","bright","machine"}},
        crash    ={type="Crash",            kw={"bright","machine","707","linn"}},
        ride     ={type="Ride",             kw={"bright","machine","707","linn"}},
        perc     ={type="Perc Electronic",  kw={"linn","707","bright","snap","machine"}},
        tom      ={type="Tom",              kw={"linn","707","bright","machine","punch"}},
      },
    },
    { name="Miami Bass", default_kw={"miami","808","sub","bass","heavy","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"miami","808","sub","bass","deep","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","bass","boom","deep"}},
        snare    ={type="Snare Electronic", kw={"heavy","snap","punch","808","bright"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","snap","punch","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","heavy","808","pop"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","tight","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","wide","pop"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","pop"}},
        ride     ={type="Ride",             kw={"bright","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic"}},
        tom      ={type="Tom",              kw={"808","heavy","sub","deep"}},
      },
    },
    { name="New Jack Swing", default_kw={"linn","snap","punch","bright","layered","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"linn","punch","bright","snap","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","snap","bright","machine"}},
        snare    ={type="Snare Electronic", kw={"linn","snap","bright","punch","layered"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","layered","linn","punch"}},
        clap     ={type="Claps & Snaps",    kw={"linn","snap","bright","punch","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","linn","synthetic","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","linn","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","linn","machine"}},
        crash    ={type="Crash",            kw={"bright","synthetic","linn","machine"}},
        ride     ={type="Ride",             kw={"bright","synthetic","linn","machine"}},
        perc     ={type="Perc Electronic",  kw={"linn","snap","bright","blip","machine"}},
        tom      ={type="Tom",              kw={"linn","punch","bright","machine","snap"}},
      },
    },
    { name="P-Funk", default_kw={"heavy","organic","room","punch","bright","funk"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","heavy","room","organic","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","punch","sub","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","punch","organic","heavy","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"room","bright","organic","flam","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","room","heavy","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","room","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","room","organic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","wide"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"punch","heavy","organic","room","bright"}},
      },
    },
    { name="Neo Soul", default_kw={"lofi","organic","soft","room","punch","flam"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","soft","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","organic","lofi","soft"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","flam","soft"}},
        snare_alt={type="Snare Acoustic",   kw={"flam","bright","room","organic","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","soft","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","soft"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","soft"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic","soft"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","soft"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","soft","bright","acoustic"}},
        tom      ={type="Tom",              kw={"room","organic","soft","punch","bright"}},
      },
    },
    { name="Boogie", default_kw={"bright","organic","punch","room","lush","disco"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","organic","lush","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"snap","bright","room","organic","lush"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","room","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","wide"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"bright","punch","room","organic","lush"}},
      },
    },
    { name="Electro Funk", default_kw={"808","machine","synthetic","bright","snap","funk"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","sub","machine","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"808","machine","synthetic","punch"}},
        snare    ={type="Snare Electronic", kw={"808","machine","snap","bright","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"snap","808","bright","machine"}},
        clap     ={type="Claps & Snaps",    kw={"808","snap","machine","bright","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"808","machine","tight","bright","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"808","machine","tight","bright"}},
        hh_o     ={type="HiHat Open",       kw={"808","machine","synthetic","bright"}},
        crash    ={type="Crash",            kw={"808","machine","bright","synthetic"}},
        ride     ={type="Ride",             kw={"machine","808","bright","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","machine","blip","bright"}},
        tom      ={type="Tom",              kw={"808","machine","bright","sub","deep"}},
      },
    },
    { name="Afrofunk", default_kw={"djembe","organic","bright","punch","room","funk"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","wide","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"punch","bright","organic","room","snap"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","snap","room","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","metallic","wide"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","acoustic","punch"}},
        tom      ={type="Tom",              kw={"organic","bright","punch","room","deep"}},
      },
    },
    { name="Deep Funk", default_kw={"heavy","organic","room","punch","vintage","deep"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","punch","room","organic","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","punch","sub","organic","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","heavy","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"room","heavy","bright","organic","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","punch","room","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","wide"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"heavy","punch","organic","room","deep"}},
      },
    },
    { name="Southern Soul", default_kw={"warm","organic","room","bright","punch","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","warm","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","warm","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","warm","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","warm","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","warm","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","warm","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","warm","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","warm","gold"}},
        crash    ={type="Crash",            kw={"bright","organic","room","warm","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","warm","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","warm","acoustic"}},
        tom      ={type="Tom",              kw={"organic","warm","room","punch","deep"}},
      },
    },
    { name="Jazz Funk", default_kw={"organic","bright","room","gold","punch","lush"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","bright","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","punch","gold"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","punch","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","room","snap","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","gold","organic","room"}},
        crash    ={type="Crash",            kw={"bright","organic","room","gold","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","gold"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","room","gold"}},
      },
    },
    { name="Rare Groove", default_kw={"vinyl","dirty","organic","room","bright","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","vintage","dirty"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","vintage","lofi"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","punch","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","vintage","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","vintage","snap","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","vintage","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","vintage","gold","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","vintage","organic"}},
        crash    ={type="Crash",            kw={"organic","bright","vintage","room","gold"}},
        ride     ={type="Ride",             kw={"acoustic","vintage","gold","bright","organic"}},
        perc     ={type="Shakers",          kw={"organic","acoustic","vintage","bright"}},
        tom      ={type="Tom",              kw={"organic","punch","vintage","room","bright"}},
      },
    },
    { name="Funk Rock", default_kw={"heavy","punch","bright","organic","room","hard"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","heavy","room","organic","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","heavy","hard","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","punch","room","organic","heavy"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","heavy","organic","room","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","heavy","organic","punch","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","room","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","heavy","organic","room"}},
        crash    ={type="Crash",            kw={"bright","heavy","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"heavy","punch","organic","room","bright"}},
      },
    },
    { name="Parliament", default_kw={"heavy","deep","sub","organic","punch","layered"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","deep","sub","organic","layered"}},
        kick_alt ={type="Kick Acoustic",    kw={"heavy","organic","room","punch","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","heavy","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","heavy","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","heavy","bright","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","gold","organic","heavy"}},
        crash    ={type="Crash",            kw={"bright","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"heavy","deep","organic","sub","punch"}},
      },
    },
    { name="Synth Funk", default_kw={"bright","synthetic","machine","punch","snap","linn"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","synthetic","linn","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","machine","bright","linn"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","linn","machine","punch"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","machine","linn"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","linn","machine","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","machine","linn","synthetic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","machine","linn","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","machine","linn","synthetic"}},
        crash    ={type="Crash",            kw={"bright","synthetic","machine","organic"}},
        ride     ={type="Ride",             kw={"bright","machine","synthetic","linn"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","linn","machine","synthetic"}},
        tom      ={type="Tom",              kw={"bright","punch","linn","machine","organic"}},
      },
    },
    { name="Future Funk", default_kw={"bright","disco","synthetic","wide","lush","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","disco","wide","lush"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","wide","sub"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","snap","synthetic","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","wide","organic","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","snap","synthetic","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","wide","machine","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","wide","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","disco"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","lush","organic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","gold"}},
        perc     ={type="Shakers",          kw={"organic","bright","wide","synthetic","lush"}},
        tom      ={type="Tom",              kw={"bright","wide","punch","organic","lush"}},
      },
    },
    { name="Groove Minimal", default_kw={"tight","organic","bright","room","punch","soft"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tight","punch","organic","bright","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","tight"}},
        snare    ={type="Snare Acoustic",   kw={"bright","tight","organic","room","snap"}},
        snare_alt={type="Snare Electronic", kw={"tight","bright","snap","organic"}},
        clap     ={type="Claps & Snaps",    kw={"tight","bright","organic","snap","room"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","acoustic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","tight","organic"}},
        crash    ={type="Crash",            kw={"bright","organic","room","soft","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","tight","organic"}},
        perc     ={type="Shakers",          kw={"organic","tight","bright","acoustic"}},
        tom      ={type="Tom",              kw={"tight","organic","bright","room","punch"}},
      },
    },
    { name="Dub Funk", default_kw={"deep","dark","heavy","organic","room","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","heavy","sub","dark","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"deep","heavy","organic","room"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","heavy","bright","wide"}},
        snare_alt={type="Snare Electronic", kw={"heavy","dark","organic","layered"}},
        clap     ={type="Claps & Snaps",    kw={"organic","heavy","dark","room","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","metallic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","metallic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"dark","metallic","heavy","organic"}},
        crash    ={type="Crash",            kw={"dark","organic","room","heavy","metallic"}},
        ride     ={type="Ride",             kw={"dark","metallic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","dark","room","acoustic"}},
        tom      ={type="Tom",              kw={"deep","dark","heavy","organic","sub"}},
      },
    },
    { name="Hip Hop Funk", default_kw={"punch","organic","room","bright","vintage","funk"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","organic","room","bright","sub"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","punch","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","punch","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","gold"}},
        crash    ={type="Crash",            kw={"bright","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","snap"}},
        tom      ={type="Tom",              kw={"punch","organic","bright","room","vintage"}},
      },
    },
  }},
  -- ── Jazz ──────────────────────────────────────────────────────────────────────
  { name="Jazz", variants={
    { name="Brushed", default_kw={"organic","room","soft","acoustic","flam","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","deep","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","soft","deep"}},
        snare    ={type="Snare Acoustic",   kw={"room","organic","soft","bright","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","flam","soft"}},
        clap     ={type="Claps & Snaps",    kw={"organic","soft","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","soft","bright","gold","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","soft","bright","gold"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","soft","bright","gold","room"}},
        crash    ={type="Crash",            kw={"acoustic","room","bright","organic","soft"}},
        ride     ={type="Ride",             kw={"acoustic","bright","gold","room","soft"}},
        perc     ={type="Perc Acoustic",    kw={"organic","soft","room","acoustic"}},
        tom      ={type="Tom",              kw={"acoustic","room","organic","soft","deep"}},
      },
    },
    { name="Bebop", default_kw={"bright","acoustic","room","organic","gold","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","deep","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","bright","punch"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","snap","punch","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","flam","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"acoustic","room","bright","organic","punch"}},
      },
    },
    { name="Latin Jazz", default_kw={"organic","bright","room","flam","bongo","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","deep","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","flam","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"flam","bright","organic","room","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","acoustic","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Perc Acoustic",    kw={"bongo","conga","organic","bright","acoustic"}},
        tom      ={type="Tom",              kw={"organic","bright","room","punch","acoustic"}},
      },
    },
    { name="Fusion", default_kw={"punch","bright","organic","layered","room","synthetic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","bright","room","organic","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","sub","organic","tight"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","punch","organic","flam"}},
        snare_alt={type="Snare Electronic", kw={"punch","bright","organic","synthetic","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"punch","bright","organic","room","acoustic"}},
      },
    },
    { name="Cool Jazz", default_kw={"soft","organic","room","vintage","acoustic","bright"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","deep","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","soft","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"room","soft","organic","bright","flam"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","acoustic","room","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","gold","acoustic","bright","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","gold","acoustic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"soft","gold","acoustic","bright","organic"}},
        crash    ={type="Crash",            kw={"soft","acoustic","room","bright","organic"}},
        ride     ={type="Ride",             kw={"soft","gold","acoustic","room","bright"}},
        perc     ={type="Perc Acoustic",    kw={"organic","soft","room","acoustic"}},
        tom      ={type="Tom",              kw={"soft","organic","room","acoustic","vintage"}},
      },
    },
    { name="Swing", default_kw={"bright","wide","gold","organic","room","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","wide"}},
        kick_alt ={type="Kick Acoustic",    kw={"wide","room","organic","punch"}},
        snare    ={type="Snare Acoustic",   kw={"bright","wide","room","organic","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","bright","room","organic","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","wide","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","wide","room"}},
        crash    ={type="Crash",            kw={"bright","wide","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","wide","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","room","acoustic","wide"}},
        tom      ={type="Tom",              kw={"wide","bright","organic","room","punch"}},
      },
    },
    { name="Free Jazz", default_kw={"noise","creative","organic","room","bright"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"room","organic","heavy","punch","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","creative","heavy","punch"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","creative","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"creative","bright","room","organic","noise"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","noise","creative","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","creative","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic","creative"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","noise","wide"}},
        crash    ={type="Crash",            kw={"bright","noise","creative","organic","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","organic","creative","noise"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","noise","creative","acoustic"}},
        tom      ={type="Tom",              kw={"creative","organic","bright","noise","room"}},
      },
    },
    { name="Bossa Nova", default_kw={"soft","bright","organic","room","acoustic","light"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","deep","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","soft","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","soft","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"soft","bright","organic","acoustic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","bright","gold","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","bright","gold","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","bright","gold","acoustic","room"}},
        crash    ={type="Crash",            kw={"soft","bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"soft","bright","gold","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","soft","bright","acoustic"}},
        tom      ={type="Tom",              kw={"soft","organic","room","acoustic","bright"}},
      },
    },
    { name="Acid Jazz", default_kw={"punch","organic","bright","room","lush","funk"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","organic","bright","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"snap","bright","room","punch","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","snap","room","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","wide"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"punch","organic","room","bright","lush"}},
      },
    },
    { name="Modal", default_kw={"organic","room","soft","bright","gold"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","deep","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","soft","deep"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","soft","organic"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","bright","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","gold","bright","acoustic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","gold","bright","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","gold","bright","acoustic","room"}},
        crash    ={type="Crash",            kw={"soft","bright","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"soft","gold","bright","acoustic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","soft","acoustic","room","bright"}},
        tom      ={type="Tom",              kw={"soft","organic","room","bright","acoustic"}},
      },
    },
    { name="Hard Bop", default_kw={"punch","bright","organic","room","snap","gold"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","room","organic"}},
        snare    ={type="Snare Acoustic",   kw={"snap","bright","punch","room","organic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","snap","punch","flam","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","tight","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","wide"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","room","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","room","acoustic","snap"}},
        tom      ={type="Tom",              kw={"punch","bright","organic","room","acoustic"}},
      },
    },
    { name="Dixieland", default_kw={"vintage","wide","organic","bright","room","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"wide","room","organic","deep","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","wide","vintage"}},
        snare    ={type="Snare Acoustic",   kw={"bright","wide","room","organic","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","bright","flam","organic","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","wide","acoustic","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","vintage","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","vintage"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","wide","vintage"}},
        crash    ={type="Crash",            kw={"bright","wide","acoustic","room","vintage"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","wide","vintage"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","wide","acoustic","vintage"}},
        tom      ={type="Tom",              kw={"wide","organic","room","bright","vintage"}},
      },
    },
    { name="Big Band", default_kw={"wide","bright","punch","room","organic","gold"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","wide","room","organic","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"wide","punch","room","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","wide","punch","room","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","bright","flam","punch","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","organic","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","wide","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","wide"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","wide","room"}},
        crash    ={type="Crash",            kw={"bright","wide","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","wide","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","wide","room","acoustic"}},
        tom      ={type="Tom",              kw={"wide","punch","organic","room","bright"}},
      },
    },
    { name="Post-Bop", default_kw={"bright","organic","creative","room","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","bright","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","punch","organic","room","creative"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","flam","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","creative","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic","creative"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","creative","organic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","creative","room"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","organic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","creative","acoustic","room"}},
        tom      ={type="Tom",              kw={"punch","organic","bright","creative","room"}},
      },
    },
    { name="Electric Miles", default_kw={"dark","heavy","layered","organic","synthetic","deep"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","organic","room","deep","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","dark","sub","layered","organic"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","heavy","bright","creative"}},
        snare_alt={type="Snare Electronic", kw={"heavy","layered","dark","synthetic","creative"}},
        clap     ={type="Claps & Snaps",    kw={"organic","heavy","dark","creative","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","metallic","organic","synthetic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","metallic","organic","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"dark","metallic","heavy","organic","synthetic"}},
        crash    ={type="Crash",            kw={"dark","heavy","metallic","organic","noise"}},
        ride     ={type="Ride",             kw={"dark","metallic","organic","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"dark","noise","heavy","synthetic","creative"}},
        tom      ={type="Tom",              kw={"heavy","dark","organic","layered","deep"}},
      },
    },
    { name="Smooth Jazz", default_kw={"soft","lush","bright","wide","organic","warm"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","bright","lush"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","sub","organic","bright","lush"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","lush","room","organic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","soft","lush","room","wide"}},
        clap     ={type="Claps & Snaps",    kw={"soft","bright","lush","organic","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","gold","bright","acoustic","lush"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","gold","bright","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","gold","bright","lush","wide"}},
        crash    ={type="Crash",            kw={"soft","bright","wide","acoustic","lush"}},
        ride     ={type="Ride",             kw={"soft","gold","bright","lush","acoustic"}},
        perc     ={type="Shakers",          kw={"soft","organic","bright","lush","wide"}},
        tom      ={type="Tom",              kw={"soft","lush","organic","bright","wide"}},
      },
    },
    { name="Avant-Garde", default_kw={"noise","creative","dark","heavy","organic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","room","organic","noise","dark"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","heavy","dark","creative","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","noise","creative","organic","room"}},
        snare_alt={type="Snare Acoustic",   kw={"creative","noise","bright","organic","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"noise","creative","organic","dark","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"noise","creative","dark","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"noise","creative","dark","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"noise","creative","dark","heavy","metallic"}},
        crash    ={type="Crash",            kw={"noise","creative","dark","heavy","organic"}},
        ride     ={type="Ride",             kw={"noise","creative","metallic","dark","organic"}},
        perc     ={type="Perc Glitch",      kw={"noise","creative","dark","heavy"}},
        tom      ={type="Tom",              kw={"heavy","noise","creative","dark","organic"}},
      },
    },
    { name="Second Line", default_kw={"wide","punch","bright","organic","snap","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","wide","room","organic","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"wide","punch","room","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","wide","punch","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"snap","bright","wide","flam","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","wide","organic","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","wide","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","wide","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","wide","organic","gold"}},
        crash    ={type="Crash",            kw={"bright","wide","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","wide","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","wide","snap","acoustic"}},
        tom      ={type="Tom",              kw={"wide","punch","bright","organic","room"}},
      },
    },
    { name="Gospel Jazz", default_kw={"heavy","wide","punch","bright","organic","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","punch","wide","room","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","wide","room","organic","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"bright","wide","punch","room","heavy"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","bright","punch","heavy","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","punch","organic","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","gold","acoustic","wide","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","gold","acoustic","wide"}},
        hh_o     ={type="HiHat Open",       kw={"bright","gold","acoustic","wide","heavy"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","heavy","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","wide","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","wide","heavy","acoustic"}},
        tom      ={type="Tom",              kw={"heavy","wide","punch","organic","bright"}},
      },
    },
    { name="Chamber Jazz", default_kw={"soft","lush","acoustic","room","gold","organic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","deep","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"soft","organic","room","deep"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","lush"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","soft","lush","organic","room"}},
        clap     ={type="Claps & Snaps",    kw={"soft","organic","bright","acoustic","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","gold","bright","acoustic","lush"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","gold","bright","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","gold","bright","lush","acoustic"}},
        crash    ={type="Crash",            kw={"soft","bright","acoustic","lush","room"}},
        ride     ={type="Ride",             kw={"soft","gold","bright","lush","acoustic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","soft","acoustic","lush","room"}},
        tom      ={type="Tom",              kw={"soft","lush","organic","acoustic","room"}},
      },
    },
  }},
  -- ── Reggae & Dub ─────────────────────────────────────────────────────────────
  { name="Reggae & Dub", variants={
    { name="Roots", default_kw={"organic","room","deep","sub","soft","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","room","organic","heavy","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","sub","heavy","organic"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","bright","soft","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"room","organic","soft","bright"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","room","soft"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","soft","organic","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","soft","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","soft","organic","room"}},
        crash    ={type="Crash",            kw={"acoustic","room","organic","soft"}},
        ride     ={type="Ride",             kw={"acoustic","bright","room","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","acoustic","room","soft"}},
        tom      ={type="Tom",              kw={"organic","deep","room","heavy"}},
      },
    },
    { name="Dub", default_kw={"deep","sub","organic","room","heavy","dirty"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","sub","heavy","dirty","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"deep","room","heavy","organic"}},
        snare    ={type="Snare Acoustic",   kw={"room","organic","soft","vintage","tape"}},
        snare_alt={type="Snare Electronic", kw={"dirty","heavy","noise","organic"}},
        clap     ={type="Claps & Snaps",    kw={"organic","tape","vinyl","lofi","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","tape","vinyl","lofi","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","tape","lofi"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","tape","vinyl","lofi"}},
        crash    ={type="Crash",            kw={"organic","room","tape","acoustic"}},
        ride     ={type="Ride",             kw={"acoustic","tape","organic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","room","acoustic","vintage"}},
        tom      ={type="Tom",              kw={"deep","heavy","organic","room","sub"}},
      },
    },
    { name="Dancehall", default_kw={"heavy","punch","808","bright","synthetic","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","sub","punch","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"808","heavy","sub","synthetic"}},
        snare    ={type="Snare Electronic", kw={"heavy","snap","bright","808","punch"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","heavy","808","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","808","heavy","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","808","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","tight","808"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","heavy","808"}},
        crash    ={type="Crash",            kw={"bright","synthetic","808","noise"}},
        ride     ={type="Ride",             kw={"bright","synthetic","808"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","bright","synthetic"}},
        tom      ={type="Tom",              kw={"heavy","808","sub","deep","punch"}},
      },
    },
    { name="Dub Techno", default_kw={"dark","metallic","synthetic","heavy","machine","deep"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","heavy","dark","sub","machine"}},
        kick_alt ={type="Kick Electronic",  kw={"dark","heavy","sub","synthetic"}},
        snare    ={type="Snare Electronic", kw={"dark","metallic","synthetic","heavy","machine"}},
        snare_alt={type="Snare Electronic", kw={"metallic","dark","heavy","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"dark","metallic","synthetic","heavy","machine"}},
        hh_c     ={type="Hihat Closed",     kw={"metallic","dark","synthetic","machine","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"metallic","dark","synthetic","machine"}},
        hh_o     ={type="HiHat Open",       kw={"metallic","dark","heavy","synthetic","machine"}},
        crash    ={type="Crash",            kw={"dark","metallic","noise","synthetic","heavy"}},
        ride     ={type="Ride",             kw={"metallic","dark","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"metallic","dark","machine","synthetic"}},
        tom      ={type="Tom",              kw={"deep","dark","heavy","machine","sub"}},
      },
    },
    { name="Rocksteady", default_kw={"organic","room","soft","bright","acoustic","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"room","organic","soft","deep","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","soft","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","soft","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"room","bright","organic","soft"}},
        clap     ={type="Claps & Snaps",    kw={"organic","soft","acoustic","room","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","soft","bright","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","soft","bright","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","soft","bright","organic"}},
        crash    ={type="Crash",            kw={"acoustic","room","organic","soft","bright"}},
        ride     ={type="Ride",             kw={"acoustic","bright","room","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","soft","room","acoustic","bright"}},
        tom      ={type="Tom",              kw={"organic","soft","room","deep","bright"}},
      },
    },
    { name="Ska", default_kw={"punch","bright","organic","room","snap","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","room","organic","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"snap","bright","punch","room","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","room","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","gold"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","snap"}},
        tom      ={type="Tom",              kw={"bright","punch","room","organic","acoustic"}},
      },
    },
    { name="Lovers Rock", default_kw={"soft","lush","organic","bright","room","warm"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"soft","room","organic","deep","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"soft","sub","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"soft","bright","room","organic","lush"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","soft","room","organic","warm"}},
        clap     ={type="Claps & Snaps",    kw={"soft","bright","organic","room","lush"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","acoustic","bright","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","acoustic","bright","gold"}},
        hh_o     ={type="HiHat Open",       kw={"soft","acoustic","bright","organic","lush"}},
        crash    ={type="Crash",            kw={"soft","acoustic","room","organic","bright"}},
        ride     ={type="Ride",             kw={"soft","bright","gold","acoustic","room"}},
        perc     ={type="Shakers",          kw={"organic","soft","bright","acoustic"}},
        tom      ={type="Tom",              kw={"soft","organic","room","deep","bright"}},
      },
    },
    { name="Digital Reggae", default_kw={"synthetic","heavy","808","sub","bright","machine"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","sub","synthetic","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","synthetic","machine"}},
        snare    ={type="Snare Electronic", kw={"heavy","bright","808","synthetic","snap"}},
        snare_alt={type="Snare Electronic", kw={"bright","808","synthetic","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","808","synthetic","machine","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","808","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","tight","808"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","808","machine"}},
        crash    ={type="Crash",            kw={"bright","synthetic","808","machine"}},
        ride     ={type="Ride",             kw={"bright","machine","808","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","bright","machine"}},
        tom      ={type="Tom",              kw={"808","synthetic","deep","heavy","sub"}},
      },
    },
    { name="Ragga", default_kw={"heavy","808","synthetic","bright","punch","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","sub","punch","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"808","heavy","sub","bright"}},
        snare    ={type="Snare Electronic", kw={"heavy","snap","bright","808","punch"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","808","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","808","heavy","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","808","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","tight","808"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","808","heavy"}},
        crash    ={type="Crash",            kw={"bright","808","synthetic","noise"}},
        ride     ={type="Ride",             kw={"bright","808","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","bright","synthetic"}},
        tom      ={type="Tom",              kw={"heavy","808","sub","deep","punch"}},
      },
    },
    { name="Nyahbinghi", default_kw={"organic","deep","acoustic","heavy","room","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","heavy","organic","room","wide"}},
        kick_alt ={type="Kick Acoustic",    kw={"deep","organic","heavy","room"}},
        snare    ={type="Snare Acoustic",   kw={"organic","wide","room","heavy","bright"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","organic","room","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","wide","room","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","organic","bright","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","organic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","organic","wide","heavy"}},
        crash    ={type="Crash",            kw={"acoustic","organic","wide","room","heavy"}},
        ride     ={type="Ride",             kw={"acoustic","bright","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","heavy","deep","wide"}},
        tom      ={type="Tom",              kw={"deep","heavy","organic","wide","room"}},
      },
    },
    { name="One Drop", default_kw={"deep","organic","room","heavy","sub","soft"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","heavy","room","organic","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","sub","heavy","organic"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","soft","bright","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"room","soft","organic","bright"}},
        clap     ={type="Claps & Snaps",    kw={"organic","soft","acoustic","room","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","soft","organic","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","soft","organic"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","soft","organic","room"}},
        crash    ={type="Crash",            kw={"acoustic","organic","room","soft"}},
        ride     ={type="Ride",             kw={"acoustic","bright","organic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","acoustic","room","soft","wide"}},
        tom      ={type="Tom",              kw={"deep","heavy","organic","room","sub"}},
      },
    },
    { name="Steppers", default_kw={"heavy","punch","organic","deep","wide","sub"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"heavy","punch","deep","organic","wide"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","punch","sub","deep","organic"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","bright","wide","heavy"}},
        snare_alt={type="Snare Acoustic",   kw={"wide","organic","room","bright","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"organic","heavy","wide","room","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","organic","bright","wide","heavy"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","organic","bright","heavy"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","organic","wide","heavy","bright"}},
        crash    ={type="Crash",            kw={"acoustic","organic","wide","room","heavy"}},
        ride     ={type="Ride",             kw={"acoustic","bright","organic","wide"}},
        perc     ={type="Perc Acoustic",    kw={"organic","heavy","wide","acoustic","room"}},
        tom      ={type="Tom",              kw={"heavy","deep","organic","wide","punch"}},
      },
    },
    { name="Dub Plate", default_kw={"dirty","lofi","organic","tape","vintage","heavy"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","heavy","dirty","organic","room"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","dirty","sub","heavy","tape"}},
        snare    ={type="Snare Acoustic",   kw={"lofi","tape","organic","room","dirty"}},
        snare_alt={type="Snare Acoustic",   kw={"tape","vinyl","dirty","organic","room"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","tape","organic","dirty","vinyl"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","tape","acoustic","organic","dirty"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","tape","acoustic","dirty"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","tape","organic","dirty","vinyl"}},
        crash    ={type="Crash",            kw={"lofi","organic","tape","room","dirty"}},
        ride     ={type="Ride",             kw={"acoustic","tape","organic","lofi","dirty"}},
        perc     ={type="Perc Acoustic",    kw={"organic","lofi","tape","room","dirty"}},
        tom      ={type="Tom",              kw={"deep","heavy","dirty","organic","tape"}},
      },
    },
    { name="Bashment", default_kw={"bright","synthetic","snap","punch","sub","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"sub","punch","bright","wide","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","punch","synthetic"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","punch","wide","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","wide","punch","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","wide","punch","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","snap","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","snap"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","punch"}},
        crash    ={type="Crash",            kw={"bright","synthetic","wide","noise"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide"}},
        perc     ={type="Perc Electronic",  kw={"bright","snap","synthetic","wide","punch"}},
        tom      ={type="Tom",              kw={"sub","heavy","punch","deep","wide"}},
      },
    },
    { name="Conscious Dub", default_kw={"deep","organic","soft","room","sub","vintage"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","soft","organic","room","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","sub","organic","soft"}},
        snare    ={type="Snare Acoustic",   kw={"soft","organic","room","bright","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"room","organic","soft","vintage","bright"}},
        clap     ={type="Claps & Snaps",    kw={"organic","soft","acoustic","room","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","soft","organic","bright","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","soft","organic","vintage"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","soft","organic","room","vintage"}},
        crash    ={type="Crash",            kw={"acoustic","organic","room","soft","vintage"}},
        ride     ={type="Ride",             kw={"acoustic","soft","organic","bright","vintage"}},
        perc     ={type="Perc Acoustic",    kw={"organic","soft","room","acoustic","vintage"}},
        tom      ={type="Tom",              kw={"deep","soft","organic","room","sub"}},
      },
    },
    { name="Deep Dub", default_kw={"dark","heavy","sub","noise","machine","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","sub","heavy","dark","noise"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","heavy","dark","machine","noise"}},
        snare    ={type="Snare Electronic", kw={"dark","heavy","noise","synthetic","organic"}},
        snare_alt={type="Snare Electronic", kw={"heavy","dark","noise","machine","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"dark","heavy","noise","organic","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","metallic","noise","synthetic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","metallic","noise","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"dark","heavy","noise","metallic","synthetic"}},
        crash    ={type="Crash",            kw={"dark","noise","heavy","metallic","synthetic"}},
        ride     ={type="Ride",             kw={"dark","metallic","noise","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"dark","noise","heavy","machine","synthetic"}},
        tom      ={type="Tom",              kw={"deep","sub","heavy","dark","noise"}},
      },
    },
    { name="Studio One", default_kw={"vintage","organic","bright","room","acoustic","warm"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"vintage","room","organic","bright","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","vintage","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","vintage","room","organic","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"vintage","bright","organic","room","soft"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","vintage","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","vintage","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","vintage","gold"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","bright","vintage","organic","room"}},
        crash    ={type="Crash",            kw={"acoustic","bright","vintage","room","organic"}},
        ride     ={type="Ride",             kw={"acoustic","bright","gold","vintage","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","vintage","acoustic","room"}},
        tom      ={type="Tom",              kw={"organic","vintage","room","deep","bright"}},
      },
    },
    { name="Rub-a-Dub", default_kw={"bright","punch","organic","room","soft","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","bright","deep"}},
        kick_alt ={type="Kick Acoustic",    kw={"room","organic","bright","punch"}},
        snare    ={type="Snare Acoustic",   kw={"bright","organic","room","soft","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"soft","bright","organic","room","wide"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","soft","acoustic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"acoustic","bright","soft","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"acoustic","bright","soft","gold"}},
        hh_o     ={type="HiHat Open",       kw={"acoustic","soft","bright","organic","room"}},
        crash    ={type="Crash",            kw={"acoustic","bright","organic","soft","room"}},
        ride     ={type="Ride",             kw={"acoustic","bright","gold","soft","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","soft","acoustic","wide"}},
        tom      ={type="Tom",              kw={"organic","room","bright","deep","soft"}},
      },
    },
    { name="Sound System", default_kw={"heavy","sub","wide","deep","machine","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"sub","heavy","deep","wide","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","heavy","machine","dark","wide"}},
        snare    ={type="Snare Electronic", kw={"heavy","wide","synthetic","machine","bright"}},
        snare_alt={type="Snare Electronic", kw={"wide","heavy","synthetic","bright","noise"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","wide","synthetic","bright","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","metallic","machine","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","metallic","machine"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","heavy","wide","machine","metallic"}},
        crash    ={type="Crash",            kw={"heavy","wide","synthetic","noise","metallic"}},
        ride     ={type="Ride",             kw={"metallic","synthetic","wide","machine"}},
        perc     ={type="Perc Electronic",  kw={"heavy","sub","wide","synthetic","machine"}},
        tom      ={type="Tom",              kw={"sub","deep","heavy","wide","organic"}},
      },
    },
    { name="Jungle Riddim", default_kw={"heavy","wide","punch","snap","noise","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","punch","sub","wide","noise"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","heavy","wide","organic","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","punch","wide","heavy"}},
        snare_alt={type="Snare Electronic", kw={"snap","heavy","punch","noise","bright"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","heavy","wide","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","tight","organic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","tight","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","heavy","wide","organic"}},
        crash    ={type="Crash",            kw={"bright","heavy","wide","noise","organic"}},
        ride     ={type="Ride",             kw={"bright","metallic","wide","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","heavy","wide","bright","snap"}},
        tom      ={type="Tom",              kw={"heavy","wide","punch","organic","deep"}},
      },
    },
  }},
  -- ── Breakbeat ─────────────────────────────────────────────────────────────────
  { name="Breakbeat", variants={
    { name="Amen", default_kw={"punch","bright","snap","noise","heavy","room"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","sub","deep","noise"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","bright","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","punch","room","organic"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","noise","punch","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","punch","organic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","tight","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","metallic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","room"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","room"}},
        tom      ={type="Tom",              kw={"punch","bright","room","organic"}},
      },
    },
    { name="Big Beat", default_kw={"punch","bright","heavy","snap","dirty","grit"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","sub","dirty","hard"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","heavy","organic"}},
        snare    ={type="Snare Electronic", kw={"punch","snap","heavy","bright","dirty"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","snap","punch","room"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","punch","snap","bright","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","metallic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","heavy","metallic","noise"}},
        crash    ={type="Crash",            kw={"bright","noise","heavy","organic"}},
        ride     ={type="Ride",             kw={"bright","metallic","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","punch","noise"}},
        tom      ={type="Tom",              kw={"punch","heavy","bright","organic"}},
      },
    },
    { name="Nu Skool", default_kw={"punch","heavy","synthetic","tight","noise","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","sub","tight","noise"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","synthetic","tight","punch"}},
        snare    ={type="Snare Electronic", kw={"punch","heavy","tight","synthetic","bright"}},
        snare_alt={type="Snare Electronic", kw={"tight","heavy","noise","punch"}},
        clap     ={type="Claps & Snaps",    kw={"punch","heavy","tight","synthetic","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","bright","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","heavy","noise","bright"}},
        crash    ={type="Crash",            kw={"bright","noise","heavy","synthetic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","heavy","noise","tight"}},
        tom      ={type="Tom",              kw={"heavy","punch","tight","synthetic"}},
      },
    },
    { name="Electro Breaks", default_kw={"808","machine","synthetic","snap","heavy","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","heavy","machine","punch","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"808","machine","synthetic","heavy"}},
        snare    ={type="Snare Electronic", kw={"808","machine","snap","bright","heavy"}},
        snare_alt={type="Snare Electronic", kw={"machine","snap","808","synthetic","bright"}},
        clap     ={type="Claps & Snaps",    kw={"808","snap","machine","heavy","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"808","machine","tight","synthetic","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"808","machine","tight","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"808","machine","synthetic","heavy"}},
        crash    ={type="Crash",            kw={"808","machine","synthetic","bright"}},
        ride     ={type="Ride",             kw={"machine","808","synthetic","bright"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","machine","blip"}},
        tom      ={type="Tom",              kw={"808","machine","heavy","synthetic","deep"}},
      },
    },
    { name="Acid Breaks", default_kw={"noise","synthetic","hard","punch","tight"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","noise","punch","hard","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","hard","synthetic","heavy"}},
        snare    ={type="Snare Electronic", kw={"noise","hard","punch","tight","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"noise","tight","hard","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"noise","hard","tight","synthetic","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","noise","synthetic","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","noise","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"noise","heavy","synthetic","metallic"}},
        crash    ={type="Crash",            kw={"noise","metallic","synthetic","heavy"}},
        ride     ={type="Ride",             kw={"noise","metallic","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"noise","snap","synthetic","metal"}},
        tom      ={type="Tom",              kw={"noise","heavy","hard","synthetic"}},
      },
    },
    { name="Baltimore Club", default_kw={"punch","tight","snap","bright","808","fast"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","punch","tight","bright","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"808","tight","punch","snap"}},
        snare    ={type="Snare Electronic", kw={"snap","tight","bright","808","punch"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","tight","808"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","tight","808","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","808","synthetic","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","808","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","808","synthetic","snap","tight"}},
        crash    ={type="Crash",            kw={"bright","808","synthetic","machine"}},
        ride     ={type="Ride",             kw={"bright","808","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"snap","808","blip","tight","bright"}},
        tom      ={type="Tom",              kw={"808","punch","tight","bright"}},
      },
    },
    { name="2-Step", default_kw={"tight","sub","punch","bright","synthetic","shuffle"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","tight","sub","bright","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","sub","synthetic","punch"}},
        snare    ={type="Snare Electronic", kw={"snap","tight","bright","synthetic","punch"}},
        snare_alt={type="Snare Electronic", kw={"tight","snap","bright","organic"}},
        clap     ={type="Claps & Snaps",    kw={"snap","tight","bright","synthetic","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","organic","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","synthetic","snap"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","tight","organic"}},
        crash    ={type="Crash",            kw={"bright","synthetic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","synthetic","tight"}},
        tom      ={type="Tom",              kw={"tight","sub","bright","punch","synthetic"}},
      },
    },
    { name="UK Hardcore", default_kw={"punch","bright","heavy","noise","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","bright","noise","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","heavy","bright","snap"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","snap","heavy","noise"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","punch","noise"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","punch","heavy","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","noise","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","noise"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","heavy","noise","snap"}},
        crash    ={type="Crash",            kw={"bright","noise","heavy","synthetic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","heavy","noise","punch"}},
        tom      ={type="Tom",              kw={"heavy","punch","bright","noise"}},
      },
    },
    { name="Progressive Breaks", default_kw={"wide","bright","punch","organic","layered"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"wide","bright","organic","punch"}},
        snare    ={type="Snare Acoustic",   kw={"bright","wide","room","organic","punch"}},
        snare_alt={type="Snare Electronic", kw={"bright","wide","punch","organic","layered"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","organic","punch","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","wide","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","wide","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","wide","organic","room"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","acoustic","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","wide","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","wide"}},
        tom      ={type="Tom",              kw={"wide","punch","bright","organic","room"}},
      },
    },
    { name="Funky Breaks", default_kw={"funk","punch","bright","organic","snap","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","deep","funk"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","organic","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","snap","room","organic","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","punch","organic"}},
        clap     ={type="Claps & Snaps",    kw={"snap","organic","bright","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","funk"}},
        tom      ={type="Tom",              kw={"organic","punch","room","bright","deep"}},
      },
    },
    { name="Glitch Breaks", default_kw={"glitch","creative","noise","synthetic","bright"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","noise","synthetic","sub","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","synthetic","creative","punch"}},
        snare    ={type="Snare Electronic", kw={"noise","creative","synthetic","bright","punch"}},
        snare_alt={type="Snare Electronic", kw={"noise","synthetic","creative","bright"}},
        clap     ={type="Claps & Snaps",    kw={"noise","snap","creative","synthetic","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","noise","synthetic","creative"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","noise","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"noise","synthetic","creative","heavy"}},
        crash    ={type="Crash",            kw={"noise","creative","synthetic","bright"}},
        ride     ={type="Ride",             kw={"noise","synthetic","creative"}},
        perc     ={type="Perc Glitch",      kw={"noise","creative","synthetic","bright"}},
        tom      ={type="Tom",              kw={"noise","heavy","synthetic","creative"}},
      },
    },
    { name="Lo-Fi Breaks", default_kw={"lofi","tape","vinyl","vintage","organic","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","lofi","room","organic","vintage"}},
        kick_alt ={type="Kick Electronic",  kw={"lofi","tape","punch","sub","dirty"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","lofi","organic","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"lofi","tape","room","organic","bright"}},
        clap     ={type="Claps & Snaps",    kw={"lofi","organic","tape","bright","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"lofi","acoustic","metallic","bright","tape"}},
        hh_pedal ={type="Hihat Closed",     kw={"lofi","acoustic","metallic","tape"}},
        hh_o     ={type="HiHat Open",       kw={"lofi","acoustic","bright","organic","tape"}},
        crash    ={type="Crash",            kw={"lofi","acoustic","organic","room","bright"}},
        ride     ={type="Ride",             kw={"lofi","acoustic","bright","metallic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","lofi","tape","bright","room"}},
        tom      ={type="Tom",              kw={"lofi","organic","room","punch","vintage"}},
      },
    },
    { name="Oldschool Breaks", default_kw={"vintage","warm","room","organic","tape","bright"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","warm","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","deep","room","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","warm","punch"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","punch","vintage","organic"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","room","warm","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","metallic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic","room"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","warm"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room","warm"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic","room"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","warm","room"}},
        tom      ={type="Tom",              kw={"organic","room","punch","warm","bright"}},
      },
    },
    { name="Tribal Breaks", default_kw={"djembe","organic","deep","punch","acoustic","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","punch","organic","room","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","sub","punch","organic"}},
        snare    ={type="Snare Acoustic",   kw={"organic","bright","room","punch","metallic"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","punch","room","bright"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","punch","bright","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","metallic"}},
        crash    ={type="Crash",            kw={"bright","organic","acoustic","metallic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","punch","room"}},
        tom      ={type="Tom",              kw={"deep","organic","punch","room","wide"}},
      },
    },
    { name="Cut & Paste", default_kw={"creative","layered","synthetic","noise","bright","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","layered","synthetic","sub","creative"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","layered","creative","punch"}},
        snare    ={type="Snare Electronic", kw={"layered","creative","bright","synthetic","punch"}},
        snare_alt={type="Snare Electronic", kw={"creative","noise","bright","layered"}},
        clap     ={type="Claps & Snaps",    kw={"snap","creative","layered","bright","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","creative","bright","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","creative","bright"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","creative","bright","noise"}},
        crash    ={type="Crash",            kw={"creative","noise","bright","synthetic"}},
        ride     ={type="Ride",             kw={"creative","synthetic","bright","noise"}},
        perc     ={type="Perc Glitch",      kw={"creative","noise","snap","bright","synthetic"}},
        tom      ={type="Tom",              kw={"layered","synthetic","punch","creative"}},
      },
    },
    { name="Abstract Beats", default_kw={"creative","dark","layered","noise","wide","deep"},
      voices={
        kick     ={type="Kick Electronic",  kw={"deep","sub","dark","heavy","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"dark","noise","heavy","sub"}},
        snare    ={type="Snare Electronic", kw={"noise","creative","dark","layered","heavy"}},
        snare_alt={type="Snare Electronic", kw={"dark","heavy","noise","creative"}},
        clap     ={type="Claps & Snaps",    kw={"noise","dark","creative","heavy","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","noise","tight","synthetic","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","noise","tight","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"dark","noise","synthetic","heavy"}},
        crash    ={type="Crash",            kw={"dark","noise","heavy","creative","metallic"}},
        ride     ={type="Ride",             kw={"dark","noise","metallic","creative"}},
        perc     ={type="Perc Glitch",      kw={"noise","creative","dark","heavy"}},
        tom      ={type="Tom",              kw={"deep","dark","heavy","wide","creative"}},
      },
    },
    { name="Future Beats", default_kw={"wide","bright","synthetic","layered","sub","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","wide","sub","bright","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"wide","synthetic","sub","punch"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","layered","synthetic","punch"}},
        snare_alt={type="Snare Electronic", kw={"wide","bright","synthetic","layered"}},
        clap     ={type="Claps & Snaps",    kw={"snap","wide","bright","synthetic","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","layered"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","creative","layered"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","creative"}},
        perc     ={type="Perc Electronic",  kw={"bright","snap","synthetic","wide","blip"}},
        tom      ={type="Tom",              kw={"wide","sub","punch","synthetic","bright"}},
      },
    },
    { name="Rave Breaks", default_kw={"hard","bright","heavy","punch","synthetic","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","punch","bright","sub","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","heavy","sub","noise"}},
        snare    ={type="Snare Electronic", kw={"bright","hard","punch","snap","noise"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","hard","heavy","noise"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","hard","punch","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","hard","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","hard"}},
        hh_o     ={type="HiHat Open",       kw={"bright","heavy","synthetic","noise","hard"}},
        crash    ={type="Crash",            kw={"bright","noise","heavy","hard","synthetic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","noise","hard"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","hard","noise","punch"}},
        tom      ={type="Tom",              kw={"hard","heavy","punch","bright","noise"}},
      },
    },
    { name="DnB Breaks", default_kw={"punch","heavy","bright","tight","sub","fast"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","sub","tight","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","sub","punch","dark"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","snap","heavy","tight"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","snap","room","punch","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","punch","heavy","tight"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","metallic","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","tight","heavy"}},
        crash    ={type="Crash",            kw={"bright","heavy","metallic","organic"}},
        ride     ={type="Ride",             kw={"bright","metallic","tight","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"snap","bright","punch","tight","noise"}},
        tom      ={type="Tom",              kw={"heavy","punch","tight","bright","sub"}},
      },
    },
    { name="Halftime Breaks", default_kw={"heavy","deep","sub","wide","layered","dark"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","deep","sub","wide","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","sub","dark","layered"}},
        snare    ={type="Snare Electronic", kw={"heavy","wide","layered","punch","deep"}},
        snare_alt={type="Snare Electronic", kw={"heavy","dark","noise","punch","wide"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","snap","wide","punch","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","dark","synthetic","metallic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","dark","synthetic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"dark","heavy","synthetic","noise","wide"}},
        crash    ={type="Crash",            kw={"heavy","dark","noise","wide","synthetic"}},
        ride     ={type="Ride",             kw={"dark","metallic","synthetic","noise"}},
        perc     ={type="Perc Electronic",  kw={"heavy","sub","noise","synthetic","dark"}},
        tom      ={type="Tom",              kw={"heavy","deep","sub","wide","dark"}},
      },
    },
  }},
  -- ── Afrobeat ──────────────────────────────────────────────────────────────────
  { name="Afrobeat", variants={
    { name="Classic", default_kw={"djembe","balafon","organic","bright","acoustic","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","deep","room","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","deep","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","flam"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","room","bright","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","bright","room","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","balafon","organic","bright"}},
        tom      ={type="Tom",              kw={"organic","deep","punch","room","wide"}},
      },
    },
    { name="Contemporary", default_kw={"djembe","organic","punch","bright","room","synthetic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","deep","sub","organic","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","deep"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","organic","synthetic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","snap","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","synthetic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","organic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","organic","synthetic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","balafon"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","room"}},
      },
    },
    { name="Afro House", default_kw={"djembe","organic","punch","bright","synthetic","room"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","organic","deep","bright","synthetic"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","bright"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","synthetic","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","snap"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","snap","synthetic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","organic","synthetic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","organic","metallic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","balafon"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","room","deep"}},
      },
    },
    { name="Afropop", default_kw={"bright","organic","punch","synthetic","wide","pop"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","sub","organic","wide"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","room","organic"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","wide","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","snap","organic","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","wide","pop"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","organic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","organic","wide","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","organic","synthetic","wide"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","acoustic"}},
        tom      ={type="Tom",              kw={"punch","bright","organic","wide","room"}},
      },
    },
    { name="Highlife", default_kw={"bright","organic","acoustic","room","vintage","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","bright","room","organic","vintage"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","organic","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","vintage","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","organic","room","flam"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","room","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic","vintage"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","vintage"}},
        crash    ={type="Crash",            kw={"bright","acoustic","room","organic","vintage"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","acoustic","balafon","room"}},
        tom      ={type="Tom",              kw={"organic","bright","room","punch","vintage"}},
      },
    },
    { name="Juju", default_kw={"bright","metallic","organic","acoustic","vintage","room"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","room","organic","deep","vintage"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","sub","bright"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","vintage","metallic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","organic","room"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","bright","vintage","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","vintage"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","acoustic","room"}},
        crash    ={type="Crash",            kw={"bright","metallic","acoustic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","metallic","bright","organic"}},
        tom      ={type="Tom",              kw={"organic","deep","room","punch","vintage"}},
      },
    },
    { name="Soukous", default_kw={"bright","organic","punch","wide","synthetic","acoustic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","room","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","wide"}},
        snare_alt={type="Snare Electronic", kw={"bright","punch","organic","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","wide","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","organic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","organic","metallic","wide"}},
        crash    ={type="Crash",            kw={"bright","organic","wide","acoustic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","organic","wide"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","balafon"}},
        tom      ={type="Tom",              kw={"punch","organic","bright","wide","room"}},
      },
    },
    { name="Afrobeats", default_kw={"punch","bright","sub","wide","synthetic","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","sub","deep","bright","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"808","punch","sub","wide"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","wide","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","punch","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","wide","organic","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","organic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","tight","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","organic","wide","synthetic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","organic","wide"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","punch"}},
        tom      ={type="Tom",              kw={"punch","deep","sub","organic","wide"}},
      },
    },
    { name="Coupe-Decale", default_kw={"punch","bright","snap","synthetic","wide","disco"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","sub","wide","disco"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","snap","sub"}},
        snare    ={type="Snare Electronic", kw={"snap","bright","wide","punch","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","punch","wide"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","wide","punch","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","snap","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","snap"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","tight"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","metallic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","punch"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","organic"}},
      },
    },
    { name="Fela Style", default_kw={"organic","room","punch","deep","vintage","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","deep","room","organic","vintage"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","vintage"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","room","bright","punch","wide"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","room","bright","vintage"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","metallic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room","metallic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic","room"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","balafon","room"}},
        tom      ={type="Tom",              kw={"organic","deep","room","punch","wide"}},
      },
    },
    { name="Tony Allen Style", default_kw={"organic","tight","bright","metallic","room","punch"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","tight","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","bright","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","tight","metallic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","tight","room","punch"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","snap","tight","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","tight","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","acoustic","organic","tight"}},
        crash    ={type="Crash",            kw={"bright","metallic","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","tight","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","metallic","tight"}},
        tom      ={type="Tom",              kw={"organic","tight","bright","room","punch"}},
      },
    },
    { name="Afro Funk", default_kw={"funk","organic","punch","bright","room","deep"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","deep","room","funk"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","organic","bright","funk"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","punch","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","organic","room","punch","wide"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","snap","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic","funk"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","metallic"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","balafon","funk"}},
        tom      ={type="Tom",              kw={"organic","punch","deep","room","bright"}},
      },
    },
    { name="Afro Disco", default_kw={"disco","bright","organic","lush","wide","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","sub","wide","disco"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","room","organic"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","wide","organic","lush"}},
        snare_alt={type="Snare Electronic", kw={"bright","wide","punch","organic","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","wide","organic","disco"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","acoustic","wide","organic"}},
        crash    ={type="Crash",            kw={"bright","organic","wide","acoustic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","gold","acoustic","wide"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","wide","lush"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","organic","room"}},
      },
    },
    { name="Afro Electronic", default_kw={"synthetic","bright","organic","punch","wide","djembe"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","synthetic"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","organic","sub","bright"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","synthetic","organic","wide"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","punch","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","synthetic","organic","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","organic","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","tight","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","organic","wide","metallic"}},
        crash    ={type="Crash",            kw={"bright","synthetic","organic","wide","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","metallic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","punch","balafon"}},
        tom      ={type="Tom",              kw={"organic","punch","bright","synthetic","wide"}},
      },
    },
    { name="Lagos Street", default_kw={"heavy","punch","bright","organic","wide","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","sub","bright","wide"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","heavy"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","heavy","organic","snap"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","punch","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","punch","organic","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","metallic","organic","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","metallic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","organic","metallic","wide","heavy"}},
        crash    ={type="Crash",            kw={"bright","organic","wide","heavy","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","organic","wide"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","punch","heavy"}},
        tom      ={type="Tom",              kw={"heavy","punch","organic","bright","wide"}},
      },
    },
    { name="Afro Punk", default_kw={"heavy","bright","organic","noise","punch","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","punch","sub","bright","noise"}},
        kick_alt ={type="Kick Acoustic",    kw={"heavy","punch","organic","room"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","punch","heavy","organic"}},
        snare_alt={type="Snare Electronic", kw={"bright","heavy","punch","noise","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","heavy","punch","snap","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","heavy","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic","heavy"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","heavy","acoustic","noise"}},
        crash    ={type="Crash",            kw={"bright","heavy","organic","noise","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","heavy","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","heavy","punch"}},
        tom      ={type="Tom",              kw={"heavy","organic","punch","bright","wide"}},
      },
    },
    { name="Afro Spiritual", default_kw={"deep","organic","warm","room","soft","wide"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","organic","room","warm","soft"}},
        kick_alt ={type="Kick Acoustic",    kw={"deep","organic","room","heavy"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","soft","bright","warm"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","room","warm","bright","wide"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","soft","bright","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","metallic","organic","soft"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","metallic","soft"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","room","soft"}},
        crash    ={type="Crash",            kw={"bright","organic","acoustic","room","soft"}},
        ride     ={type="Ride",             kw={"bright","acoustic","metallic","organic","soft"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","balafon","warm"}},
        tom      ={type="Tom",              kw={"deep","organic","warm","room","wide"}},
      },
    },
    { name="Naija Beats", default_kw={"punch","bright","sub","wide","synthetic","lush"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","sub","bright","wide","lush"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","sub","organic"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","wide","lush","organic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","punch","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","wide","lush","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","wide","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","tight","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","organic","lush"}},
        crash    ={type="Crash",            kw={"bright","organic","wide","lush","room"}},
        ride     ={type="Ride",             kw={"bright","organic","wide","synthetic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","punch","wide"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","sub","organic"}},
      },
    },
    { name="Afro Jazz", default_kw={"organic","bright","room","metallic","soft","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"punch","organic","room","soft","bright"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","organic","room","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","organic","soft","metallic"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","room","bright","soft","wide"}},
        clap     ={type="Claps & Snaps",    kw={"organic","acoustic","bright","soft","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","acoustic","organic","room"}},
        crash    ={type="Crash",            kw={"bright","acoustic","organic","room","metallic"}},
        ride     ={type="Ride",             kw={"bright","metallic","gold","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","balafon","soft"}},
        tom      ={type="Tom",              kw={"organic","room","bright","soft","punch"}},
      },
    },
    { name="Highlife Electronic", default_kw={"bright","synthetic","organic","wide","vintage","lush"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","bright","room","organic","vintage"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","organic","synthetic","lush"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","organic","wide","vintage"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","organic","wide","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","synthetic","organic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","synthetic","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","organic","wide","synthetic"}},
        crash    ={type="Crash",            kw={"bright","organic","wide","synthetic","room"}},
        ride     ={type="Ride",             kw={"bright","metallic","synthetic","organic","wide"}},
        perc     ={type="Perc Acoustic",    kw={"organic","bright","balafon","punch","wide"}},
        tom      ={type="Tom",              kw={"organic","bright","wide","punch","room"}},
      },
    },
  }},
  -- ── Footwork ──────────────────────────────────────────────────────────────────
  { name="Footwork", variants={
    { name="Chicago", default_kw={"808","tight","synthetic","snap","machine","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","tight","punch","snap","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"808","machine","snap","tight"}},
        snare    ={type="Snare Electronic", kw={"snap","tight","808","machine","punch"}},
        snare_alt={type="Snare Electronic", kw={"snap","tight","bright","808"}},
        clap     ={type="Claps & Snaps",    kw={"808","snap","tight","machine","hard"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","808","machine","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","808","snap"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","808","tight","machine"}},
        crash    ={type="Crash",            kw={"synthetic","808","bright","machine"}},
        ride     ={type="Ride",             kw={"synthetic","808","machine"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","tight","machine","blip"}},
        tom      ={type="Tom",              kw={"808","punch","tight","deep"}},
      },
    },
    { name="Juke", default_kw={"punch","bright","snap","tight","machine","808"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","tight","sub","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"808","punch","snap","tight"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","punch","tight","machine"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","tight","punch"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","punch","tight","machine"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","machine"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","tight","machine"}},
        crash    ={type="Crash",            kw={"bright","synthetic","machine"}},
        ride     ={type="Ride",             kw={"bright","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","bright","punch"}},
        tom      ={type="Tom",              kw={"punch","bright","tight","deep"}},
      },
    },
    { name="Ghetto House", default_kw={"tight","punch","808","snap","machine","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","punch","tight","hard","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"808","tight","machine","snap"}},
        snare    ={type="Snare Electronic", kw={"snap","tight","808","hard","punch"}},
        snare_alt={type="Snare Electronic", kw={"snap","tight","bright","808","hard"}},
        clap     ={type="Claps & Snaps",    kw={"808","snap","tight","hard","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","808","synthetic","machine","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","808","synthetic","machine"}},
        hh_o     ={type="HiHat Open",       kw={"808","synthetic","tight","machine"}},
        crash    ={type="Crash",            kw={"808","synthetic","bright","machine"}},
        ride     ={type="Ride",             kw={"808","machine","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","tight","machine","blip"}},
        tom      ={type="Tom",              kw={"808","punch","tight","deep"}},
      },
    },
    { name="Battle", default_kw={"snap","tight","punch","bright","noise","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","tight","sub","bright","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","snap","tight","hard"}},
        snare    ={type="Snare Electronic", kw={"snap","tight","bright","punch","hard"}},
        snare_alt={type="Snare Electronic", kw={"snap","bright","tight","noise","punch"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","tight","punch","hard"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","snap","synthetic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","snap","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","tight","noise"}},
        crash    ={type="Crash",            kw={"bright","noise","synthetic","hard"}},
        ride     ={type="Ride",             kw={"bright","synthetic","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","bright","punch","noise"}},
        tom      ={type="Tom",              kw={"punch","tight","bright","hard"}},
      },
    },
    { name="Teklife", default_kw={"snap","tight","808","machine","blip","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","tight","snap","hard","punch"}},
        kick_alt ={type="Kick Electronic",  kw={"808","snap","machine","tight"}},
        snare    ={type="Snare Electronic", kw={"snap","tight","808","hard","machine"}},
        snare_alt={type="Snare Electronic", kw={"snap","808","tight","bright"}},
        clap     ={type="Claps & Snaps",    kw={"snap","808","tight","hard","machine"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","808","synthetic","snap","machine"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","808","synthetic","snap"}},
        hh_o     ={type="HiHat Open",       kw={"808","synthetic","tight","machine"}},
        crash    ={type="Crash",            kw={"808","synthetic","machine","bright"}},
        ride     ={type="Ride",             kw={"808","machine","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"blip","snap","808","tight","machine"}},
        tom      ={type="Tom",              kw={"808","punch","tight","deep"}},
      },
    },
    { name="Neo Juke", default_kw={"bright","punch","synthetic","layered","wide","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","synthetic","bright","snap"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","wide","synthetic","layered"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","wide","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","wide","synthetic","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","tight"}},
        crash    ={type="Crash",            kw={"bright","synthetic","wide","creative"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide"}},
        perc     ={type="Perc Electronic",  kw={"blip","bright","snap","synthetic","punch"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","synthetic"}},
      },
    },
    { name="Bass Music", default_kw={"sub","heavy","punch","synthetic","dark","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"sub","heavy","deep","punch","synthetic"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","heavy","dark","noise"}},
        snare    ={type="Snare Electronic", kw={"heavy","punch","noise","synthetic","hard"}},
        snare_alt={type="Snare Electronic", kw={"heavy","noise","hard","punch"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","snap","noise","hard","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","dark","noise","synthetic","metal"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","dark","noise","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"dark","noise","synthetic","heavy"}},
        crash    ={type="Crash",            kw={"noise","heavy","dark","synthetic"}},
        ride     ={type="Ride",             kw={"dark","synthetic","noise"}},
        perc     ={type="Perc Electronic",  kw={"sub","noise","heavy","synthetic"}},
        tom      ={type="Tom",              kw={"sub","heavy","deep","punch","dark"}},
      },
    },
    { name="Juke House", default_kw={"punch","deep","lush","organic","sub","machine"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","deep","sub","organic","lush"}},
        kick_alt ={type="Kick Electronic",  kw={"808","deep","sub","punch"}},
        snare    ={type="Snare Electronic", kw={"punch","bright","organic","layered","wide"}},
        snare_alt={type="Snare Electronic", kw={"punch","soft","organic","lush"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","lush","snap","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","organic","bright","synthetic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","organic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"bright","organic","synthetic","lush"}},
        crash    ={type="Crash",            kw={"bright","organic","lush","wide"}},
        ride     ={type="Ride",             kw={"bright","organic","synthetic","wide"}},
        perc     ={type="Perc Electronic",  kw={"blip","soft","organic","synthetic"}},
        tom      ={type="Tom",              kw={"deep","punch","organic","sub"}},
      },
    },
    { name="Floatin", default_kw={"soft","dark","sub","synthetic","layered","deep"},
      voices={
        kick     ={type="Kick Electronic",  kw={"sub","deep","soft","dark","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","dark","deep"}},
        snare    ={type="Snare Electronic", kw={"soft","dark","layered","synthetic","wide"}},
        snare_alt={type="Snare Electronic", kw={"soft","synthetic","dark","layered"}},
        clap     ={type="Claps & Snaps",    kw={"soft","synthetic","dark","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","soft","synthetic","dark"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","soft","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"soft","synthetic","dark","wide"}},
        crash    ={type="Crash",            kw={"soft","dark","synthetic","layered"}},
        ride     ={type="Ride",             kw={"soft","synthetic","dark"}},
        perc     ={type="Perc Electronic",  kw={"soft","blip","synthetic","dark"}},
        tom      ={type="Tom",              kw={"sub","deep","dark","soft"}},
      },
    },
    { name="Stepper", default_kw={"tight","machine","snap","synthetic","hard","dry"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tight","punch","hard","synthetic","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","machine","hard","snap"}},
        snare    ={type="Snare Electronic", kw={"tight","snap","synthetic","hard","bright"}},
        snare_alt={type="Snare Electronic", kw={"tight","snap","hard","bright"}},
        clap     ={type="Claps & Snaps",    kw={"snap","tight","hard","synthetic","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","machine","bright"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","machine"}},
        hh_o     ={type="HiHat Open",       kw={"tight","synthetic","bright","machine"}},
        crash    ={type="Crash",            kw={"bright","synthetic","tight","hard"}},
        ride     ={type="Ride",             kw={"synthetic","tight","machine","bright"}},
        perc     ={type="Perc Electronic",  kw={"snap","tight","hard","machine"}},
        tom      ={type="Tom",              kw={"tight","punch","hard","deep"}},
      },
    },
    { name="Booty", default_kw={"808","heavy","sub","punch","bass","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","sub","heavy","punch","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"808","sub","heavy","bass"}},
        snare    ={type="Snare Electronic", kw={"808","heavy","snap","punch","wide"}},
        snare_alt={type="Snare Electronic", kw={"808","snap","heavy","punch"}},
        clap     ={type="Claps & Snaps",    kw={"808","snap","heavy","punch","wide"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","808","synthetic","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","808","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"808","synthetic","heavy","wide"}},
        crash    ={type="Crash",            kw={"808","heavy","synthetic","wide"}},
        ride     ={type="Ride",             kw={"808","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","heavy","blip"}},
        tom      ={type="Tom",              kw={"808","sub","heavy","deep"}},
      },
    },
    { name="Bangs", default_kw={"punch","hard","bright","snap","heavy","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","hard","heavy","sub","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","hard","heavy","snap"}},
        snare    ={type="Snare Electronic", kw={"hard","punch","bright","snap","heavy"}},
        snare_alt={type="Snare Electronic", kw={"hard","punch","snap","noise","bright"}},
        clap     ={type="Claps & Snaps",    kw={"hard","snap","punch","bright","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","hard","snap","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","hard","snap"}},
        hh_o     ={type="HiHat Open",       kw={"bright","hard","metallic","heavy"}},
        crash    ={type="Crash",            kw={"bright","hard","heavy","noise","metallic"}},
        ride     ={type="Ride",             kw={"bright","metallic","hard","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","hard","bright","punch","noise"}},
        tom      ={type="Tom",              kw={"punch","hard","heavy","bright"}},
      },
    },
    { name="UK Footwork", default_kw={"tight","sub","punch","bright","synthetic","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"sub","punch","tight","bright","synthetic"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","tight","punch","snap"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","tight","snap","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"bright","tight","snap","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","tight","punch","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","tight","wide"}},
        crash    ={type="Crash",            kw={"bright","synthetic","wide","metallic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","metallic","wide"}},
        perc     ={type="Perc Electronic",  kw={"blip","bright","snap","tight","synthetic"}},
        tom      ={type="Tom",              kw={"sub","punch","tight","deep"}},
      },
    },
    { name="Tokyo Footwork", default_kw={"bright","tight","synthetic","clean","machine","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tight","bright","punch","synthetic","clean"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","bright","snap","machine"}},
        snare    ={type="Snare Electronic", kw={"bright","tight","snap","synthetic","clean"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","tight","machine"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","tight","synthetic","clean"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","synthetic","metallic","clean"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","synthetic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","tight","metallic"}},
        crash    ={type="Crash",            kw={"bright","synthetic","metallic","wide"}},
        ride     ={type="Ride",             kw={"bright","metallic","synthetic","tight"}},
        perc     ={type="Perc Electronic",  kw={"blip","bright","tight","synthetic","machine"}},
        tom      ={type="Tom",              kw={"tight","punch","bright","synthetic"}},
      },
    },
    { name="Future Footwork", default_kw={"layered","wide","bright","synthetic","creative","sub"},
      voices={
        kick     ={type="Kick Electronic",  kw={"layered","wide","sub","punch","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"layered","sub","synthetic","wide"}},
        snare    ={type="Snare Electronic", kw={"wide","bright","layered","synthetic","creative"}},
        snare_alt={type="Snare Electronic", kw={"bright","layered","wide","creative"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","layered","synthetic","creative"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","wide","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","wide"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","creative"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","creative","layered"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","creative"}},
        perc     ={type="Perc Glitch",      kw={"creative","bright","synthetic","wide"}},
        tom      ={type="Tom",              kw={"wide","punch","layered","sub","bright"}},
      },
    },
    { name="Drillin", default_kw={"hard","heavy","dark","noise","punch","tight"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","heavy","punch","dark","sub"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","heavy","dark","noise"}},
        snare    ={type="Snare Electronic", kw={"hard","heavy","noise","punch","tight"}},
        snare_alt={type="Snare Electronic", kw={"hard","noise","heavy","dark"}},
        clap     ={type="Claps & Snaps",    kw={"hard","heavy","noise","punch","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","hard","noise","metallic","dark"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","hard","noise","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"hard","noise","dark","heavy"}},
        crash    ={type="Crash",            kw={"noise","hard","heavy","dark","metallic"}},
        ride     ={type="Ride",             kw={"metallic","hard","noise","dark"}},
        perc     ={type="Perc Electronic",  kw={"noise","hard","punch","heavy","dark"}},
        tom      ={type="Tom",              kw={"hard","heavy","dark","punch"}},
      },
    },
    { name="Flexin", default_kw={"bright","snap","punch","wide","synthetic","layered"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","snap","layered"}},
        snare    ={type="Snare Electronic", kw={"bright","snap","punch","wide","layered"}},
        snare_alt={type="Snare Electronic", kw={"bright","snap","punch","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","punch","wide","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","snap","synthetic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","snap","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","snap"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","layered"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","layered"}},
        perc     ={type="Perc Electronic",  kw={"bright","snap","punch","synthetic","blip"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","snap"}},
      },
    },
    { name="Jersey Footwork", default_kw={"punch","tight","bright","snap","808","machine"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","tight","bright","sub","808"}},
        kick_alt ={type="Kick Electronic",  kw={"808","tight","punch","snap"}},
        snare    ={type="Snare Electronic", kw={"tight","snap","bright","punch","808"}},
        snare_alt={type="Snare Electronic", kw={"tight","bright","snap","machine"}},
        clap     ={type="Claps & Snaps",    kw={"snap","tight","bright","punch","808"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","808","synthetic","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","808","snap"}},
        hh_o     ={type="HiHat Open",       kw={"bright","808","synthetic","tight"}},
        crash    ={type="Crash",            kw={"bright","808","synthetic","wide"}},
        ride     ={type="Ride",             kw={"bright","808","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"snap","blip","bright","808","tight"}},
        tom      ={type="Tom",              kw={"punch","tight","808","deep"}},
      },
    },
    { name="Trap Footwork", default_kw={"808","snap","heavy","dark","sub","machine"},
      voices={
        kick     ={type="Kick Electronic",  kw={"808","sub","heavy","dark","deep"}},
        kick_alt ={type="Kick Electronic",  kw={"808","heavy","sub","dark"}},
        snare    ={type="Snare Electronic", kw={"808","snap","heavy","punch","bright"}},
        snare_alt={type="Snare Electronic", kw={"808","heavy","snap","dark"}},
        clap     ={type="Claps & Snaps",    kw={"808","snap","heavy","punch","bright"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","808","synthetic","snap","dark"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","808","synthetic","snap"}},
        hh_o     ={type="HiHat Open",       kw={"808","synthetic","dark","heavy"}},
        crash    ={type="Crash",            kw={"808","dark","synthetic","heavy"}},
        ride     ={type="Ride",             kw={"808","dark","synthetic","machine"}},
        perc     ={type="Perc Electronic",  kw={"808","snap","heavy","blip","dark"}},
        tom      ={type="Tom",              kw={"808","sub","heavy","dark"}},
      },
    },
    { name="Prank", default_kw={"noise","creative","bright","snap","synthetic","glitch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","noise","synthetic","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"noise","punch","synthetic","creative"}},
        snare    ={type="Snare Electronic", kw={"noise","snap","bright","creative","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"noise","bright","creative","snap"}},
        clap     ={type="Claps & Snaps",    kw={"snap","noise","bright","creative","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","noise","synthetic","bright","creative"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","noise","synthetic","bright"}},
        hh_o     ={type="HiHat Open",       kw={"noise","synthetic","bright","creative"}},
        crash    ={type="Crash",            kw={"noise","bright","creative","synthetic"}},
        ride     ={type="Ride",             kw={"noise","synthetic","bright","creative"}},
        perc     ={type="Perc Glitch",      kw={"noise","creative","snap","bright","synthetic"}},
        tom      ={type="Tom",              kw={"noise","punch","bright","creative"}},
      },
    },
  }},
  -- ── Trance ───────────────────────────────────────────────────────────────────
  { name="Trance", variants={
    { name="Uplifting", default_kw={"punch","bright","wide","room","synth","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","tight"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","punch","sub","organic"}},
        snare    ={type="Snare Electronic", kw={"bright","room","wide","organic","layered"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","snap","wide"}},
        clap     ={type="Claps & Snaps",    kw={"bright","room","organic","wide","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","synthetic","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","synthetic","wide"}},
        crash    ={type="Crash",            kw={"bright","wide","room","organic","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","synthetic","wide"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","wide"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","organic","room"}},
      },
    },
    { name="Tech", default_kw={"hard","punch","tight","synth","metal","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","hard","tight","sub","snap"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","sub","deep","heavy"}},
        snare    ={type="Snare Electronic", kw={"hard","punch","tight","snap","metal"}},
        snare_alt={type="Snare Electronic", kw={"metal","tight","noise","punch"}},
        clap     ={type="Claps & Snaps",    kw={"hard","snap","punch","tight","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","metal","synthetic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","metal","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"metal","synthetic","tight","noise"}},
        crash    ={type="Crash",            kw={"synth","metal","noise","hard"}},
        ride     ={type="Ride",             kw={"synth","metal","tight","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","metal","hard","punch"}},
        tom      ={type="Tom",              kw={"hard","punch","tight","deep"}},
      },
    },
    { name="Dark Psy", default_kw={"dark","heavy","noise","grit","layered","metal"},
      voices={
        kick     ={type="Kick Electronic",  kw={"dark","heavy","deep","sub","noise"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","sub","dark","layered"}},
        snare    ={type="Snare Electronic", kw={"dark","heavy","noise","grit","metal"}},
        snare_alt={type="Snare Electronic", kw={"heavy","layered","noise","dark"}},
        clap     ={type="Claps & Snaps",    kw={"heavy","dark","noise","grit"}},
        hh_c     ={type="Hihat Closed",     kw={"metal","dark","noise","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"metal","dark","noise"}},
        hh_o     ={type="HiHat Open",       kw={"metal","heavy","dark","noise"}},
        crash    ={type="Crash",            kw={"noise","dark","metal","heavy"}},
        ride     ={type="Ride",             kw={"metal","dark","noise"}},
        perc     ={type="Perc Electronic",  kw={"metal","dark","noise","grit"}},
        tom      ={type="Tom",              kw={"deep","heavy","dark","hard"}},
      },
    },
    { name="Progressive", default_kw={"wide","bright","layered","organic","room","synth"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"wide","organic","bright","layered"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","layered","room","organic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","wide","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","layered","organic","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","wide","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","wide"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","organic"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","wide"}},
        tom      ={type="Tom",              kw={"bright","wide","punch","organic","room"}},
      },
    },
    { name="Melodic", default_kw={"bright","organic","lush","wide","room","acoustic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","organic","lush","wide"}},
        kick_alt ={type="Kick Electronic",  kw={"bright","organic","lush","sub"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","wide","organic","lush"}},
        snare_alt={type="Snare Electronic", kw={"bright","organic","layered","lush"}},
        clap     ={type="Claps & Snaps",    kw={"bright","organic","lush","wide","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold","room"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","gold","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","wide","gold"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","organic"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"bright","organic","lush","wide","room"}},
      },
    },
    { name="Goa", default_kw={"noise","heavy","organic","bright","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","deep","punch","noise","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","sub","noise","hard"}},
        snare    ={type="Snare Electronic", kw={"noise","heavy","organic","bright","hard"}},
        snare_alt={type="Snare Electronic", kw={"heavy","noise","bright","hard"}},
        clap     ={type="Claps & Snaps",    kw={"noise","organic","heavy","bright","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","noise","tight"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","noise"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","noise","heavy"}},
        crash    ={type="Crash",            kw={"noise","bright","organic","heavy","metallic"}},
        ride     ={type="Ride",             kw={"bright","metallic","noise","organic"}},
        perc     ={type="Perc Electronic",  kw={"noise","bright","snap","metal"}},
        tom      ={type="Tom",              kw={"heavy","noise","deep","organic"}},
      },
    },
    { name="Hi-NRG / Eurodance", default_kw={"punch","bright","wide","snap","synthetic","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","snap","wide"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","wide","snap","synthetic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","wide","snap"}},
        clap     ={type="Claps & Snaps",    kw={"snap","bright","wide","punch","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","wide","snap"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","snap"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","tight"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","organic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","metallic"}},
        perc     ={type="Shakers",          kw={"bright","organic","synthetic","wide"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","organic","room"}},
      },
    },
    { name="Hard Trance", default_kw={"hard","punch","tight","synthetic","noise","heavy"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","punch","tight","sub","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","heavy","sub","noise"}},
        snare    ={type="Snare Electronic", kw={"hard","punch","tight","snap","noise"}},
        snare_alt={type="Snare Electronic", kw={"hard","noise","tight","punch"}},
        clap     ={type="Claps & Snaps",    kw={"hard","snap","punch","tight","noise"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","synthetic","hard","noise","metal"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","synthetic","hard","noise"}},
        hh_o     ={type="HiHat Open",       kw={"synthetic","hard","noise","heavy"}},
        crash    ={type="Crash",            kw={"noise","hard","synthetic","heavy","metal"}},
        ride     ={type="Ride",             kw={"synthetic","metal","hard","noise"}},
        perc     ={type="Perc Electronic",  kw={"snap","hard","metal","noise"}},
        tom      ={type="Tom",              kw={"hard","heavy","punch","deep"}},
      },
    },
    { name="Acid Trance", default_kw={"synthetic","noise","organic","bright","acid","punch"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","deep","sub","organic","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","sub","synthetic","tight"}},
        snare    ={type="Snare Electronic", kw={"bright","organic","noise","punch","synthetic"}},
        snare_alt={type="Snare Electronic", kw={"bright","noise","punch","synthetic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","noise","snap","organic","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","synthetic","tight","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","synthetic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","noise","organic"}},
        crash    ={type="Crash",            kw={"noise","bright","synthetic","organic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","noise","organic"}},
        perc     ={type="Perc Electronic",  kw={"noise","bright","snap","synthetic"}},
        tom      ={type="Tom",              kw={"punch","deep","organic","noise","bright"}},
      },
    },
    { name="Orchestral Trance", default_kw={"bright","wide","lush","organic","room","acoustic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","wide","bright","sub","organic"}},
        kick_alt ={type="Kick Acoustic",    kw={"punch","room","organic","wide","deep"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","wide","organic","lush"}},
        snare_alt={type="Snare Electronic", kw={"bright","wide","layered","lush","room"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","organic","lush","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","wide","organic","room"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","acoustic"}},
        ride     ={type="Ride",             kw={"bright","acoustic","wide","organic","gold"}},
        perc     ={type="Shakers",          kw={"organic","bright","acoustic","wide","lush"}},
        tom      ={type="Tom",              kw={"bright","wide","organic","lush","room"}},
      },
    },
    { name="Tribal Trance", default_kw={"organic","deep","punch","bright","djembe","acoustic"},
      voices={
        kick     ={type="Kick Acoustic",    kw={"deep","punch","organic","room","heavy"}},
        kick_alt ={type="Kick Electronic",  kw={"deep","sub","punch","organic"}},
        snare    ={type="Snare Acoustic",   kw={"organic","room","bright","punch","metallic"}},
        snare_alt={type="Snare Acoustic",   kw={"organic","bright","punch","room"}},
        clap     ={type="Claps & Snaps",    kw={"organic","bright","acoustic","punch","room"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","acoustic","organic"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","acoustic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","organic","metallic"}},
        crash    ={type="Crash",            kw={"bright","organic","acoustic","room","metallic"}},
        ride     ={type="Ride",             kw={"bright","metallic","acoustic","organic"}},
        perc     ={type="Perc Acoustic",    kw={"djembe","organic","bright","punch","room"}},
        tom      ={type="Tom",              kw={"deep","organic","punch","room","wide"}},
      },
    },
    { name="Full-On", default_kw={"punch","bright","heavy","layered","noise","wide"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","heavy","bright","sub","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","heavy","sub","noise"}},
        snare    ={type="Snare Electronic", kw={"bright","heavy","punch","layered","noise"}},
        snare_alt={type="Snare Electronic", kw={"heavy","noise","bright","punch"}},
        clap     ={type="Claps & Snaps",    kw={"bright","punch","heavy","layered","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","metallic","tight","synthetic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","metallic","tight","noise"}},
        hh_o     ={type="HiHat Open",       kw={"bright","metallic","heavy","noise"}},
        crash    ={type="Crash",            kw={"bright","heavy","noise","metallic","wide"}},
        ride     ={type="Ride",             kw={"bright","metallic","noise","wide"}},
        perc     ={type="Perc Electronic",  kw={"noise","bright","heavy","snap","metallic"}},
        tom      ={type="Tom",              kw={"heavy","punch","noise","wide","bright"}},
      },
    },
    { name="Deep Trance", default_kw={"deep","sub","dark","lush","layered","soft"},
      voices={
        kick     ={type="Kick Electronic",  kw={"sub","deep","dark","soft","layered"}},
        kick_alt ={type="Kick Electronic",  kw={"sub","deep","dark","lush"}},
        snare    ={type="Snare Electronic", kw={"soft","wide","layered","dark","lush"}},
        snare_alt={type="Snare Electronic", kw={"soft","layered","dark","wide"}},
        clap     ={type="Claps & Snaps",    kw={"soft","wide","layered","dark","organic"}},
        hh_c     ={type="Hihat Closed",     kw={"soft","dark","synthetic","tight","lush"}},
        hh_pedal ={type="Hihat Closed",     kw={"soft","dark","synthetic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"soft","dark","synthetic","wide"}},
        crash    ={type="Crash",            kw={"soft","dark","wide","layered","lush"}},
        ride     ={type="Ride",             kw={"soft","dark","synthetic","wide"}},
        perc     ={type="Shakers",          kw={"soft","organic","dark","wide"}},
        tom      ={type="Tom",              kw={"sub","deep","dark","soft","wide"}},
      },
    },
    { name="Club Trance", default_kw={"punch","bright","wide","synthetic","snap","hard"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","hard"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","sub","tight"}},
        snare    ={type="Snare Electronic", kw={"bright","punch","wide","snap","synthetic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","wide","room","snap"}},
        clap     ={type="Claps & Snaps",    kw={"bright","snap","punch","wide","synthetic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","tight","synthetic","metallic","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","tight","synthetic","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","metallic"}},
        crash    ={type="Crash",            kw={"bright","wide","synthetic","room","organic"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","metallic"}},
        perc     ={type="Shakers",          kw={"bright","organic","wide","synthetic"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","sub"}},
      },
    },
    { name="Minimal Trance", default_kw={"tight","synthetic","bright","clean","soft","organic"},
      voices={
        kick     ={type="Kick Electronic",  kw={"tight","punch","bright","sub","soft"}},
        kick_alt ={type="Kick Electronic",  kw={"tight","soft","bright","synthetic"}},
        snare    ={type="Snare Electronic", kw={"bright","tight","soft","synthetic","organic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","soft","organic"}},
        clap     ={type="Claps & Snaps",    kw={"soft","bright","organic","synthetic","tight"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","bright","soft","synthetic","acoustic"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","bright","soft","synthetic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","soft","synthetic","organic"}},
        crash    ={type="Crash",            kw={"bright","soft","organic","wide","acoustic"}},
        ride     ={type="Ride",             kw={"bright","soft","acoustic","organic"}},
        perc     ={type="Shakers",          kw={"soft","organic","bright","acoustic"}},
        tom      ={type="Tom",              kw={"soft","bright","punch","organic"}},
      },
    },
    { name="Euro Trance", default_kw={"bright","wide","punch","synthetic","lush","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","lush"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","wide","synthetic"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","punch","lush","synthetic"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","wide","lush"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","lush","snap","punch"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","wide","synthetic","tight","lush"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","wide","synthetic","tight"}},
        hh_o     ={type="HiHat Open",       kw={"bright","synthetic","wide","lush"}},
        crash    ={type="Crash",            kw={"bright","wide","lush","organic","room"}},
        ride     ={type="Ride",             kw={"bright","synthetic","wide","lush"}},
        perc     ={type="Shakers",          kw={"bright","organic","lush","wide"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","lush"}},
      },
    },
    { name="Morning Trance", default_kw={"bright","soft","lush","organic","wide","warm"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","soft"}},
        kick_alt ={type="Kick Electronic",  kw={"bright","soft","organic","lush"}},
        snare    ={type="Snare Acoustic",   kw={"bright","room","wide","organic","soft"}},
        snare_alt={type="Snare Electronic", kw={"bright","soft","wide","organic"}},
        clap     ={type="Claps & Snaps",    kw={"bright","soft","organic","wide","acoustic"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","soft","organic","gold"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","soft","organic"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","soft","organic","wide"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","soft"}},
        ride     ={type="Ride",             kw={"bright","acoustic","gold","organic","soft"}},
        perc     ={type="Shakers",          kw={"soft","organic","bright","acoustic","lush"}},
        tom      ={type="Tom",              kw={"bright","soft","organic","wide","lush"}},
      },
    },
    { name="Ibiza", default_kw={"bright","wide","lush","punch","organic","room"},
      voices={
        kick     ={type="Kick Electronic",  kw={"punch","bright","wide","sub","organic"}},
        kick_alt ={type="Kick Electronic",  kw={"punch","bright","organic","lush"}},
        snare    ={type="Snare Electronic", kw={"bright","wide","punch","layered","lush"}},
        snare_alt={type="Snare Acoustic",   kw={"bright","room","wide","organic","lush"}},
        clap     ={type="Claps & Snaps",    kw={"bright","wide","lush","organic","snap"}},
        hh_c     ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold","wide"}},
        hh_pedal ={type="Hihat Closed",     kw={"bright","acoustic","organic","gold"}},
        hh_o     ={type="HiHat Open",       kw={"bright","acoustic","wide","organic","lush"}},
        crash    ={type="Crash",            kw={"bright","wide","organic","room","lush"}},
        ride     ={type="Ride",             kw={"bright","gold","acoustic","wide","lush"}},
        perc     ={type="Shakers",          kw={"organic","bright","lush","acoustic","wide"}},
        tom      ={type="Tom",              kw={"punch","bright","wide","organic","lush"}},
      },
    },
    { name="Trance Core", default_kw={"hard","punch","noise","heavy","bright","snap"},
      voices={
        kick     ={type="Kick Electronic",  kw={"hard","punch","heavy","sub","bright"}},
        kick_alt ={type="Kick Electronic",  kw={"hard","heavy","punch","noise"}},
        snare    ={type="Snare Electronic", kw={"hard","punch","bright","noise","heavy"}},
        snare_alt={type="Snare Electronic", kw={"hard","noise","punch","heavy"}},
        clap     ={type="Claps & Snaps",    kw={"hard","snap","punch","bright","heavy"}},
        hh_c     ={type="Hihat Closed",     kw={"tight","hard","bright","metallic","noise"}},
        hh_pedal ={type="Hihat Closed",     kw={"tight","hard","bright","metallic"}},
        hh_o     ={type="HiHat Open",       kw={"hard","bright","metallic","heavy"}},
        crash    ={type="Crash",            kw={"hard","bright","heavy","noise","metallic"}},
        ride     ={type="Ride",             kw={"hard","metallic","bright","noise"}},
        perc     ={type="Perc Electronic",  kw={"hard","snap","bright","noise","punch"}},
        tom      ={type="Tom",              kw={"hard","heavy","punch","bright"}},
      },
    },
    { name="Neuro Trance", default_kw={"layered","dark","synthetic","heavy","creative","noise"},
      voices={
        kick     ={type="Kick Electronic",  kw={"heavy","dark","layered","sub","synthetic"}},
        kick_alt ={type="Kick Electronic",  kw={"heavy","dark","sub","noise"}},
        snare    ={type="Snare Electronic", kw={"dark","heavy","layered","noise","creative"}},
        snare_alt={type="Snare Electronic", kw={"dark","layered","heavy","noise"}},
        clap     ={type="Claps & Snaps",    kw={"dark","heavy","noise","synthetic","layered"}},
        hh_c     ={type="Hihat Closed",     kw={"dark","tight","synthetic","noise","metallic"}},
        hh_pedal ={type="Hihat Closed",     kw={"dark","tight","synthetic","noise"}},
        hh_o     ={type="HiHat Open",       kw={"dark","synthetic","heavy","noise"}},
        crash    ={type="Crash",            kw={"dark","heavy","noise","metallic","synthetic"}},
        ride     ={type="Ride",             kw={"dark","metallic","noise","synthetic"}},
        perc     ={type="Perc Electronic",  kw={"dark","noise","heavy","creative","synthetic"}},
        tom      ={type="Tom",              kw={"heavy","dark","sub","layered","noise"}},
      },
    },
  }},
}

-- Voice key → GM notes (shared by all vibe kits)
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
  max_voices       = 8,   -- Max polyphony per instance: normalized N/9 (0=unlimited)
  attack           = 9,   -- ADSR attack time: 0=instant, 1=max
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
  local val = string.format("note:%d|L%d|%s|%s", note, layer, drum_type or "Unknown", tag or "")
  reaper.SetProjExtState(0, "TRIAZ_BROWSER", meta_key(track, fx_idx), val)
end

local function load_meta(track, fx_idx)
  local ok, val = reaper.GetProjExtState(0, "TRIAZ_BROWSER", meta_key(track, fx_idx))
  if not ok or val == "" then return nil end
  local note, layer, dtype, tag = val:match("^note:(%d+)|L(%d+)|(.+)|(.*)$")
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
local _loaded_kit        = nil  -- {genre_n, variant_n} of last loaded kit

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
  if params.mode then
    reaper.TrackFX_SetNamedConfigParm(track, fx_idx, "MODE", tostring(params.mode))
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
  if params.attack ~= nil then
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.attack, params.attack)
  end
  if params.max_voices ~= nil then
    -- 0 = unlimited; N voices = N/9 normalized (0.111≈1, 0.222≈2 … 1.0≈9)
    local norm = (params.max_voices == 0) and 0.0 or (params.max_voices / 9.0)
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.max_voices, norm)
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
  gfx.init("", 0, 0, 0, 0, 0)
  gfx.x, gfx.y = 0, 0
  -- Disabled header item shows title as instruction; screen reader reads it before items.
  -- gfx counts it as index 1, so real items start at 2 — subtract 1 from result.
  local choice = gfx.showmenu("#" .. title .. "|" .. table.concat(items, "|"))
  gfx.quit()
  return (choice > 1) and (choice - 1) or nil
end

local function ask_yes_no(msg, title)
  return reaper.MB(msg, title or "TRIAZ Browser", 4) == 6
end

-- Show a gate dialog, then read the most recent MIDI note-on from input buffer.
-- Returns note name string. Falls back to note_name(gm_note) if no note-on found.
local function pick_note_default(gm_note, wav_name)
  local body = wav_name and (wav_name .. "\n\n") or ""
  reaper.MB(
    body .. "Play a MIDI note now, then click OK.\nThe note you play will be pre-filled in the next dialog.",
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

-- ── Source picker: file browser or from selected timeline items ───────────────
-- Returns wav_name, full_path, drum_type, tag — same contract as browse_sample().
-- When no items are selected on timeline, goes straight to file browser.
-- When items are selected, offers submenu: Browse file | From selected item.

local function pick_source()
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

  if #sel_paths == 0 then return browse_sample() end

  -- Build source submenu
  local choices = {"Browse file"}
  if #sel_paths == 1 then
    local name = sel_paths[1]:match("[^\\/]+$") or sel_paths[1]
    choices[#choices + 1] = "From selected: " .. name
  else
    choices[#choices + 1] = string.format("From selected item (%d available)", #sel_paths)
  end

  local pick = pick_from_list("Sample source", choices)
  if not pick then return nil end
  if pick == 1 then return browse_sample() end

  local source_path
  if #sel_paths == 1 then
    source_path = sel_paths[1]
  else
    local names = {}
    for _, p in ipairs(sel_paths) do names[#names + 1] = p:match("[^\\/]+$") or p end
    local n = pick_from_list("Pick item", names)
    if not n then return nil end
    source_path = sel_paths[n]
  end

  local wav_name = source_path:match("[^\\/]+$") or source_path
  local drum_type, tag = parse_triaz_path(source_path)
  drum_type = drum_type or "Unknown"
  tag       = tag       or ""
  return wav_name, source_path, drum_type, tag
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
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then return nil end
  if track == reaper.GetMasterTrack(0) then return nil end
  if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1 then return nil end
  return track
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

-- ── Assign sample to RS5k ────────────────────────────────────────────────────

-- Find or create RS5k for note+layer, configure it.
-- force_new=true: always add new instance, skip existing-instance lookup.
local function assign_sample(track, note, layer, drum_type, tag, wav_name, full_path, zone, force_new)
  local fx_name = make_fx_name(note, layer, drum_type, tag)

  local fx_idx
  if not force_new then
    for _, inst in ipairs(scan_triaz_instances(track)) do
      if inst.info.note == note and inst.info.layer == layer then
        fx_idx = inst.fx_idx; break
      end
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

  local note_lo, note_hi, pitch_st, pitch_note_lo, mode
  if zone then
    note_lo       = zone.lo
    note_hi       = zone.hi
    pitch_st      = 0
    pitch_note_lo = zone.lo - zone.mid  -- semitones from center at lowest note
    mode          = 2                   -- NoteSemitoneShifted: 1st per semitone from pitch_note_lo
  else
    note_lo  = note
    note_hi  = note
    pitch_st = 0
    mode     = 1                        -- Sample/drum mode: ignore MIDI note pitch
  end

  configure_rs5k(track, fx_idx, {
    path          = full_path,
    note_lo       = note_lo,
    note_hi       = note_hi,
    pitch_st      = pitch_st,
    pitch_note_lo = pitch_note_lo,
    mode          = mode,
    volume        = 0.8,
    pan           = 0.5,
    no_loop       = is_noise,
    fx_name       = fx_name,
    meta          = {note=note, layer=layer, drum_type=drum_type, tag=tag},
  })

  return true, fx_idx
end

-- ── Shared assign dialog + preview + keep/retry/discard loop ────────────────
-- wav_name/full_path/drum_type/tag: initial sample to show in dialog.
-- defs (optional table): pre-populate fields {note, layer, zone_n, vol_db, pan_pct,
--   pitch_st, zone_lo_st, zone_hi_st, attack, max_voices, skip_layer_check, force_new}.
--   zone_lo_st/zone_hi_st: semitones at zone low/high note (RS5k params 5+6 directly).
-- Returns fx_idx of kept instance, or nil if discarded/cancelled.

local function run_assign_dialog(track, wav_name, full_path, drum_type, tag, defs)
  defs = defs or {}
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
    "Zone: pitch at low note st (ignored if no zone)",
    "Zone: pitch at high note st (ignored if no zone)",
    "Attack (0.0=instant  1.0=max)",
    "Max voices (0=unlimited  1-9)",
  }, ",")

  local note_default = defs.note and note_name(defs.note) or pick_note_default(gm_note, wav_name)
  local defaults_str = string.format("%s,%d,%d,%d,%d,%d,%d,%d,%.2f,%d",
    note_default,
    defs.layer      or 1,
    defs.zone_n     or 0,
    defs.vol_db     or 0,
    defs.pan_pct    or 0,
    defs.pitch_st   or 0,
    defs.zone_lo_st or -7,
    defs.zone_hi_st or 10,
    defs.attack     or 0.0,
    defs.max_voices or 0
  )

  local ok, result = reaper.GetUserInputs("Assign: " .. wav_name, 10, captions, defaults_str)
  if not ok then return nil end

  local parts = {}
  for p in result:gmatch("[^,]+") do parts[#parts + 1] = p:match("^%s*(.-)%s*$") end
  while #parts < 10 do parts[#parts + 1] = "0" end

  local zone_n = tonumber(parts[3]) or 0
  local zone = (zone_n >= 1 and zone_n <= #PITCH_ZONES) and PITCH_ZONES[zone_n] or nil

  local target_note
  if zone then
    target_note = zone.mid
  else
    target_note = tonumber(parts[1]) or note_from_name(parts[1] or "")
    if not target_note or target_note < 0 or target_note > 127 then
      reaper.MB("Invalid note: " .. (parts[1] or ""), "Error", 0); return nil
    end
  end

  local layer      = math.max(1, math.min(3, tonumber(parts[2]) or 1))
  local vol_db     = tonumber(parts[4]) or 0
  local pan_pct    = tonumber(parts[5]) or 0
  local pitch_st   = math.max(-24, math.min(24, tonumber(parts[6]) or 0))
  local zone_lo_st = tonumber(parts[7]) or -7
  local zone_hi_st = tonumber(parts[8]) or 10
  local attack     = math.max(0.0, math.min(1.0, tonumber(parts[9]) or 0.0))
  local max_voices = math.max(0, math.min(9, math.floor(tonumber(parts[10]) or 0)))

  if not defs.skip_layer_check then
    local instances = scan_triaz_instances(track)
    local layer_count = 0
    for _, inst in ipairs(instances) do
      if inst.info.note == target_note then layer_count = layer_count + 1 end
    end
    if layer_count >= 3 then
      if not ask_yes_no(
        "3 layers already on note " .. note_name(target_note) .. ". Add anyway?",
        "Max Layers"
      ) then return nil end
    end
  end

  while true do
    local assign_ok, fx_idx = assign_sample(
      track, target_note, layer, drum_type, tag, wav_name, full_path, zone, defs.force_new
    )
    if not assign_ok then return nil end

    local lin_vol = math.min(1.0, 10 ^ (vol_db / 20.0))
    configure_rs5k(track, fx_idx, {
      volume     = lin_vol,
      pan        = (pan_pct / 200.0) + 0.5,
      attack     = attack > 0 and attack or nil,
      max_voices = max_voices > 0 and max_voices or nil,
    })
    reaper.TrackFX_SetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_st, pitch_to_param(pitch_st))

    if zone then
      configure_rs5k(track, fx_idx, {
        pitch_note_lo = zone_lo_st,
        pitch_note_hi = zone_hi_st,
        mode = 0,
      })
    end

    preview_wav(full_path)

    local atk_str   = attack > 0 and string.format("  Atk:%.2f", attack) or ""
    local voice_str = max_voices > 0 and ("  Voices:" .. max_voices) or ""
    local choice = reaper.MB(
      string.format(
        "%s / %s / %s\nNote: %s%s  L%d  Vol:%ddB  Pan:%d%%  Pitch:%dst%s%s%s\n\nYes = keep\nNo = try another sample\nCancel = discard",
        drum_type, tag, wav_name,
        note_name(target_note),
        zone and string.format(" zone %s-%s  lo:%dst hi:%dst",
          note_name(zone.lo), note_name(zone.hi), zone_lo_st, zone_hi_st) or "",
        layer, vol_db, pan_pct, pitch_st,
        "",
        atk_str, voice_str
      ),
      "Keep this sample?", 3
    )
    stop_preview()

    if choice == 6 then       -- Yes: keep
      return fx_idx
    elseif choice == 7 then   -- No: try another sample
      remove_rs5k(track, fx_idx)
      local new_wav, new_path, new_type, new_tag = pick_source()
      if not new_wav then return nil end
      wav_name, full_path, drum_type, tag = new_wav, new_path, new_type, new_tag
    else                      -- Cancel: discard
      remove_rs5k(track, fx_idx)
      return nil
    end
  end
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

  local choices = {
    "Swap sample (re-browse)",
    "Edit parameters (vol / pan / pitch / attack / voices)",
    "Preview current sample",
    "Dump RS5k params (diagnostic)",
    "Remove this instance",
  }

  -- All actions loop back to picker. Confirmed remove (action 5) is the only exit.
  local function refresh_file()
    ok_f, cur_file = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "FILE0")
    cur_wav = (ok_f and cur_file ~= "") and (cur_file:match("[^\\/]+$") or cur_file) or "?"
  end

  local next_action = action_n
  while true do
    local action = next_action
    next_action = nil  -- subsequent iterations always show picker
    if not action then
      action = pick_from_list("Edit: " .. cur_wav, choices)
      if not action then return end
    end

    if action == 1 then
      local new_wav, new_path, new_type, new_tag = pick_source()
      if new_wav then
        local is_noise = (new_type == "Noise") and NOISE_LOOP_FILES[new_wav]
        configure_rs5k(track, fx_idx, {
          path    = new_path,
          no_loop = is_noise,
          fx_name = make_fx_name(info.note, info.layer, new_type, new_tag),
        })
        info.drum_type = new_type
        info.tag       = new_tag
        refresh_file()
      end
      -- loop back to picker

    elseif action == 2 then
      local vol_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.volume)
      local pan_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.pan)
      local pit_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_st)
      local atk_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.attack)
      local vox_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.max_voices)

      local zone_n_def = 0
      for zi, z in ipairs(PITCH_ZONES) do
        if info.note == z.mid then zone_n_def = zi; break end
      end

      local pnlo_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_note_lo)
      local pnhi_raw = reaper.TrackFX_GetParamNormalized(track, fx_idx, RS5K_PARAM.pitch_note_hi)
      local zone_lo_st_def = math.floor(param_to_pitch(pnlo_raw) + 0.5)
      local zone_hi_st_def = math.floor(param_to_pitch(pnhi_raw) + 0.5)
      if zone_n_def > 0 and zone_lo_st_def == -24 and zone_hi_st_def == -24 then
        zone_lo_st_def, zone_hi_st_def = -7, 10
      end

      local wav_path = (ok_f and cur_file ~= "") and cur_file or ""
      local wn = wav_path:match("[^\\/]+$") or cur_wav

      local new_fx = run_assign_dialog(track, wn, wav_path, info.drum_type, info.tag, {
        note             = info.note,
        layer            = info.layer,
        zone_n           = zone_n_def,
        vol_db           = math.floor(20 * math.log(vol_raw + 1e-9, 10) + 0.5),
        pan_pct          = math.floor((pan_raw - 0.5) * 200 + 0.5),
        pitch_st         = math.floor(param_to_pitch(pit_raw) + 0.5),
        zone_lo_st       = zone_lo_st_def,
        zone_hi_st       = zone_hi_st_def,
        attack           = math.floor(atk_raw * 100 + 0.5) / 100,
        max_voices       = math.floor(vox_raw * 9 + 0.5),
        skip_layer_check = true,
        force_new        = true,
      })
      if new_fx then
        local old_fx_idx = fx_idx
        remove_rs5k(track, old_fx_idx)
        fx_idx = (new_fx > old_fx_idx) and (new_fx - 1) or new_fx
        refresh_file()
      end
      -- loop back to picker

    elseif action == 3 then
      if ok_f and cur_file ~= "" then
        preview_wav(cur_file)
        reaper.MB("Playing preview. Close to stop.", "Preview", 0)
        stop_preview()
      else
        reaper.MB("No sample loaded.", "Preview", 0)
      end
      -- loop back to picker

    elseif action == 4 then
      dump_rs5k_params(track, fx_idx)
      -- loop back to picker

    elseif action == 5 then
      if ask_yes_no("Remove this RS5k instance?", "Confirm Remove") then
        remove_rs5k(track, fx_idx)
        reaper.MB("Removed.", "Done", 0)
        return  -- instance gone, exit
      end
      -- cancelled remove: loop back to picker
    end
  end
end

-- ── Assign to pitch zone (top-level tweak item) ───────────────────────────────
-- Play a note to identify the instance, then pick a zone to move it to.

local function assign_to_zone_flow(track)
  local instances = scan_triaz_instances(track)
  if #instances == 0 then
    reaper.MB("No TRIAZ RS5k instances on this track.", "Assign to pitch zone", 0)
    return
  end

  reaper.MB(
    "Play the note you want to move to a pitch zone, then click OK.",
    "Assign to pitch zone — capture note", 0
  )

  local played_note
  for idx = 0, 31 do
    local retval, buf = reaper.MIDI_GetRecentInputEvent(idx)
    if retval == 0 then break end
    if buf and #buf >= 3 then
      local st  = buf:byte(1)
      local num = buf:byte(2)
      local vel = buf:byte(3)
      if st >= 0x90 and st <= 0x9F and vel > 0 then played_note = num; break end
    end
  end

  if not played_note then
    reaper.MB("No MIDI note captured.", "Error", 0); return
  end

  local matches = {}
  for _, inst in ipairs(instances) do
    if inst.info.note == played_note then matches[#matches + 1] = inst end
  end

  if #matches == 0 then
    reaper.MB("No RS5k instance on note " .. note_name(played_note) .. ".", "Error", 0)
    return
  end

  local inst
  if #matches == 1 then
    inst = matches[1]
  else
    local labels = {}
    for _, m in ipairs(matches) do
      labels[#labels + 1] = string.format("L%d — %s/%s",
        m.info.layer, m.info.drum_type, m.info.tag)
    end
    local n = pick_from_list(
      note_name(played_note) .. " has " .. #matches .. " layers — pick one", labels)
    if not n then return end
    inst = matches[n]
  end

  local zone_lines = {}
  for i, z in ipairs(PITCH_ZONES) do
    zone_lines[#zone_lines + 1] = string.format(
      "%d: %s–%s (center %s)", i, note_name(z.lo), note_name(z.hi), note_name(z.mid))
  end
  local zn = pick_from_list("Pick pitch zone", zone_lines)
  if not zn then return end
  local zone = PITCH_ZONES[zn]

  local ok_s, s_result = reaper.GetUserInputs(
    "Zone pitch range", 2,
    "Pitch at low note st,Pitch at high note st", "-7,10"
  )
  if not ok_s then return end
  local s_parts = {}
  for p in s_result:gmatch("[^,]+") do s_parts[#s_parts + 1] = p end
  local pnlo = tonumber(s_parts[1]) or -7
  local pnhi = tonumber(s_parts[2]) or 10

  local fx_idx = inst.fx_idx
  local info   = inst.info

  configure_rs5k(track, fx_idx, {
    note_lo       = zone.lo,
    note_hi       = zone.hi,
    pitch_note_lo = pnlo,
    pitch_note_hi = pnhi,
    mode          = 0,
    fx_name       = make_fx_name(zone.mid, info.layer, info.drum_type, info.tag),
  })
  save_meta(track, fx_idx, zone.mid, info.layer, info.drum_type, info.tag)
  reaper.MB(
    string.format("%s (%s/%s) → zone %s–%s.",
      note_name(played_note), info.drum_type, info.tag,
      note_name(zone.lo), note_name(zone.hi)),
    "Done", 0
  )
end

-- ── Add new assignment flow ───────────────────────────────────────────────────

local function add_assignment_flow(track)
  local wav_name, full_path, drum_type, tag = pick_source()
  if not wav_name then return end
  run_assign_dialog(track, wav_name, full_path, drum_type, tag, nil)
end

-- ── Kit loader ───────────────────────────────────────────────────────────────

-- Load one voice group: resolve tag, pick WAV, create RS5k per note.
-- pitch_center: if set, pitch_st = (note - pitch_center) per note (pitched toms).
-- tag="" means WAVs live in the drum type root folder (Noise).
-- opts (optional): { pitch_scale=number, pan_list=table }
-- pitch_scale compresses the semitone spread (1.0 = full, 0.5 = half).
-- pan_list[i] overrides pan for the i-th note in the notes array.
local function load_voice(track, drum_type, tag, notes, pitch_center, stats, opts)
  local kw = opts and opts.kw
  local resolved_tag, wav, path

  if kw then
    wav, path = pick_by_keywords(drum_type, kw, opts and opts.used_wavs)
    if not wav then stats.failed = stats.failed + 1; return end
    if opts and opts.used_wavs then opts.used_wavs[path] = true end
    -- extract tag segment from full path
    local type_base = TRIAZ_BASE .. drum_type
    local rel = path:sub(#type_base + 2)              -- "Tag\file.wav" or "file.wav"
    resolved_tag = rel:match("^([^\\/]+)[/\\]") or ""
  else
    if tag == "" then
      resolved_tag = ""
    else
      resolved_tag = find_tag(drum_type, tag)
      if not resolved_tag then stats.failed = stats.failed + 1; return end
    end
    wav, path = pick_kit_wav(drum_type, resolved_tag)
    if not wav then stats.failed = stats.failed + 1; return end
  end

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

-- Inner kit loader — shared by load_vibe_kit_flow and the reload loop.
-- used_wavs: table (path→true) for cross-voice dedup; passed into pick_by_keywords.
local function _do_load_kit(track, genre_n, variant_n, used_wavs)
  local genre   = VIBE_GENRES[genre_n]
  local variant = genre.variants[variant_n]
  local stats   = {loaded=0, failed=0}
  local dkw     = variant.default_kw
  local voices  = variant.voices
  local uw      = used_wavs or {}

  reaper.PreventUIRefresh(1)

  -- Rimshot: keyword-scored with default_kw
  load_voice(track, RIMSHOT_DEFAULT[1], "", {37}, nil, stats, {kw=dkw, used_wavs=uw})

  -- Main voices
  local voice_order = {"kick","kick_alt","snare","snare_alt","clap","hh_c","hh_pedal","hh_o","crash","ride","perc"}
  for _, vkey in ipairs(voice_order) do
    local vdef = voices[vkey]
    if vdef then
      load_voice(track, vdef.type, "", KIT_VOICE_NOTES[vkey], nil, stats, {kw=vdef.kw, used_wavs=uw})
    end
  end

  -- Toms: pitched + panned, keyword-scored
  local tom_def = voices.tom
  if tom_def then
    local pan_list = {}
    for i = 1, #TOM_NOTES do
      pan_list[i] = TOM_PAN_LOW + (i-1)/(#TOM_NOTES-1) * (TOM_PAN_HIGH - TOM_PAN_LOW)
    end
    load_voice(track, tom_def.type, "", TOM_NOTES, TOM_PITCH_CENTER, stats,
      {kw=tom_def.kw, pitch_scale=TOM_PITCH_SCALE, pan_list=pan_list, used_wavs=uw})
  end

  -- Fixed voices: keyword-scored with default_kw
  for _, v in ipairs(KIT_FIXED_VOICES) do
    load_voice(track, v.type, "", v.notes, nil, stats, {kw=dkw, used_wavs=uw})
  end

  -- Lower extras: keyword-scored with default_kw
  for _, v in ipairs(KIT_LOWER_VOICES) do
    load_voice(track, v.type, "", v.notes, nil, stats, {kw=dkw, used_wavs=uw})
  end

  -- Upper zones: 3 empty RS5k slots
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

  if stats.failed > 0 then
    reaper.MB(
      string.format("%s / %s\nLoaded: %d  Failed: %d\n\nSome voices could not be loaded — check library cache.",
        genre.name, variant.name, stats.loaded, stats.failed),
      "Kit: partial load", 0
    )
  end
  return stats
end

-- genre_n, variant_n: indices into VIBE_GENRES (from submenu)
local function load_vibe_kit_flow(track, genre_n, variant_n)
  -- Always overwrite — REAPER undo handles recovery
  local existing = scan_triaz_instances(track)
  for i = #existing, 1, -1 do remove_rs5k(track, existing[i].fx_idx) end
  _do_load_kit(track, genre_n, variant_n, {})
  _loaded_kit = {genre_n, variant_n}
end

-- ── Quick assign ─────────────────────────────────────────────────────────────
-- Browse file → minimal 2-field dialog (note + layer) → assign → preview

local function quick_assign_flow(track)
  local wav_name, full_path, drum_type, tag = pick_source()
  if not wav_name then return end

  local gm_note = (GM_SUGGESTIONS[drum_type] or {36})[1]
  local note_default = pick_note_default(gm_note, wav_name)
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
      local new_wav, new_path, new_type, new_tag = pick_source()
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

  -- For multiple items, choose sequential (chromatic) or manual (ask note each time)
  local sequential = false
  local seq_note, seq_layer
  if #items > 1 then
    local res = reaper.MB(
      string.format("%d items found.\n\nYes = sequential from a start note (chromatic)\nNo = ask note for each item",
        #items),
      "Import Mode", 3
    )
    if res == 2 then return end   -- Cancel
    sequential = (res == 6)       -- Yes = sequential
  end

  if sequential then
    local ok, result = reaper.GetUserInputs(
      string.format("Sequential import: %d items", #items), 2,
      "Start note (e.g. C2),Layer (1-3)",
      "C2,1"
    )
    if not ok then return end
    local sn, sl = parse_note_layer(result)
    if not sn then reaper.MB("Invalid note.", "Error", 0); return end
    seq_note, seq_layer = sn, sl
  end

  local current_note = seq_note

  for idx, full_path in ipairs(items) do
    stop_preview()

    local wav_name = full_path:match("[^\\/]+$") or full_path
    local drum_type, tag = parse_triaz_path(full_path)
    drum_type = drum_type or "Unknown"
    tag       = tag       or ""

    if sequential then
      assign_sample(track, current_note, seq_layer, drum_type, tag, wav_name, full_path, nil)
      current_note = current_note + 1

    else
      -- Manual: filename visible in dialog title; user enters note, then hears preview
      local gm_note = (GM_SUGGESTIONS[drum_type] or {36})[1]
      local note_default = pick_note_default(gm_note, wav_name)
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
    end

    ::continue::
  end

  stop_preview()
end

-- ── Cycle samples ────────────────────────────────────────────────────────────

local function scan_non_zone_instances(track)
  local voices = {}
  for _, inst in ipairs(scan_triaz_instances(track)) do
    if inst.info.drum_type ~= "Zone" then voices[#voices + 1] = inst end
  end
  return voices
end

local function cycle_samples_flow(track)
  -- Partition: toms group, assigned zones, and individual voices
  local zone_mids = {}
  for _, z in ipairs(PITCH_ZONES) do zone_mids[z.mid] = true end

  local tom_group  = {}   -- all Tom instances (cycle together)
  local zone_group = {}   -- assigned zone instances (note == PITCH_ZONES.mid)
  local solo_list  = {}   -- everything else
  for _, v in ipairs(scan_non_zone_instances(track)) do
    if v.info.drum_type == "Tom" then
      tom_group[#tom_group + 1] = v
    elseif zone_mids[v.info.note] then
      zone_group[#zone_group + 1] = v
    else
      solo_list[#solo_list + 1] = v
    end
  end

  -- entries: {label, etype, instances, drum_type, tag, cur_wav}
  local entries = {}

  local function get_file0(fx_idx)
    local ok_f, f = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "FILE0")
    return (ok_f and f ~= "") and (f:match("[^\\/]+$") or f) or "?"
  end

  for _, v in ipairs(solo_list) do
    local info    = v.info
    local cur_wav = get_file0(v.fx_idx)
    local tag     = (info.tag ~= "" and info.tag ~= "(root)") and info.tag or ""
    local lbl     = note_name(info.note) .. "  " .. info.drum_type
    if tag ~= "" then lbl = lbl .. " / " .. tag end
    entries[#entries + 1] = {
      label     = lbl .. " — " .. cur_wav,
      etype     = "solo",
      instances = {v},
      drum_type = info.drum_type,
      tag       = tag,
      cur_wav   = cur_wav,
    }
  end

  if #tom_group > 0 then
    local v0      = tom_group[1]
    local cur_wav = get_file0(v0.fx_idx)
    local tag     = (v0.info.tag ~= "" and v0.info.tag ~= "(root)") and v0.info.tag or ""
    -- Show note range of grouped toms
    local lo_note = tom_group[1].info.note
    local hi_note = tom_group[#tom_group].info.note
    local note_rng = note_name(lo_note) .. "–" .. note_name(hi_note)
    local lbl = note_rng .. "  Tom" .. (tag ~= "" and " / " .. tag or "")
    entries[#entries + 1] = {
      label     = lbl .. " — " .. cur_wav,
      etype     = "toms",
      instances = tom_group,
      drum_type = "Tom",
      tag       = tag,
      cur_wav   = cur_wav,
    }
  end

  if #zone_group > 0 then
    entries[#entries + 1] = {
      label     = "Pitch Zones (" .. #zone_group .. " assigned)",
      etype     = "zones",
      instances = zone_group,
    }
  end

  if #entries == 0 then
    reaper.MB("No samples loaded on this track.", "Cycle Samples", 0)
    return
  end

  local labels = {}
  for _, e in ipairs(entries) do labels[#labels + 1] = e.label end

  local pick = pick_from_list("Cycle samples — pick voice", labels)
  if not pick then return end

  local entry = entries[pick]

  -- Zones: sub-pick which zone then enter cycle loop for that one
  if entry.etype == "zones" then
    local zlabels = {}
    for _, v in ipairs(entry.instances) do
      local cur_wav = get_file0(v.fx_idx)
      local zn = "Zone ?"
      for zi, z in ipairs(PITCH_ZONES) do
        if v.info.note == z.mid then
          zn = "Zone " .. zi .. " (" .. note_name(z.lo) .. "–" .. note_name(z.hi) .. ")"
          break
        end
      end
      local tag = (v.info.tag ~= "" and v.info.tag ~= "(root)") and v.info.tag or ""
      local lbl = zn .. "  " .. v.info.drum_type
      if tag ~= "" then lbl = lbl .. " / " .. tag end
      zlabels[#zlabels + 1] = lbl .. " — " .. cur_wav
    end
    local zpick = pick_from_list("Pick zone", zlabels)
    if not zpick then return end
    local zv = entry.instances[zpick]
    local tag = (zv.info.tag ~= "" and zv.info.tag ~= "(root)") and zv.info.tag or ""
    entry = {
      etype     = "solo",
      instances = {zv},
      drum_type = zv.info.drum_type,
      tag       = tag,
      cur_wav   = get_file0(zv.fx_idx),
    }
  end

  -- ── Cycle loop ───────────────────────────────────────────────────────────────
  local drum_type   = entry.drum_type
  local current_tag = entry.tag
  local current_wav = entry.cur_wav
  local instances   = entry.instances

  local function get_wavs_for_tag(tag)
    local path = TRIAZ_BASE .. drum_type
    if tag ~= "" then path = path .. "\\" .. tag end
    return list_wavs(path), path
  end

  local wavs, wav_dir = get_wavs_for_tag(current_tag)
  local current_idx = 1
  for i, w in ipairs(wavs) do
    if w == current_wav then current_idx = i; break end
  end

  local is_hh_open = (drum_type == "HiHat Open")

  local function swap_group(wav_name, full_path, tag)
    local is_noise = (drum_type == "Noise") and NOISE_LOOP_FILES[wav_name]
    local disp_tag = (tag ~= "" and tag ~= "(root)") and tag or "(root)"
    for _, v in ipairs(instances) do
      configure_rs5k(track, v.fx_idx, {
        path            = full_path,
        no_loop         = is_noise,
        obey_note_off   = is_noise or is_hh_open,
        hh_open_release = is_hh_open,
        fx_name         = make_fx_name(v.info.note, v.info.layer, drum_type, disp_tag),
      })
      save_meta(track, v.fx_idx, v.info.note, v.info.layer, drum_type, disp_tag)
    end
  end

  local all_tags = (drum_type ~= "Noise") and list_dirs(TRIAZ_BASE .. drum_type) or {}
  -- Fixed nav items; WAVs appended inline each iteration (current marked with *)
  local IDX_PREV = 1; local IDX_NEXT = 2
  local IDX_TAG  = #all_tags > 0 and 3 or nil
  local IDX_DONE = IDX_TAG and 4 or 3
  local WAV_OFFSET = IDX_DONE  -- wav items start at IDX_DONE + 1

  while true do
    local header = drum_type
    if current_tag ~= "" then header = header .. " / " .. current_tag end
    header = header .. " — " .. current_wav

    local items = {"Previous", "Next"}
    if IDX_TAG then items[#items + 1] = "Change tag" end
    items[#items + 1] = "Done"
    for i, w in ipairs(wavs) do
      items[#items + 1] = (i == current_idx and "* " or "") .. w
    end

    local choice = pick_from_list(header, items)
    if not choice or choice == IDX_DONE then break end

    if choice == IDX_PREV then
      if #wavs > 0 then
        current_idx = (current_idx - 2) % #wavs + 1
        current_wav = wavs[current_idx]
        swap_group(current_wav, wav_dir .. "\\" .. current_wav, current_tag)
      end

    elseif choice == IDX_NEXT then
      if #wavs > 0 then
        current_idx = current_idx % #wavs + 1
        current_wav = wavs[current_idx]
        swap_group(current_wav, wav_dir .. "\\" .. current_wav, current_tag)
      end

    elseif IDX_TAG and choice == IDX_TAG then
      local t = pick_from_list("Tag — " .. drum_type, all_tags)
      if t then
        current_tag = all_tags[t]
        wavs, wav_dir = get_wavs_for_tag(current_tag)
        current_idx = 1
        if #wavs > 0 then
          current_wav = wavs[current_idx]
          swap_group(current_wav, wav_dir .. "\\" .. current_wav, current_tag)
        end
      end

    elseif choice > IDX_DONE then
      local wav_pick = choice - WAV_OFFSET
      if wav_pick >= 1 and wav_pick <= #wavs then
        current_idx = wav_pick
        current_wav = wavs[current_idx]
        swap_group(current_wav, wav_dir .. "\\" .. current_wav, current_tag)
      end
    end
  end
end

-- ── Randomize ────────────────────────────────────────────────────────────────

-- Extract character keywords from a TRIAZ WAV filename for "similar" scoring.
-- "wa-triaz-kick_elec-808-afro_crack.wav" → {"kick","elec","808","afro","crack"}
local function extract_kw_from_wav(wav_name)
  local inner = wav_name:lower():gsub("%.wav$",""):gsub("^wa%-triaz%-","")
  local words = {}
  for w in inner:gmatch("[a-z0-9]+") do
    if #w >= 3 then words[#words + 1] = w end
  end
  return words
end

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

  local voices = scan_non_zone_instances(track)

  if #voices == 0 then
    reaper.MB("No voice instances on track. Load a kit first.", "Randomize", 0)
    return
  end

  local modes = {
    "1  Single voice — same type/tag, new random WAV",
    "2  Entire kit  — same type/tag, new random WAV each voice",
    "3  Entire kit  — random tag within same drum type",
    "4  Full random — random type/tag/WAV every voice",
    "5  Similar     — stay close to current character (all voices)",
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

  elseif mode == 5 then
    -- Similar: score all WAVs in same drum type by keywords from current filename.
    -- Pick highest-scoring WAV that isn't the current one.
    local changed, failed = 0, 0
    for _, inst in ipairs(voices) do
      local info = inst.info
      local ok_f, cur_file = reaper.TrackFX_GetNamedConfigParm(track, inst.fx_idx, "FILE0")
      local cur_wav = (ok_f and cur_file ~= "") and (cur_file:match("[^\\/]+$") or "") or ""
      local kw = extract_kw_from_wav(cur_wav)
      if #kw == 0 then
        -- no keywords — fall back to random same type/tag
        if apply_random_wav(track, inst, nil, nil) then changed = changed + 1
        else failed = failed + 1 end
      else
        -- score all WAVs across type, skip current
        local tags = list_dirs(TRIAZ_BASE .. info.drum_type)
        local best_score, best_wav, best_path = -1, nil, nil
        local function try_sim(tag, dir)
          for _, wav in ipairs(list_wavs(dir)) do
            if wav ~= cur_wav then
              local s = score_wav_kw(tag, wav, kw)
              if s > best_score then
                best_score, best_wav, best_path = s, wav, dir .. "\\" .. wav
              end
            end
          end
        end
        if #tags == 0 then
          try_sim("", TRIAZ_BASE .. info.drum_type)
        else
          for _, tag in ipairs(tags) do
            try_sim(tag, TRIAZ_BASE .. info.drum_type .. "\\" .. tag)
          end
        end
        if best_wav then
          local is_noise   = (info.drum_type == "Noise") and NOISE_LOOP_FILES[best_wav]
          local is_hh_open = (info.drum_type == "HiHat Open")
          local tag_from_path = best_path:match("[^\\/]+[/\\]([^\\/]+)[/\\][^\\/]+$") or info.tag
          configure_rs5k(track, inst.fx_idx, {
            path            = best_path,
            no_loop         = is_noise,
            obey_note_off   = is_noise or is_hh_open,
            hh_open_release = is_hh_open,
            fx_name         = make_fx_name(info.note, info.layer, info.drum_type, tag_from_path),
            meta            = {note=info.note, layer=info.layer, drum_type=info.drum_type, tag=tag_from_path},
          })
          changed = changed + 1
        else
          failed = failed + 1
        end
      end
    end
    reaper.MB(string.format("Similar: %d voices updated. Failed: %d.", changed, failed), "Done", 0)
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
This script gives you the TRIAZ drum plugin's browse-and-build workflow
using only native REAPER tools — no inaccessible drawn windows. The goal
is to match, and in places improve on, what the visual TRIAZ plugin does,
in a fully screen-reader-friendly way.

It loads TRIAZ samples into ReaSamplOmatic5000 (RS5k) on a track. Each
sample gets its own RS5k instance on a MIDI note; play that note and the
sample plays.

TIP: Use your screen reader's object navigation to read this help in full.

HOW THE LIBRARY IS ORGANIZED
-----------------------------
Three levels: Drum Type (e.g. "Kick Electronic") > Tag (e.g. "Deep",
"808") > WAV files. Browsing walks you through them in that order.

LIBRARY CACHE
-------------
On first run the script scans the whole library and caches every Drum
Type, Tag, and WAV. A dialog lets you confirm or correct the library
path. The scan takes up to a minute and the window looks frozen while it
runs — that is expected.

The cache is saved here and survives REAPER restarts, so the scan only
happens once:
  <REAPER resource path>\Scripts\triaz_browser_cache.lua
Find that folder via Options > Show REAPER resource path in explorer.

To rebuild: use "Refresh library cache" or "Change library path" in the
menu, or just delete the cache file by hand — it rebuilds next run.

NOTES AND LAYERS
----------------
Each RS5k instance sits on a MIDI note (C2 = MIDI 36 = Kick in General
MIDI). The script suggests a GM note per drum type. You can stack up to 3
samples on one note (layers 1-3) — all play together.
]]
    },
    {
      title = "TRIAZ RS5k Browser — Help (2/4): Main Menu Items",
      text = [[
MAIN MENU — WHAT EACH ITEM DOES
---------------------------------

ADD / ASSIGN SAMPLE
  Pick a source (file browser, or "From selected item" if timeline audio
  is selected), then a full dialog: note, layer, pitch zone, volume, pan,
  pitch, zone pitch lo/hi, attack, voices. Previews, then keep / try
  another / discard.

QUICK ASSIGN
  Same source picker but asks only for note and layer. Fast path when you
  don't need vol/pan/pitch.

IMPORT SELECTED
  Batch-assigns all selected timeline audio items — each gets its own
  note + layer dialog and preview. Only shows when items are selected.

LOAD KIT
  Loads a full drum kit in one shot. Navigate: genre submenu → variant.
  Genres: Techno, House, Drum & Bass, Electronica, Lo-Fi, Pop & Disco,
  Rap, Acoustic, World, Trance. Each genre has 2-5 character variants
  (Dark, Punchy, 808 Sub, Uplifting, etc.). WAVs are chosen by scoring
  the full library against keyword lists — duplicate files are avoided so
  kick and kick_alt always get distinct sounds. Always overwrites existing
  instances (use REAPER Undo to reverse). Returns to main menu after load.
  Fills notes 21-108 (kicks/snares/hats/toms/perc/extras) plus 3 empty
  pitch-zone slots at 88-108.

TWEAK
  Top of the submenu:
    - Assign to pitch zone (play note) — play a note; the script finds that
      sample and asks which zone to move it to + pitch range (default -7/+10).
    - Cycle samples (see below).
  Each loaded sample also gets its own sub-menu:
    - Swap sample      Pick a different WAV
    - Edit parameters  Full dialog, pre-filled with current values
    - Preview          Play it
    - Dump RS5k params Show all parameter values (message box + console)
    - Remove           Delete this instance

CYCLE SAMPLES  (inside Tweak)
  Live browsing — swap sounds while the kit plays, no keep/discard.
  Pick a voice (toms group as one; zones ask which zone first), then use
  Previous / Next / Change tag / Done, or pick any WAV from the listed tag
  (current one marked *). Swaps apply instantly.

RANDOMIZE
  1. Single voice       one instance, new WAV (same type/tag)
  2. Entire kit         every instance, new WAV (same type/tag)
  3. Entire kit + tags  also random tag (same drum type)
  4. Full random        random type/tag/WAV everywhere
  5. Similar            stays close to current character — scores all WAVs
                        in same drum type by keywords from current filename,
                        picks highest-scoring different sound per voice

REFRESH LIBRARY CACHE
  Rescans the whole library — use after adding/removing samples. Takes up
  to a minute (window looks frozen while scanning; expected).

CHANGE LIBRARY PATH
  Point the script at a new library folder (pre-filled with current path).
  Clears the old cache and scans the new location. Remembered across
  restarts.
]]
    },
    {
      title = "TRIAZ RS5k Browser — Help (3/4): Kits and Zones",
      text = [[
VIBE KITS
---------
Genre → variant submenus mirror the TRIAZ preset browser. Genres:
Techno (Dark / Punchy / Classic 909 / 808 Sub / Industrial / Detroit / Minimal)
House (Classic / Electronic / Deep / Disco / Afro / Chicago / Micro)
Drum & Bass (Dark / Liquid / Jungle / Roller)
Electronica (IDM / Ambient)
Lo-Fi (Tape / Boom Bap)
Pop & Disco (Pop / Disco)
Rap (Trap 808 / Boom Bap / UK Drill)
Acoustic (Studio / Live)
World (Organic / Latin / African / Tribal)
Trance (Uplifting / Tech / Dark Psy)
Funk (Classic / 80s Linn / Miami Bass)
Jazz (Brushed / Bebop)
Reggae & Dub (Roots / Dub)
Breakbeat (Amen / Big Beat)
Afrobeat (Classic / Contemporary)
Footwork (Chicago / Juke)

Each voice (kick, snare, hats, etc.) has a keyword list. The full TRIAZ
library is scored across every tag — highest match wins. Fixed voices and
lower extras use the variant's default keywords so everything stays
cohesive. No confirmation dialog unless voices fail to load.

UPPER PITCH ZONES (notes 88-108)
---------------------------------
Three empty slots for pitched samples:
  Zone 1: E5-A#5  (88-94,  center MIDI 91)
  Zone 2: B5-F6   (95-101, center MIDI 98)
  Zone 3: F#6-C7  (102-108, center MIDI 105)

A zone sets a pitch offset at its lowest and highest key, interpolating
across the keys between. "Pitch at low/high note" = semitone offset at
each end; e.g. lo=-7, hi=+10 sweeps the pitch up across the zone.

Assign to a zone:
  - Add / assign sample: enter zone # (1-3) and the lo/hi pitch fields.
  - Tweak > Assign to pitch zone (play note): play an instance's note to
    pick it, choose the zone, set lo/hi.
Edit later via Tweak > (instance) > Edit parameters — changing zone #
moves it to a different range.

NOISE SAMPLES AND LOOPING
--------------------------
The 10 Noise WAVs have embedded loop points; the script disables looping
so they play once and stop. Hi-Hat Open uses a short note-off release
(~50ms) to fade cleanly on key release.
]]
    },
    {
      title = "TRIAZ RS5k Browser — Help (4/4): Tips and Troubleshooting",
      text = [[
TIPS FOR SCREEN READER USERS
-----------------------------
- Menus are native context menus — navigate with arrow keys.
- Data entry uses standard REAPER input dialogs (Tab between fields).
- Preview dialogs are message boxes — Enter or Space closes them and
  stops playback.
- "Dump RS5k params" also prints to the ReaScript console (open it from
  the Actions list — search "ReaScript console output").

TRACK SETUP
-----------
Uses the currently selected track. Select one before running. If nothing
is selected — or the master track or a folder track is — the script
exits silently. To switch tracks, select another and re-run.

OVERWRITING A KIT
-----------------
Loading a kit always clears existing instances first. Use REAPER Undo
(Ctrl+Z) immediately after if you want to go back.

COMMON ISSUES
-------------
"RS5k not found"
  ReaSamplOmatic5000 ships with REAPER — check it isn't disabled in prefs.

"Cannot parse DrumType/Tag from path"
  File isn't inside the Drum Type / Tag / WAV structure. Browse into your
  library folder first.

"No WAVs found"
  Tag folder empty or path wrong. Try another tag, or "Change library
  path" if you moved the library.

Menu out of date / samples missing after moving the library
  "Refresh library cache" to rescan, or "Change library path" for a new
  location.
]]
    },
  }

  for _, page in ipairs(pages) do
    reaper.MB(page.text, page.title, 0)
  end
end

-- ── Main menu (structured with submenus) ─────────────────────────────────────

-- Builds menu string + parallel action list, shows it, runs chosen action.
-- Returns: continue (bool), track.
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

  -- Import selected: flat item, batch only (single-item access via Add / assign)
  if #sel_paths > 0 then
    add(string.format("Import selected (%d)", #sel_paths),
      function() import_selected_items_flow(track) end)
  else
    add("#Import selected (0)")
  end

  -- Load kit: genre → variant submenus
  open_sub("Load kit")
  for gi, genre in ipairs(VIBE_GENRES) do
    open_sub(genre.name)
    for vi, variant in ipairs(genre.variants) do
      local g, v = gi, vi
      local is_loaded = _loaded_kit and _loaded_kit[1] == gi and _loaded_kit[2] == vi
      local label = is_loaded and ("!" .. variant.name) or variant.name
      add(label, function() load_vibe_kit_flow(track, g, v) end)
    end
    close_sub()
  end
  close_sub()

  -- Tweak submenu: each instance expands to its 6 actions
  if inst_count > 0 then
    open_sub(string.format("Tweak (%d)", inst_count))
    add("Assign to pitch zone (play note)", function() assign_to_zone_flow(track) end)
    add("Cycle samples",                    function() cycle_samples_flow(track) end)
    for i, inst in ipairs(instances) do
      local info  = inst.info
      local idx   = i
      local label = string.format("L%d %s — %s/%s", info.layer, note_name(info.note), info.drum_type, info.tag)
      open_sub(label)
      add("Swap sample",      function() tweak_mode(track, idx, 1) end)
      add("Edit parameters",  function() tweak_mode(track, idx, 2) end)
      add("Preview",          function() tweak_mode(track, idx, 3) end)
      add("Dump RS5k params", function() tweak_mode(track, idx, 4) end)
      add("Remove",           function() tweak_mode(track, idx, 5) end)
      close_sub()
    end
    close_sub()
  else
    add("#Tweak (0 instances)")
  end

  add("Randomize",             function() randomize_flow(track) end)
  add("Refresh library cache", function() clear_cache() end)
  add("Change library path",   function() change_library_path() end)
  add("Help",                  function() show_help() end)
  local exit_pos = add("Close menu")

  gfx.init("", 0, 0, 0, 0, 0)
  gfx.x, gfx.y = 0, 0
  local choice = gfx.showmenu(table.concat(parts, "|"))
  gfx.quit()

  if choice == 0         then return true,  track end
  if choice == exit_pos  then return false, track end

  local fn = actions[choice]
  if fn then fn() end
  return true, track
end

-- ── Main ──────────────────────────────────────────────────────────────────────

local function main()
  reaper.Undo_BeginBlock()

  if not _cache_loaded then
    local choice = reaper.MB(
      "No TRIAZ library cache found.\n\n" ..
      "Do you have the Wave Alchemy TRIAZ library installed?\n\n" ..
      "Yes  =  scan library and build cache (takes ~1 minute)\n" ..
      "No   =  skip scan and use RS5k manager features only",
      "TRIAZ Browser", 4)
    if choice == 6 then
      build_cache()
    else
      local f = io.open(CACHE_PATH, "w")
      if f then f:write("return {_no_library = true}\n"); f:close() end
      _cache_loaded = true
    end
  end

  local track = select_track()
  if not track then
    reaper.Undo_EndBlock("TRIAZ Browser (no track)", -1)
    return
  end

  local keep_going = true
  while keep_going do
    keep_going, track = show_main_menu(track)
  end

  reaper.Undo_EndBlock("TRIAZ Browser", -1)
  save_cache()
  stop_preview()
end

main()
