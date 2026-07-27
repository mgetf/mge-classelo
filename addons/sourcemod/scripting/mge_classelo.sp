#pragma semicolon 1
#pragma newdecls required

#if defined (MAXPLAYERS)
    #undef MAXPLAYERS
    #define MAXPLAYERS 101
#endif

#include <sourcemod>
#include <tf2_stocks>
#include <clientprefs>
#include <mge>

#define PLUGIN_VERSION "0.2"
#define DEFAULT_CLASS_ELO 1600
#define MAX_TF_CLASSES 10
#define MAXARENAS 63

public Plugin myinfo =
{
    name = "MGE Class ELO",
    author = "mgetf",
    description = "Per-class ELO ratings for MGE 1v1 duels",
    version = PLUGIN_VERSION,
    url = "https://github.com/mgetf/mge-classelo"
};

Database g_DB;
ConVar g_cvDBConfig;

int g_iClassElo[MAXPLAYERS + 1][MAX_TF_CLASSES];
int g_iClassWins[MAXPLAYERS + 1][MAX_TF_CLASSES];
int g_iClassLosses[MAXPLAYERS + 1][MAX_TF_CLASSES];
bool g_bClassEloLoaded[MAXPLAYERS + 1];

ArrayList g_alDuelClasses[MAXPLAYERS + 1];
bool g_bDuelTracking[MAXPLAYERS + 1];

bool g_bShowClassElo[MAXPLAYERS + 1];
Cookie g_hShowClassEloCookie;

bool g_bPendingClassElo[MAXARENAS + 1];
int g_iPendingWinner[MAXARENAS + 1];
int g_iPendingLoser[MAXARENAS + 1];

public void OnPluginStart()
{
    g_cvDBConfig = CreateConVar("mge_classelo_dbconfig", "mgemod", "Name of databases.cfg entry for class ELO storage");

    g_hShowClassEloCookie = new Cookie("mge_classelo_show", "Show per-class ELO on MGE HUD", CookieAccess_Public);

    RegConsoleCmd("sm_classelo", Command_ToggleClassElo, "Toggle per-class ELO display on the MGE HUD");

    HookEvent("player_changeclass", Event_PlayerChangeClass, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

    for (int i = 0; i <= MaxClients; i++)
        ResetClientState(i);

    PrepareSQL();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && AreClientCookiesCached(i))
            OnClientCookiesCached(i);

        if (IsClientInGame(i) && !IsFakeClient(i) && IsClientAuthorized(i))
            LoadPlayerClassElo(i);
    }
}

public void OnPluginEnd()
{
    for (int i = 0; i <= MaxClients; i++)
        ClearDuelClasses(i);
}

public void OnClientPutInServer(int client)
{
    ResetClientState(client);
}

public void OnClientDisconnect(int client)
{
    ResetClientState(client);
}

public void OnClientCookiesCached(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    char value[8];
    g_hShowClassEloCookie.Get(client, value, sizeof(value));
    g_bShowClassElo[client] = (value[0] == '\0' || value[0] == '1');
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    LoadPlayerClassElo(client);
}

// ===== DATABASE =====

