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

#define PLUGIN_VERSION "0.6"
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
bool g_bSQLReady;
bool g_bSQLConnecting;

// ===== RATING ENGINE (Elo default, Glicko-2 opt-in) =====

enum ClassRatingEngine
{
    CLASS_RATING_ENGINE_ELO = 0,
    CLASS_RATING_ENGINE_GLICKO2 = 1
}

ClassRatingEngine g_eClassRatingEngine;

ConVar g_cvRatingEngine;
ConVar g_cvGlickoTau;
ConVar g_cvGlickoPeriodDays;
ConVar g_cvGlickoProvisionalRd;

float g_fGlickoTau;
float g_fGlickoPeriodDays;
float g_fGlickoProvisionalRd;

#define CLASS_GLICKO2_SCALE               173.7178
#define CLASS_GLICKO2_MAX_RD              350.0
#define CLASS_GLICKO2_DEFAULT_VOLATILITY  0.06
#define CLASS_GLICKO2_CONVERGENCE_EPSILON 0.000001
#define CLASS_GLICKO2_E                   2.718281828459045
#define CLASS_GLICKO2_PI                  3.14159265358979323846

int g_iClassElo[MAXPLAYERS + 1][MAX_TF_CLASSES];
int g_iClassWins[MAXPLAYERS + 1][MAX_TF_CLASSES];
int g_iClassLosses[MAXPLAYERS + 1][MAX_TF_CLASSES];
bool g_bClassEloLoaded[MAXPLAYERS + 1];

// Glicko-2 rating engine state (only meaningful when mge_classelo_rating_engine is "glicko2")
bool g_bClassGlickoSeeded[MAXPLAYERS + 1][MAX_TF_CLASSES];
float g_fClassRD[MAXPLAYERS + 1][MAX_TF_CLASSES];
float g_fClassVolatility[MAXPLAYERS + 1][MAX_TF_CLASSES];
int g_iClassLastPlayed[MAXPLAYERS + 1][MAX_TF_CLASSES];

ArrayList g_alDuelClasses[MAXPLAYERS + 1];
bool g_bDuelTracking[MAXPLAYERS + 1];

bool g_bShowClassElo[MAXPLAYERS + 1];
Cookie g_hShowClassEloCookie;

bool g_bPendingClassElo[MAXARENAS + 1];
int g_iPendingWinner[MAXARENAS + 1];
int g_iPendingLoser[MAXARENAS + 1];

public void OnPluginStart()
{
    g_cvDBConfig = CreateConVar("mge_classelo_dbconfig", "mge_classelo", "Name of the databases.cfg entry used for class ELO storage. Must exist and be reachable; the plugin will not start without it.");

    g_cvRatingEngine = CreateConVar("mge_classelo_rating_engine", "elo", "Rating engine used to score per-class duels: \"elo\" (default) or \"glicko2\" (opt-in). Independent from MGEMod core's own mgemod_rating_engine.");
    g_cvGlickoTau = CreateConVar("mge_classelo_glicko_tau", "0.5", "Glicko-2 system constant controlling how fast per-class volatility reacts to surprising results. Only used when mge_classelo_rating_engine is \"glicko2\".", FCVAR_NONE, true, 0.2, true, 1.2);
    g_cvGlickoPeriodDays = CreateConVar("mge_classelo_glicko_period_days", "7.0", "Number of days considered one Glicko-2 rating period for per-class RD inflation due to inactivity. Higher than MGEMod core's default since a single class is played far less often than the game overall. Only used when mge_classelo_rating_engine is \"glicko2\".", FCVAR_NONE, true, 0.5);
    g_cvGlickoProvisionalRd = CreateConVar("mge_classelo_glicko_provisional_rd", "250.0", "RD threshold above which a per-class Glicko-2 rating is considered provisional. Only used when mge_classelo_rating_engine is \"glicko2\".", FCVAR_NONE, true, 50.0, true, 350.0);

    g_cvRatingEngine.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoTau.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoPeriodDays.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoProvisionalRd.AddChangeHook(OnRatingConVarChanged);
    ReadRatingConVars();

    g_hShowClassEloCookie = new Cookie("mge_classelo_show", "Show per-class ELO on MGE HUD", CookieAccess_Public);

    RegConsoleCmd("sm_classelo", Command_ToggleClassElo, "Toggle per-class ELO display on the MGE HUD");

    HookEvent("player_changeclass", Event_PlayerChangeClass, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    AddCommandListener(Listener_JoinClass, "joinclass");
    AddCommandListener(Listener_JoinClass, "join_class");

    for (int i = 0; i <= MaxClients; i++)
        ResetClientState(i);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && AreClientCookiesCached(i))
            OnClientCookiesCached(i);
    }
}

