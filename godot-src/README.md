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

Export (single-threaded web, no COOP/COEP needed):

    godot --headless --path godot-src --export-release "Web" godot/index.html

Debug: `godot --path godot-src -- --autoplay --shots` plays a bot-vs-bot game and saves screenshots to user://.

Wallet deck: `window.THX_DECK = {wallet, heroes:[{token, hero, rar}]}` is read in `main.gd` via `JavaScriptBridge`. Your NFTs are drawn first; wallets with fewer than 8 are padded with random heroes. No signing, no transactions.

Note: keep `glow_enabled = false`. The Compatibility-renderer glow pass crashed the browser GPU process (WebGL context lost) during the first frame, which left the loading screen stuck.

Camera zoom / pan (phones + desktop): two-finger pinch (handled from InputEventScreenTouch/ScreenDrag), InputEventMagnifyGesture, mouse wheel, and the +/−/Reset buttons (right edge; bigger and under the table in portrait). Zoom is a camera-distance multiplier clamped to 0.6–2.2, smoothed in `_process`; screen shake is applied on top of the zoomed transform. When zoomed in, a one-finger drag pans (clamped to the board); card taps now fire on release and are cancelled only by a pan drag or a multi-finger gesture. The shell blocks browser page zoom (viewport meta, `touch-action:none`, gesture/ctrl+wheel/multi-touch `preventDefault`). On the web, `window.THX_CAM` and `window.THX_STATUS` expose zoom/pan and the status line for automated tests.

3D backdrop (`_build_space`, built over several frames): 3 parallax starfield layers (billboard MultiMesh quads, twinkle shader; far layers follow the camera, the near one stays put), additive nebula billboards with a 96 px procedural cloud texture, 4 planets with 128×64 procedural textures (lava, banded gas giant with a textured ring, earth-like, ice giant) plus fresnel atmosphere shells, a cratered moon in orbit, a distant sun with corona, and a small asteroid belt. Low-poly spheres, no shadows, glow still off.
