# MGE Class ELO

A companion [SourceMod](https://www.sourcemod.net/) plugin for [MGEMod](https://github.com/mgetf/MGEMod) that tracks a **separate ELO rating per TF2 class** for 1v1 duels, displayed inline on MGEMod's own HUD as `PlayerName (globalElo/classElo): score`.

This plugin does not modify MGEMod's global ELO system. It maintains its own per-class ratings in a dedicated database table, computed from match results MGEMod already reports through its public API.

## Requirements

- [MGEMod](https://github.com/mgetf/MGEMod) with `MGE_On1v1MatchEnd` on frag-limit, forfeit, bball, and koth (v3.1.0-beta36 or later)
- SourceMod 1.11+

## How class ELO is calculated

Only 1v1 duels are tracked in this version (2v2 is out of scope).

For every duel, each player's classes are tracked from the point they enter the fight. Switching classes **before either player has scored** is treated as a free pre-fight pick and does not count as a "switch" (this matches MGEMod's own behavior, which always allows free class changes while the score is still 0-0). Switching **after** the score has moved counts as a real mid-duel switch.

Given a finished duel:

1. **If the winner switched classes mid-duel** → the duel is voided entirely. Neither player's class ELO changes.
2. **If the winner did not switch:**
   - If the loser also did not switch → a normal ELO update is applied between the winner's class and the loser's class.
   - If the loser switched → the update is still applied, but the loser is debited on whichever of their used classes currently has the **highest rating** (they don't get to hide behind a weaker class they only used briefly).

Known limitation: this is role-based (winner/loser), not order-based (who switched first). A player who switches first can still avoid punishment if their opponent also switches at any point during the same duel, since that makes it a winner-switched (voided) duel. Fixing this would require tracking switch order/timestamps to identify the instigator regardless of who wins; this is intentionally out of scope for now.

The ELO math itself mirrors MGEMod's own formula (K=15, or K=10 once a class rating reaches 2400+).

## Coverage

The plugin listens for `MGE_On1v1MatchEnd` (frag-limit, forfeit, bball, and koth 1v1 paths in MGEMod v3.1.0-beta36+). 2v2 / 4-player arenas are skipped. Elo class ratings still update live per duel. Glicko-2 class ratings log the duel and show a HUD preview until the wall-clock period seals.

## Commands

| Command | Description |
|---|---|
| `sm_classelo` | Toggle your own per-class ELO display on the MGE HUD (saved as a client cookie) |

## Rating Engines

Per-class ratings support two pluggable rating engines, selected via `mge_classelo_rating_engine`. This is fully independent from MGEMod core's own `mgemod_rating_engine` - either plugin can run Elo while the other runs Glicko-2, with no conflict.

* **Elo (default)**: the original K-factor formula this plugin has always used. Zero behavior change. Live per duel.
* **Glicko-2 (opt-in)**: same published algorithm as MGEMod core's own opt-in engine (RD + volatility), but implemented independently for this plugin's per-class table - no shared code with MGEMod core. Period length and close phase match MGEMod (`mge_classelo_glicko_period_hours` plus hour/minute/utc_offset). Each class is sealed on its own from `mge_classelo_duels` rows for that `(steamid, class)`. HUD wraps MGEMod's `extraDisplay` and appends `/~1850` while that class is dirty, or `/1850` after seal. `?` still means provisional **sealed** class RD. Close uses lock name `mge_classelo_period_close` so it does not queue behind overall MGEMod close.

Unused classes do **not** gain RD every 24h. `mge_classelo_glicko_period_days` stays the inactivity window (default 7). A class with no games in this window inflates RD only after that many days since `lastplayed`. A never-played class has no row.

**Sparse classes.** Batching only helps when several games share one window. Eight engineer duels the same night become one period. Eight engineer duels on eight different days are eight one-game periods, and RD can still rise. Raising `mge_classelo_glicko_period_hours` (for example 168) is optional later, not a v1 bug.

The calibration defaults are deliberately different from MGEMod core's Glicko-2 engine, because a single class is played far less often than the game overall (a player might have 500 global duels but only 20 as an off-meta class). `mge_classelo_glicko_period_days` defaults to a wider inactivity window (7 days instead of 1) and `mge_classelo_glicko_provisional_rd` defaults slightly looser (250 instead of 200) to account for this.

## ConVars

| ConVar | Default | Description |
|---|---|---|
| `mge_classelo_dbconfig` | `mge_classelo` | Name of the `databases.cfg` entry to use. The plugin waits until `server.cfg` has been applied before connecting. If that entry is missing or unreachable, the plugin fails to load. There is no SQLite fallback. |
| `mge_classelo_rating_engine` | `elo` | Rating engine used to score per-class duels: `elo` (default) or `glicko2` (opt-in). |
| `mge_classelo_glicko_tau` | `0.5` | Glicko-2 system constant controlling how fast per-class volatility reacts to surprising results. Only used when `mge_classelo_rating_engine` is `glicko2`. |
| `mge_classelo_glicko_period_hours` | `24` | Length of one per-class Glicko-2 rating period in hours (1-168). Match MGEMod. |
| `mge_classelo_glicko_period_hour` | `8` | Local hour (0-23) of the class period boundary. Match MGEMod. |
| `mge_classelo_glicko_period_minute` | `20` | Local minute (0-59) of the class period boundary. Match MGEMod. |
| `mge_classelo_glicko_period_utc_offset` | `-3` | Hours added to UTC to get local time for the class period boundary (ART is -3). |
| `mge_classelo_glicko_period_days` | `7.0` | Days of inactivity before an unused class gets one period of RD inflation. Daily close does not inflate unused classes every 24h. Only used when `mge_classelo_rating_engine` is `glicko2`. |
| `mge_classelo_glicko_provisional_rd` | `250.0` | RD threshold above which a per-class Glicko-2 rating is considered provisional (shown with a `?` suffix on the HUD). Only used when `mge_classelo_rating_engine` is `glicko2`. |

## Installation

1. Make sure MGEMod is installed and includes the HUD forwards this plugin depends on (v3.1.0-beta36 or later so bball/koth fire `MGE_On1v1MatchEnd`).
2. Drop `plugins/mge_classelo.smx` into your server's `addons/sourcemod/plugins/` folder.
3. Drop `translations/mge_classelo.phrases.txt` into `addons/sourcemod/translations/`.
4. Add a `"mge_classelo"` block to `addons/sourcemod/configs/databases.cfg` pointing at the dedicated class-ELO database.
5. Keep `mge_classelo_dbconfig "mge_classelo"` in `server.cfg` (that is also the plugin default). The plugin reads this after configs execute, so `server.cfg` wins over the compiled default.
6. For Glicko-2 periods on empty boxes, keep `sv_hibernate_when_empty 0` (same as MGEMod overall).

## Building from source

```
spcomp -i"./scripting/include/" scripting/mge_classelo.sp -o ./plugins/mge_classelo.smx
```

`scripting/include/mge.inc` is a vendored copy of MGEMod's public API header, kept in sync with the MGEMod version this plugin targets.

## Agent notes

Wall-clock Glicko-2 periods, locks, leftover close, HUD `~`, sparse-class RD, and the classelo-vs-mgemod DB incident are documented in MGEMod:

[docs/glicko2-24h-period-walkthrough.md](https://github.com/mgetf/MGEMod/blob/master/docs/glicko2-24h-period-walkthrough.md)

classelo uses lock name `mge_classelo_period_close`, table `mge_classelo_duels`, and `GetClientAuthId` (not an MGE Steam ID native).

## License

See [MGEMod](https://github.com/mgetf/MGEMod) for licensing of the base plugin this depends on.
