# Changelog

## v0.6.1

A fix-first release. **v0.6.0's Windows build shipped without its bundled ffmpeg**, which broke
saving journeys — that's sorted. Along with it: a much faster way to build Pool Rounds, boss
encounters, reusable round templates, and a couple of long-standing bugs squashed.

### 🛠 The ffmpeg fix — read this if v0.6.0 wouldn't save
The v0.6.0 Windows download was missing the bundled **ffmpeg / ffprobe**, so saving a journey failed with *"ffmpeg / ffprobe could not be run"* unless you happened to already have ffmpeg installed system-wide. The binaries are back in the Windows build — just update, nothing else to do. Sorry for the run-around.

If you worked around it by switching **Auto-Transcode** off, you can safely turn it back on in Options → Transcoding.

*Linux:* the Linux build has never bundled ffmpeg and still uses your system one — install it from your package manager (`apt install ffmpeg`, or your distro's equivalent) if saving complains.

### ⚔ Pool Rounds — build them in seconds
- **Drop a folder in.** Building a pool used to mean adding encounters one at a time. There's now a **drop zone**: drop in a pile of videos — or whole folders — and every video becomes an encounter, with its funscript, extra-axis and vibrator scripts matched up by filename.
- **Encounters can be bosses.** Any encounter in a pool can be flagged a **boss**, with its own forced modifiers, intro tagline and image. Roll it and the mystery card gives way to the boss intro — open the door, and maybe it's a boss.
- **Extra axes & vibrator scripts** are now editable per encounter. They were always being loaded and played; you just had no way to see or change them.

### ★ Round templates
Save any round's full definition — media, round type, boss setup, its entire encounter pool — as a named **template**, then apply it to another round in two clicks. No more rebuilding the same pool by hand.

### 🎁 Round rewards
Rounds can now **award an item** when they finish, the same way storyboards already could. Pick one from the round's *Item Reward* dropdown and the player gets it — with a toast — as the round ends.

### 🔖 Journey version stamps
Journeys now record the version of FHJ that built them. Open one made for a newer version than you're running and you'll get a clear heads-up instead of a confusing failure.

### 🐛 Fixes
- **Fork screens always read "0 ROUNDS"** on every path. They now show how many rounds each branch actually holds.
- **Journey Audit ignored Pool Rounds.** They counted as zero score and zero length, quietly skewing score totals, run-length estimates and checkpoint spacing. Pool rounds are now measured from their encounters — including the best/worst range across whichever one gets rolled.

## v0.6.0

A big one. Since v0.5.0: an on-the-fly **Randomizer** that builds journeys from your
own clip library, direct **Handy (WiFi)** support, a fully reworked **Effect Round**
system, and a new **Pool Round** (random encounter) type for creators — plus a batch
of fixes and polish.

### 🎲 The Randomizer
Point it at your videos and let it assemble a run for you — no authoring required.
- **Build a library** — drag in videos and whole folders (or browse to them); matching funscripts, and any extra-axis / vibrator scripts, pair up automatically by filename. Missing a script on a clip? Drop one onto its card later.
- **Generate a run** by **round count** or **session length** — ask for ~30 minutes and it packs clips to fit.
- **Tune the mix** — effect-round chance, a **boss finale**, shop frequency, and an **intensity build-up** that ramps toward the end. Clip intensity is auto-rated from the funscript; weight a clip to make favourites appear more.
- **Set a seed** to reproduce a specific run, or leave it blank for a fresh roll every time.
- **Preview & re-roll** — see the run laid out as a map and re-roll instantly until it looks right, then play. Recently-played clips are quietly deprioritized so back-to-back runs stay fresh.
- **Keep the ones you love** — save a run to your journey library, from the preview *or* the end screen, as a permanent, replayable journey.
- **Presets** — save your favourite settings combos and load them in a click.

### 🌐 The Handy — now over WiFi
Drive **The Handy directly over WiFi** — no cables, no Bluetooth bridge. Drop your connection key into Options and the app streams each round's script straight to the device, synced to the video.
- Real-time sync to Handy's clock, so the strokes land where the video is.
- Your stroke range, items, and round effects all reach the device.
- A per-device **delay** trim (Quick Settings — press **S**) to dial in perfect sync.
- Needs Handy firmware 4+ and an internet connection.

### ✦ Effect Rounds — build your own
Cursed and Blessed rounds have merged into one flexible **Effect Round** that creators can shape however they want:
- **Mix hindrances and boons** in a single round — or tick nothing for a pure intro-card / atmosphere beat.
- **Tune every effect's strength** — stroke scale, clamp range, coin penalties, score/coin multipliers, toll, interest. Stroke effects tune **live in the funscript preview**, so you watch the curve reshape as you drag.
- **Rename and re-flavor** any effect (gameplay *or* visual/audio) — turn "Choked" into "The Serpent's Grip" with your own intro-card description.
- **Custom look** — choose the border colour, intro-card accent, and header, and toggle the screen border on or off.
- Optional **resolvable** layer — let players pay to cleanse an effect, or endure it for a reward.

Existing Cursed / Blessed journeys convert automatically — nothing to redo.

### ⚔ Pool Rounds — random encounters
A new round type in the builder: a **pool of encounters** — several video + funscript sets bundled into one round. Each playthrough **rolls one at random** (weighted, if you like), revealed with a slide-in **"ENCOUNTER!"** card. Great for replayable journeys where you never quite know what's next.

### 🎛️ Device delay — direction fixed
The delay sliders now work the intuitive way across **all** backends (Serial, Bluetooth, Handy): **positive adds delay** (the device fires later), negative fires it ahead. If you'd dialed in a delay before, double-check the value.

### 🐛 Fixes & polish
- The mouse cursor now **hides during playback** and no longer covers the action in fullscreen.
- The HUD no longer **pops in on its own** while you're hands-off.
- Fixed journeys whose title ended in a period failing to save or delete.
- Assorted save-pipeline and stability improvements.
