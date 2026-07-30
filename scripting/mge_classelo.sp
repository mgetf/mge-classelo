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

#define DEBUG 1

#define PLUGIN_VERSION "0.3.2"
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

#if DEBUG
    ClassElo_Log("lifecycle", "OnPluginStart version=%s maxclients=%d", PLUGIN_VERSION, MaxClients);
#endif

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
#if DEBUG
    ClassElo_Log("lifecycle", "OnPluginEnd clearing duel class lists");
#endif
    for (int i = 0; i <= MaxClients; i++)
        ClearDuelClasses(i);
}

#if DEBUG
public void OnMapStart()
{
    ClassElo_Log("lifecycle", "OnMapStart db=%s", g_DB == null ? "null" : "ok");
}
#endif

public void OnClientPutInServer(int client)
{
#if DEBUG
    char who[96];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassElo_Log("client", "PutInServer %s", who);
#endif
    ResetClientState(client);
}

public void OnClientDisconnect(int client)
{
#if DEBUG
    char who[96];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassElo_Log("client", "Disconnect %s tracking=%d loaded=%d",
        who, g_bDuelTracking[client], g_bClassEloLoaded[client]);
#endif
    ResetClientState(client);
}

public void OnClientCookiesCached(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
    {
#if DEBUG
        ClassElo_Log("cookie", "skip cookies client=%d valid=%d fake=%d",
            client, IsValidClient(client), IsValidClient(client) ? IsFakeClient(client) : false);
#endif
        return;
    }

    char value[8];
    g_hShowClassEloCookie.Get(client, value, sizeof(value));
    g_bShowClassElo[client] = (value[0] == '\0' || value[0] == '1');

#if DEBUG
    char who[96];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassElo_Log("cookie", "cached %s raw='%s' show=%d", who, value, g_bShowClassElo[client]);
#endif
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
    {
#if DEBUG
        ClassElo_Log("client", "PostAdminCheck skip client=%d", client);
#endif
        return;
    }

#if DEBUG
    char who[96];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassElo_Log("client", "PostAdminCheck %s -> LoadPlayerClassElo", who);
#endif
    LoadPlayerClassElo(client);
}

#if DEBUG
// ===== LOGGING =====

void ClassElo_Log(const char[] flow, const char[] fmt, any ...)
{
    char message[512];
    VFormat(message, sizeof(message), fmt, 3);
    LogMessage("[mge_classelo][%s] %s", flow, message);
}

void ClassElo_DescribeClient(int client, char[] buf, int maxlen)
{
    if (client <= 0 || client > MaxClients)
    {
        Format(buf, maxlen, "client=%d<invalid>", client);
        return;
    }

    char name[MAX_NAME_LENGTH];
    char steamid[32];
    if (IsClientConnected(client))
        GetClientName(client, name, sizeof(name));
    else
        strcopy(name, sizeof(name), "?");

    if (!IsClientConnected(client) || !GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
        strcopy(steamid, sizeof(steamid), "noauth");

    Format(buf, maxlen, "%s<%d>(%s) ingame=%d fake=%d",
        name, GetClientUserId(client), steamid,
        IsClientInGame(client), IsFakeClient(client));
}

void ClassElo_FormatClassList(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (g_alDuelClasses[client] == null || g_alDuelClasses[client].Length == 0)
    {
        strcopy(buffer, maxlen, "(empty)");
        return;
    }

    for (int i = 0; i < g_alDuelClasses[client].Length; i++)
    {
        char cname[16];
        char part[32];
        TFClassType cls = view_as<TFClassType>(g_alDuelClasses[client].Get(i));
        ClassToName(cls, cname, sizeof(cname));
        Format(part, sizeof(part), "%s%s(%d)",
            (i == 0) ? "" : ",",
            cname,
            g_iClassElo[client][view_as<int>(cls)]);
        StrCat(buffer, maxlen, part);
    }
}

void ClassElo_LogClientDuelState(const char[] flow, int client, const char[] context)
{
    char who[96];
    char classes[128];
    char liveClass[16];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassElo_FormatClassList(client, classes, sizeof(classes));

    int arena = IsValidClient(client) ? MGE_GetPlayerArena(client) : 0;
    if (IsValidClient(client))
        ClassToName(TF2_GetPlayerClass(client), liveClass, sizeof(liveClass));
    else
        strcopy(liveClass, sizeof(liveClass), "n/a");

    ClassElo_Log(flow, "%s %s tracking=%d loaded=%d arena=%d in_arena=%d score1=%d score2=%d classes=[%s] live_class=%s",
        context,
        who,
        g_bDuelTracking[client],
        g_bClassEloLoaded[client],
        arena,
        IsValidClient(client) ? MGE_IsPlayerInArena(client) : false,
        (arena > 0) ? MGE_GetArenaScore(arena, SLOT_ONE) : -1,
        (arena > 0) ? MGE_GetArenaScore(arena, SLOT_TWO) : -1,
        classes,
        liveClass);
}
#endif

// ===== DATABASE =====

void PrepareSQL()
{
    char error[256];
    char dbConfig[64];
    g_cvDBConfig.GetString(dbConfig, sizeof(dbConfig));

#if DEBUG
    ClassElo_Log("db", "PrepareSQL config='%s' check=%d", dbConfig, SQL_CheckConfig(dbConfig));
#endif

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
#if DEBUG
        ClassElo_Log("db", "connected via storage-local fallback");
#endif
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
#if DEBUG
            ClassElo_Log("db", "connected via storage-local after primary failure");
#endif
        }
#if DEBUG
        else
        {
            ClassElo_Log("db", "connected via config '%s'", dbConfig);
        }
#endif
    }

    char ident[16];
    g_DB.Driver.GetIdentifier(ident, sizeof(ident));
