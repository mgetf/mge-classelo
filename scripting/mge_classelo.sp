#pragma semicolon 1
#pragma newdecls required

#if defined (MAXPLAYERS)
    #undef MAXPLAYERS
    #define MAXPLAYERS 101
#endif

#include <sourcemod>
#include <tf2_stocks>
#include <morecolors>
#include <clientprefs>
#include <mge>

#define PLUGIN_VERSION "0.7"
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
ConVar g_cvGlickoPeriodHours;
ConVar g_cvGlickoPeriodHour;
ConVar g_cvGlickoPeriodMinute;
ConVar g_cvGlickoPeriodUtcOffset;

float g_fGlickoTau;
float g_fGlickoPeriodDays;
float g_fGlickoProvisionalRd;
int g_iGlickoPeriodHours;
int g_iGlickoPeriodHour;
int g_iGlickoPeriodMinute;
int g_iGlickoPeriodUtcOffset;
char g_sClassEloDriver[16];
bool g_bClassPeriodSchemaReady;
bool g_bClassPeriodCloseRunning;
bool g_bClassPeriodLockHeld;
bool g_bClassPeriodRecomputeOnly;
Handle g_hClassPeriodTimer;
int g_iClassLastSealedPeriodId;
int g_iClassPeriodCloseTarget;
int g_iClassPeriodLeftoverPasses;
int g_iClassPeriodUpdateIndex;
int g_iClassPeriodSchemaStep;
StringMap g_hClassPeriodGameMap;
StringMap g_hClassPeriodStartMap;
ArrayList g_hClassPeriodPlayers;
ArrayList g_hClassPeriodUpdateQueue;

#define CLASS_GLICKO2_MAX_PERIOD_GAMES 256
#define CLASS_PERIOD_LOCK_NAME "mge_classelo_period_close"
#define CLASS_PERIOD_UPDATE_CHUNK 40
#define CLASS_PERIOD_LEFTOVER_MAX 3

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
bool g_bClassPeriodDirty[MAXPLAYERS + 1][MAX_TF_CLASSES];
float g_fClassRD[MAXPLAYERS + 1][MAX_TF_CLASSES];
float g_fClassVolatility[MAXPLAYERS + 1][MAX_TF_CLASSES];
float g_fClassRDEst[MAXPLAYERS + 1][MAX_TF_CLASSES];
int g_iClassLastPlayed[MAXPLAYERS + 1][MAX_TF_CLASSES];
int g_iClassEloEst[MAXPLAYERS + 1][MAX_TF_CLASSES];

ArrayList g_alDuelClasses[MAXPLAYERS + 1];
bool g_bDuelTracking[MAXPLAYERS + 1];

bool g_bShowClassElo[MAXPLAYERS + 1];
Cookie g_hShowClassEloCookie;

public void OnPluginStart()
{
    g_cvDBConfig = CreateConVar("mge_classelo_dbconfig", "mge_classelo", "Name of the databases.cfg entry used for class ELO storage. Must exist and be reachable; the plugin will not start without it.");

    g_cvRatingEngine = CreateConVar("mge_classelo_rating_engine", "elo", "Rating engine used to score per-class duels: \"elo\" (default) or \"glicko2\" (opt-in). Independent from MGEMod core's own mgemod_rating_engine.");
    g_cvGlickoTau = CreateConVar("mge_classelo_glicko_tau", "0.5", "Glicko-2 system constant controlling how fast per-class volatility reacts to surprising results. Only used when mge_classelo_rating_engine is \"glicko2\".", FCVAR_NONE, true, 0.2, true, 1.2);
    g_cvGlickoPeriodDays = CreateConVar("mge_classelo_glicko_period_days", "7.0", "Number of days considered one Glicko-2 rating period for per-class RD inflation due to inactivity. Higher than MGEMod core's default since a single class is played far less often than the game overall. Only used when mge_classelo_rating_engine is \"glicko2\".", FCVAR_NONE, true, 0.5);
    g_cvGlickoProvisionalRd = CreateConVar("mge_classelo_glicko_provisional_rd", "250.0", "RD threshold above which a per-class Glicko-2 rating is considered provisional. Only used when mge_classelo_rating_engine is \"glicko2\".", FCVAR_NONE, true, 50.0, true, 350.0);
    g_cvGlickoPeriodHours = CreateConVar("mge_classelo_glicko_period_hours", "24", "Length of one per-class Glicko-2 rating period in hours (1-168).", FCVAR_NONE, true, 1.0, true, 168.0);
    g_cvGlickoPeriodHour = CreateConVar("mge_classelo_glicko_period_hour", "8", "Local hour (0-23) of the class Glicko-2 period boundary. Match MGEMod.", FCVAR_NONE, true, 0.0, true, 23.0);
    g_cvGlickoPeriodMinute = CreateConVar("mge_classelo_glicko_period_minute", "20", "Local minute (0-59) of the class Glicko-2 period boundary. Match MGEMod.", FCVAR_NONE, true, 0.0, true, 59.0);
    g_cvGlickoPeriodUtcOffset = CreateConVar("mge_classelo_glicko_period_utc_offset", "-3", "Hours added to UTC to get local time for the class period boundary (ART is -3).");

    g_cvRatingEngine.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoTau.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoPeriodDays.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoProvisionalRd.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoPeriodHours.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoPeriodHour.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoPeriodMinute.AddChangeHook(OnRatingConVarChanged);
    g_cvGlickoPeriodUtcOffset.AddChangeHook(OnRatingConVarChanged);
    ReadRatingConVars();

    LoadTranslations("mge_classelo.phrases");

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
    g_iGlickoPeriodHours = g_cvGlickoPeriodHours.IntValue;
    g_iGlickoPeriodHour = g_cvGlickoPeriodHour.IntValue;
    g_iGlickoPeriodMinute = g_cvGlickoPeriodMinute.IntValue;
    g_iGlickoPeriodUtcOffset = g_cvGlickoPeriodUtcOffset.IntValue;
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

    delete g_hClassPeriodTimer;
    g_hClassPeriodTimer = null;
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
        SetFailState("mge_classelo_dbconfig is empty");

    if (!SQL_CheckConfig(dbConfig))
        SetFailState("databases.cfg has no '%s' entry", dbConfig);

    g_bSQLConnecting = true;
    g_DB = SQL_Connect(dbConfig, true, error, sizeof(error));
    if (g_DB == null)
        SetFailState("Could not connect to '%s': %s", dbConfig, error);

    char ident[16];
    g_DB.Driver.GetIdentifier(ident, sizeof(ident));
    strcopy(g_sClassEloDriver, sizeof(g_sClassEloDriver), ident);

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
        SetFailState("Unsupported database type '%s' for config '%s'", ident, dbConfig);
    }

    g_DB.Query(SQL_OnCreateTable, query);
}

