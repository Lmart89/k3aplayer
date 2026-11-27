-- English only: KOReader's gettext would translate just the words its own catalog knows
-- ("off", "About"…) and leave the rest in English, mixing two languages
local _ = function(s) return s end
return {
    name = "k3aplayer",
    fullname = _("K3 Audio Player"),
    version = "1.0",
    description = _([[Plays the MP3 files of the Kindle's music folder with the Kindle 3's own audio hardware (GStreamer), with a player screen, a song list, repeat, shuffle and a sleep timer. Keys: Alt + Space play / pause, Alt + F next song, Alt + M open the player, volume keys.]]),
}