void PrepareSQL()
{
    char error[256];
    char dbConfig[64];
    g_cvDBConfig.GetString(dbConfig, sizeof(dbConfig));

    if (strlen(dbConfig) == 0 || !SQL_CheckConfig(dbConfig))
    {
        if (strlen(dbConfig) > 0)
            LogMessage("[mge_classelo] Database config '%s' not found, falling back to storage-local", dbConfig);

        g_DB = SQL_Connect("storage-local", true, error, sizeof(error));
        if (g_DB == null)
        {
            LogError("[mge_classelo] Could not connect to SQLite: %s", error);
            return;
        }
    }
    else
    {
        g_DB = SQL_Connect(dbConfig, true, error, sizeof(error));
        if (g_DB == null)
        {
            LogError("[mge_classelo] Could not connect to '%s': %s - falling back to storage-local", dbConfig, error);
            g_DB = SQL_Connect("storage-local", true, error, sizeof(error));
            if (g_DB == null)
            {
                LogError("[mge_classelo] Could not connect to SQLite fallback: %s", error);
                return;
            }
        }
    }

    char ident[16];
    g_DB.Driver.GetIdentifier(ident, sizeof(ident));

    char query[512];
    if (StrEqual(ident, "sqlite", false))
    {
        strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_stats (steamid TEXT NOT NULL, class INTEGER NOT NULL, rating INTEGER NOT NULL DEFAULT 1600, wins INTEGER NOT NULL DEFAULT 0, losses INTEGER NOT NULL DEFAULT 0, lastplayed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (steamid, class))");
    }
    else if (StrEqual(ident, "mysql", false))
    {
        g_DB.SetCharset("utf8mb4");
        strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_stats (steamid VARCHAR(32) NOT NULL, class INT NOT NULL, rating INT NOT NULL DEFAULT 1600, wins INT NOT NULL DEFAULT 0, losses INT NOT NULL DEFAULT 0, lastplayed INT NOT NULL DEFAULT 0, PRIMARY KEY (steamid, class))");
    }
    else if (StrEqual(ident, "pgsql", false))
    {
        strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_stats (steamid VARCHAR(32) NOT NULL, class INT NOT NULL, rating INT NOT NULL DEFAULT 1600, wins INT NOT NULL DEFAULT 0, losses INT NOT NULL DEFAULT 0, lastplayed INT NOT NULL DEFAULT 0, PRIMARY KEY (steamid, class))");
    }
    else
    {
        LogError("[mge_classelo] Unsupported database type: %s", ident);
        delete g_DB;
        g_DB = null;
        return;
    }

    g_DB.Query(SQL_OnCreateTable, query);
}

void SQL_OnCreateTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("[mge_classelo] Failed to create table: %s", error);
        return;
    }

    LogMessage("[mge_classelo] Database ready");
}

void LoadPlayerClassElo(int client)
{
    if (g_DB == null || !IsValidClient(client) || IsFakeClient(client))
        return;

    char steamid[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
        return;

    for (int c = 1; c < MAX_TF_CLASSES; c++)
    {
        g_iClassElo[client][c] = DEFAULT_CLASS_ELO;
        g_iClassWins[client][c] = 0;
        g_iClassLosses[client][c] = 0;
    }
    g_bClassEloLoaded[client] = false;

    char query[256];
    g_DB.Format(query, sizeof(query),
        "SELECT class, rating, wins, losses FROM mge_classelo_stats WHERE steamid = '%s'",
        steamid);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    g_DB.Query(SQL_OnPlayerClassEloReceived, query, pack);
}

void SQL_OnPlayerClassEloReceived(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client))
        return;

    if (results == null)
    {
        LogError("[mge_classelo] Failed to load class ELO for %N: %s", client, error);
        g_bClassEloLoaded[client] = true;
        return;
    }

    while (results.FetchRow())
    {
        int classIdx = results.FetchInt(0);
        if (classIdx < 1 || classIdx >= MAX_TF_CLASSES)
            continue;

        g_iClassElo[client][classIdx] = results.FetchInt(1);
        g_iClassWins[client][classIdx] = results.FetchInt(2);
        g_iClassLosses[client][classIdx] = results.FetchInt(3);
    }

    g_bClassEloLoaded[client] = true;
}

