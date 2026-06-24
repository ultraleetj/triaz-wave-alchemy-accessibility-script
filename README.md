# TRIAZ Wave Alchemy Accessibility Script

A fully screen-reader-accessible REAPER script for browsing the **Wave Alchemy TRIAZ** drum library and building kits with ReaSamplOmatic5000 (RS5k).

It gives you the TRIAZ plugin's browse-and-build workflow using only native REAPER dialogs, with no inaccessible drawn windows. The goal is to match, and in places improve on, what the visual TRIAZ plugin does, in a way that works cleanly with a screen reader (tested with OSARA + NVDA).

**Don't own TRIAZ?** The script also works as a general-purpose RS5k manager. You can browse any folder of WAVs, assign samples to MIDI notes, swap, tweak, preview, and randomize voices -- everything except the TRIAZ-specific kit presets and cache. See [Using without TRIAZ](#using-without-triaz) below.

## Download

**[Download `triaz_browser.lua` (latest release)](https://github.com/ultraleetj/triaz-wave-alchemy-accessibility-script/releases/latest/download/triaz_browser.lua)**

Right-click and choose *Save link as…* if your browser opens it in a tab.

## Install

1. Save `triaz_browser.lua` into your REAPER **Scripts** folder.
   Find it via *Options, Show REAPER resource path in explorer/finder…* then open the `Scripts` subfolder.
2. In REAPER, open the **Actions** list (`?`), click **New action, Load ReaScript…**, and pick `triaz_browser.lua`.
3. Optionally bind it to a key or toolbar button.

### Requirements

- **REAPER** (Windows)
- **SWS/S&M extension** for sample preview (`CF_Preview`)
- **js_ReaScriptAPI** for the native file browser dialog
- **OSARA** screen reader accessibility layer (recommended)
- The **Wave Alchemy TRIAZ** sample library installed locally *(optional — see below)*

## First run

On the first launch the script scans your TRIAZ library and builds a cache of every Drum Type, Tag, and WAV. A dialog lets you confirm or correct the library path. The scan takes up to a minute and the window will appear frozen while it runs. This is expected.

The cache is saved to `<REAPER resource path>\Scripts\triaz_browser_cache.lua` and survives REAPER restarts, so the scan only happens once. After that the menu opens instantly.

If you move the library or add samples, use **Refresh library cache** or **Change library path** from the menu to rebuild.

## What it does

- Browse the TRIAZ library by Drum Type, Tag, and WAV, then assign samples to MIDI notes on any RS5k instrument.
- **320 genre-based vibe kits** across 16 genres and 20 variants each (Techno, House, DnB, Electronica, Lo-Fi, Rap, Acoustic, World, Funk, Jazz, Reggae and Dub, Breakbeat, Afrobeat, Footwork, Trance, Pop and Disco) -- loaded in one shot with pitched/panned toms, perc, and pitch zones.
- **Quick assign** and **batch import** of selected timeline items.
- **Tweak** any voice: swap sample, edit parameters, preview, remove.
- **Cycle samples** live while the kit plays.
- **Randomize** a single voice or the whole kit (5 modes including keyword-similarity matching).
- Three upper **pitch zones** for melodic/pitched samples.

Full in-app help is available from the menu (**Help**).

## Using without TRIAZ

If you point the script at any folder of WAVs (or skip the library scan), the core RS5k management tools still work:

- **Add / assign sample** — file browser, assign to any MIDI note, set pitch, volume, pan, attack, voice count.
- **Quick assign** — one-step note + file assignment.
- **Import selected** — drag audio items from the timeline directly into RS5k slots.
- **Tweak** — swap, edit parameters, preview, remove any RS5k instance on the track.
- **Randomize** — randomize samples across instances.
- **Pitch zones** — configure RS5k pitch scaling zones for melodic use.

The TRIAZ-specific features (genre kits, Drum Type/Tag browser, library cache) require the TRIAZ library. Everything else works with any WAV collection.

## Accessibility

Everything runs through native REAPER message boxes, input dialogs, and context menus, all reachable with arrow keys and Tab, and announced by your screen reader. No GFX canvas UI is used for interaction.

## Contributing

Bug reports, feature suggestions, and pull requests are welcome. Open an issue on GitHub if something is not working or you have an idea for improvement.

## Credits

Built by **ultraleetj** with [Claude Code](https://claude.com/claude-code) (Anthropic).

TRIAZ is a product of **Wave Alchemy**. This is an independent, unofficial accessibility tool and is not affiliated with or endorsed by Wave Alchemy.

## License

MIT
