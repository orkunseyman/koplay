# Studying KoPlay

A guided tour of this repo for someone new to Lua and KOReader.

Line numbers point at the current working tree. That tree includes the audit fixes made in this
fork, which are not committed yet. If you check out a different version, the numbers shift a little.

Things marked *(KOReader convention)* describe how KOReader behaves, based on how plugins are
normally written, and have not been checked in KOReader's source yet. Section 11 is based on
KOReader's source, commit `55471ca` (23 Nov 2026).

---

## 1. Folder and file layout

```
koplay-kindle/
|-- koplay.koplugin/          the plugin itself: this folder is what goes on the Kindle
|   |-- _meta.lua             name and description shown in KOReader's plugin list
|   |-- main.lua              the plugin: menu, gestures, polling, playback commands
|   |-- koplayapi.lua         Spotify Web API client: tokens, HTTP, JSON, every endpoint
|   |-- koplayview.lua        the full screen "now playing" view, drawn pixel by pixel
|   |-- koplaylibrary.lua     the library browser: playlists, liked songs, search, recent, queue
|   `-- koplayl10n.lua        translations (English source strings, Turkish table)
|-- tools/
|   |-- koplay_auth.py        one time login on your computer, writes koplay.json
|   |-- emulator.sh           runs KOReader's macOS emulator with the plugin loaded
|   `-- test_koplayapi.lua    tests for koplayapi.lua with KOReader stubbed out (added in this fork)
|-- docs/screenshots/         PNGs used by the READMEs
|-- README.md, README.tr.md   English and Turkish docs
|-- LICENSE                   AGPL-3.0, same as KOReader
|-- .github/FUNDING.yml       GitHub Sponsors link for the original author
`-- .gitignore                keeps tools/koplay.json (your secret) and .emulator/ out of git
```

Only `koplay.koplugin/` runs on the e-reader. Everything in `tools/` runs on your computer.

---

## 2. How KOReader loads the plugin

### The two entry files

- `_meta.lua` returns a small table: `fullname` and `description`. KOReader reads it to list the
  plugin under Settings, Plugin management, without running any plugin code.
- `main.lua` returns the plugin class, `KoPlay`. KOReader creates an object from it.

### Lifecycle

```
KOReader starts
  |
  |-- finds koreader/plugins/koplay.koplugin/
  |-- reads _meta.lua                       (name for the plugin list)
  `-- loads main.lua, gets the KoPlay class
                |
File browser opens, or a book opens
  |
  |-- KOReader makes a new KoPlay object:  KoPlay:new{ ui = <the FileManager or the ReaderUI> }
  `-- calls KoPlay:init()                   main.lua:68
          |-- onDispatcherRegisterActions() registers 6 gesture actions   main.lua:46
          `-- self.ui.menu:registerToMainMenu(self)                        main.lua:70
                |
You open the top menu
  `-- KOReader calls KoPlay:addToMainMenu(menu_items)                      main.lua:77
                |
You tap Tools, KoPlay
  `-- sub_item_table_func() builds the KoPlay submenu, fresh every time    main.lua:123
                |
A gesture fires "KoPlay: play/pause"
  `-- KOReader sends the event "KoPlayToggle" -> KoPlay:onKoPlayToggle()   main.lua:253