public void OnConfigsExecuted()
{
    ReadRatingConVars();

    if (g_bSQLReady || g_bSQLConnecting)
        return;

    PrepareSQL();
}

void ReadRatingConVars()
{
    char sRatingEngine[16];
    g_cvRatingEngine.GetString(sRatingEngine, sizeof(sRatingEngine));
    g_eClassRatingEngine = StrEqual(sRatingEngine, "glicko2", false) ? CLASS_RATING_ENGINE_GLICKO2 : CLASS_RATING_ENGINE_ELO;

    g_fGlickoTau = g_cvGlickoTau.FloatValue;
    g_fGlickoPeriodDays = g_cvGlickoPeriodDays.FloatValue;
    g_fGlickoProvisionalRd = g_cvGlickoProvisionalRd.FloatValue;
}

void OnRatingConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ReadRatingConVars();
}

public void OnPluginEnd()
{
    RemoveCommandListener(Listener_JoinClass, "joinclass");
    RemoveCommandListener(Listener_JoinClass, "join_class");
    for (int i = 0; i <= MaxClients; i++)
        ClearDuelClasses(i);

    delete g_DB;
    g_DB = null;
    g_bSQLReady = false;
    g_bSQLConnecting = false;
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
    {
        return;
    }

    char value[8];
    g_hShowClassEloCookie.Get(client, value, sizeof(value));
    g_bShowClassElo[client] = (value[0] == '\0' || value[0] == '1');
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
    {
        return;
    }

    LoadPlayerClassElo(client);
}

// ===== DATABASE =====

void PrepareSQL()
{
    char error[256];
    char dbConfig[64];
    g_cvDBConfig.GetString(dbConfig, sizeof(dbConfig));

    if (dbConfig[0] == '\0')
        SetFailState("[mge_classelo] mge_classelo_dbconfig is empty");

    if (!SQL_CheckConfig(dbConfig))
        SetFailState("[mge_classelo] databases.cfg has no '%s' entry", dbConfig);

    g_bSQLConnecting = true;
    g_DB = SQL_Connect(dbConfig, true, error, sizeof(error));
    if (g_DB == null)
        SetFailState("[mge_classelo] Could not connect to '%s': %s", dbConfig, error);

    char ident[16];
    g_DB.Driver.GetIdentifier(ident, sizeof(ident));

    char query[512];
    if (StrEqual(ident, "sqlite", false))
    {
        strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_stats (steamid TEXT NOT NULL, class INTEGER NOT NULL, rating INTEGER NOT NULL DEFAULT 1600, wins INTEGER NOT NULL DEFAULT 0, losses INTEGER NOT NULL DEFAULT 0, lastplayed INTEGER NOT NULL DEFAULT 0, rd REAL, volatility REAL, PRIMARY KEY (steamid, class))");
    }
    else if (StrEqual(ident, "mysql", false))
    {
        g_DB.SetCharset("utf8mb4");
        strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_stats (steamid VARCHAR(32) NOT NULL, class INT NOT NULL, rating INT NOT NULL DEFAULT 1600, wins INT NOT NULL DEFAULT 0, losses INT NOT NULL DEFAULT 0, lastplayed INT NOT NULL DEFAULT 0, rd FLOAT, volatility FLOAT, PRIMARY KEY (steamid, class))");
    }
    else if (StrEqual(ident, "pgsql", false))
    {
        strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_stats (steamid VARCHAR(32) NOT NULL, class INT NOT NULL, rating INT NOT NULL DEFAULT 1600, wins INT NOT NULL DEFAULT 0, losses INT NOT NULL DEFAULT 0, lastplayed INT NOT NULL DEFAULT 0, rd REAL, volatility REAL, PRIMARY KEY (steamid, class))");
    }
    else
    {
        SetFailState("[mge_classelo] Unsupported database type '%s' for config '%s'", ident, dbConfig);
    }

    g_DB.Query(SQL_OnCreateTable, query);
}