void SQL_OnCreateTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        SetFailState("Failed to create table: %s", error);

    g_bSQLReady = true;
    g_bSQLConnecting = false;
    LogMessage("Database ready");

    AddGlickoColumnsIfMissing();
    ClassPeriod_EnsureSchema();
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

    LogError("Failed to add Glicko-2 column: %s", error);
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
        g_iClassEloEst[client][c] = DEFAULT_CLASS_ELO;
        g_fClassRDEst[client][c] = 0.0;
        g_bClassPeriodDirty[client][c] = false;
    }
    g_bClassEloLoaded[client] = false;

    char query[384];
    if (g_bClassPeriodSchemaReady)
    {
        g_DB.Format(query, sizeof(query),
            "SELECT class, rating, wins, losses, rd, volatility, lastplayed, rating_est, rd_est, period_dirty FROM mge_classelo_stats WHERE steamid = '%s'",
            steamid);
    }
    else
    {
        g_DB.Format(query, sizeof(query),
            "SELECT class, rating, wins, losses, rd, volatility, lastplayed FROM mge_classelo_stats WHERE steamid = '%s'",
            steamid);
    }


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
        LogError("Failed to load class ELO for %N: %s", client, error);
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
        g_iClassEloEst[client][classIdx] = g_iClassElo[client][classIdx];
        g_fClassRDEst[client][classIdx] = g_fClassRD[client][classIdx];
        g_bClassPeriodDirty[client][classIdx] = false;
        if (results.FieldCount > 7)
        {
            if (!results.IsFieldNull(7))
                g_iClassEloEst[client][classIdx] = results.FetchInt(7);
            if (!results.IsFieldNull(8))
                g_fClassRDEst[client][classIdx] = results.FetchFloat(8);
            g_bClassPeriodDirty[client][classIdx] = (results.FetchInt(9) != 0);
        }
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

    char query[1024];

    // Under Glicko-2, rd/volatility are also persisted every duel. Under Elo they're left
    // untouched (stay NULL for players who never touched the glicko2 engine for this class).
    if (g_eClassRatingEngine == CLASS_RATING_ENGINE_GLICKO2)
    {
        float rd = g_fClassRD[client][classIdx];
        float volatility = g_fClassVolatility[client][classIdx];
        int ratingEst = g_iClassEloEst[client][classIdx];
        float rdEst = g_fClassRDEst[client][classIdx];
        int dirty = g_bClassPeriodDirty[client][classIdx] ? 1 : 0;

        if (g_bClassPeriodSchemaReady)
        {
            if (StrEqual(ident, "sqlite", false))
            {
                g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed, rd, volatility, rating_est, rd_est, period_dirty) VALUES ('%s', %d, %d, %d, %d, %d, %f, %f, %d, %f, %d) ON CONFLICT(steamid, class) DO UPDATE SET rating = excluded.rating, wins = excluded.wins, losses = excluded.losses, lastplayed = excluded.lastplayed, rd = excluded.rd, volatility = excluded.volatility, rating_est = excluded.rating_est, rd_est = excluded.rd_est, period_dirty = excluded.period_dirty", steamid, classIdx, rating, wins, losses, timestamp, rd, volatility, ratingEst, rdEst, dirty);
            }
            else if (StrEqual(ident, "pgsql", false))
            {
                g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed, rd, volatility, rating_est, rd_est, period_dirty) VALUES ('%s', %d, %d, %d, %d, %d, %f, %f, %d, %f, %d) ON CONFLICT (steamid, class) DO UPDATE SET rating = EXCLUDED.rating, wins = EXCLUDED.wins, losses = EXCLUDED.losses, lastplayed = EXCLUDED.lastplayed, rd = EXCLUDED.rd, volatility = EXCLUDED.volatility, rating_est = EXCLUDED.rating_est, rd_est = EXCLUDED.rd_est, period_dirty = EXCLUDED.period_dirty", steamid, classIdx, rating, wins, losses, timestamp, rd, volatility, ratingEst, rdEst, dirty);
            }
            else
            {
                g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_stats (steamid, class, rating, wins, losses, lastplayed, rd, volatility, rating_est, rd_est, period_dirty) VALUES ('%s', %d, %d, %d, %d, %d, %f, %f, %d, %f, %d) ON DUPLICATE KEY UPDATE rating = VALUES(rating), wins = VALUES(wins), losses = VALUES(losses), lastplayed = VALUES(lastplayed), rd = VALUES(rd), volatility = VALUES(volatility), rating_est = VALUES(rating_est), rd_est = VALUES(rd_est), period_dirty = VALUES(period_dirty)", steamid, classIdx, rating, wins, losses, timestamp, rd, volatility, ratingEst, rdEst, dirty);
            }
        }
        else if (StrEqual(ident, "sqlite", false))
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
        LogError("Query failed: %s", error);
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

// Single entry point ProcessClassEloMatch calls to apply a finished duel's result to
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