void PersistClassElo(int client, TFClassType classType)
{
    if (g_DB == null || !IsValidClient(client) || IsFakeClient(client))
        return;

    char steamid[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
        return;

    int classIdx = view_as<int>(classType);
    int rating = g_iClassElo[client][classIdx];
    int wins = g_iClassWins[client][classIdx];
    int losses = g_iClassLosses[client][classIdx];
    int timestamp = GetTime();

    char ident[16];
    g_DB.Driver.GetIdentifier(ident, sizeof(ident));

    char query[512];
    if (StrEqual(ident, "sqlite", false))
    {
        g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed) VALUES ('%s', %d, %d, %d, %d, %d) ON CONFLICT(steamid, class) DO UPDATE SET rating = excluded.rating, wins = excluded.wins, losses = excluded.losses, lastplayed = excluded.lastplayed", steamid, classIdx, rating, wins, losses, timestamp);
    }
    else if (StrEqual(ident, "pgsql", false))
    {
        g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed) VALUES ('%s', %d, %d, %d, %d, %d) ON CONFLICT (steamid, class) DO UPDATE SET rating = EXCLUDED.rating, wins = EXCLUDED.wins, losses = EXCLUDED.losses, lastplayed = EXCLUDED.lastplayed", steamid, classIdx, rating, wins, losses, timestamp);
    }
    else
    {
        g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed) VALUES ('%s', %d, %d, %d, %d, %d) ON DUPLICATE KEY UPDATE rating = VALUES(rating), wins = VALUES(wins), losses = VALUES(losses), lastplayed = VALUES(lastplayed)", steamid, classIdx, rating, wins, losses, timestamp);
    }

    g_DB.Query(SQL_OnGenericQuery, query);
}

void SQL_OnGenericQuery(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("[mge_classelo] Query failed: %s", error);
}

// ===== CLASS TRACKING =====

void ClearDuelClasses(int client)
{
    if (client < 0 || client > MaxClients)
        return;

    delete g_alDuelClasses[client];
    g_alDuelClasses[client] = null;
    g_bDuelTracking[client] = false;
}

void BeginDuelClassTracking(int client)
{
    if (!IsValidClient(client))
        return;

    ClearDuelClasses(client);
    g_alDuelClasses[client] = new ArrayList();
    g_bDuelTracking[client] = true;

    TFClassType current = TF2_GetPlayerClass(client);
    if (current != TFClass_Unknown)
        g_alDuelClasses[client].Push(view_as<int>(current));
}

void RecordClassChange(int client, TFClassType newClass)
{
    if (!IsValidClient(client) || !g_bDuelTracking[client] || g_alDuelClasses[client] == null)
        return;

    if (newClass == TFClass_Unknown)
        return;

    int arena_index = MGE_GetPlayerArena(client);
    if (arena_index <= 0 || !MGE_IsPlayerInArena(client))
        return;

    if (MGE_ArenaHasGameMode(arena_index, MGE_GAMEMODE_4PLAYER))
        return;

    int newIdx = view_as<int>(newClass);
    bool scoreStarted = (MGE_GetArenaScore(arena_index, SLOT_ONE) != 0 || MGE_GetArenaScore(arena_index, SLOT_TWO) != 0);

    if (!scoreStarted)
    {
        if (g_alDuelClasses[client].Length == 0)
            g_alDuelClasses[client].Push(newIdx);
        else
            g_alDuelClasses[client].Set(0, newIdx);
        return;
    }

    if (g_alDuelClasses[client].Length > 0)
    {
        int last = g_alDuelClasses[client].Get(g_alDuelClasses[client].Length - 1);
        if (last == newIdx)
            return;
    }

    if (g_alDuelClasses[client].FindValue(newIdx) == -1)
        g_alDuelClasses[client].Push(newIdx);
}

bool DidPlayerSwitchClass(int client)
{
    return (g_alDuelClasses[client] != null && g_alDuelClasses[client].Length > 1);
}

TFClassType GetStartingClass(int client)
{
    if (g_alDuelClasses[client] == null || g_alDuelClasses[client].Length == 0)
        return TF2_GetPlayerClass(client);

    return view_as<TFClassType>(g_alDuelClasses[client].Get(0));
}

