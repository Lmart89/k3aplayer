<p align="right"><sub>🌐 <b>English</b> · <a href="readme-es.md">Español</a></sub></p>

# K3aPlayer

**K3 Audio Player**: an audio player for the **Kindle 3 (Keyboard)** built on [KOReader](https://koreader.rocks/).

It uses the device's **own audio hardware**: the built-in speakers and the **3.5 mm headphone jack**. No Bluetooth, no adapters.

<p align="center">
  <img src="docs/pantalla.png" alt="K3aPlayer screen on the Kindle 3: current track, progress bar, playback controls and queue" width="360">
  <br>
  <sub>The interface is currently in Spanish.</sub>
</p>

## Why Kindle 3 only?

The Kindle 3 is one of the few Kindles with dedicated audio hardware (speakers and a headphone jack). Newer models rely on Bluetooth to play sound. K3aPlayer is built to take advantage of exactly that, which is why this is a version specific to this device.

## Features

- Plays **MP3** files stored on the Kindle.
- **"Now playing"** screen with the track title, file name and position in the list (for example, *Song 6 of 30*).
- **Progress bar** with elapsed time and total duration.
- Controls: **previous**, **−15 s**, **play/pause**, **+15 s** and **next**.
- Adjustable **volume**.
- **Repeat** (for example, *all*) and **Shuffle**.
- **"Up next"** queue showing the upcoming songs and their duration.
- **Music keeps playing** when you go back to read or use another KOReader feature.
- Works with the K3's physical keys: arrows to select, *Press* to activate and *Menu* for options.

## How it works

The Kindle 3 already ships with a GStreamer-based audio service (`com.lab126.audio`, run by `audioServer`), which is what its native MP3 player uses. K3aPlayer includes no decoder of its own: it sends playback commands to that service through `lipc` (create, start, pause, seek, volume), and the interface is built with KOReader's widgets.

## Requirements

- A **jailbroken** Kindle 3 (Keyboard).
- **KOReader** installed on the Kindle (a legacy version compatible with the K3).
- MP3 audio files stored on the Kindle.

## Installation

> These steps are a guide; adjust the paths to your own setup.

**As a KOReader plugin**

1. Connect the Kindle to your computer over USB.
2. Copy the `k3aplayer.koplugin` folder into `koreader/plugins/`.
3. Eject the Kindle, open KOReader and enable the plugin from the menu.

**As a standalone app**

Coming soon: a version that opens the player directly, without the rest of KOReader's features.

## Roadmap

- [ ] Standalone app version.
- [ ] Internet radio (BBN Radio) via streaming.

## Disclaimer

K3aPlayer is an independent community project. It is not affiliated with or endorsed by Amazon or the KOReader project. *Kindle* is a registered trademark of Amazon.com, Inc.

## License

K3aPlayer is released under the **GNU AGPL-3.0** license, the same as KOReader, from which it is derived. See the `LICENSE` file.

## Acknowledgments

- The [KOReader](https://github.com/koreader/koreader) team and community, whose work makes this project possible.
