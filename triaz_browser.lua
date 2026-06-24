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
    _dir_cache    = cached
    _cache_loaded = true
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

local function build_cache()
  -- Confirm or correct library path before scanning
  local ok, fields = reaper.GetUserInputs(
    "TRIAZ Library Path", 1,
    "Samples folder (edit if needed),extrawidth=400", TRIAZ_BASE)
  if not ok or fields == "" then
    reaper.MB("Cancelled — no cache built.", "TRIAZ Browser", 0)
    return false
  end
  local new_path = fields:gsub("[\\/]+$", "") .. "\\"
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
  local ok, fields = reaper.GetUserInputs(
    "TRIAZ Library Path", 1,
    "Samples folder,extrawidth=400", TRIAZ_BASE)
  if not ok or fields == "" then return end
  local new_path = fields:gsub("[\\/]+$", "") .. "\\"
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
-- Scans the full type across every tag — no pre-selection needed.
local function pick_by_keywords(drum_type, kw)
  local tags = list_dirs(TRIAZ_BASE .. drum_type)
  local best_score, best_wav, best_path = -1, nil, nil
  local function try_dir(tag, dir)
    local wavs = list_wavs(dir)
    for _, wav in ipairs(wavs) do
      local s = score_wav_kw(tag, wav, kw)
      if s > best_score then
        best_score, best_wav, best_path = s, wav, dir .. "\\" .. wav
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
  return best_wav, best_path
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

  local note_default = defs.note and note_name(defs.note) or pick_note_default(gm_note)
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
    wav, path = pick_by_keywords(drum_type, kw)
    if not wav then stats.failed = stats.failed + 1; return end
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

-- genre_n, variant_n: indices into VIBE_GENRES (from submenu)
local function load_vibe_kit_flow(track, genre_n, variant_n)
  local genre   = VIBE_GENRES[genre_n]
  local variant = genre.variants[variant_n]

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

  local stats  = {loaded=0, failed=0}
  local dkw    = variant.default_kw
  local voices = variant.voices

  reaper.PreventUIRefresh(1)

  -- Rimshot: keyword-scored with default_kw
  load_voice(track, RIMSHOT_DEFAULT[1], "", {37}, nil, stats, {kw=dkw})

  -- Main voices
  local voice_order = {"kick","kick_alt","snare","snare_alt","clap","hh_c","hh_pedal","hh_o","crash","ride","perc"}
  for _, vkey in ipairs(voice_order) do
    local vdef = voices[vkey]
    if vdef then
      load_voice(track, vdef.type, "", KIT_VOICE_NOTES[vkey], nil, stats, {kw=vdef.kw})
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
      {kw=tom_def.kw, pitch_scale=TOM_PITCH_SCALE, pan_list=pan_list})
  end

  -- Fixed voices: keyword-scored with default_kw
  for _, v in ipairs(KIT_FIXED_VOICES) do
    load_voice(track, v.type, "", v.notes, nil, stats, {kw=dkw})
  end

  -- Lower extras: keyword-scored with default_kw
  for _, v in ipairs(KIT_LOWER_VOICES) do
    load_voice(track, v.type, "", v.notes, nil, stats, {kw=dkw})
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

  -- Only report if there were failures
  if stats.failed > 0 then
    reaper.MB(
      string.format("%s / %s\nLoaded: %d  Failed: %d\n\nSome voices could not be loaded — check library cache.",
        genre.name, variant.name, stats.loaded, stats.failed),
      "Kit: partial load", 0
    )
  end
end

-- ── Quick assign ─────────────────────────────────────────────────────────────
-- Browse file → minimal 2-field dialog (note + layer) → assign → preview

local function quick_assign_flow(track)
  local wav_name, full_path, drum_type, tag = pick_source()
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
  Rap, Acoustic, World. Each genre has 2-5 character variants (Dark,
  Punchy, 808 Sub, etc.). WAVs are chosen by scoring the full library
  against keyword lists — so every voice gets the best matching sound.
  Fills notes 21-108 (kicks/snares/hats/toms/perc/extras) plus 3 empty
  pitch-zone slots at 88-108. Returns to menu immediately; only shows a
  dialog if some voices failed to load.

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
Techno (Dark / Punchy / Classic 909 / 808 Sub / Industrial)
House (Classic / Electronic / Deep / Disco)
Drum & Bass (Dark / Liquid)
Electronica (IDM / Ambient)
Lo-Fi (Tape / Boom Bap)
Pop & Disco (Pop / Disco)
Rap (Trap 808 / Boom Bap)
Acoustic (Studio / Live)
World (Organic)

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
Load kit when the track already has instances:
  Yes = replace all with a fresh kit | No = add alongside | Cancel = abort

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
      add(variant.name, function() load_vibe_kit_flow(track, g, v) end)
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

  if not _cache_loaded then build_cache() end

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