TFClassType GetHighestRatedUsedClass(int client)
{
    if (g_alDuelClasses[client] == null || g_alDuelClasses[client].Length == 0)
        return GetStartingClass(client);

    TFClassType best = view_as<TFClassType>(g_alDuelClasses[client].Get(0));
    int bestRating = g_iClassElo[client][view_as<int>(best)];

    for (int i = 1; i < g_alDuelClasses[client].Length; i++)
    {
        TFClassType cls = view_as<TFClassType>(g_alDuelClasses[client].Get(i));
        int rating = g_iClassElo[client][view_as<int>(cls)];
        if (rating > bestRating)
        {
            bestRating = rating;
            best = cls;
        }
    }

    return best;
}

public void Event_PlayerChangeClass(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    TFClassType newClass = view_as<TFClassType>(event.GetInt("class"));
    RecordClassChange(client, newClass);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || IsFakeClient(client) || !g_bDuelTracking[client])
        return;

    RecordClassChange(client, TF2_GetPlayerClass(client));
}

public void MGE_On1v1MatchStart(int arena_index, int player1, int player2)
{
    BeginDuelClassTracking(player1);
    BeginDuelClassTracking(player2);
}

// ===== ELO CALCULATION =====

public void MGE_OnPlayerELOChange(int client, int old_elo, int new_elo, int arena_index)
{
    if (arena_index < 1 || arena_index > MAXARENAS)
        return;

    if (MGE_ArenaHasGameMode(arena_index, MGE_GAMEMODE_4PLAYER))
        return;

    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    bool gained = (new_elo > old_elo);

    if (!g_bPendingClassElo[arena_index])
    {
        g_bPendingClassElo[arena_index] = true;
        g_iPendingWinner[arena_index] = 0;
        g_iPendingLoser[arena_index] = 0;

        if (gained)
            g_iPendingWinner[arena_index] = client;
        else
            g_iPendingLoser[arena_index] = client;

        RequestFrame(Frame_ProcessClassElo, arena_index);
    }
    else
    {
        if (gained)
            g_iPendingWinner[arena_index] = client;
        else
            g_iPendingLoser[arena_index] = client;
    }
}

void Frame_ProcessClassElo(int arena_index)
{
    if (arena_index < 1 || arena_index > MAXARENAS)
        return;

    if (!g_bPendingClassElo[arena_index])
        return;

    int winner = g_iPendingWinner[arena_index];
    int loser = g_iPendingLoser[arena_index];

    g_bPendingClassElo[arena_index] = false;
    g_iPendingWinner[arena_index] = 0;
    g_iPendingLoser[arena_index] = 0;

    if (!IsValidClient(winner) || !IsValidClient(loser))
        return;

    if (IsFakeClient(winner) || IsFakeClient(loser))
        return;

    if (!g_bClassEloLoaded[winner] || !g_bClassEloLoaded[loser])
        return;

    if (DidPlayerSwitchClass(winner))
    {
        ClearDuelClasses(winner);
        ClearDuelClasses(loser);
        return;
    }

    TFClassType winnerClass = GetStartingClass(winner);
    TFClassType loserClass;

    if (DidPlayerSwitchClass(loser))
        loserClass = GetHighestRatedUsedClass(loser);
    else
        loserClass = GetStartingClass(loser);

    if (winnerClass == TFClass_Unknown || loserClass == TFClass_Unknown)
    {
        ClearDuelClasses(winner);
        ClearDuelClasses(loser);
        return;
    }

    int wIdx = view_as<int>(winnerClass);
    int lIdx = view_as<int>(loserClass);

    int winnerRating = g_iClassElo[winner][wIdx];
    int loserRating = g_iClassElo[loser][lIdx];

    float expected = 1.0 / (Pow(10.0, float(winnerRating - loserRating) / 400.0) + 1.0);
    int kWin = (winnerRating >= 2400) ? 10 : 15;
    int kLose = (loserRating >= 2400) ? 10 : 15;
    int winnerDelta = RoundFloat(float(kWin) * expected);
    int loserDelta = RoundFloat(float(kLose) * expected);

    g_iClassElo[winner][wIdx] += winnerDelta;
    g_iClassElo[loser][lIdx] -= loserDelta;
    g_iClassWins[winner][wIdx]++;
    g_iClassLosses[loser][lIdx]++;

    PersistClassElo(winner, winnerClass);
    PersistClassElo(loser, loserClass);

    if (g_bShowClassElo[winner])
        PrintToChat(winner, "[Class ELO] +%d %s (%d)", winnerDelta, ClassToName(winnerClass), g_iClassElo[winner][wIdx]);

    if (g_bShowClassElo[loser])
        PrintToChat(loser, "[Class ELO] -%d %s (%d)", loserDelta, ClassToName(loserClass), g_iClassElo[loser][lIdx]);

    ClearDuelClasses(winner);
    ClearDuelClasses(loser);
}