void SQL_OnCreateTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        SetFailState("[mge_classelo] Failed to create table: %s", error);

    g_bSQLReady = true;
    g_bSQLConnecting = false;
    LogMessage("[mge_classelo] Database ready");

    AddGlickoColumnsIfMissing();
    LoadConnectedPlayers();
}

void LoadConnectedPlayers()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && IsClientAuthorized(i))
            LoadPlayerClassElo(i);
    }
}

// Adds the rd/volatility columns for installs that created the table before Glicko-2 support
// existed. Tolerates "column already exists" errors from every supported driver, since this
// runs unconditionally on every plugin start.
void AddGlickoColumnsIfMissing()
{
    char ident[16];
    g_DB.Driver.GetIdentifier(ident, sizeof(ident));

    char rdQuery[256], volatilityQuery[256];
    if (StrEqual(ident, "mysql", false))
    {
        strcopy(rdQuery, sizeof(rdQuery), "ALTER TABLE mge_classelo_stats ADD COLUMN rd FLOAT DEFAULT NULL");
        strcopy(volatilityQuery, sizeof(volatilityQuery), "ALTER TABLE mge_classelo_stats ADD COLUMN volatility FLOAT DEFAULT NULL");
    }
    else
    {
        strcopy(rdQuery, sizeof(rdQuery), "ALTER TABLE mge_classelo_stats ADD COLUMN rd REAL DEFAULT NULL");
        strcopy(volatilityQuery, sizeof(volatilityQuery), "ALTER TABLE mge_classelo_stats ADD COLUMN volatility REAL DEFAULT NULL");
    }

    g_DB.Query(SQL_OnAddGlickoColumn, rdQuery);
    g_DB.Query(SQL_OnAddGlickoColumn, volatilityQuery);
}

void SQL_OnAddGlickoColumn(Database db, DBResultSet results, const char[] error, any data)
{
    if (results != null)
        return;

    if (StrContains(error, "duplicate column", false) != -1
        || StrContains(error, "already exists", false) != -1)
    {
        return;
    }

    LogError("[mge_classelo] Failed to add Glicko-2 column: %s", error);
}

