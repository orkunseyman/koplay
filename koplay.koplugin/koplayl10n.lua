--[[--
Translations for KoPlay. Source strings are English; KOReader's own catalog doesn't know
them, so we keep our own table per language and pick it from KOReader's UI language.
Languages without a table fall back to English.

Usage: local _ = require("koplayl10n")
--]]

local GetText = require("gettext")

local translations = {
    tr = {
        -- now playing view
        ["☰ Library"] = "☰ Kütüphane",
        ["Close ×"] = "Kapat ×",
        ["Nothing playing right now"] = "Şu an çalan bir şey yok",
        ["Start something on Spotify"] = "Spotify'da bir şey başlat",
        ["Connecting…"] = "Bağlanıyor…",
        -- menus and actions
        ["Now playing"] = "Şimdi çalan",
        ["Now playing: %1"] = "Şimdi çalan: %1",
        ["Settings"] = "Ayarlar",
        ["Refresh interval"] = "Yenileme aralığı",
        ["%1 seconds"] = "%1 saniye",
        ["Keep screen awake while open"] = "Açıkken ekranı uyanık tut",
        ["KoPlay: now playing"] = "KoPlay: şimdi çalan",
        ["KoPlay: library"] = "KoPlay: kütüphane",
        ["KoPlay: play/pause"] = "KoPlay: oynat/duraklat",
        ["KoPlay: next track"] = "KoPlay: sonraki şarkı",
        ["KoPlay: previous track"] = "KoPlay: önceki şarkı",
        ["KoPlay: show current track"] = "KoPlay: çalan şarkıyı göster",
        ["Paused"] = "Duraklatıldı",
        ["Where should it play?"] = "Nerede çalınsın?",
        -- errors
        ["Spotify account not connected"] = "Spotify hesabı bağlı değil",
        ["Copy koplay.json into koreader/settings"] = "koplay.json dosyasını koreader/settings klasörüne kopyala",
        ["Spotify login is no longer valid"] = "Spotify girişi geçersiz",
        ["Run koplay_auth.py on your computer again"] = "Bilgisayarda koplay_auth.py'yi yeniden çalıştır",
        ["No connection"] = "Bağlantı yok",
        ["Check Wi-Fi, will retry"] = "Wi-Fi'yi kontrol et, tekrar denenecek",
        ["Spotify asked us to slow down"] = "Spotify biraz beklememizi istedi",
        ["Will retry shortly"] = "Birazdan tekrar denenecek",
        ["Spotify refused this"] = "Spotify buna izin vermedi",
        ["Premium may be required, or the content isn't available"] = "Premium gerekebilir ya da içerik erişilebilir değil",
        ["No active Spotify device"] = "Açık bir Spotify cihazı yok",
        ["Open Spotify on your phone or computer"] = "Telefonda ya da bilgisayarda Spotify'ı aç",
        ["Couldn't reach Spotify"] = "Spotify'a ulaşılamadı",
        ["Spotify account not connected.\n\nRun tools/koplay_auth.py on your computer and copy the resulting koplay.json into koreader/settings/ on this device."] =
            "Spotify hesabı bağlı değil.\n\nBilgisayarda tools/koplay_auth.py'yi çalıştır, oluşan koplay.json dosyasını bu cihazda koreader/settings/ klasörüne kopyala.",
        -- library
        ["Loading…"] = "Yükleniyor…",
        ["Playlists"] = "Çalma listeleri",
        ["Liked Songs"] = "Beğenilen şarkılar",
        ["Search"] = "Ara",
        ["Recently played"] = "Son çalınanlar",
        ["Queue"] = "Sıradakiler",
        ["Play"] = "Çal",
        ["Add to queue"] = "Sıraya ekle",
        ["Added to queue: %1"] = "Sıraya eklendi: %1",
        ["(empty)"] = "(boş)",
        ["Load more…"] = "Daha fazla yükle…",
        ["▶ Play all"] = "▶ Tümünü çal",
        ["▶ Play album"] = "▶ Albümü çal",
        ["(Someone else's playlist: tracks can't be listed)"] = "(Başkasının listesi: şarkılar gösterilemiyor)",
        ["Nothing in the queue"] = "Sırada bir şey yok",
        ["Search Spotify"] = "Spotify'da ara",
        ["Song, album, playlist"] = "Şarkı, albüm, çalma listesi",
        ["Cancel"] = "Vazgeç",
        ["Album: %1"] = "Albüm: %1",
        ["Playlist: %1"] = "Liste: %1",
        ["No results"] = "Sonuç yok",
        -- transport controls
        ["Previous"] = "Önceki",
        ["Pause"] = "Duraklat",
        ["Resume"] = "Oynat",
        ["Next"] = "Sonraki",
    },
}

return function(msg)
    -- e.g. "tr", "pt_BR", or "C" when no language was picked
    local lang = (GetText.current_lang or "C"):match("^%a+")
    local t = translations[lang]
    return t and t[msg] or msg
end
