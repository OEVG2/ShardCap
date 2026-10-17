# ShardCap 2.0 (WoW 1.12.1 and WoW 1.18.1 Clients)

Keeps your Soul Shards at a cap. Lightweight and silent by default.

Merges the original [ShardCap](https://github.com/dogmax/ShardCap), the stacking support from
[ShardCapPlus](https://github.com/akzkak/ShardCapPlus) and the soul-bag sorting idea from
[voxan-dev's fork](https://github.com/voxan-dev/ShardCap), and fixes their bugs.

## What it does
- **Trims to the cap when you leave combat** (or any time your bags change out of combat).
- **WoW 1.18.1 Clients stacking (3 per slot):** counts shards per stack and deletes *exactly* the excess,
  splitting a stack if needed. 13 shards at cap 12 → deletes 1, not a whole stack of 3.
- **Merges partial stacks** (e.g. 1 + 2 → 3) so shards use as few slots as possible.
- **Soul bag aware:** deletes shards in normal bags first (backpack first), keeps the ones in your
  soul bag, and moves loose shards into free soul bag slots. Soul bag can be in any bag slot.
- **Warlock reagents into the soul bag (WoW 1.18.1 Clients):** Demonic Figurines and Infernal
  Stones are moved into free soul bag slots, filling from the end of the bag. Enough slots are always kept
  free to hold your shard cap (e.g. cap 12 at 3 per slot = 4 slots), so reagents never crowd out shards.
  Skipped on servers where shards don't stack. If the server refuses the move anyway, it stops
  after one notice and doesn't retry that session.
- **Safe:** never acts while you hold something on the cursor or a stack is locked, and only
  touches item ID 6265 (the 1.x addons matched any link containing "6265", e.g. item 16265).
- Settings from ShardCap 1.x are migrated automatically.

## Install
Download the zip, rename the `shardcap-main` folder to `ShardCap`, and put it in `Interface/AddOns/`, replacing the old one. Disable ShardCapPlus
if you have it — the addon warns you if both are on.

## Commands (`/shardcap` or `/scap`)
| Command | Effect |
|---|---|
| `/shardcap 12` | Set the cap (0–200) |
| `/shardcap` or `status` | Shards carried vs. cap (e.g. `5/12`), soul bags, settings |
| `/shardcap delete` | Trim right now, even in combat |
| `/shardcap spam` | Toggle chat notifications |
| `/shardcap sort` | Toggle merging/moving shards into the soul bag |
| `/shardcap combat` | Toggle trimming during combat |
| `/shardcap reagents` | Toggle moving Demonic Figurines / Infernal Stones into the soul bag |
| `/shardcap soulbag auto` / `1-4` | Auto-detect, or mark a bag as soul bag manually |
| `/shardcap reset` | Restore defaults |

## Client mods (optional, auto-detected)
- **ClassicAPI** — used when present: exact item ID and stack size per slot, locale-free soul bag
  detection (works for any custom soul bag on WoW 1.18.1 Clients), cursor-free moves/merges, and `BAG_UPDATE_DELAYED`
  so a loot or trade burst triggers one scan instead of many.
- **Nampower** — used if ClassicAPI isn't: `GetBagItem` gives the item ID without parsing links.
  Small gain; the vanilla path is already exact.
- **SuperWoW / UnitXP SP3** — not used. Neither adds anything for bags or items.

## Tests
`tests/test.lua` runs the addon against a mock 1.12 client (stacking, soul bags, combat, cursor,
locked items, migration). Run it from the repo root with a Lua 5.0 interpreter: `lua tests/test.lua`.