int ClassRating_GetHudDisplayValue(int client, TFClassType classType)
{
    int classIdx = view_as<int>(classType);
    if (g_eClassRatingEngine == CLASS_RATING_ENGINE_GLICKO2 && g_bClassPeriodSchemaReady && g_bClassPeriodDirty[client][classIdx])
        return g_iClassEloEst[client][classIdx];
    return g_iClassElo[client][classIdx];
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
// Identical math to what ProcessClassEloMatch used to compute inline. Zero behavior
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
void ClassGlicko2_InflateRdOnePeriod(float rd, float volatility, float &newRd)
{
    float phi = rd / CLASS_GLICKO2_SCALE;
    float inflatedPhi = SquareRoot((phi * phi) + (volatility * volatility));
    float maxPhi = CLASS_GLICKO2_MAX_RD / CLASS_GLICKO2_SCALE;
    if (inflatedPhi > maxPhi)
        inflatedPhi = maxPhi;
    newRd = inflatedPhi * CLASS_GLICKO2_SCALE;
}

void ClassGlicko2_ComputePeriodUpdate(float rating, float rd, float volatility, int gameCount,
    const float[] oppRating, const float[] oppRd, const float[] score,
    float &newRating, float &newRd, float &newVolatility)
{
    if (gameCount <= 0)
    {
        newRating = rating;
        newRd = rd;
        newVolatility = volatility;
        return;
    }

    float mu = (rating - 1500.0) / CLASS_GLICKO2_SCALE;
    float phi = rd / CLASS_GLICKO2_SCALE;
    float sigma = volatility;
    float vInv = 0.0;
    float deltaSum = 0.0;

    for (int i = 0; i < gameCount; i++)
    {
        float oppMu = (oppRating[i] - 1500.0) / CLASS_GLICKO2_SCALE;
        float oppPhi = oppRd[i] / CLASS_GLICKO2_SCALE;
        float g = ClassGlicko2_G(oppPhi);
        float e = ClassGlicko2_E(mu, oppMu, oppPhi);
        if (e < 0.0001)
            e = 0.0001;
        else if (e > 0.9999)
            e = 0.9999;
        vInv += g * g * e * (1.0 - e);
        deltaSum += g * (score[i] - e);
    }

    if (vInv <= 0.0)
    {
        newRating = rating;
        ClassGlicko2_InflateRdOnePeriod(rd, volatility, newRd);
        newVolatility = volatility;
        return;
    }

    float v = 1.0 / vInv;
    float delta = v * deltaSum;
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
    float newMu = mu + ((newPhi * newPhi) * deltaSum);
    newRating = (newMu * CLASS_GLICKO2_SCALE) + 1500.0;
    float newRdRaw = newPhi * CLASS_GLICKO2_SCALE;
    newRd = (newRdRaw > CLASS_GLICKO2_MAX_RD) ? CLASS_GLICKO2_MAX_RD : newRdRaw;
    newVolatility = newSigma;
}

void ClassGlicko2_ComputeUpdate(float rating, float rd, float volatility, float oppRating, float oppRd, float score,
    float &newRating, float &newRd, float &newVolatility)
{
    float oppRatings[1], oppRds[1], scores[1];
    oppRatings[0] = oppRating;
    oppRds[0] = oppRd;
    scores[0] = score;
    ClassGlicko2_ComputePeriodUpdate(rating, rd, volatility, 1, oppRatings, oppRds, scores, newRating, newRd, newVolatility);
}

// Calculates Glicko-2 class ratings for a finished 1v1 duel and updates in-memory state.
// Persistence and chat messages stay in ProcessClassEloMatch, same as the Elo engine.
void ClassEngine_Glicko2_OnMatchResult(int winner, TFClassType winnerClass, int loser, TFClassType loserClass)
{
    if (!g_bClassPeriodSchemaReady)
    {
        ClassEngine_Glicko2_OnMatchResultLegacy(winner, winnerClass, loser, loserClass);
        return;
    }

    int wIdx = view_as<int>(winnerClass);
    int lIdx = view_as<int>(loserClass);
    int now = GetTime();

    ClassGlicko2_EnsureSeeded(winner, wIdx);
    ClassGlicko2_EnsureSeeded(loser, lIdx);

    g_iClassLastPlayed[winner][wIdx] = now;
    g_iClassLastPlayed[loser][lIdx] = now;
    g_iClassWins[winner][wIdx]++;
    g_iClassLosses[loser][lIdx]++;

    ClassPeriod_InsertDuel(winner, wIdx, loser, lIdx, now);
}

void ClassEngine_Glicko2_OnMatchResultLegacy(int winner, TFClassType winnerClass, int loser, TFClassType loserClass)
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

public void MGE_On1v1MatchEnd(int arena_index, int winner, int loser, int winner_score, int loser_score)
{
    #pragma unused winner_score, loser_score
    ProcessClassEloMatch(arena_index, winner, loser);
}

void ProcessClassEloMatch(int arena_index, int winner, int loser)
{
    if (arena_index < 1 || arena_index > MAXARENAS)
        return;

    if (MGE_ArenaHasGameMode(arena_index, MGE_GAMEMODE_4PLAYER))
        return;

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

    bool periodHud = (g_eClassRatingEngine == CLASS_RATING_ENGINE_GLICKO2 && g_bClassPeriodSchemaReady);
    int winnerDisplayBefore = 0;
    int loserDisplayBefore = 0;
    if (!periodHud)
    {
        winnerDisplayBefore = ClassRating_GetDisplayValue(winner, winnerClass);
        loserDisplayBefore = ClassRating_GetDisplayValue(loser, loserClass);
    }

    ClassRating_ReportResult(winner, winnerClass, loser, loserClass);

    PersistClassElo(winner, winnerClass);
    PersistClassElo(loser, loserClass);

    if (periodHud)
    {
        ClassPeriod_RefreshEstimate(winner, view_as<int>(winnerClass));
        ClassPeriod_RefreshEstimate(loser, view_as<int>(loserClass));
    }
    else
    {
        char wc[16];
        char lc[16];
        ClassToName(winnerClass, wc, sizeof(wc));
        ClassToName(loserClass, lc, sizeof(lc));

        int winnerDisplayAfter = ClassRating_GetDisplayValue(winner, winnerClass);
        int loserDisplayAfter = ClassRating_GetDisplayValue(loser, loserClass);
        int winnerDelta = winnerDisplayAfter - winnerDisplayBefore;
        int loserDelta = loserDisplayBefore - loserDisplayAfter;

        if (g_bShowClassElo[winner])
            MC_PrintToChat(winner, "%t", "GainedClassPoints", winnerDelta, wc, winnerDisplayAfter);

        if (g_bShowClassElo[loser])
            MC_PrintToChat(loser, "%t", "LostClassPoints", loserDelta, lc, loserDisplayAfter);
    }

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

    int rating = ClassRating_GetHudDisplayValue(player, cls);
    char globalEloText[16];
    strcopy(globalEloText, sizeof(globalEloText), info.extraDisplay);

    bool dirty = (g_eClassRatingEngine == CLASS_RATING_ENGINE_GLICKO2 && g_bClassPeriodDirty[player][view_as<int>(cls)]);
    char classText[16];
    if (dirty)
        Format(classText, sizeof(classText), "~%d", rating);
    else
        Format(classText, sizeof(classText), "%d", rating);

    if (ClassRating_IsProvisional(player, cls))
        Format(info.extraDisplay, sizeof(info.extraDisplay), "%s/%s?", globalEloText, classText);
    else
        Format(info.extraDisplay, sizeof(info.extraDisplay), "%s/%s", globalEloText, classText);
}

// ===== COMMANDS =====

Action Command_ToggleClassElo(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    g_bShowClassElo[client] = !g_bShowClassElo[client];
    g_hShowClassEloCookie.Set(client, g_bShowClassElo[client] ? "1" : "0");

    char status_text[32];
    Format(status_text, sizeof(status_text), "%T", g_bShowClassElo[client] ? "EnabledLabel" : "DisabledLabel", client);
    MC_PrintToChat(client, "%t", "HudToggle", status_text);
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
        g_iClassEloEst[client][c] = DEFAULT_CLASS_ELO;
        g_fClassRDEst[client][c] = 0.0;
        g_bClassPeriodDirty[client][c] = false;
    }
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

void ClassToName(TFClassType classType, char[] name, int maxlen)
{
    static const char classNames[][] =
    {
        "Unknown",
        "Scout",
        "Sniper",
        "Soldier",
        "Demoman",
        "Medic",
        "Heavy",
        "Pyro",
        "Spy",
        "Engineer"
    };

    int idx = view_as<int>(classType);
    if (idx < 0 || idx >= sizeof(classNames))
        idx = 0;
    strcopy(name, maxlen, classNames[idx]);
}

// ===== GLICKO-2 WALL-CLOCK PERIOD CLOSE =====

enum struct ClassPeriodGame
{
    float oppRating;
    float oppRd;
    float score;
}

enum struct ClassPeriodPlayer
{
    char steamid[32];
    int classIdx;
    int rating;
    float rd;
    float volatility;
    int lastplayed;
    int newRating;
    float newRd;
    float newVolatility;
    bool hadGames;
}

enum struct ClassPeriodStart
{
    int rating;
    float rd;
    float volatility;
}

void ClassPeriod_MakeKey(char[] key, int maxlen, const char[] steamid, int classIdx)
{
    Format(key, maxlen, "%s:%d", steamid, classIdx);
}

bool ClassPeriod_IsIgnorableSchemaError(const char[] error)
{
    return (StrContains(error, "duplicate column", false) != -1
        || StrContains(error, "already exists", false) != -1
        || StrContains(error, "Duplicate column", false) != -1);
}

int ClassPeriod_GetId(int unixTime = 0)
{
    if (unixTime <= 0)
        unixTime = GetTime();

    int hours = g_iGlickoPeriodHours;
    if (hours < 1)
        hours = 1;
    if (hours > 168)
        hours = 168;

    int periodSec = hours * 3600;
    int offsetSec = g_iGlickoPeriodUtcOffset * 3600;
    int phaseSec = (g_iGlickoPeriodHour * 3600) + (g_iGlickoPeriodMinute * 60);
    int shifted = unixTime + offsetSec - phaseSec;
    if (periodSec <= 0)
        return 0;
    if (shifted < 0)
        return (shifted - periodSec + 1) / periodSec;
    return shifted / periodSec;
}

void ClassPeriod_EnsureSchema()
{
    if (g_DB == null || g_bClassPeriodSchemaReady)
        return;

    g_iClassPeriodSchemaStep = 0;
    ClassPeriod_RunSchemaStep();
}

void ClassPeriod_RunSchemaStep()
{
    char query[1024];
    bool mysql = StrEqual(g_sClassEloDriver, "mysql", false);
    bool pgsql = StrEqual(g_sClassEloDriver, "pgsql", false);

    switch (g_iClassPeriodSchemaStep)
    {
        case 0:
        {
            if (mysql)
                strcopy(query, sizeof(query), "ALTER TABLE mge_classelo_stats ADD COLUMN rating_est INT DEFAULT NULL");
            else
                strcopy(query, sizeof(query), "ALTER TABLE mge_classelo_stats ADD COLUMN rating_est INTEGER DEFAULT NULL");
        }
        case 1:
        {
            if (mysql)
                strcopy(query, sizeof(query), "ALTER TABLE mge_classelo_stats ADD COLUMN rd_est FLOAT DEFAULT NULL");
            else
                strcopy(query, sizeof(query), "ALTER TABLE mge_classelo_stats ADD COLUMN rd_est REAL DEFAULT NULL");
        }
        case 2:
        {
            if (mysql)
                strcopy(query, sizeof(query), "ALTER TABLE mge_classelo_stats ADD COLUMN period_dirty TINYINT NOT NULL DEFAULT 0");
            else
                strcopy(query, sizeof(query), "ALTER TABLE mge_classelo_stats ADD COLUMN period_dirty INTEGER NOT NULL DEFAULT 0");
        }
        case 3:
        {
            if (mysql)
                strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_duels (winner VARCHAR(32) NOT NULL, loser VARCHAR(32) NOT NULL, winner_class INT NOT NULL, loser_class INT NOT NULL, starttime INT NOT NULL, endtime INT NOT NULL, period_id INT NOT NULL DEFAULT 0, winner_sealed_rating INT, winner_sealed_rd FLOAT, winner_sealed_volatility FLOAT, loser_sealed_rating INT, loser_sealed_rd FLOAT, loser_sealed_volatility FLOAT, period_sealed TINYINT NOT NULL DEFAULT 0, UNIQUE KEY uq_classelo_duel (winner, loser, winner_class, loser_class, starttime, endtime))");
            else if (pgsql)
                strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_duels (winner VARCHAR(32) NOT NULL, loser VARCHAR(32) NOT NULL, winner_class INT NOT NULL, loser_class INT NOT NULL, starttime INT NOT NULL, endtime INT NOT NULL, period_id INT NOT NULL DEFAULT 0, winner_sealed_rating INT, winner_sealed_rd REAL, winner_sealed_volatility REAL, loser_sealed_rating INT, loser_sealed_rd REAL, loser_sealed_volatility REAL, period_sealed INT NOT NULL DEFAULT 0, UNIQUE (winner, loser, winner_class, loser_class, starttime, endtime))");
            else
                strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_duels (winner TEXT NOT NULL, loser TEXT NOT NULL, winner_class INTEGER NOT NULL, loser_class INTEGER NOT NULL, starttime INTEGER NOT NULL, endtime INTEGER NOT NULL, period_id INTEGER NOT NULL DEFAULT 0, winner_sealed_rating INTEGER, winner_sealed_rd REAL, winner_sealed_volatility REAL, loser_sealed_rating INTEGER, loser_sealed_rd REAL, loser_sealed_volatility REAL, period_sealed INTEGER NOT NULL DEFAULT 0, UNIQUE (winner, loser, winner_class, loser_class, starttime, endtime))");
        }
        case 4:
        {
            if (mysql)
                strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_period_state (id INT NOT NULL PRIMARY KEY, last_sealed_period_id INT NOT NULL DEFAULT 0)");
            else if (pgsql)
                strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_period_state (id INT NOT NULL PRIMARY KEY, last_sealed_period_id INT NOT NULL DEFAULT 0)");
            else
                strcopy(query, sizeof(query), "CREATE TABLE IF NOT EXISTS mge_classelo_period_state (id INTEGER NOT NULL PRIMARY KEY, last_sealed_period_id INTEGER NOT NULL DEFAULT 0)");
        }
        case 5:
        {
            if (mysql)
                strcopy(query, sizeof(query), "INSERT IGNORE INTO mge_classelo_period_state (id, last_sealed_period_id) VALUES (1, 0)");
            else if (pgsql)
                strcopy(query, sizeof(query), "INSERT INTO mge_classelo_period_state (id, last_sealed_period_id) VALUES (1, 0) ON CONFLICT (id) DO NOTHING");
            else
                strcopy(query, sizeof(query), "INSERT OR IGNORE INTO mge_classelo_period_state (id, last_sealed_period_id) VALUES (1, 0)");
        }
        case 6:
        {
            strcopy(query, sizeof(query), "UPDATE mge_classelo_stats SET rating_est = rating, rd_est = rd, period_dirty = 0 WHERE rating_est IS NULL");
        }
        default:
        {
            ClassPeriod_OnSchemaReady();
            return;
        }
    }

    g_DB.Query(ClassPeriod_OnSchemaStep, query);
}

void ClassPeriod_OnSchemaStep(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null && !ClassPeriod_IsIgnorableSchemaError(error))
        LogError("Period schema step %d failed: %s", g_iClassPeriodSchemaStep, error);

    g_iClassPeriodSchemaStep++;
    ClassPeriod_RunSchemaStep();
}