```

Key points:

- `KoPlay = WidgetContainer:extend{ name = "koplay", is_doc_only = false }` (`main.lua:41`).
  `is_doc_only = false` means the plugin also loads in the file browser, not only inside a book.
- **There is one KoPlay object per screen.** Moving from the file browser into a book throws away
  the old UI and its KoPlay object and makes a new one. Checked in KOReader's source: ReaderUI
  creates every plugin with `PluginLoader:createPluginInstance` and stores it with
  `registerModule("koplay", ...)`, so inside a book the plugin is also reachable as `self.ui.koplay`
  (`readerui.lua:94`, `:464`). So `self.now_playing`,
  `self.state` and `self.menu_state` reset.
- **KOReader also hands every plugin some fields:** `ui`, `document`, `dialog` and, inside a book,
  `view` (KOReader's own page view, `readerui.lua:467`). A plugin must not use these names for
  its own things. Original KoPlay kept its now playing screen in `self.view`, so inside a book
  it always thought that screen was open: play/pause only ever sent "play", and the now playing
  screen wouldn't open. This fork renamed it to `self.now_playing`. The Spotify client lives in a module (`koplayapi.lua`),
  and modules are loaded only once, so the access token survives the switch. See section 8.
- **Events** are found by name. KOReader passes an event down through its widgets, and any object
  with a method called `on` + the event name gets it. Event `KoPlayToggle` calls `onKoPlayToggle`.
  A handler that returns `true` says "handled, stop here".
- **Settings** go in `G_reader_settings`, KOReader's global settings file:
  - `readSetting("koplay_poll_interval", 10)`: read, with 10 as the default
  - `saveSetting(key, value)`: write
  - `nilOrTrue` / `flipNilOrTrue`: an on/off switch that is "on" until you first turn it off

---

## 3. The Spotify side: login, koplay.json, tokens

### Why there is a script on your computer

Spotify login needs a web browser and a web address Spotify can redirect back to. That is hard on
an e-reader, so the login happens once on your computer. Afterwards the e-reader only needs a
**refresh token**, a long-lived secret it can trade for short-lived **access tokens**.

### The login flow (`tools/koplay_auth.py`)

KoPlay uses **Authorization Code with PKCE** (Proof Key for Code Exchange). PKCE lets an app log in
without a client secret, which matters because KoPlay has nowhere safe to hide one.

```
 your computer                                 Spotify
 -------------                                 -------
 1. make a random "verifier" (64 bytes)        koplay_auth.py:98
    challenge = base64url(sha256(verifier))    koplay_auth.py:99
    state = another random value               koplay_auth.py:100
 2. open the browser at accounts.spotify.com/authorize
       ?client_id ... &scope ... &redirect_uri=http://127.0.0.1:8888/callback
       &code_challenge=<challenge> &state=<state>  --------------------->
                                                   you log in and accept
 3. tiny web server on 127.0.0.1:8888  <------  redirect: /callback?code=...&state=...
    checks state matches (blocks forged replies)   wait_for_code, koplay_auth.py:41
 4. POST /api/token with code + verifier  ---------------------------->
                                                   Spotify checks sha256(verifier)
                                       <------  { access_token, refresh_token, ... }
 5. write koplay.json, permission 0600             koplay_auth.py:120
```

- **Redirect URI** `http://127.0.0.1:8888/callback` must match your Spotify app's setting exactly.
  Spotify rejects `localhost`, so it must be the number form.
- **Scopes** (what KoPlay may do, `koplay_auth.py:24`): read playback state and the current track,
  control playback, read recently played, read your saved songs, read your private and
  collaborative playlists. KoPlay cannot change your library or playlists.
- **`state`** is a random value checked when the browser comes back. It stops another site from
  handing the script a login code of its own.

### What is in koplay.json

```json
{ "client_id": "your app's id", "refresh_token": "the long-lived secret" }
```

No access token is stored. Anyone with this file can control your Spotify, so keep it private.

### Refresh and save (`koplayapi.lua`)

```
first API call (or token about to expire)
  -> refreshAccessToken()                        koplayapi.lua:112
       POST https://accounts.spotify.com/api/token
            grant_type=refresh_token & refresh_token=... & client_id=...
       200 -> access_token kept in memory only
              token_expires = now + expires_in - 60 s     (a minute early, to be safe)
              Spotify may send a NEW refresh_token: if so -> saveAuth()
       400/401 -> login revoked: forget it, return "auth_revoked"
       other   -> "network"
```

`saveAuth()` (`koplayapi.lua:62`) writes `koplay.json.tmp` first and then renames it over
`koplay.json`. A crash in the middle of writing can't leave you with an empty file.

`hasAuth()` (`koplayapi.lua:74`) returns the login cached in memory, or reads the file if there is none.

---

## 4. How API calls are made

### Modules used (all ship with KOReader)

| Module | What it is |
|---|---|
| `socket.http` | LuaSocket's HTTP client. In KOReader it also handles `https://` (through LuaSec, which KOReader ships) |
| `ltn12` | LuaSocket's "pipes": `ltn12.source.string(body)` feeds the request body |
| `socketutil` | KOReader helpers: `table_sink` collects the response, `set_timeout` / `reset_timeout` |
| `json` | KOReader's JSON module: `JSON.encode(table)`, `JSON.decode(string)` |
| `socket` | `socket.gettime()`: current time with fractions of a second |

### Request flow