void LoadPlayerClassElo(int client)
{
    if (g_DB == null || !IsValidClient(client) || IsFakeClient(client))
    {
        return;
    }

    char steamid[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
    {
        return;
    }

    for (int c = 1; c < MAX_TF_CLASSES; c++)
    {
        g_iClassElo[client][c] = DEFAULT_CLASS_ELO;
        g_iClassWins[client][c] = 0;
        g_iClassLosses[client][c] = 0;
        g_bClassGlickoSeeded[client][c] = false;
        g_fClassRD[client][c] = 0.0;
        g_fClassVolatility[client][c] = 0.0;
        g_iClassLastPlayed[client][c] = 0;
    }
    g_bClassEloLoaded[client] = false;

    char query[256];
    g_DB.Format(query, sizeof(query),
        "SELECT class, rating, wins, losses, rd, volatility, lastplayed FROM mge_classelo_stats WHERE steamid = '%s'",
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
    {
        return;
    }

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

        if (results.IsFieldNull(4))
        {
            g_bClassGlickoSeeded[client][classIdx] = false;
            g_fClassRD[client][classIdx] = 0.0;
            g_fClassVolatility[client][classIdx] = 0.0;
        }
        else
        {
            g_bClassGlickoSeeded[client][classIdx] = true;
            g_fClassRD[client][classIdx] = results.FetchFloat(4);
            g_fClassVolatility[client][classIdx] = results.FetchFloat(5);
        }
        g_iClassLastPlayed[client][classIdx] = results.FetchInt(6);
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

    // Under Glicko-2, rd/volatility are also persisted every duel. Under Elo they're left
    // untouched (stay NULL for players who never touched the glicko2 engine for this class).
    if (g_eClassRatingEngine == CLASS_RATING_ENGINE_GLICKO2)
    {
        float rd = g_fClassRD[client][classIdx];
        float volatility = g_fClassVolatility[client][classIdx];

        if (StrEqual(ident, "sqlite", false))
        {
            g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed, rd, volatility) VALUES ('%s', %d, %d, %d, %d, %d, %f, %f) ON CONFLICT(steamid, class) DO UPDATE SET rating = excluded.rating, wins = excluded.wins, losses = excluded.losses, lastplayed = excluded.lastplayed, rd = excluded.rd, volatility = excluded.volatility", steamid, classIdx, rating, wins, losses, timestamp, rd, volatility);
        }
        else if (StrEqual(ident, "pgsql", false))
        {
            g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed, rd, volatility) VALUES ('%s', %d, %d, %d, %d, %d, %f, %f) ON CONFLICT (steamid, class) DO UPDATE SET rating = EXCLUDED.rating, wins = EXCLUDED.wins, losses = EXCLUDED.losses, lastplayed = EXCLUDED.lastplayed, rd = EXCLUDED.rd, volatility = EXCLUDED.volatility", steamid, classIdx, rating, wins, losses, timestamp, rd, volatility);
        }
        else
        {
            g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed, rd, volatility) VALUES ('%s', %d, %d, %d, %d, %d, %f, %f) ON DUPLICATE KEY UPDATE rating = VALUES(rating), wins = VALUES(wins), losses = VALUES(losses), lastplayed = VALUES(lastplayed), rd = VALUES(rd), volatility = VALUES(volatility)", steamid, classIdx, rating, wins, losses, timestamp, rd, volatility);
        }
    }
    else if (StrEqual(ident, "sqlite", false))
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
    {
        return;
    }

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
    int score1 = MGE_GetArenaScore(arena_index, SLOT_ONE);
    int score2 = MGE_GetArenaScore(arena_index, SLOT_TWO);
    bool scoreStarted = (score1 != 0 || score2 != 0);

    if (!scoreStarted)
    {
        if (g_alDuelClasses[client].Length == 0)
            g_alDuelClasses[client].Push(newIdx);
        else if (g_alDuelClasses[client].Get(0) != newIdx)
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

    RecordClassChange(client, view_as<TFClassType>(event.GetInt("class")));
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || IsFakeClient(client) || !g_bDuelTracking[client])
        return;

    TFClassType cls = TF2_GetPlayerClass(client);
    RecordClassChange(client, cls);
}

Action Listener_JoinClass(int client, const char[] command, int argc)
{
    if (client <= 0 || !IsValidClient(client) || IsFakeClient(client))
        return Plugin_Continue;

    char classArg[32];
    if (argc >= 1)
        GetCmdArg(1, classArg, sizeof(classArg));
    else
        classArg[0] = '\0';

    if (!g_bDuelTracking[client])
        return Plugin_Continue;

    TFClassType requested = TF2_GetClass(classArg);
    int arena_index = MGE_GetPlayerArena(client);
    bool scoreStarted = (arena_index > 0
        && (MGE_GetArenaScore(arena_index, SLOT_ONE) != 0 || MGE_GetArenaScore(arena_index, SLOT_TWO) != 0));

    if (requested != TFClass_Unknown && !scoreStarted)
        RecordClassChange(client, requested);

    RequestFrame(Frame_RecordLiveClass, GetClientUserId(client));
    return Plugin_Continue;
}

