# Changelog

## 1.0 — 2026-11-27

First release.

- Plays the MP3 files of the Kindle 3's music folder with the Kindle's own GStreamer, in a separate
  process, so the music keeps playing while reading.
- Player screen (cover, progress, five buttons, "Up next"), song list with "All" and "Shuffle",
  options panel (sleep timer, volume, repeat, shuffle, go to minute, song list, stop, keys, About).
- Global keys: Alt + Space, Alt + F, Alt + M and the volume keys. Dispatcher actions.
- Partial repaints, SVG buttons painted by copying bytes and a cached screen, for the K3's slow
  Lua painting. LuaJIT machine-code fence against the K3's long-run slowdown.
- About screen with the app icon, author and GitHub address.
- English only (KOReader's own translations are not mixed in).
