# K3 Audio Player (k3aplayer.koplugin)

A music player plugin for KOReader on the **Kindle 3 (Kindle Keyboard)**. It plays the MP3 files in
the Kindle's `music` folder through the Kindle's own audio stack (GStreamer 0.10), in a separate
process, so the music keeps playing while you read.

## Install

Copy the `k3aplayer.koplugin` folder into KOReader's `plugins` folder (for example
`/mnt/us/koreader/plugins/`) and restart KOReader. Put MP3 files in the Kindle's `music` folder over
USB.

## Use

Main menu → **Tools** → **Music player**:

- **Open the player**: the player screen if a song is loaded, otherwise the song list.
- **Play / Pause**, **Next song**, **Stop the music**.
- **Music folder**: choose another folder (default `/mnt/us/music`).
- **Music keys**: turn the global keys on or off.
- **Player keys**: a summary of all keys.

Global keys (when enabled):

| Keys | Action |
| --- | --- |
| Alt + Space | play / pause |
| Alt + F | next song |
| Alt + M | open the player |
| Volume + / − | music volume (while a song is loaded) |

While you type in a text box, Alt keeps typing as usual.

In the player: ◀ ▶ move between the buttons, ▲ ▼ go down to "Up next", Press activates, the page
keys change song, Menu opens the options (sleep timer, volume, repeat, shuffle, go to minute, song
list, stop) and Back returns while the music keeps playing.

The same actions are available to the Dispatcher (gestures, profiles): open the player, play /
pause, next song, previous song.

## How it works

- `k3aplayer_engine.lua` runs as its own process with KOReader's `luajit` and drives GStreamer over
  FFI (`fdsrc ! mfw_mp3decoder ! … ! alsasink`). Seeking reopens the file at the right byte, which
  is much faster on the K3 than GStreamer's own seek. It quits by itself when KOReader exits.
- `k3aplayer_music.lua` keeps the list, order, repeat, shuffle and sleep timer, and talks to the
  engine through a FIFO in `/tmp/k3aplayer`.
- `k3aplayer_screens.lua` draws the player and the song list. On the K3 everything is painted in
  Lua, so the screens repaint only what changes, the buttons and cover are SVG icons (`icons/`)
  rendered once and then copied, and the screen is kept in memory to come back instantly after the
  options panel or a notice.
- `k3aplayer_jit.lua` keeps room for LuaJIT's compiled code on the K3 (otherwise, after a while,
  every repaint becomes ~30× slower).

The engine log goes to `k3aplayer.log` in KOReader's folder.

## Requirements

Kindle 3 with KOReader (legacy build for the Kindle 3). Other Kindles do not have the same
GStreamer elements; the player screens will open but the engine will report an error.