void Frame_RecordLiveClass(int userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    RecordClassChange(client, TF2_GetPlayerClass(client));
}

public void MGE_On1v1MatchStart(int arena_index, int player1, int player2)
{
    BeginDuelClassTracking(player1);
    BeginDuelClassTracking(player2);
}

// ===== RATING ENGINE DISPATCHER (Elo default, Glicko-2 opt-in) =====
//
// Independent from MGEMod core's own rating engine dispatcher. Same design principle
// (switch-on-enum, Elo default with zero behavior change) but its own implementation,
// its own convars, and its own calibration - per-class match volume is much lower than
// the global mode, so inactivity decay and the "provisional" threshold need looser
// defaults (see mge_classelo_glicko_period_days / mge_classelo_glicko_provisional_rd).

// Single entry point Frame_ProcessClassElo calls to apply a finished duel's result to
// both players' per-class ratings. Callers never know which engine actually computed
// the new numbers.
void ClassRating_ReportResult(int winner, TFClassType winnerClass, int loser, TFClassType loserClass)
{
    switch (g_eClassRatingEngine)
    {
        case CLASS_RATING_ENGINE_GLICKO2:
            ClassEngine_Glicko2_OnMatchResult(winner, winnerClass, loser, loserClass);
        default:
            ClassEngine_Elo_OnMatchResult(winner, winnerClass, loser, loserClass);
    }
}

// Returns the number to show/print for a player's class rating, regardless of active engine.
// Always the stored rating. Glicko-2 uncertainty is the HUD "?" via ClassRating_IsProvisional,
// not a subtracted display value. Same rule as MGEMod's Rating_GetDisplayValue.
int ClassRating_GetDisplayValue(int client, TFClassType classType)
{
    return g_iClassElo[client][view_as<int>(classType)];
}

// Whether this player's per-class rating is still provisional (not enough duels in this
// specific class, or too much inactivity, to trust it). Always false under Elo.
bool ClassRating_IsProvisional(int client, TFClassType classType)
{
    int classIdx = view_as<int>(classType);
    if (g_eClassRatingEngine != CLASS_RATING_ENGINE_GLICKO2)
        return false;

    if (!g_bClassGlickoSeeded[client][classIdx])
        return true;

    return g_fClassRD[client][classIdx] > g_fGlickoProvisionalRd;
}

// ===== ELO ENGINE =====
//
// Identical math to what Frame_ProcessClassElo used to compute inline. Zero behavior
// change for servers that never touch mge_classelo_rating_engine.
void ClassEngine_Elo_OnMatchResult(int winner, TFClassType winnerClass, int loser, TFClassType loserClass)
{
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

}

// ===== GLICKO-2 ENGINE =====
//
// Opt-in (mge_classelo_rating_engine "glicko2"). Own implementation of Glickman's published
// algorithm (http://www.glicko.net/glicko/glicko2.pdf), independent from MGEMod core's copy -
// same public formulas, no shared code, own calibration convars. No 2v2 handling: this
// plugin has never tracked 2v2 class ratings.

// Seeds a class rating's RD/volatility on first contact with the Glicko-2 engine. The
// rating itself is left untouched (whatever Elo value it already had, or the 1600 default).
void ClassGlicko2_EnsureSeeded(int client, int classIdx)
{
    if (g_bClassGlickoSeeded[client][classIdx])
        return;

    g_fClassRD[client][classIdx] = CLASS_GLICKO2_MAX_RD;
    g_fClassVolatility[client][classIdx] = CLASS_GLICKO2_DEFAULT_VOLATILITY;
    g_bClassGlickoSeeded[client][classIdx] = true;
}