void ClassPeriod_OnSchemaReady()
{
    if (g_bClassPeriodSchemaReady)
        return;

    g_bClassPeriodSchemaReady = true;
    if (g_hClassPeriodTimer == null)
        g_hClassPeriodTimer = CreateTimer(30.0, Timer_ClassPeriodTick, _, TIMER_REPEAT);
    CreateTimer(15.0, Timer_ClassPeriodBootClose);
    LoadConnectedPlayers();
}

Action Timer_ClassPeriodTick(Handle timer)
{
    ClassPeriod_TryClose();
    return Plugin_Continue;
}

Action Timer_ClassPeriodBootClose(Handle timer)
{
    ClassPeriod_TryClose();
    return Plugin_Stop;
}

void ClassPeriod_InsertDuel(int winner, int wIdx, int loser, int lIdx, int now)
{
    if (g_DB == null)
        return;

    char winnerId[32], loserId[32];
    if (!GetClientAuthId(winner, AuthId_Steam2, winnerId, sizeof(winnerId)))
        return;
    if (!GetClientAuthId(loser, AuthId_Steam2, loserId, sizeof(loserId)))
        return;

    int periodId = ClassPeriod_GetId();
    int wRating = g_iClassElo[winner][wIdx];
    int lRating = g_iClassElo[loser][lIdx];
    float wRd = g_fClassRD[winner][wIdx];
    float lRd = g_fClassRD[loser][lIdx];
    float wVol = g_fClassVolatility[winner][wIdx];
    float lVol = g_fClassVolatility[loser][lIdx];

    char query[1024];
    if (StrEqual(g_sClassEloDriver, "sqlite", false))
    {
        g_DB.Format(query, sizeof(query), "INSERT OR IGNORE INTO mge_classelo_duels (winner, loser, winner_class, loser_class, starttime, endtime, period_id, winner_sealed_rating, winner_sealed_rd, winner_sealed_volatility, loser_sealed_rating, loser_sealed_rd, loser_sealed_volatility, period_sealed) VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %f, %f, %d, %f, %f, 0)", winnerId, loserId, wIdx, lIdx, now, now, periodId, wRating, wRd, wVol, lRating, lRd, lVol);
    }
    else if (StrEqual(g_sClassEloDriver, "pgsql", false))
    {
        g_DB.Format(query, sizeof(query), "INSERT INTO mge_classelo_duels (winner, loser, winner_class, loser_class, starttime, endtime, period_id, winner_sealed_rating, winner_sealed_rd, winner_sealed_volatility, loser_sealed_rating, loser_sealed_rd, loser_sealed_volatility, period_sealed) VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %f, %f, %d, %f, %f, 0) ON CONFLICT (winner, loser, winner_class, loser_class, starttime, endtime) DO NOTHING", winnerId, loserId, wIdx, lIdx, now, now, periodId, wRating, wRd, wVol, lRating, lRd, lVol);
    }
    else
    {
        g_DB.Format(query, sizeof(query), "INSERT IGNORE INTO mge_classelo_duels (winner, loser, winner_class, loser_class, starttime, endtime, period_id, winner_sealed_rating, winner_sealed_rd, winner_sealed_volatility, loser_sealed_rating, loser_sealed_rd, loser_sealed_volatility, period_sealed) VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %f, %f, %d, %f, %f, 0)", winnerId, loserId, wIdx, lIdx, now, now, periodId, wRating, wRd, wVol, lRating, lRd, lVol);
    }

    g_DB.Query(SQL_OnGenericQuery, query);
}

