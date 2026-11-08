# THALVORIX Duel Arena 3D — Godot prototype

Godot 4.7.2-stable, GDScript only, Compatibility renderer (WebGL2). Published build: https://thalvorix.xyz/godot/

- `main.gd` – scene, UI, rules, bot, animations (everything is built in code)
- `card.gd` – 3D card (art, name, ATK/DEF, back, glow)
- `hero_data.gd` – 20 heroes picked from `meta/*.json` (art from `hd/h<id>.webp`, resized to 256 px JPG in `heroes/`)
- `audio/` – music (from `web-music.m4a`, ogg) + generated SFX wav

Rules: 5 slots per side, 8-card deck each, LP 4000. Pick your card, then an enemy card.
ATK > target DEF → target destroyed, owner loses the difference. ATK < DEF → attacker's owner loses the difference.
Equal → both destroyed. Empty slots refill from the deck at each turn. Win at enemy LP 0 or when the enemy has no cards.

Export (single-threaded web, no COOP/COEP needed):

    godot --headless --path godot-src --export-release "Web" godot/index.html

Debug: `godot --path godot-src -- --autoplay --shots` plays a bot-vs-bot game and saves screenshots to user://.