// Inflates a class RD to reflect uncertainty accumulated while that specific class wasn't
// played, following Glickman's step 1 (applied once per full rating period skipped).
void ClassGlicko2_ApplyInactivityDecay(int client, int classIdx, int now)
{
    if (g_iClassLastPlayed[client][classIdx] <= 0 || g_fGlickoPeriodDays <= 0.0)
        return;

    float periodSeconds = g_fGlickoPeriodDays * 86400.0;
    int elapsedPeriods = RoundToFloor(float(now - g_iClassLastPlayed[client][classIdx]) / periodSeconds);
    if (elapsedPeriods <= 0)
        return;

    float phi = g_fClassRD[client][classIdx] / CLASS_GLICKO2_SCALE;
    float sigma = g_fClassVolatility[client][classIdx];
    float inflatedPhi = SquareRoot((phi * phi) + (float(elapsedPeriods) * sigma * sigma));

    float maxPhi = CLASS_GLICKO2_MAX_RD / CLASS_GLICKO2_SCALE;
    if (inflatedPhi > maxPhi)
        inflatedPhi = maxPhi;

    g_fClassRD[client][classIdx] = inflatedPhi * CLASS_GLICKO2_SCALE;
}

// g(phi): discounts an opponent's rating impact by their own uncertainty.
float ClassGlicko2_G(float phi)
{
    return 1.0 / SquareRoot(1.0 + ((3.0 * phi * phi) / (CLASS_GLICKO2_PI * CLASS_GLICKO2_PI)));
}

// E(mu, mu_j, phi_j): expected score against an opponent.
float ClassGlicko2_E(float mu, float otherMu, float otherPhi)
{
    return 1.0 / (1.0 + Pow(CLASS_GLICKO2_E, -ClassGlicko2_G(otherPhi) * (mu - otherMu)));
}

// f(x): the function whose root is the new volatility (in ln(variance) space), solved
// below via the Illinois algorithm, per Glickman's step 5.
float ClassGlicko2_F(float delta, float phi, float v, float x, float a, float tau)
{
    float ex = Pow(CLASS_GLICKO2_E, x);
    float num = ex * ((delta * delta) - (phi * phi) - v - ex);
    float den = 2.0 * Pow((phi * phi) + v + ex, 2.0);
    return (num / den) - ((x - a) / (tau * tau));
}