```
caller: poll, control, library, gesture
   |
   v
KoPlayApi:getPlayback / control / play / get ...
   |
   v
KoPlayApi:call(method, path, body)                         koplayapi.lua:146
   |
   |-- still inside a 429 wait (retry_after)?  -> return nil, "rate_limited"
   |-- no access token, or expired?           -> refreshAccessToken() (section 3)
   |                                              fails -> return nil, <its error>
   v
KoPlayApi:request(method, url, headers, body)              koplayapi.lua:83
   |  adds Content-Length (Spotify answers 411 without it on empty PUT/POST)
   |  timeouts: 5 s per wait, 10 s total (cover art downloads get longer ones)
   v
socket.http.request  ---- HTTPS ---->  api.spotify.com/v1/...
   |
   v
status code back in call():
   nil (no answer)      -> return nil, "network"
   401, first try       -> drop the access token, loop once: refresh and retry
   429                  -> retry_after = now + Retry-After header (or 30 s)
                           return 429, "rate_limited"
   anything else        -> if the body starts with "{", decode JSON
                           return code, data
```

### What each status means to the callers

| Status | Where | Meaning in KoPlay |
|---|---|---|
| 200 | everywhere | worked, body is JSON |
| 204 | `getPlayback` (`koplayapi.lua:240`) | "nothing is playing" -> `{ idle = true }` |
| 2xx | `controlResult` (`koplayapi.lua:275`) | command accepted (play, pause, next, queue) |
| 401 | `call` | access token stale: refresh once and retry |
| 400/401 on the token URL | `refreshAccessToken` | login revoked -> `"auth_revoked"` |
| 403 | `get`, `controlResult` | `"forbidden"`: no Premium, or not allowed (someone else's playlist) |
| 404 on a command | `controlResult` | `"no_device"`: no active Spotify device |
| 429 | `call` | `"rate_limited"`: wait as long as Spotify says |
| no answer | `call` | `"network"` |

Every failing function returns **two values**: `nil` (or `false`) and an error kind string. The
plugin turns kinds into text with the `ERRORS` table (`main.lua:32`) and `errorLines`
(`main.lua:171`). Each kind gets a title line and a hint line, both translated.

### The "no active device" rescue

When you press play and Spotify says 404, `startPlayback` (`main.lua:358`) does this:

```
fn(nil) fails with "no_device"
  -> getDevices()
       0 devices -> show "No active Spotify device"
       1 device  -> try again on that device
       many      -> ButtonDialog "Where should it play?" -> try on the one you tap
```

Only playing goes through this path. Pause, next and previous on a dead device just show the error.

---

## 5. Wi-Fi handling

KoPlay never turns Wi-Fi on or off itself. It asks KOReader's `NetworkMgr`:

- `NetworkMgr:runWhenOnline(fn)`: if online, run `fn` now. If not, do what your KOReader Wi-Fi
  setting says (turn Wi-Fi on, or ask you first), then run `fn` once connected *(KOReader convention)*.
- `NetworkMgr:isOnline()`: only checks, never turns anything on.

| Entry point | Wi-Fi behavior |
|---|---|
| Open now playing (`main.lua:211`) | `runWhenOnline` for the first poll |
| Open library (`main.lua:228`) | `runWhenOnline` |
| Gesture play/pause/next/previous (`main.lua:247`) | `runWhenOnline` |
| Gesture "show current track" (`main.lua:257`) | `runWhenOnline` |
| KoPlay menu opens (`refreshMenuState`, `main.lua:159`) | `isOnline` only: if offline it skips the fetch and shows the plain "Now playing" line |
| Later polls (timer) | no check: if Wi-Fi dropped they fail with "network" and retry in 20 s |

So Wi-Fi turns on only when you open a KoPlay screen or use a KoPlay gesture. While the now playing
screen is open, "Keep screen awake" stops the Kindle from sleeping (`setKeepAwake`, `main.lua:183`).
On a Kindle that is a `lipc-set-prop com.lab126.powerd preventScreenSaver 1` call. It also keeps
Wi-Fi alive.

---

## 6. UI

### Now playing screen (`koplayview.lua`)

It is an `InputContainer` (a KOReader widget that can receive taps and keys) with its own
`paintTo`. It doesn't stack text and button widgets. It draws everything itself into the screen
buffer (`bb`, a Blitbuffer) with simple shapes:

```
+--------------------------------------+  header: "Library" | "Spotify . device" | "Close x"
|  [ cover art, square ]               |  paintCover: image, or a vinyl record placeholder
|                                      |
|  Title (bold)                        |  paintTitle: title / artist / album . year
|  Artist                              |
|  Album . 2024                        |
|  ==========o-------------            |  paintProgress: bar + knob
|  1:23                       3:45     |
|      (|<)      ( > )      (>|)       |  paintControls: circles + triangles
+--------------------------------------+
```

- `computeLayout` (`koplayview.lua:107`) works out every size as a fraction of screen width and
  height, once, when the view is created.
- While painting, each button saves its rectangle into `self.hit`. `onTap` (`koplayview.lua:307`)
  checks which rectangle your finger landed in. A swipe down closes the view.
- The view knows nothing about Spotify. It gets data through `update{ state = ... }` and reports
  taps through callbacks the plugin passed in: `on_control`, `on_close`, `on_library`.
- `refresh(full)` asks KOReader to redraw: `"ui"` for a quick partial update, `"full"` (flashes the
  screen) only when the track or cover changes, to clear e-ink ghosting.
- The progress bar doesn't animate. At paint time it guesses the position from
  `progress_ms + (now - fetched_at)`, so it jumps forward on each poll.

### KoPlay menu (`main.lua:77`)

A plain KOReader touch menu entry. Each item is a table:

| Field | Meaning |
|---|---|
| `text` / `text_func` | fixed label, or a function called each time the menu draws |
| `callback` | runs on tap; gets the menu itself (`touchmenu_instance`) |
| `keep_menu_open` | don't close the menu after the tap |
| `checked_func` | shows a check mark when it returns true |
| `sub_item_table` / `sub_item_table_func` | a submenu, fixed or built on each opening |
| `sorting_hint = "tools"` | which top menu tab it goes in |

The control items flip the Pause/Resume label right away (an "optimistic" update). They send the
command, and 1.5 s later fetch the real state and call `touchmenu_instance:updateItems()` to redraw.

### Gesture actions (Dispatcher, `main.lua:46`)

`Dispatcher:registerAction(id, { event = "KoPlayToggle", title = ..., general = true })` adds an
entry under Taps and gestures, General. Picking it for a gesture makes KOReader send that event, which
lands in `onKoPlayToggle` and friends.

### Notifications and popups

- `Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)` (`main.lua:263`): a small toast at
  the top that disappears by itself. Used for gestures, so your page isn't covered.
- `InfoMessage:new{ text = ..., timeout = 3 }`: a centered popup for errors and "Added to queue".
- `ButtonDialog`: the device picker, and the long-press Play / Add to queue choice.

### Library (`koplaylibrary.lua`)

One KOReader `Menu` widget, full screen. Opening a sub-list pushes the current list onto
`menu.paths` (`push`, `koplaylibrary.lua:67`). The back arrow pops it (`back`, `koplaylibrary.lua:75`).
`busy(fn)` (`koplaylibrary.lua:30`) shows "Loading..." while a network call blocks the screen.
Paged lists add a "Load more..." item at the end (`openPaged`, `koplaylibrary.lua:143`).

### Album art

```
getPlayback(cover_size)       pickImage: smallest Spotify image at least as big as the cover box,
   |                          else the biggest one (Spotify offers about 640, 300 and 64 px)
   v
loadCover(url)                main.lua:295, skips if it's the same url as last time
   |-- KoPlayApi:download(url)               raw JPEG bytes, longer timeouts
   |-- RenderImage:renderImageData(...)      decode + scale to cover_size x cover_size
   |-- ImageWidget{ image_disposable = true } widget that frees the pixels when done
   v
view:setCover(image)          frees the previous cover
view:paintCover               draws it with a 2 px border
```

---

## 7. Refresh and polling: every timer

KOReader timers: `UIManager:scheduleIn(seconds, fn)` runs `fn` once later.
`UIManager:unschedule(fn)` cancels it. Nothing repeats by itself: each poll schedules the next one.

| Timer | When | Delay |
|---|---|---|
| `poll_task` | only while the now playing screen is open | see below |
| re-poll after a command | `schedule(SETTLE_DELAY)` after play/pause/next/previous | 1.2 s (Spotify needs a moment) |
| menu refresh after a menu control | `main.lua:112` | 1.5 s |
| toast after a gesture | `report()`, `main.lua:410` | 1.2 s, then shows the new track |
| catch up after closing the library | `on_close`, `main.lua:233` | 0.5 s |

How `poll()` (`main.lua:319`) chooses the next delay:

```
library covering the view?      -> check again in 30 s, no network
fetch failed:
    no_auth / auth_revoked      -> stop polling (nothing will fix itself)
    rate_limited                -> wait what Spotify asked (at least 5 s)
    anything else               -> 20 s
playing                         -> your interval (5 / 10 / 15 / 30 s, default 10)
                                   but if the track ends sooner: end of track + 1 s
paused or nothing playing       -> 30 s
never less than 2 s
```

Closing the view (`onViewClosed`, `main.lua:280`) unschedules `poll_task`, so nothing runs in the
background while you read. The KoPlay menu doesn't use a timer. It fetches when it opens, at most
once every 5 seconds (`refreshMenuState`, `main.lua:159`).

All network calls block the screen while they run. KOReader runs everything on one thread.

---

## 8. Lua crash course (with examples from this repo)

**Tables are everything.** One type does arrays, dictionaries and objects.

```lua
local ERRORS = {                                   -- dictionary (main.lua:32)
    network = { "No connection", "Check Wi-Fi, will retry" },   -- value is an array
}
ERRORS.network[1]          --> "No connection"     (arrays start at 1, not 0)
for _i, action in ipairs{ "previous", "toggle", "next" } do ... end   -- koplayview.lua:316
#items                     --> length of an array
```

`ipairs` walks an array in order. `pairs` walks every key in no fixed order.

**`local` or global.** Without `local`, a variable is global. This code makes everything `local`
except what KOReader itself provides (`G_reader_settings`).

**Modules are files that return a value.** `require` runs the file once, caches what it returned
and hands the same value to everyone:

```lua
local KoPlayApi = require("koplayapi")   -- koplayapi.lua ends with: return KoPlayApi
```

That is why the access token survives switching screens: every KoPlay object shares the one
`KoPlayApi` table.

**Colon vs dot.** `obj:method(x)` is shorthand for `obj.method(obj, x)`. Inside, `self` is `obj`.

```lua
function KoPlayApi:call(method, path, body) ... self.access_token ... end  -- uses self
function KoPlayApi.track(item) ... end    -- dot: a plain function, no self (koplayapi.lua:216)
KoPlayApi:call("GET", "/me/player")       -- colon call passes KoPlayApi as self
KoPlayApi.track(data.item)                -- dot call, no self
```

Mixing them up is the most common Lua bug: `KoPlayApi.call("GET", ...)` makes `self` the string "GET".

**Calling with a table.** `f{ ... }` means `f({ ... })`. KOReader uses it everywhere:

```lua
UIManager:show(InfoMessage:new{ text = self:errorText(err), timeout = 4 })   -- main.lua:368
```

**Classes are metatables.** A metatable tells Lua where to look when a key is missing:

```lua
function KoPlayLibrary:new(o)          -- koplaylibrary.lua:22
    o = o or {}
    setmetatable(o, self)              -- o's missing keys...
    self.__index = self                -- ...are looked up in KoPlayLibrary
    return o
end
```

So `library:show()` finds `show` on the class. KOReader's widgets do the same through
`WidgetContainer:extend{ ... }` (`main.lua:41`) and `InputContainer:extend{ ... }` (`koplayview.lua:26`).

**Functions are values, and closures remember their surroundings.**

```lua
local function intervalItem(sec)       -- main.lua:78
    return {
        checked_func = function() return self:getInterval() == sec end,  -- remembers sec
    }
end
intervalItem(5), intervalItem(10)      -- each menu item has its own sec
```

```lua
self.poll_task = function() self:poll() end   -- main.lua:222: one closure, so the same value
UIManager:unschedule(self.poll_task)          -- can be passed to unschedule later
```

Declaring a variable first lets a closure use it before it has a value:

```lua
local dialog
dialog = ButtonDialog:new{ buttons = {{ { callback = function() UIManager:close(dialog) end } }} }
```

**Several return values.** Errors are returned, not thrown:

```lua
local ok, err = KoPlayApi:control(action)          -- true            or  false, "no_device"
local data, err = self:get("/me/player/devices")   -- table           or  nil, "forbidden"
```

**`pcall`** catches errors from code that may throw, like decoding bad JSON:

```lua
local ok, data = pcall(JSON.decode, content)       -- koplayapi.lua:47
```

**`a and b or c` is Lua's "if/else in one line"**:

```lua
local method = (action == "play" or action == "pause") and "PUT" or "POST"   -- koplayapi.lua:287
```

Pitfall: if `b` is `false` or `nil`, you get `c` anyway. Only `nil` and `false` count as false in
Lua. `0` and `""` count as true.

**Why loops say `_i` and not `_`.** By habit `_` means "ignore this", but here
`local _ = require("koplayl10n")` makes `_` the translation function. A loop variable named `_`
would hide it, so this code writes `for _i, x in ipairs(...)`.

**Strings.** `..` joins strings. `string.format("%d:%02d", m, s)` works like printf.
`str:gsub(pattern, fn)` replaces with a function (see `urlencode`, `koplayapi.lua:28`).

---

## 9. The 5 functions to understand first

1. **`KoPlayApi:call`** (`koplayapi.lua:146`). Every Spotify request goes through it: token
   refresh, the one retry on 401, the 429 wait, JSON decoding. Read it with `request` (`:83`) and
   `refreshAccessToken` (`:112`).
2. **`KoPlayApi:getPlayback`** (`koplayapi.lua:240`). Turns Spotify's big JSON into the small
   `state` table used everywhere: `is_playing, title, artist, album, cover_url, device, idle`.
   If you know this table, you know what the UI can show.
3. **`KoPlay:control`** (`main.lua:401`) with **`KoPlay:startPlayback`** (`main.lua:358`). One
   path for every button and gesture: turns "toggle" into play or pause, rescues "no device",
   updates the screen early, then re-checks after 1.2 s. The Music tab buttons will call this.
4. **`KoPlay:poll`** (`main.lua:319`). The now playing loop: fetch, compare, redraw, pick the next
   delay. It shows how KOReader timers and e-ink refresh types are used.
5. **`KoPlay:addToMainMenu`** (`main.lua:77`) with **`refreshMenuState`** (`main.lua:159`). The
   closest thing to the Music tab: dynamic text with `text_func`, a cached state shown at once,
   a fresh fetch, and redrawing after a command.

---

## 10. What looks fragile on a 600x800 screen (Kindle 10th gen, 167 ppi)

I worked `computeLayout` through for 600x800. All sizes are in pixels. At 167 ppi, 10 px is about 1.5 mm.

| Part | Size at 600x800 | Comment |
|---|---|---|
| cover | 524 x 524 | fits; Spotify's 640 px image is downloaded and scaled down |
| header bar | 40 tall, text 16 px | "Library" and "Close" tap areas are only about 6 mm tall |
| title / artist / album text | 24 / 16 / 15 px | one line each; long names are cut short |
| time labels | 12 px | about 1.8 mm tall: hard to read |
| play button | 78 px wide (about 12 mm) | fine |
| prev / next | 58 px drawn, 80 px tap area | fine |
| gap between blocks | 9 px | tight but nothing overlaps |

Other risks:

- **Light grays on a low contrast screen.** The progress track (`COLOR_GRAY_D`), the placeholder
  (`COLOR_GRAY_E`) and the album line (`COLOR_GRAY_6`, 15 px) may look faint on the Kindle 10's panel.
- **Only one line of text per field.** A long song title loses its end. Nothing wraps.
- **The center status text** ("Spotify . device name") is limited to 40% of the width (240 px), so
  long device names are cut. It shouldn't collide with the left and right labels.
- **Blocking network calls.** Every fetch freezes the screen briefly. The Kindle 10 is slower than
  a Paperwhite 3, so taps during a fetch feel late.
- **Library rows.** "Title, artist" plus the duration on the right get cut off quickly at 600 px.
  This is KOReader's `Menu` behavior, not KoPlay's.
- **Not verified on a real 600x800 screen.** These numbers are computed from the code, not measured.

---

## 11. How KOReader's bottom menu is built

Files read (KOReader commit `55471ca`): `frontend/ui/widget/configdialog.lua`,
`frontend/apps/reader/modules/readerconfig.lua`, `frontend/ui/data/creoptions.lua`,
`frontend/ui/data/koptoptions.lua`. Also, where they lead: `toggleswitch.lua`, `configurable.lua`,
`iconwidget.lua`, `readerui.lua`, `readercoptlistener.lua`, `readerkoptlistener.lua`, `userpatch.lua`.

The bottom menu only exists inside a book. The file browser has none.

### The pieces

```
ReaderUI (one per open book)
 |-- ReaderConfig  (self.ui.config)                         readerconfig.lua
 |     options = CreOptions  (EPUB, FB2...: prefix "copt")  picked in init, readerconfig.lua:14
 |            or KoptOptions (PDF, DjVu:    prefix "kopt")
 |     swipe up / tap bottom -> onShowConfigMenu()           readerconfig.lua:133
 |        builds a NEW ConfigDialog every time it opens
 |
 `-- ConfigDialog                                           configdialog.lua:863
       +--------------------------------------+
       |  ConfigPanel: the options of one tab |   ConfigOption:init, configdialog.lua:187
       |   name on the left | widget on right |
       |   name on the left | widget on right |
       +--------------------------------------+
       |  MenuBar: one icon per tab            |   MenuBar:init, configdialog.lua:733
       +--------------------------------------+
```

### The data: a list of tabs, each a list of options

```lua
CreOptions = {
    prefix = "copt",
    {   icon = "appbar.rotation", options = { {...}, {...} } },   -- tab 1
    {   icon = "appbar.textsize", options = { {...}, {...} } },   -- tab 4
    ...
}
```

`CreOptions` and `KoptOptions` are plain modules, so every book shares the same two tables.
Anything a plugin adds to them shows up the next time the menu opens.

The option fields that matter for the Music tab:

| Field | What it does | Where |
|---|---|---|
| `name` | **Required.** Key used to store the value. `loadDefaults` joins `prefix .. "_" .. name`, so a missing name crashes | `configurable.lua` |
| `name_text` / `name_text_func(configurable, document)` | label on the left; the func is called each time the panel is built (twice: once to measure, once to draw) | `configdialog.lua:223`, `:284` |
| `toggle` | a row of boxed buttons (ToggleSwitch) | `configdialog.lua:545` |
| `values` | values to store; a ToggleSwitch **needs** this table, even empty, or it crashes on `#self.values` | `toggleswitch.lua` |
| `event` + `args` | event to send on tap, with `args[position]` as its argument | `configdialog.lua:1014` |
| `show_func` / `enabled_func` | hide or grey out an option | `configdialog.lua:257`, `:278` |
| `height` | row height, and the toggle's height (default 30 for a toggle row) | `configdialog.lua:267`, `:550` |

### Your understanding, checked

1. **"Bottom menu tabs are lists of options."** Correct. See above.
2. **"Options support `name_text_func` for dynamic text."** Correct, with one catch: it is not
   live. It runs only when the panel is built: when the menu opens, when you switch tabs, and after
   any tap on an option (`onConfigChoose` calls `self:update()`, which rebuilds the panel). To show
   new text later, for example after a network fetch, the code has to call
   `config_dialog:update()` and then `UIManager:setDirty(config_dialog, ...)` itself.
3. **"Toggle buttons can fire an event that `onConfigChoose` sends through `ui:handleEvent`."**
   Correct. The full path:

```
tap on a toggle button
  -> ToggleSwitch:onTapSelect                      toggleswitch.lua
       highlights the tapped button
       -> ConfigDialog:onConfigChoose(values, name, event, args, position)   configdialog.lua:991
            (waits one tick: UIManager:tickAfterNext)
            if values:  onConfigChoice(name, values[position])
                          -> ui:handleEvent("ConfigChange", name, value)
                          -> ReaderCoptListener / ReaderKoptListener:onConfigChange
                               document.configurable[name] = value   <- this is what gets SAVED
            if event:   onConfigEvent(event, args[position])
                          -> ui:handleEvent(Event:new(event, arg))
                          -> any module with on<event>, e.g. KoPlay:onKoPlayMusic("next")
            self:update()   rebuilds the panel, name_text_func runs again
```

### What gets saved into the book, and how to avoid it

- When a book closes, `ReaderConfig:onSaveSettings` (`readerconfig.lua:197`) calls
  `Configurable:saveSettings`. That writes **every number, string or table** in `configurable`
  into the book's `.sdr` settings file as `copt_<name>` or `kopt_<name>`.
- When a book opens, `loadDefaults` sets `configurable[name] = G_reader_settings "copt_<name>" or
  default_value`.

So the trick is the one KOReader already uses for its own **Font size decrease / increase** buttons
(`font_fine_tune`, `creoptions.lua:430`): `values = {}`, plus an `event` and `args`.
`values[position]` is then `nil`, `configurable[name]` stays `nil`, and nothing is saved.

**Highlight:** the tapped button turns black. The panel rebuild right after finds no stored value
(`current_item` is `nil`, `configdialog.lua:340`), so the button draws white again. It does not stay
highlighted.

Side effects of `values = {}` to know about:

- On PDFs, `ReaderKoptListener:onConfigChange` repaints the whole screen ("partial" refresh) on
  every press. That is a little extra flicker.
- On a Kindle, the ConfigChange handlers also fire `StartActivityIndicator`. That only shows the
  Kindle spinner for PDFs in reflow mode (`text_wrap == 1`), and it stops at the next page draw.
- **Long-press** on a toggle opens "Set default ... to ...?" (`onMakeDefault`,
  `configdialog.lua:1391`). KOReader skips this only for the name `font_fine_tune`. For us,
  accepting it would store `nil`, which is harmless but confusing.

### Other facts the Music tab must respect

- **Tab index is saved per book.** `last_panel_index` goes into the book's settings as
  `config_panel_index`, and on open it is capped at the number of tabs (`readerconfig.lua:188`).
  So add the Music tab **at the end**. Removing it while the menu is set to reopen on it must also
  lower `ui.config.last_panel_index`, or the next open asks for a tab that no longer exists and crashes.
- **Insert once.** The KoPlay object is created again for every book, but the option tables are
  shared. Adding the tab must check that it is not already there.
- **Icons are looked up by name** in `koreader/icons/` (your own icons), then
  `resources/icons/mdlight/`, then fallbacks (`iconwidget.lua:20`). KOReader has **no music icon**.
  A missing name shows `icon-not-found.svg` instead of crashing.
- **Network calls block the screen**, so "show cached text first, then update" means:
  `name_text_func` returns the cached text right away, and the fetch runs a moment later
  (`UIManager:scheduleIn`), followed by `config_dialog:update()`.

### Fit on 600x800

KOReader sizes are designed around a 600 px wide screen, so on your Kindle `scaleBySize` is close
to 1:1. Rough numbers:

- Tab bar: icons are 40 px. Reflowable books have 6 tabs and PDFs have 7, so 7 or 8 with Music:
  about 330 to 370 px of 600. It fits.
- Option names take 25% to 50% of the width (150 to 300 px) and are cut beyond that. A long
  "Song · Artist" as the name of the button row would be cut at about 300 px, so the track line is
  better as its own full width row.
- A toggle row is 30 px tall by default, about 4.5 mm on your screen. That is small for a finger,
  so the button row should set a taller `height`.

---

## 12. Two ways to add the Music tab

### Option A: from the plugin (a new file in koplay.koplugin)

`koplay.koplugin/koplaymusictab.lua` holds the whole feature. `main.lua` gets a few lines:
one call in `init` (only inside a book, when `self.ui.config` exists), one event handler that
forwards the button to `self:control(action)`, and one on/off item in the KoPlay settings menu.

```
KoPlay:init  ->  MusicTab.install(self)   adds the tab to CreOptions / KoptOptions once
button tap   ->  ui:handleEvent("KoPlayMusic", "next")  ->  KoPlay:onKoPlayMusic  ->  self:control("next")
menu opens   ->  name_text_func -> cached text now, fetch shortly after -> config_dialog:update()
```

Pros:
- One folder to copy to the Kindle, same as today.
- Calls KoPlay's own `control()`, `KoPlayApi:getPlayback`, `errorLines`, Wi-Fi handling and device
  picker directly. Nothing is duplicated.
- The on/off setting sits naturally in the KoPlay menu, and turning the plugin off removes the tab too.
- Testable in the emulator like the rest of the plugin.

Cons:
- Touches `main.lua` (about 8 lines). Merging upstream changes to `main.lua` may need a small manual fix.
- Changes KOReader's shared option tables at runtime. A future KOReader change to the option format
  would break it (Option B has the same risk).

### Option B: a user patch (koreader/patches/2-koplay-music-tab.lua)

KOReader runs every `koreader/patches/2-*.lua` file after startup (`userpatch.lua`, "late"
priority). The patch appends the tab to both option tables and, on a button press, reaches the
plugin through `ui.koplay`.

Pros:
- Zero changes to KoPlay's files. Upstream merges never conflict.
- It's KOReader's official mechanism for UI tweaks.

Cons:
- Two things to install and keep in sync: the plugin folder and the patch file.
- The patch depends on KoPlay's internal names (`ui.koplay`, `control`, `koplayapi`) without
  KoPlay knowing it exists. An upstream rename breaks it silently.
- The patch runs before plugins load, so it can't `require("koplayapi")` at startup. It must wait
  until a button is tapped.
- The on/off setting in the KoPlay menu needs a change to `main.lua` anyway, or more patching of
  KoPlay's menu code from outside.
- Patches can be turned off globally in KOReader (`.patches_disabled`), which also hides the tab.

### Recommendation

**Option A.** The "setting in the KoPlay menu" requirement already means touching `main.lua`, and
then B's main advantage is gone. A keeps everything in one folder, and the `main.lua` diff stays
around 8 lines.