// ===== HUD =====

// Rewrites the "(elo)" parenthetical into "(elo/classelo)" for the viewer's class-ELO preference
public void MGE_OnFormatHudLine(MGEHudLineInfo info)
{
    if (!IsValidClient(info.viewer) || !g_bShowClassElo[info.viewer])
        return;

    int player = info.player;
    if (!IsValidClient(player) || IsFakeClient(player) || !g_bClassEloLoaded[player])
        return;

    if (info.arena_index < 1 || MGE_ArenaHasGameMode(info.arena_index, MGE_GAMEMODE_4PLAYER))
        return;

    TFClassType cls;
    if (g_bDuelTracking[player] && g_alDuelClasses[player] != null && g_alDuelClasses[player].Length > 0)
        cls = GetStartingClass(player);
    else
        cls = TF2_GetPlayerClass(player);

    if (cls == TFClass_Unknown)
        return;

    int rating = g_iClassElo[player][view_as<int>(cls)];
    char globalEloText[16];
    strcopy(globalEloText, sizeof(globalEloText), info.extraDisplay);
    Format(info.extraDisplay, sizeof(info.extraDisplay), "%s/%d", globalEloText, rating);
}

// ===== COMMANDS =====

Action Command_ToggleClassElo(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    g_bShowClassElo[client] = !g_bShowClassElo[client];
    g_hShowClassEloCookie.Set(client, g_bShowClassElo[client] ? "1" : "0");

    PrintToChat(client, "[Class ELO] Display %s", g_bShowClassElo[client] ? "enabled" : "disabled");
    return Plugin_Handled;
}

// ===== HELPERS =====

void ResetClientState(int client)
{
    if (client < 0 || client > MaxClients)
        return;

    ClearDuelClasses(client);
    g_bClassEloLoaded[client] = false;
    g_bShowClassElo[client] = true;

    for (int c = 0; c < MAX_TF_CLASSES; c++)
    {
        g_iClassElo[client][c] = DEFAULT_CLASS_ELO;
        g_iClassWins[client][c] = 0;
        g_iClassLosses[client][c] = 0;
    }
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

char[] ClassToName(TFClassType classType)
{
    char name[16];
    switch (classType)
    {
        case TFClass_Scout: strcopy(name, sizeof(name), "scout");
        case TFClass_Sniper: strcopy(name, sizeof(name), "sniper");
        case TFClass_Soldier: strcopy(name, sizeof(name), "soldier");
        case TFClass_DemoMan: strcopy(name, sizeof(name), "demoman");
        case TFClass_Medic: strcopy(name, sizeof(name), "medic");
        case TFClass_Heavy: strcopy(name, sizeof(name), "heavy");
        case TFClass_Pyro: strcopy(name, sizeof(name), "pyro");
        case TFClass_Spy: strcopy(name, sizeof(name), "spy");
        case TFClass_Engineer: strcopy(name, sizeof(name), "engineer");
        default: strcopy(name, sizeof(name), "unknown");
    }
    return name;
}