#if DEBUG
    ClassElo_Log("db", "driver ident=%s", ident);
#endif

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

#if DEBUG
    ClassElo_Log("db", "CREATE TABLE query queued");
#endif
    g_DB.Query(SQL_OnCreateTable, query);
}

void SQL_OnCreateTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("[mge_classelo] Failed to create table: %s", error);
        return;
    }

#if DEBUG
    ClassElo_Log("db", "Database ready (table ensure ok)");
#else
    LogMessage("[mge_classelo] Database ready");
#endif
}

void LoadPlayerClassElo(int client)
{
    if (g_DB == null || !IsValidClient(client) || IsFakeClient(client))
    {
#if DEBUG
        ClassElo_Log("db", "LoadPlayerClassElo SKIP client=%d db=%s", client, g_DB == null ? "null" : "ok");
#endif
        return;
    }

    char steamid[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
    {
#if DEBUG
        ClassElo_Log("db", "LoadPlayerClassElo SKIP no steamid client=%d", client);
#endif
        return;
    }

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

#if DEBUG
    char who[96];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassElo_Log("db", "LoadPlayerClassElo query %s steamid=%s", who, steamid);
#endif

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
    {
#if DEBUG
        ClassElo_Log("db", "Load callback SKIP client gone userid=%d", userid);
#endif
        return;
    }

    if (results == null)
    {
        LogError("[mge_classelo] Failed to load class ELO for %N: %s", client, error);
        g_bClassEloLoaded[client] = true;
        return;
    }

    int rows = 0;
    while (results.FetchRow())
    {
        int classIdx = results.FetchInt(0);
        if (classIdx < 1 || classIdx >= MAX_TF_CLASSES)
            continue;

        g_iClassElo[client][classIdx] = results.FetchInt(1);
        g_iClassWins[client][classIdx] = results.FetchInt(2);
        g_iClassLosses[client][classIdx] = results.FetchInt(3);
        rows++;

#if DEBUG
        char who[96];
        char cname[16];
        ClassElo_DescribeClient(client, who, sizeof(who));
        ClassToName(view_as<TFClassType>(classIdx), cname, sizeof(cname));
        ClassElo_Log("db", "Load row %s class=%s rating=%d w=%d l=%d",
            who, cname,
            g_iClassElo[client][classIdx],
            g_iClassWins[client][classIdx],
            g_iClassLosses[client][classIdx]);
#endif
    }

    g_bClassEloLoaded[client] = true;
#if DEBUG
    char whoDone[96];
    ClassElo_DescribeClient(client, whoDone, sizeof(whoDone));
    ClassElo_Log("db", "Load complete %s rows=%d loaded=1", whoDone, rows);
#endif
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

#if DEBUG
    char who[96];
    char cname[16];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassToName(classType, cname, sizeof(cname));
    ClassElo_Log("db", "Persist queued %s steamid=%s class=%s rating=%d w=%d l=%d driver=%s",
        who, steamid, cname, rating, wins, losses, ident);
#endif
    g_DB.Query(SQL_OnGenericQuery, query);
}

void SQL_OnGenericQuery(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("[mge_classelo] Query failed: %s", error);
#if DEBUG
    else
        ClassElo_Log("db", "Query ok");
#endif
}

// ===== CLASS TRACKING =====

void ClearDuelClasses(int client)
{
    if (client < 0 || client > MaxClients)
        return;

#if DEBUG
    bool had = (g_alDuelClasses[client] != null || g_bDuelTracking[client]);
#endif
    delete g_alDuelClasses[client];
    g_alDuelClasses[client] = null;
    g_bDuelTracking[client] = false;
#if DEBUG
    if (had)
        ClassElo_Log("track", "ClearDuelClasses client=%d", client);
#endif
}

void BeginDuelClassTracking(int client)
{
    if (!IsValidClient(client))
    {
#if DEBUG
        ClassElo_Log("track", "BeginDuel SKIP invalid client=%d", client);
#endif
        return;
    }

    ClearDuelClasses(client);
    g_alDuelClasses[client] = new ArrayList();
    g_bDuelTracking[client] = true;

    TFClassType current = TF2_GetPlayerClass(client);
    if (current != TFClass_Unknown)
        g_alDuelClasses[client].Push(view_as<int>(current));

#if DEBUG
    ClassElo_LogClientDuelState("track", client, "BeginDuel");
#endif
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
    int score1 = MGE_GetArenaScore(arena_index, SLOT_ONE);
    int score2 = MGE_GetArenaScore(arena_index, SLOT_TWO);
    bool scoreStarted = (score1 != 0 || score2 != 0);

    if (!scoreStarted)
    {
        if (g_alDuelClasses[client].Length == 0)
            g_alDuelClasses[client].Push(newIdx);
        else
            g_alDuelClasses[client].Set(0, newIdx);
#if DEBUG
        char who[96];
        char cname[16];
        char classes[128];
        ClassElo_DescribeClient(client, who, sizeof(who));
        ClassToName(newClass, cname, sizeof(cname));
        ClassElo_FormatClassList(client, classes, sizeof(classes));
        ClassElo_Log("track", "RecordClassChange pre-score replace %s arena=%d score=%d-%d new=%s classes=[%s]",
            who, arena_index, score1, score2, cname, classes);
#endif
        return;
    }

    if (g_alDuelClasses[client].Length > 0)
    {
        int last = g_alDuelClasses[client].Get(g_alDuelClasses[client].Length - 1);
        if (last == newIdx)
            return;
    }

    if (g_alDuelClasses[client].FindValue(newIdx) == -1)
    {
        g_alDuelClasses[client].Push(newIdx);
#if DEBUG
        char who[96];
        char cname[16];
        char classes[128];
        ClassElo_DescribeClient(client, who, sizeof(who));
        ClassToName(newClass, cname, sizeof(cname));
        ClassElo_FormatClassList(client, classes, sizeof(classes));
        ClassElo_Log("track", "RecordClassChange mid-duel SWITCH %s arena=%d score=%d-%d new=%s classes=[%s]",
            who, arena_index, score1, score2, cname, classes);
#endif
    }
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
#if DEBUG
    char who[96];
    char cname[16];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassToName(newClass, cname, sizeof(cname));
    ClassElo_Log("event", "player_changeclass %s class=%s tracking=%d", who, cname, g_bDuelTracking[client]);
#endif
    RecordClassChange(client, newClass);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || IsFakeClient(client) || !g_bDuelTracking[client])
        return;

    TFClassType cls = TF2_GetPlayerClass(client);
#if DEBUG
    char who[96];
    char cname[16];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassToName(cls, cname, sizeof(cname));
    ClassElo_Log("event", "player_spawn (tracking) %s class=%s", who, cname);
#endif
    RecordClassChange(client, cls);
}