void ClassPeriod_TryClose()
{
    if (g_eClassRatingEngine != CLASS_RATING_ENGINE_GLICKO2 || g_DB == null || !g_bClassPeriodSchemaReady)
        return;

    if (g_bClassPeriodCloseRunning)
        return;

    g_bClassPeriodCloseRunning = true;
    ClassPeriod_TryLock();
}

void ClassPeriod_TryLock()
{
    char query[256];
    if (StrEqual(g_sClassEloDriver, "mysql", false))
        g_DB.Format(query, sizeof(query), "SELECT GET_LOCK('%s', 0)", CLASS_PERIOD_LOCK_NAME);
    else if (StrEqual(g_sClassEloDriver, "pgsql", false))
        g_DB.Format(query, sizeof(query), "SELECT pg_try_advisory_lock(hashtext('%s'))", CLASS_PERIOD_LOCK_NAME);
    else
        strcopy(query, sizeof(query), "BEGIN IMMEDIATE");

    g_DB.Query(ClassPeriod_OnLockResult, query);
}

void ClassPeriod_OnLockResult(Database db, DBResultSet results, const char[] error, any data)
{
    if (db == null || results == null || !StrEqual("", error))
    {
        if (!StrEqual("", error))
            LogError("Period lock failed: %s", error);
        g_bClassPeriodCloseRunning = false;
        return;
    }

    bool acquired = true;
    if (!StrEqual(g_sClassEloDriver, "sqlite", false))
    {
        if (!results.FetchRow())
        {
            g_bClassPeriodCloseRunning = false;
            return;
        }
        acquired = (results.FetchInt(0) == 1);
    }

    if (!acquired)
    {
        g_bClassPeriodCloseRunning = false;
        return;
    }

    g_bClassPeriodLockHeld = true;
    char query[192];
    strcopy(query, sizeof(query), "SELECT last_sealed_period_id FROM mge_classelo_period_state WHERE id = 1 LIMIT 1");
    g_DB.Query(ClassPeriod_OnMeta, query);
}

void ClassPeriod_OnMeta(Database db, DBResultSet results, const char[] error, any data)
{
    if (db == null || results == null || !StrEqual("", error))
    {
        LogError("Failed to read period_state: %s", error);
        ClassPeriod_Finish(false);
        return;
    }

    int lastSealed = 0;
    if (results.FetchRow())
        lastSealed = results.FetchInt(0);

    g_iClassLastSealedPeriodId = lastSealed;
    int current = ClassPeriod_GetId();

    if (lastSealed == 0)
    {
        int seed = current - 1;
        if (seed < 1)
            seed = current;
        char query[192];
        g_DB.Format(query, sizeof(query), "UPDATE mge_classelo_period_state SET last_sealed_period_id = %d WHERE id = 1", seed);
        g_iClassLastSealedPeriodId = seed;
        g_DB.Query(ClassPeriod_OnBootstrapped, query);
        return;
    }

    if (lastSealed >= current - 1)
    {
        g_iClassPeriodCloseTarget = lastSealed;
        ClassPeriod_FetchLeftovers();
        return;
    }

    g_iClassPeriodCloseTarget = lastSealed + 1;
    g_bClassPeriodRecomputeOnly = false;
    g_iClassPeriodLeftoverPasses = 0;
    ClassPeriod_FetchPeriodDuels();
}

void ClassPeriod_OnBootstrapped(Database db, DBResultSet results, const char[] error, any data)
{
    if (!StrEqual("", error))
        LogError("Bootstrap last_sealed failed: %s", error);
    ClassPeriod_Finish(true);
}

void ClassPeriod_FetchPeriodDuels()
{
    char query[384];
    g_DB.Format(query, sizeof(query),
        "SELECT winner, loser, winner_class, loser_class, winner_sealed_rating, winner_sealed_rd, winner_sealed_volatility, loser_sealed_rating, loser_sealed_rd, loser_sealed_volatility FROM mge_classelo_duels WHERE period_id = %d",
        g_iClassPeriodCloseTarget);
    g_DB.Query(ClassPeriod_OnPeriodDuels, query);
}

