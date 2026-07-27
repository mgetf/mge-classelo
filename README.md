# MGE Class ELO

A companion [SourceMod](https://www.sourcemod.net/) plugin for [MGEMod](https://github.com/mgetf/MGEMod) that tracks a **separate ELO rating per TF2 class** for 1v1 duels, displayed inline on MGEMod's own HUD as `PlayerName (globalElo/classElo): score`.

This plugin does not modify MGEMod's global ELO system. It maintains its own per-class ratings in a dedicated database table, computed from match results MGEMod already reports through its public API.

## Requirements

- [MGEMod](https://github.com/mgetf/MGEMod) with the `MGE_OnFormatHudLine` / `MGE_OnBuildHudScoreReport` HUD forwards (v3.1.0-beta29 or later)
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

The plugin listens for `MGE_OnPlayerELOChange` rather than `MGE_On1v1MatchEnd`, since the latter is only fired for frag-limit-completion wins. Forfeits/early leaves, bball wins, and koth wins all update global ELO through a different code path that skips that forward, but they all still fire `MGE_OnPlayerELOChange` — so class ELO stays in sync with every path that can move global ELO.

## Commands

| Command | Description |
|---|---|
| `sm_classelo` | Toggle your own per-class ELO display on the MGE HUD (saved as a client cookie) |

## ConVars

| ConVar | Default | Description |
|---|---|---|
| `mge_classelo_dbconfig` | `mgemod` | Name of the `databases.cfg` entry to use. Falls back to SQLite (`storage-local`) if not found. |

## Installation

1. Make sure MGEMod is installed and includes the HUD forwards this plugin depends on.
2. Drop `addons/sourcemod/plugins/mge_classelo.smx` into your server's `addons/sourcemod/plugins/` folder.
3. (Optional) Set `mge_classelo_dbconfig` if you want class ELO stored in a specific database config other than the default `mgemod` entry.

## Building from source

```
spcomp -i"./addons/sourcemod/scripting/include/" addons/sourcemod/scripting/mge_classelo.sp -o ./addons/sourcemod/plugins/mge_classelo.smx
```

`addons/sourcemod/scripting/include/mge.inc` is a vendored copy of MGEMod's public API header, kept in sync with the MGEMod version this plugin targets.

## License

See [MGEMod](https://github.com/mgetf/MGEMod) for licensing of the base plugin this depends on.