public void MGE_On1v1MatchStart(int arena_index, int player1, int player2)
{
#if DEBUG
    char p1[96];
    char p2[96];
    ClassElo_DescribeClient(player1, p1, sizeof(p1));
    ClassElo_DescribeClient(player2, p2, sizeof(p2));
    ClassElo_Log("match", "On1v1MatchStart arena=%d p1=%s p2=%s gamemode4=%d",
        arena_index, p1, p2, MGE_ArenaHasGameMode(arena_index, MGE_GAMEMODE_4PLAYER));
#endif

    BeginDuelClassTracking(player1);
    BeginDuelClassTracking(player2);
}

#if DEBUG
public void MGE_On1v1MatchEnd(int arena_index, int winner, int loser, int winner_score, int loser_score)
{
    char w[96];
    char l[96];
    ClassElo_DescribeClient(winner, w, sizeof(w));
    ClassElo_DescribeClient(loser, l, sizeof(l));
    ClassElo_Log("match", "On1v1MatchEnd arena=%d score=%d-%d winner=%s loser=%s pending=%d pendW=%d pendL=%d",
        arena_index, winner_score, loser_score, w, l,
        g_bPendingClassElo[arena_index],
        g_iPendingWinner[arena_index],
        g_iPendingLoser[arena_index]);
    ClassElo_LogClientDuelState("match", winner, "end-winner");
    ClassElo_LogClientDuelState("match", loser, "end-loser");
}
#endif