void ClassPeriod_OnPeriodDuels(Database db, DBResultSet results, const char[] error, any data)
{
    if (db == null || results == null || !StrEqual("", error))
    {
        LogError("Failed to load period duels: %s", error);
        ClassPeriod_Finish(false);
        return;
    }

    ClassPeriod_ClearGameMap();
    g_hClassPeriodGameMap = new StringMap();
    g_hClassPeriodStartMap = new StringMap();

    while (results.FetchRow())
    {
        if (results.IsFieldNull(4) || results.IsFieldNull(7))
            continue;

        char winner[32], loser[32];
        results.FetchString(0, winner, sizeof(winner));
        results.FetchString(1, loser, sizeof(loser));
        int winnerClass = results.FetchInt(2);
        int loserClass = results.FetchInt(3);
        float winnerRating = float(results.FetchInt(4));
        float winnerRd = results.FetchFloat(5);
        float winnerVol = results.FetchFloat(6);
        float loserRating = float(results.FetchInt(7));
        float loserRd = results.FetchFloat(8);
        float loserVol = results.FetchFloat(9);

        ClassPeriod_RememberStart(winner, winnerClass, RoundFloat(winnerRating), winnerRd, winnerVol);
        ClassPeriod_RememberStart(loser, loserClass, RoundFloat(loserRating), loserRd, loserVol);
        ClassPeriod_AddGame(winner, winnerClass, loserRating, loserRd, 1.0);
        ClassPeriod_AddGame(loser, loserClass, winnerRating, winnerRd, 0.0);
    }

    if (g_bClassPeriodRecomputeOnly)
    {
        ClassPeriod_QueueGamePlayersOnly();
        return;
    }

    char query[256];
    strcopy(query, sizeof(query), "SELECT steamid, class, rating, rd, volatility, lastplayed FROM mge_classelo_stats WHERE rd IS NOT NULL");
    g_DB.Query(ClassPeriod_OnStats, query);
}

void ClassPeriod_RememberStart(const char[] steamid, int classIdx, int rating, float rd, float volatility)
{
    char key[48];
    ClassPeriod_MakeKey(key, sizeof(key), steamid, classIdx);

    ClassPeriodStart start;
    if (g_hClassPeriodStartMap.GetArray(key, start, sizeof(start)))
        return;

    start.rating = rating;
    start.rd = rd;
    start.volatility = volatility;
    g_hClassPeriodStartMap.SetArray(key, start, sizeof(start));
}

void ClassPeriod_AddGame(const char[] steamid, int classIdx, float oppRating, float oppRd, float score)
{
    char key[48];
    ClassPeriod_MakeKey(key, sizeof(key), steamid, classIdx);

    ArrayList games;
    if (!g_hClassPeriodGameMap.GetValue(key, games) || games == null)
    {
        games = new ArrayList(sizeof(ClassPeriodGame));
        g_hClassPeriodGameMap.SetValue(key, games);
    }

    if (games.Length >= CLASS_GLICKO2_MAX_PERIOD_GAMES)
        return;

    ClassPeriodGame game;
    game.oppRating = oppRating;
    game.oppRd = oppRd;
    game.score = score;
    games.PushArray(game);
}

void ClassPeriod_OnStats(Database db, DBResultSet results, const char[] error, any data)
{
    if (db == null || results == null || !StrEqual("", error))
    {
        LogError("Failed to load stats for close: %s", error);
        ClassPeriod_Finish(false);
        return;
    }

    delete g_hClassPeriodPlayers;
    g_hClassPeriodPlayers = new ArrayList(sizeof(ClassPeriodPlayer));

    int hours = g_iGlickoPeriodHours;
    if (hours < 1)
        hours = 1;
    int windowsPerIdle = RoundToNearest(g_fGlickoPeriodDays * 24.0 / float(hours));
    if (windowsPerIdle < 1)
        windowsPerIdle = 1;

    while (results.FetchRow())
    {
        ClassPeriodPlayer player;
        results.FetchString(0, player.steamid, sizeof(player.steamid));
        player.classIdx = results.FetchInt(1);
        player.rating = results.FetchInt(2);
        player.rd = results.FetchFloat(3);
        player.volatility = results.FetchFloat(4);
        player.lastplayed = results.FetchInt(5);
        player.newRating = player.rating;
        player.newRd = player.rd;
        player.newVolatility = player.volatility;
        player.hadGames = false;

        char key[48];
        ClassPeriod_MakeKey(key, sizeof(key), player.steamid, player.classIdx);

        ArrayList games;
        if (g_hClassPeriodGameMap != null && g_hClassPeriodGameMap.GetValue(key, games) && games != null && games.Length > 0)
        {
            player.hadGames = true;
            ClassPeriodStart start;
            if (g_hClassPeriodStartMap != null && g_hClassPeriodStartMap.GetArray(key, start, sizeof(start)))
            {
                player.rating = start.rating;
                player.rd = start.rd;
                player.volatility = start.volatility;
            }
            ClassPeriod_ComputeFromGames(player.rating, player.rd, player.volatility, games, player.newRating, player.newRd, player.newVolatility);
        }
        else if (player.lastplayed > 0)
        {
            int lastPlayedPeriod = ClassPeriod_GetId(player.lastplayed);
            int missedWindows = g_iClassPeriodCloseTarget - lastPlayedPeriod;
            if (missedWindows >= windowsPerIdle && (missedWindows % windowsPerIdle) == 0)
                ClassGlicko2_InflateRdOnePeriod(player.rd, player.volatility, player.newRd);
        }

        g_hClassPeriodPlayers.PushArray(player);
    }

    ClassPeriod_QueueUpdates();
}

void ClassPeriod_ComputeFromGames(int rating, float rd, float volatility, ArrayList games, int &newRating, float &newRd, float &newVolatility)
{
    int count = games.Length;
    if (count > CLASS_GLICKO2_MAX_PERIOD_GAMES)
        count = CLASS_GLICKO2_MAX_PERIOD_GAMES;

    float oppRating[CLASS_GLICKO2_MAX_PERIOD_GAMES];
    float oppRd[CLASS_GLICKO2_MAX_PERIOD_GAMES];
    float score[CLASS_GLICKO2_MAX_PERIOD_GAMES];

    for (int i = 0; i < count; i++)
    {
        ClassPeriodGame game;
        games.GetArray(i, game);
        oppRating[i] = game.oppRating;
        oppRd[i] = game.oppRd;
        score[i] = game.score;
    }

    float newRatingF, newRdF, newVolF;
    ClassGlicko2_ComputePeriodUpdate(float(rating), rd, volatility, count, oppRating, oppRd, score, newRatingF, newRdF, newVolF);
    newRating = RoundFloat(newRatingF);
    newRd = newRdF;
    newVolatility = newVolF;
}

