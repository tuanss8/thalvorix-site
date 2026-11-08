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