// Pure Glicko-2 update for a single class-rating against a single opponent's class-rating
// in one rating period. Operates entirely on the Elo-like display scale (rating ~1600,
// rd in points). Does not read or write any global state.
void ClassGlicko2_ComputeUpdate(float rating, float rd, float volatility, float oppRating, float oppRd, float score,
    float &newRating, float &newRd, float &newVolatility)
{
    float mu = (rating - 1500.0) / CLASS_GLICKO2_SCALE;
    float phi = rd / CLASS_GLICKO2_SCALE;
    float sigma = volatility;

    float oppMu = (oppRating - 1500.0) / CLASS_GLICKO2_SCALE;
    float oppPhi = oppRd / CLASS_GLICKO2_SCALE;

    float g = ClassGlicko2_G(oppPhi);
    float e = ClassGlicko2_E(mu, oppMu, oppPhi);
    float v = 1.0 / (g * g * e * (1.0 - e));
    float delta = v * g * (score - e);

    float a = Logarithm(sigma * sigma, CLASS_GLICKO2_E);
    float tau = g_fGlickoTau;

    float A = a;
    float B;
    if ((delta * delta) > (phi * phi) + v)
    {
        B = Logarithm((delta * delta) - (phi * phi) - v, CLASS_GLICKO2_E);
    }
    else
    {
        int k = 1;
        B = a - (float(k) * tau);
        while (ClassGlicko2_F(delta, phi, v, B, a, tau) < 0.0)
        {
            k++;
            B = a - (float(k) * tau);
        }
    }

    float fA = ClassGlicko2_F(delta, phi, v, A, a, tau);
    float fB = ClassGlicko2_F(delta, phi, v, B, a, tau);

    int iterations = 0;
    while (FloatAbs(B - A) > CLASS_GLICKO2_CONVERGENCE_EPSILON && iterations < 100)
    {
        float C = A + (((A - B) * fA) / (fB - fA));
        float fC = ClassGlicko2_F(delta, phi, v, C, a, tau);

        if ((fC * fB) < 0.0)
        {
            A = B;
            fA = fB;
        }
        else
        {
            fA = fA / 2.0;
        }

        B = C;
        fB = fC;
        iterations++;
    }

    float newSigma = Pow(CLASS_GLICKO2_E, A / 2.0);
    float phiStar = SquareRoot((phi * phi) + (newSigma * newSigma));
    float newPhi = 1.0 / SquareRoot((1.0 / (phiStar * phiStar)) + (1.0 / v));
    float newMu = mu + ((newPhi * newPhi) * g * (score - e));

    newRating = (newMu * CLASS_GLICKO2_SCALE) + 1500.0;
    float newRdRaw = newPhi * CLASS_GLICKO2_SCALE;
    newRd = (newRdRaw > CLASS_GLICKO2_MAX_RD) ? CLASS_GLICKO2_MAX_RD : newRdRaw;
    newVolatility = newSigma;
}