void ClassPeriod_QueueGamePlayersOnly()
{
    delete g_hClassPeriodPlayers;
    g_hClassPeriodPlayers = new ArrayList(sizeof(ClassPeriodPlayer));

    if (g_hClassPeriodGameMap != null)
    {
        StringMapSnapshot snap = g_hClassPeriodGameMap.Snapshot();
        int len = snap.Length;
        for (int i = 0; i < len; i++)
        {
            char key[48];
            snap.GetKey(i, key, sizeof(key));

            ArrayList games;
            if (!g_hClassPeriodGameMap.GetValue(key, games) || games == null)
                continue;

            ClassPeriodStart start;
            if (g_hClassPeriodStartMap == null || !g_hClassPeriodStartMap.GetArray(key, start, sizeof(start)))
                continue;

            int colon = FindCharInString(key, ':', true);
            if (colon <= 0)
                continue;

            ClassPeriodPlayer player;
            strcopy(player.steamid, colon + 1, key);
            player.classIdx = StringToInt(key[colon + 1]);
            player.rating = start.rating;
            player.rd = start.rd;
            player.volatility = start.volatility;
            player.newRating = start.rating;
            player.newRd = start.rd;
            player.newVolatility = start.volatility;
            player.hadGames = true;
            ClassPeriod_ComputeFromGames(player.rating, player.rd, player.volatility, games, player.newRating, player.newRd, player.newVolatility);
            g_hClassPeriodPlayers.PushArray(player);
        }
        delete snap;
    }

    ClassPeriod_QueueUpdates();
}

void ClassPeriod_QueueUpdates()
{
    delete g_hClassPeriodUpdateQueue;
    g_hClassPeriodUpdateQueue = new ArrayList(ByteCountToCells(512));
    g_iClassPeriodUpdateIndex = 0;

    if (g_hClassPeriodPlayers != null)
    {
        for (int i = 0; i < g_hClassPeriodPlayers.Length; i++)
        {
            ClassPeriodPlayer player;
            g_hClassPeriodPlayers.GetArray(i, player);

            char query[512];
            g_DB.Format(query, sizeof(query),
                "UPDATE mge_classelo_stats SET rating=%d, rd=%f, volatility=%f, rating_est=%d, rd_est=%f, period_dirty=0 WHERE steamid='%s' AND class=%d",
                player.newRating, player.newRd, player.newVolatility, player.newRating, player.newRd, player.steamid, player.classIdx);
            g_hClassPeriodUpdateQueue.PushString(query);
        }
    }

    char markQuery[192];
    g_DB.Format(markQuery, sizeof(markQuery),
        "UPDATE mge_classelo_duels SET period_sealed=1 WHERE period_id=%d", g_iClassPeriodCloseTarget);
    g_hClassPeriodUpdateQueue.PushString(markQuery);

    ClassPeriod_FlushUpdateChunk();
}

void ClassPeriod_FlushUpdateChunk()
{
    if (g_hClassPeriodUpdateQueue == null)
    {
        ClassPeriod_AfterUpdates();
        return;
    }

    int remaining = g_hClassPeriodUpdateQueue.Length - g_iClassPeriodUpdateIndex;
    if (remaining <= 0)
    {
        ClassPeriod_AfterUpdates();
        return;
    }

    Transaction txn = new Transaction();
    int chunk = remaining;
    if (chunk > CLASS_PERIOD_UPDATE_CHUNK)
        chunk = CLASS_PERIOD_UPDATE_CHUNK;

    for (int i = 0; i < chunk; i++)
    {
        char query[512];
        g_hClassPeriodUpdateQueue.GetString(g_iClassPeriodUpdateIndex + i, query, sizeof(query));
        txn.AddQuery(query);
    }

    g_iClassPeriodUpdateIndex += chunk;
    g_DB.Execute(txn, ClassPeriod_OnUpdateChunkOk, ClassPeriod_OnUpdateChunkFail);
}

void ClassPeriod_OnUpdateChunkOk(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    ClassPeriod_FlushUpdateChunk();
}

void ClassPeriod_OnUpdateChunkFail(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    LogError("Stats update chunk failed: %s", error);
    ClassPeriod_Finish(false);
}

void ClassPeriod_AfterUpdates()
{
    char query[192];
    g_DB.Format(query, sizeof(query),
        "SELECT COUNT(*) FROM mge_classelo_duels WHERE period_id=%d AND period_sealed=0",
        g_iClassPeriodCloseTarget);
    g_DB.Query(ClassPeriod_OnLeftoverCount, query);
}

void ClassPeriod_OnLeftoverCount(Database db, DBResultSet results, const char[] error, any data)
{
    int leftover = 0;
    if (results != null && StrEqual("", error) && results.FetchRow())
        leftover = results.FetchInt(0);

    if (leftover > 0 && g_iClassPeriodLeftoverPasses < CLASS_PERIOD_LEFTOVER_MAX)
    {
        g_iClassPeriodLeftoverPasses++;
        g_bClassPeriodRecomputeOnly = true;
        ClassPeriod_FetchPeriodDuels();
        return;
    }

    char query[192];
    g_DB.Format(query, sizeof(query),
        "UPDATE mge_classelo_period_state SET last_sealed_period_id=%d WHERE id=1",
        g_iClassPeriodCloseTarget);
    g_DB.Query(ClassPeriod_OnSealed, query);
}

void ClassPeriod_OnSealed(Database db, DBResultSet results, const char[] error, any data)
{
    if (!StrEqual("", error))
        LogError("Failed to write last_sealed: %s", error);

    g_iClassLastSealedPeriodId = g_iClassPeriodCloseTarget;
    g_iClassPeriodLeftoverPasses = 0;
    ClassPeriod_NotifyConnectedClients();

    int current = ClassPeriod_GetId();
    if (g_iClassLastSealedPeriodId < current - 1)
    {
        g_iClassPeriodCloseTarget = g_iClassLastSealedPeriodId + 1;
        g_bClassPeriodRecomputeOnly = false;
        g_iClassPeriodLeftoverPasses = 0;
        ClassPeriod_FetchPeriodDuels();
        return;
    }

    ClassPeriod_Finish(true);
}

void ClassPeriod_FetchLeftovers()
{
    char query[256];
    g_DB.Format(query, sizeof(query),
        "SELECT COUNT(*) FROM mge_classelo_duels WHERE period_id > 0 AND period_id <= %d AND period_sealed=0",
        g_iClassLastSealedPeriodId);
    g_DB.Query(ClassPeriod_OnStaleLeftoverCount, query);
}

void ClassPeriod_OnStaleLeftoverCount(Database db, DBResultSet results, const char[] error, any data)
{
    int leftover = 0;
    if (results != null && StrEqual("", error) && results.FetchRow())
        leftover = results.FetchInt(0);

    if (leftover > 0)
    {
        g_iClassPeriodCloseTarget = g_iClassLastSealedPeriodId;
        g_iClassPeriodLeftoverPasses = 0;
        g_bClassPeriodRecomputeOnly = true;
        ClassPeriod_FetchPeriodDuels();
        return;
    }

    ClassPeriod_Finish(true);
}

