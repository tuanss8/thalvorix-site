# THALVORIX Duel Arena 3D — Godot prototype

Godot 4.7.2-stable, GDScript only, Compatibility renderer (WebGL2). Published build: https://thalvorix.xyz/godot/

- `main.gd` – scene, UI, rules, bot, animations (everything is built in code)
- `card.gd` – 3D card (art, name, ATK/DEF, back, glow)
- `hero_data.gd` – all 100 heroes (id = on-chain `heroIdOf`, art `hd/h<id>.webp` resized to 256 px JPG in `heroes/`) + the 20-hero default pool
- `shell.html` – custom web shell: deck chooser (connect wallet / paste address / random), read-only NFT scan via public BSC RPC + Multicall3, on-screen error box, WebGL-context-lost notice and a 60 s start watchdog. Passes the deck to Godot as `window.THX_DECK`.
- `audio/` – music (from `web-music.m4a`, ogg) + generated SFX wav

Rules: 5 slots per side, 8-card deck each, LP 4000. Pick your card, then an enemy card.
ATK > target DEF → target destroyed, owner loses the difference. ATK < DEF → attacker's owner loses the difference.
Equal → both destroyed. Empty slots refill from the deck at each turn. Win at enemy LP 0 or when the enemy has no cards.

Export (single-threaded web, no COOP/COEP needed), then generate the service worker:

    godot --headless --path godot-src --export-release "Web" godot/index.html
    python3 godot-src/tools/post_export.py godot

`post_export.py` writes `godot/sw.js` (cache name = hash of the exported files). Always run it after an export, or repeat visitors keep the previous cached build until it runs.

Loading pipeline (2026-11-09):
- `<link rel="preload">` for index.wasm/index.pck in the shell head starts both downloads before index.js runs (same URL + cors mode as the Godot loader: one fetch each, verified).
- The shell starts downloading `index.wasm` + `index.pck` and compiles/instantiates the engine (`engine.init`) as soon as the page opens, while the player picks a deck; Play only calls `engine.start`. Progress shows `Downloading game… N%` (both files), then `Preparing engine…` (compile), `Starting engine…`, `Building the arena…`. The overlay stays until Godot calls `window.THX_onTitle()` after the title frame (20 s fallback).
- `sw.js` (registered 3 s after the title shows, scope `/godot/`) precaches this build from the HTTP cache and serves it cache-first on repeat visits; a new export = new cache name, old caches are deleted on activate. `?nosw` skips registration.
- Startup order in `main.gd`: lights/camera → table + UI → title frame → backdrop over the following frames → one hidden card drawn under the table to pre-compile card shaders. Backdrop textures are baked PNGs in `space/` (regenerate with `godot --headless --path godot-src -s res://tools/bake_space.gd`); the generator functions stay in `main.gd`. The 4 planet rim shells share one Shader (one GPU program).
- Timing marks: `window.THX_T` (GDScript side, performance.now ms) and `window.THX_STAGES` (shell side).

Debug: `godot --path godot-src -- --autoplay --shots` plays a bot-vs-bot game and saves screenshots to user://.

Wallet deck: `window.THX_DECK = {wallet, heroes:[{token, hero, rar}]}` is read in `main.gd` via `JavaScriptBridge`. Your NFTs are drawn first; wallets with fewer than 8 are padded with random heroes. No signing, no transactions.

Note: keep `glow_enabled = false`. The Compatibility-renderer glow pass crashed the browser GPU process (WebGL context lost) during the first frame, which left the loading screen stuck.

Camera orbit (2026-11-09): one-finger horizontal drag (or mouse drag) orbits the camera around the table (yaw, clamped ±70°, eased); Left/Right arrow keys step 12°. A press only counts as a tap if it moves less than 18 px. Two-finger drag pans (a little at normal zoom, more when zoomed in); pinch still zooms (zoom = orbit distance). Reset returns to the front view. The far starfield/nebula layers follow the camera, planets stay put, so the backdrop parallax follows the orbit. `window.THX_CAM` now also has `orbit`/`orbitT` (degrees).

Camera zoom / pan (phones + desktop, older notes; one-finger pan was replaced by orbit): two-finger pinch (handled from InputEventScreenTouch/ScreenDrag), InputEventMagnifyGesture, mouse wheel, and the +/−/Reset buttons (right edge; bigger and under the table in portrait). Zoom is a camera-distance multiplier clamped to 0.6–2.2, smoothed in `_process`; screen shake is applied on top of the zoomed transform. When zoomed in, a one-finger drag pans (clamped to the board); card taps now fire on release and are cancelled only by a pan drag or a multi-finger gesture. The shell blocks browser page zoom (viewport meta, `touch-action:none`, gesture/ctrl+wheel/multi-touch `preventDefault`). On the web, `window.THX_CAM` and `window.THX_STATUS` expose zoom/pan and the status line for automated tests.

3D backdrop (`_build_space`, built over several frames): 3 parallax starfield layers (billboard MultiMesh quads, twinkle shader; far layers follow the camera, the near one stays put), additive nebula billboards with a 96 px procedural cloud texture, 4 planets with 128×64 procedural textures (lava, banded gas giant with a textured ring, earth-like, ice giant) plus fresnel atmosphere shells, a cratered moon in orbit, a distant sun with corona, and a small asteroid belt. Low-poly spheres, no shadows, glow still off.