// ===== ELO CALCULATION =====

public void MGE_OnPlayerELOChange(int client, int old_elo, int new_elo, int arena_index)
{
#if DEBUG
    char who[96];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassElo_Log("elo", "OnPlayerELOChange arena=%d %s old=%d new=%d delta=%d",
        arena_index, who, old_elo, new_elo, new_elo - old_elo);
#endif

    if (arena_index < 1 || arena_index > MAXARENAS)
        return;

    if (MGE_ArenaHasGameMode(arena_index, MGE_GAMEMODE_4PLAYER))
        return;

    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    // MGE CalcELO fires winner then loser; pair roles by that call order.
#if DEBUG
    if (new_elo == old_elo)
        ClassElo_Log("elo", "NOTE elo unchanged (still paired by call order) arena=%d %s", arena_index, who);

    ClassElo_LogClientDuelState("elo", client, (new_elo >= old_elo) ? "elo-first-or-gain" : "elo-loss");
#endif

    if (!g_bPendingClassElo[arena_index])
    {
        g_bPendingClassElo[arena_index] = true;
        g_iPendingWinner[arena_index] = client;
        g_iPendingLoser[arena_index] = 0;

#if DEBUG
        ClassElo_Log("elo", "pending START arena=%d role=winner(first-call) winner=%d loser=%d -> RequestFrame",
            arena_index, g_iPendingWinner[arena_index], g_iPendingLoser[arena_index]);
#endif
        RequestFrame(Frame_ProcessClassElo, arena_index);
    }
    else if (client != g_iPendingWinner[arena_index])
    {
        g_iPendingLoser[arena_index] = client;
#if DEBUG
        ClassElo_Log("elo", "pending UPDATE arena=%d role=loser(second-call) winner=%d loser=%d",
            arena_index, g_iPendingWinner[arena_index], g_iPendingLoser[arena_index]);
#endif
    }
}