void ClassPeriod_NotifyConnectedClients()
{
    if (g_hClassPeriodPlayers == null)
        return;

    StringMap byKey = new StringMap();
    for (int i = 0; i < g_hClassPeriodPlayers.Length; i++)
    {
        ClassPeriodPlayer player;
        g_hClassPeriodPlayers.GetArray(i, player);
        char key[48];
        ClassPeriod_MakeKey(key, sizeof(key), player.steamid, player.classIdx);
        byKey.SetArray(key, player, sizeof(player));
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client) || IsFakeClient(client) || !g_bClassEloLoaded[client])
            continue;

        char steamid[32];
        if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
            continue;

        for (int classIdx = 1; classIdx < MAX_TF_CLASSES; classIdx++)
        {
            char key[48];
            ClassPeriod_MakeKey(key, sizeof(key), steamid, classIdx);

            ClassPeriodPlayer player;
            if (!byKey.GetArray(key, player, sizeof(player)))
                continue;

            g_iClassElo[client][classIdx] = player.newRating;
            g_fClassRD[client][classIdx] = player.newRd;
            g_fClassVolatility[client][classIdx] = player.newVolatility;
            g_iClassEloEst[client][classIdx] = player.newRating;
            g_fClassRDEst[client][classIdx] = player.newRd;
            g_bClassPeriodDirty[client][classIdx] = false;
        }
    }

    delete byKey;
}

void ClassPeriod_Finish(bool unlock)
{
    #pragma unused unlock
    ClassPeriod_ClearGameMap();
    delete g_hClassPeriodPlayers;
    g_hClassPeriodPlayers = null;
    delete g_hClassPeriodUpdateQueue;
    g_hClassPeriodUpdateQueue = null;
    g_iClassPeriodLeftoverPasses = 0;

    if (g_bClassPeriodLockHeld && g_DB != null)
    {
        char query[256];
        if (StrEqual(g_sClassEloDriver, "mysql", false))
            g_DB.Format(query, sizeof(query), "SELECT RELEASE_LOCK('%s')", CLASS_PERIOD_LOCK_NAME);
        else if (StrEqual(g_sClassEloDriver, "pgsql", false))
            g_DB.Format(query, sizeof(query), "SELECT pg_advisory_unlock(hashtext('%s'))", CLASS_PERIOD_LOCK_NAME);
        else
            strcopy(query, sizeof(query), "COMMIT");
        g_DB.Query(SQL_OnGenericQuery, query);
        g_bClassPeriodLockHeld = false;
    }

    g_bClassPeriodCloseRunning = false;
}

void ClassPeriod_ClearGameMap()
{
    if (g_hClassPeriodGameMap != null)
    {
        StringMapSnapshot snap = g_hClassPeriodGameMap.Snapshot();
        int len = snap.Length;
        for (int i = 0; i < len; i++)
        {
            char key[48];
            snap.GetKey(i, key, sizeof(key));
            ArrayList games;
            if (g_hClassPeriodGameMap.GetValue(key, games))
                delete games;
        }
        delete snap;
        delete g_hClassPeriodGameMap;
        g_hClassPeriodGameMap = null;
    }

    delete g_hClassPeriodStartMap;
    g_hClassPeriodStartMap = null;
}

void ClassPeriod_RefreshEstimate(int client, int classIdx)
{
    if (g_eClassRatingEngine != CLASS_RATING_ENGINE_GLICKO2 || !g_bClassPeriodSchemaReady || g_DB == null)
        return;
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    char steamid[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
        return;

    int periodId = ClassPeriod_GetId();
    char query[512];
    g_DB.Format(query, sizeof(query),
        "SELECT winner, loser, winner_class, loser_class, winner_sealed_rating, winner_sealed_rd, loser_sealed_rating, loser_sealed_rd FROM mge_classelo_duels WHERE period_id = %d AND ((winner = '%s' AND winner_class = %d) OR (loser = '%s' AND loser_class = %d))",
        periodId, steamid, classIdx, steamid, classIdx);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(classIdx);
    pack.WriteString(steamid);
    pack.WriteCell(g_bClassPeriodDirty[client][classIdx] ? g_iClassEloEst[client][classIdx] : g_iClassElo[client][classIdx]);
    pack.WriteCell(g_iClassElo[client][classIdx]);
    pack.WriteFloat(g_fClassRD[client][classIdx]);
    pack.WriteFloat(g_fClassVolatility[client][classIdx]);
    g_DB.Query(ClassPeriod_OnEstimateDuels, query, pack);
}

void ClassPeriod_OnEstimateDuels(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int classIdx = pack.ReadCell();
    char steamid[32];
    pack.ReadString(steamid, sizeof(steamid));
    int previousHud = pack.ReadCell();
    int sealedRating = pack.ReadCell();
    float sealedRd = pack.ReadFloat();
    float sealedVol = pack.ReadFloat();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client))
        return;

    if (results == null || !StrEqual("", error))
    {
        LogError("Estimate query failed: %s", error);
        return;
    }

    float oppRating[CLASS_GLICKO2_MAX_PERIOD_GAMES];
    float oppRd[CLASS_GLICKO2_MAX_PERIOD_GAMES];
    float score[CLASS_GLICKO2_MAX_PERIOD_GAMES];
    int count = 0;

    while (results.FetchRow() && count < CLASS_GLICKO2_MAX_PERIOD_GAMES)
    {
        if (results.IsFieldNull(4) || results.IsFieldNull(6))
            continue;

        char winner[32], loser[32];
        results.FetchString(0, winner, sizeof(winner));
        results.FetchString(1, loser, sizeof(loser));
        int winnerClass = results.FetchInt(2);
        int loserClass = results.FetchInt(3);

        if (StrEqual(winner, steamid) && winnerClass == classIdx)
        {
            oppRating[count] = float(results.FetchInt(6));
            oppRd[count] = results.FetchFloat(7);
            score[count] = 1.0;
        }
        else if (StrEqual(loser, steamid) && loserClass == classIdx)
        {
            oppRating[count] = float(results.FetchInt(4));
            oppRd[count] = results.FetchFloat(5);
            score[count] = 0.0;
        }
        else
        {
            continue;
        }
        count++;
    }

    float newRating = float(sealedRating);
    float newRd = sealedRd;
    float newVol = sealedVol;
    if (count > 0)
        ClassGlicko2_ComputePeriodUpdate(float(sealedRating), sealedRd, sealedVol, count, oppRating, oppRd, score, newRating, newRd, newVol);

    int estRating = RoundFloat(newRating);
    g_iClassEloEst[client][classIdx] = estRating;
    g_fClassRDEst[client][classIdx] = newRd;
    g_bClassPeriodDirty[client][classIdx] = (count > 0);

    char query[384];
    g_DB.Format(query, sizeof(query),
        "UPDATE mge_classelo_stats SET rating_est=%d, rd_est=%f, period_dirty=%d WHERE steamid='%s' AND class=%d",
        estRating, newRd, g_bClassPeriodDirty[client][classIdx] ? 1 : 0, steamid, classIdx);
    g_DB.Query(SQL_OnGenericQuery, query);

    if (g_bShowClassElo[client])
    {
        char clsName[16];
        ClassToName(view_as<TFClassType>(classIdx), clsName, sizeof(clsName));
        int delta = estRating - previousHud;
        if (delta >= 0)
            MC_PrintToChat(client, "%t", "GainedClassRatingEst", delta, clsName, estRating);
        else
            MC_PrintToChat(client, "%t", "LostClassRatingEst", -delta, clsName, estRating);
    }
}