// Calculates Glicko-2 class ratings for a finished 1v1 duel and updates in-memory state.
// Persistence and chat messages stay in Frame_ProcessClassElo, same as the Elo engine.
void ClassEngine_Glicko2_OnMatchResult(int winner, TFClassType winnerClass, int loser, TFClassType loserClass)
{
    int wIdx = view_as<int>(winnerClass);
    int lIdx = view_as<int>(loserClass);
    int now = GetTime();

    ClassGlicko2_EnsureSeeded(winner, wIdx);
    ClassGlicko2_EnsureSeeded(loser, lIdx);
    ClassGlicko2_ApplyInactivityDecay(winner, wIdx, now);
    ClassGlicko2_ApplyInactivityDecay(loser, lIdx, now);

    int winnerPreviousRating = g_iClassElo[winner][wIdx];
    int loserPreviousRating = g_iClassElo[loser][lIdx];
    float winnerPreviousRd = g_fClassRD[winner][wIdx];
    float loserPreviousRd = g_fClassRD[loser][lIdx];

    float newWinnerRating, newWinnerRd, newWinnerVolatility;
    float newLoserRating, newLoserRd, newLoserVolatility;

    ClassGlicko2_ComputeUpdate(float(winnerPreviousRating), winnerPreviousRd, g_fClassVolatility[winner][wIdx],
        float(loserPreviousRating), loserPreviousRd, 1.0, newWinnerRating, newWinnerRd, newWinnerVolatility);
    ClassGlicko2_ComputeUpdate(float(loserPreviousRating), loserPreviousRd, g_fClassVolatility[loser][lIdx],
        float(winnerPreviousRating), winnerPreviousRd, 0.0, newLoserRating, newLoserRd, newLoserVolatility);

    g_iClassElo[winner][wIdx] = RoundFloat(newWinnerRating);
    g_fClassRD[winner][wIdx] = newWinnerRd;
    g_fClassVolatility[winner][wIdx] = newWinnerVolatility;
    g_iClassLastPlayed[winner][wIdx] = now;

    g_iClassElo[loser][lIdx] = RoundFloat(newLoserRating);
    g_fClassRD[loser][lIdx] = newLoserRd;
    g_fClassVolatility[loser][lIdx] = newLoserVolatility;
    g_iClassLastPlayed[loser][lIdx] = now;

    g_iClassWins[winner][wIdx]++;
    g_iClassLosses[loser][lIdx]++;

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

    // MGE CalcELO fires winner then loser; pair roles by that call order.

    if (!g_bPendingClassElo[arena_index])
    {
        g_bPendingClassElo[arena_index] = true;
        g_iPendingWinner[arena_index] = client;
        g_iPendingLoser[arena_index] = 0;

        RequestFrame(Frame_ProcessClassElo, arena_index);
    }
    else if (client != g_iPendingWinner[arena_index])
    {
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

    if (g_DB == null)
    {
        if (IsValidClient(winner))
            ClearDuelClasses(winner);
        if (IsValidClient(loser))
            ClearDuelClasses(loser);
        return;
    }

    if (!IsValidClient(winner) || !IsValidClient(loser))
    {
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
        ClearDuelClasses(winner);
        ClearDuelClasses(loser);
        return;
    }

    bool winnerSwitched = DidPlayerSwitchClass(winner);
    bool loserSwitched = DidPlayerSwitchClass(loser);


    if (winnerSwitched)
    {
        ClearDuelClasses(winner);
        ClearDuelClasses(loser);
        return;
    }

    TFClassType winnerClass = GetStartingClass(winner);
    TFClassType loserClass = loserSwitched ? GetHighestRatedUsedClass(loser) : GetStartingClass(loser);


    if (winnerClass == TFClass_Unknown || loserClass == TFClass_Unknown)
    {
        ClearDuelClasses(winner);
        ClearDuelClasses(loser);
        return;
    }

    char wc[16];
    char lc[16];
    ClassToName(winnerClass, wc, sizeof(wc));
    ClassToName(loserClass, lc, sizeof(lc));

    int winnerDisplayBefore = ClassRating_GetDisplayValue(winner, winnerClass);
    int loserDisplayBefore = ClassRating_GetDisplayValue(loser, loserClass);

    ClassRating_ReportResult(winner, winnerClass, loser, loserClass);

    int winnerDisplayAfter = ClassRating_GetDisplayValue(winner, winnerClass);
    int loserDisplayAfter = ClassRating_GetDisplayValue(loser, loserClass);
    int winnerDelta = winnerDisplayAfter - winnerDisplayBefore;
    int loserDelta = loserDisplayBefore - loserDisplayAfter;


    PersistClassElo(winner, winnerClass);
    PersistClassElo(loser, loserClass);

    if (g_bShowClassElo[winner])
        PrintToChat(winner, "[Class ELO] +%d %s (%d)", winnerDelta, wc, winnerDisplayAfter);

    if (g_bShowClassElo[loser])
        PrintToChat(loser, "[Class ELO] -%d %s (%d)", loserDelta, lc, loserDisplayAfter);

    ClearDuelClasses(winner);
    ClearDuelClasses(loser);
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

    bool scoreStarted = (MGE_GetArenaScore(info.arena_index, SLOT_ONE) != 0
        || MGE_GetArenaScore(info.arena_index, SLOT_TWO) != 0);

    TFClassType cls;
    if (!scoreStarted)
        cls = TF2_GetPlayerClass(player);
    else if (g_bDuelTracking[player] && g_alDuelClasses[player] != null && g_alDuelClasses[player].Length > 0)
        cls = GetStartingClass(player);
    else
        cls = TF2_GetPlayerClass(player);

    if (cls == TFClass_Unknown)
        return;

    int rating = ClassRating_GetDisplayValue(player, cls);
    char globalEloText[16];
    strcopy(globalEloText, sizeof(globalEloText), info.extraDisplay);

    if (ClassRating_IsProvisional(player, cls))
        Format(info.extraDisplay, sizeof(info.extraDisplay), "%s/%d?", globalEloText, rating);
    else
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
        g_bClassGlickoSeeded[client][c] = false;
        g_fClassRD[client][c] = 0.0;
        g_fClassVolatility[client][c] = 0.0;
        g_iClassLastPlayed[client][c] = 0;
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