void Frame_ProcessClassElo(int arena_index)
{
#if DEBUG
    ClassElo_Log("compute", "Frame_ProcessClassElo ENTER arena=%d pending=%d winner=%d loser=%d",
        arena_index, g_bPendingClassElo[arena_index],
        g_iPendingWinner[arena_index], g_iPendingLoser[arena_index]);
#endif

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
    {
#if DEBUG
        ClassElo_Log("compute", "SKIP missing pair arena=%d winner=%d(valid=%d) loser=%d(valid=%d)",
            arena_index, winner, IsValidClient(winner), loser, IsValidClient(loser));
#endif
        if (IsValidClient(winner))
            ClearDuelClasses(winner);
        if (IsValidClient(loser))
            ClearDuelClasses(loser);
        return;
    }

    if (IsFakeClient(winner) || IsFakeClient(loser))
    {
        ClearDuelClasses(winner);
        ClearDuelClasses(loser);
        return;
    }

    if (!g_bClassEloLoaded[winner] || !g_bClassEloLoaded[loser])
    {
#if DEBUG
        ClassElo_Log("compute", "SKIP ratings not loaded arena=%d winner_loaded=%d loser_loaded=%d",
            arena_index, g_bClassEloLoaded[winner], g_bClassEloLoaded[loser]);
#endif
        ClearDuelClasses(winner);
        ClearDuelClasses(loser);
        return;
    }

    bool winnerSwitched = DidPlayerSwitchClass(winner);
    bool loserSwitched = DidPlayerSwitchClass(loser);

#if DEBUG
    ClassElo_LogClientDuelState("compute", winner, "pre-winner");
    ClassElo_LogClientDuelState("compute", loser, "pre-loser");
#endif

    if (winnerSwitched)
    {
#if DEBUG
        ClassElo_Log("compute", "VOID winner switched mid-duel arena=%d", arena_index);
#endif
        ClearDuelClasses(winner);
        ClearDuelClasses(loser);
        return;
    }

    TFClassType winnerClass = GetStartingClass(winner);
    TFClassType loserClass = loserSwitched ? GetHighestRatedUsedClass(loser) : GetStartingClass(loser);

#if DEBUG
    if (loserSwitched)
    {
        char lc[16];
        ClassToName(loserClass, lc, sizeof(lc));
        ClassElo_Log("compute", "loser switched -> debit highest-rated class=%s", lc);
    }
#endif

    if (winnerClass == TFClass_Unknown || loserClass == TFClass_Unknown)
    {
#if DEBUG
        ClassElo_Log("compute", "SKIP unknown class arena=%d", arena_index);
#endif
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

#if DEBUG
    int winnerBefore = winnerRating;
    int loserBefore = loserRating;
#endif

    g_iClassElo[winner][wIdx] += winnerDelta;
    g_iClassElo[loser][lIdx] -= loserDelta;
    g_iClassWins[winner][wIdx]++;
    g_iClassLosses[loser][lIdx]++;

    char wc[16];
    char lc[16];
    ClassToName(winnerClass, wc, sizeof(wc));
    ClassToName(loserClass, lc, sizeof(lc));

#if DEBUG
    char w[96];
    char l[96];
    ClassElo_DescribeClient(winner, w, sizeof(w));
    ClassElo_DescribeClient(loser, l, sizeof(l));
    ClassElo_Log("compute", "APPLIED arena=%d winner=%s class=%s %d+%d=%d (k=%d) | loser=%s class=%s %d-%d=%d (k=%d) expected=%.4f loser_switched=%d",
        arena_index,
        w, wc, winnerBefore, winnerDelta, g_iClassElo[winner][wIdx], kWin,
        l, lc, loserBefore, loserDelta, g_iClassElo[loser][lIdx], kLose,
        expected, loserSwitched);
#endif

    PersistClassElo(winner, winnerClass);
    PersistClassElo(loser, loserClass);

    if (g_bShowClassElo[winner])
        PrintToChat(winner, "[Class ELO] +%d %s (%d)", winnerDelta, wc, g_iClassElo[winner][wIdx]);

    if (g_bShowClassElo[loser])
        PrintToChat(loser, "[Class ELO] -%d %s (%d)", loserDelta, lc, g_iClassElo[loser][lIdx]);

    ClearDuelClasses(winner);
    ClearDuelClasses(loser);
#if DEBUG
    ClassElo_Log("compute", "Frame_ProcessClassElo DONE arena=%d", arena_index);
#endif
}

// ===== HUD =====

public void MGE_OnFormatHudLines(int arena_index, int client, bool is_spectator, MGEHudLineInfo redLine, MGEHudLineInfo bluLine)
{
    ApplyClassEloDisplay(redLine);
    ApplyClassEloDisplay(bluLine);
}

void ApplyClassEloDisplay(MGEHudLineInfo info)
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

#if DEBUG
    char who[96];
    ClassElo_DescribeClient(client, who, sizeof(who));
    ClassElo_Log("cmd", "sm_classelo %s show=%d", who, g_bShowClassElo[client]);
#endif
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

void ClassToName(TFClassType classType, char[] name, int maxlen)
{
    switch (classType)
    {
        case TFClass_Scout: strcopy(name, maxlen, "scout");
        case TFClass_Sniper: strcopy(name, maxlen, "sniper");
        case TFClass_Soldier: strcopy(name, maxlen, "soldier");
        case TFClass_DemoMan: strcopy(name, maxlen, "demoman");
        case TFClass_Medic: strcopy(name, maxlen, "medic");
        case TFClass_Heavy: strcopy(name, maxlen, "heavy");
        case TFClass_Pyro: strcopy(name, maxlen, "pyro");
        case TFClass_Spy: strcopy(name, maxlen, "spy");
        case TFClass_Engineer: strcopy(name, maxlen, "engineer");
        default: strcopy(name, maxlen, "unknown");
    }
}
