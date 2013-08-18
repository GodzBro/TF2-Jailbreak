/*
	https://forums.alliedmods.net/showthread.php?p=1544101
	
	Cheers to Databomb for his plugin code, I basically just took it and fixed it up for TF2.
*/

#pragma semicolon 1
#define CHAT_BANNER "[TF2Jail] "

#include <sourcemod>
#include <clientprefs>
#include <sdktools>
#include <adminmenu>
#include <tf2>
#include <tf2_stocks>

#define PLUGIN_NAME     "[TF2] Jailbreak - Bans"												//Plugin name
#define PLUGIN_AUTHOR   "Keith Warren(Jack of Designs)"											//Plugin author
#define PLUGIN_VERSION  "4.8.0"																	//Plugin version
#define PLUGIN_DESCRIPTION	"Jailbreak for Team Fortress 2."									//Plugin description
#define PLUGIN_CONTACT  "http://www.jackofdesigns.com/"											//Plugin contact URL

#define OCAOFF 0
#define USESQL 1

new Handle:g_CT_Cookie = INVALID_HANDLE;
new Handle:gH_Cvar_Enabled = INVALID_HANDLE;
new Handle:g_Handles[MAXPLAYERS+1];
new Handle:gH_TopMenu = INVALID_HANDLE;
new Handle:gH_Cvar_SoundName = INVALID_HANDLE;
new String:gS_SoundPath[PLATFORM_MAX_PATH];
new Handle:gH_Cvar_JoinBanMessage = INVALID_HANDLE;
new Handle:gH_Cvar_Database_Driver = INVALID_HANDLE;
new Handle:gH_Cvar_Debugger = INVALID_HANDLE;
new Handle:gA_DNames = INVALID_HANDLE;
new Handle:gA_DSteamIDs = INVALID_HANDLE;
new Handle:gH_CP_DataBase = INVALID_HANDLE;
new Handle:gH_BanDatabase = INVALID_HANDLE;
new Handle:gH_Cvar_Table_Prefix = INVALID_HANDLE;
new g_iCookieIndex;
new bool:g_bAuthIdNativeExists = false;
new Handle:gA_TimedBanLocalList = INVALID_HANDLE;
new gA_LocalTimeRemaining[MAXPLAYERS+1];
#if USESQL == 0
new Handle:gA_TimedBanSteamList = INVALID_HANDLE;
#endif
new gA_CTBanTargetUserId[MAXPLAYERS+1];
new gA_CTBanTimeLength[MAXPLAYERS+1];
new String:g_sLogTableName[32];
new String:g_sTimesTableName[32];
new bool:debugging;

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = PLUGIN_CONTACT
};

public OnPluginStart()
{
	CreateConVar("tf2jail_bluebans_version", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_SPONLY|FCVAR_DONTRECORD|FCVAR_REPLICATED|FCVAR_NOTIFY);

	gH_Cvar_Enabled = CreateConVar("sm_jail_blueban_enable","1","Status of the plugin: (1 = on, 0 = off)", FCVAR_PLUGIN);
	gH_Cvar_SoundName = CreateConVar("sm_jail_blueban_denysound", "", "Sound to play on join denied: (def: none)",FCVAR_PLUGIN);
	gH_Cvar_JoinBanMessage = CreateConVar("sm_jail_blueban_joinbanmsg", "Please visit our website to appeal.", "Text to give the client on join banned: (def: Please visit our website to appeal.)", FCVAR_PLUGIN);
	gH_Cvar_Table_Prefix = CreateConVar("sm_jail_blueban_tableprefix", "", "Prefix for database to use: (def: none)", FCVAR_PLUGIN);
	gH_Cvar_Database_Driver = CreateConVar("sm_jail_blueban_sqldriver", "default", "Name of the sql driver to use: (def: default)", FCVAR_PLUGIN);
	gH_Cvar_Debugger = CreateConVar("sm_jail_blueban_debug", "1", "Debugging logs status: (1 = on, 0 = off)", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	AutoExecConfig(true, "TF2Jail_BlueBans");
	
	g_CT_Cookie = RegClientCookie("TF2Jail_GuardBanned", "Are you banned from blue team? This cookies gives the information.", CookieAccess_Protected);

	RegAdminCmd("sm_banguard", Command_CTBan, ADMFLAG_SLAY, "sm_banguard <player> <optional: time> - Bans a player from guards(blue) team.");
	RegAdminCmd("sm_banstatus", Command_IsCTBanned, ADMFLAG_GENERIC, "sm_banstatus <player> - Gives you information if player is banned or not from guards(blue) team.");
	RegAdminCmd("sm_unbanguard", Command_UnCTBan, ADMFLAG_SLAY, "sm_unbanguard <player> - Unbans a player from guards(blue) team.");
	RegAdminCmd("sm_ragebanguard", Command_RageBan, ADMFLAG_SLAY, "sm_ragebanguard <player> - Lists recently disconnected players and allows you to ban them from guards(blue) team.");
	RegAdminCmd("sm_banguard_offline", Command_Offline_CTBan, ADMFLAG_KICK, "sm_banguard_offline <steamid> - Allows admins to ban players while not on the server from guards(blue) team.");
	RegAdminCmd("sm_unbanguard_offline", Command_Offline_UnCTBan, ADMFLAG_KICK, "sm_unbanguard_offline <steamid> - Allows admins to unban players while not on the server from guards(blue) team.");
	
	LoadTranslations("common.phrases");
	LoadTranslations("TF2Jail_BlueBans.phrases");

	gA_DNames = CreateArray(MAX_TARGET_LENGTH);
	gA_DSteamIDs = CreateArray(22);
	g_iCookieIndex = 0;

	HookEvent("player_spawn", PlayerSpawn);

	gA_TimedBanLocalList = CreateArray(2);
	for (new idx = 1; idx <= MaxClients; idx++)
	{
		gA_LocalTimeRemaining[idx] = 0;
		gA_CTBanTargetUserId[idx] = 0;
	}
	#if USESQL == 0
	gA_TimedBanSteamList = CreateArray(23);
	#endif
	
	CreateTimer(60.0, CheckTimedCTBans, _, TIMER_REPEAT);
		
	new Handle:topmenu;
	if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != INVALID_HANDLE))
	{
		OnAdminMenuReady(topmenu);
	}
}

public OnAllPluginsLoaded()
{
	g_bAuthIdNativeExists = IsSetAuthIdNativePresent();
}

public OnClientAuthorized(client, const String:sSteamID[])
{
	#if OCAOFF == 0	
	new iNeedle = FindStringInArray(gA_DSteamIDs, sSteamID);
	if (iNeedle != -1)
	{
		RemoveFromArray(gA_DNames, iNeedle);
		RemoveFromArray(gA_DSteamIDs, iNeedle);
		if (debugging) LogMessage("removed %N from Rage Bannable player list for re-connecting to the server", client);
	}
	#endif
	
	#if USESQL == 1
	decl String:query[255];
	Format(query, sizeof(query), "SELECT ban_time FROM %s WHERE steamid = '%s'", g_sTimesTableName, sSteamID);
	SQL_TQuery(gH_BanDatabase, DB_Callback_OnClientAuthed, query, _:client);

	#else
	
	new iSteamArrayIndex = FindStringInArray(gA_TimedBanSteamList, sSteamID);
	if (iSteamArrayIndex != -1)
	{
		gA_LocalTimeRemaining[client] = GetArrayCell(gA_TimedBanSteamList, iSteamArrayIndex, 22);
		if (debugging) LogMessage("%N joined with %i time remaining on ban", client, gA_LocalTimeRemaining[client]);
	}
	#endif
}

public DB_Callback_OnClientAuthed(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error in OnClientAuthorized query: %s", error);
	}
	else
	{
		new iRowCount = SQL_GetRowCount(hndl);
		if (debugging) LogMessage("SQL Auth: %d row count", iRowCount);
		if (iRowCount)
		{
			SQL_FetchRow(hndl);
			new iBanTimeRemaining = SQL_FetchInt(hndl, 0);
			if (debugging) LogMessage("SQL Auth: %N joined with %i time remaining on ban", client, iBanTimeRemaining);
			PushArrayCell(gA_TimedBanLocalList, client);
			gA_LocalTimeRemaining[client] = iBanTimeRemaining;
		}
	}
}

public AdminMenu_RageBan(Handle:topmenu, TopMenuAction:action, TopMenuObject:object_id, param, String:buffer[], maxlength)
{
	if (action == TopMenuAction_DisplayOption)
	{
		Format(buffer, maxlength, "Rage Ban");
	}
	else if (action == TopMenuAction_SelectOption)
	{
		DisplayRageBanMenu(param, GetArraySize(gA_DNames));
	}
}

DisplayRageBanMenu(Client, ArraySize)
{
	if (ArraySize == 0)
	{
		PrintToChat(Client, "%s %t", CHAT_BANNER, "No Targets");
	}
	else
	{
		new Handle:menu = CreateMenu(MenuHandler_RageBan);
		
		SetMenuTitle(menu, "%T", "Rage Ban Menu Title", Client);
		SetMenuExitBackButton(menu, true);

		for (new ArrayIndex = 0; ArrayIndex < ArraySize; ArrayIndex++)
		{
			decl String:sName[MAX_TARGET_LENGTH];
			GetArrayString(gA_DNames, ArrayIndex, sName, sizeof(sName));
			decl String:sSteamID[22];
			GetArrayString(gA_DSteamIDs, ArrayIndex, sSteamID, sizeof(sSteamID));
			AddMenuItem(menu, sSteamID, sName);
		}
		
		DisplayMenu(menu, Client, MENU_TIME_FOREVER);
	}
}

public MenuHandler_RageBan(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if ((param2 == MenuCancel_ExitBack) && (gH_TopMenu != INVALID_HANDLE))
		{
			DisplayTopMenu(gH_TopMenu, param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		decl String:sInfoString[22];
		GetMenuItem(menu, param2, sInfoString, sizeof(sInfoString));
		
		if (g_bAuthIdNativeExists)
		{
			//SetAuthIdCookie(sInfoString, g_CT_Cookie, "1");
		}
		else
		{
			if (gH_CP_DataBase != INVALID_HANDLE)
			{
				decl String:query[255];
				Format(query, sizeof(query), "SELECT value FROM sm_cookie_cache WHERE player = '%s' and cookie_id = '%i'", sInfoString, g_iCookieIndex);
				new Handle:TheDataPack = CreateDataPack();
				WritePackString(TheDataPack, sInfoString);
				WritePackCell(TheDataPack, param1);
				WritePackCell(TheDataPack, param2);
				SQL_TQuery(gH_CP_DataBase, CP_Callback_CheckBan, query, TheDataPack); 
			}
		}
		if (debugging) PrintToChat(param1, "%s %t", CHAT_BANNER, "Ready to CT Ban", sInfoString);
	}
}

public CP_Callback_CheckBan(Handle:owner, Handle:hndl, const String:error[], any:stringPack)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("CT Ban query had a failure: %s", error);
		CloseHandle(stringPack);
	}
	else
	{
		ResetPack(stringPack);
		decl String:authID[22];
		ReadPackString(stringPack, authID, sizeof(authID));
		new iAdminIndex = ReadPackCell(stringPack);
		new iArrayBanIndex = ReadPackCell(stringPack);
		CloseHandle(stringPack);
		
		new iTimeStamp = GetTime();
		
		new iRowCount = SQL_GetRowCount(hndl);
		if (iRowCount)
		{
			if (debugging)
			{
				SQL_FetchRow(hndl);
				new iCTBanStatus = SQL_FetchInt(hndl, 0);
				LogMessage("CTBan status on player is currently %i. Will do UPDATE on %s", iCTBanStatus, authID);
			}

			decl String:query[255];
			Format(query, sizeof(query), "UPDATE sm_cookie_cache SET value = '1', timestamp = %i WHERE player = '%s' AND cookie_id = '%i'", iTimeStamp, authID, g_iCookieIndex);
			if (debugging) LogMessage("Query to run: %s", query);
			SQL_TQuery(gH_CP_DataBase, CP_Callback_IssueBan, query);
		}
		else
		{
			if (debugging) LogMessage("couldn't find steamID in database, need to INSERT");
			
			decl String:query[255];
			Format(query, sizeof(query), "INSERT INTO sm_cookie_cache (player, cookie_id, value, timestamp) VALUES ('%s', %i, '1', %i)", authID, g_iCookieIndex, iTimeStamp);
			if (debugging) LogMessage("Query to run: %s", query);
			SQL_TQuery(gH_CP_DataBase, CP_Callback_IssueBan, query);
		}
		
		decl String:sTargetName[MAX_TARGET_LENGTH];
		GetArrayString(gA_DNames, iArrayBanIndex, sTargetName, sizeof(sTargetName));
		decl String:adminSteamID[22];
		GetClientAuthString(iAdminIndex, adminSteamID, sizeof(adminSteamID));

		#if USESQL == 1
		decl String:logQuery[350];
		Format(logQuery, sizeof(logQuery), "INSERT INTO %s (timestamp, offender_steamid, offender_name, admin_steamid, admin_name, bantime, timeleft, reason) VALUES (%d, '%s', '%s', '%s', 'Console', 0, 0, 'Rage ban')", g_sLogTableName, iTimeStamp, authID, sTargetName, adminSteamID, iAdminIndex);
		if (debugging) LogMessage("log query: %s", logQuery);
		SQL_TQuery(gH_BanDatabase, DB_Callback_CTBan, logQuery, iAdminIndex);
		#endif
		
		LogMessage("%N (%s) has issued a rage ban on %s (%s) indefinitely.", iAdminIndex, adminSteamID, sTargetName, authID);

		ShowActivity2(iAdminIndex, CHAT_BANNER, "%t", "Rage Ban", sTargetName);

		RemoveFromArray(gA_DNames, iArrayBanIndex);
		RemoveFromArray(gA_DSteamIDs, iArrayBanIndex);
		if (debugging) LogMessage("Removed %i index from rage ban menu.", iArrayBanIndex);
	}
}

public CP_Callback_IssueBan(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error writing to database: %s", error);
	}
	else
	{
		if (debugging) LogMessage("succesfully wrote to the database");
	}
}

public Action:Command_Offline_CTBan(client, args)
{
	decl String:sAuthId[32];
	GetCmdArgString(sAuthId, sizeof(sAuthId));
	if (g_bAuthIdNativeExists)
	{
		SetAuthIdCookie(sAuthId, g_CT_Cookie, "1");
		ReplyToCommand(client, CHAT_BANNER, "Banned AuthId", sAuthId);
	}
	else
	{
		ReplyToCommand(client, CHAT_BANNER, "Feature Not Available");
	}
	return Plugin_Handled;
}

public Action:Command_Offline_UnCTBan(client, args)
{
	decl String:sAuthId[32];
	GetCmdArgString(sAuthId, sizeof(sAuthId));
	if (g_bAuthIdNativeExists)
	{
		SetAuthIdCookie(sAuthId, g_CT_Cookie, "0");
		ReplyToCommand(client, CHAT_BANNER, "Unbanned AuthId", sAuthId);
	}
	else
	{
		ReplyToCommand(client, CHAT_BANNER, "Feature Not Available");
	}
	return Plugin_Handled;
}

public Action:Command_RageBan(client, args)
{
	new iArraySize = GetArraySize(gA_DNames);
	if (iArraySize == 0)
	{
		ReplyToCommand(client, CHAT_BANNER, "No Targets");
		return Plugin_Handled;
	}
	
	if (!args)
	{
		if (client)
		{
			DisplayRageBanMenu(client, iArraySize);
		}
		else
		{
			ReplyToCommand(client, CHAT_BANNER, "Feature Not Available On Console");
		}
		return Plugin_Handled;
	}
	else
	{
		ReplyToCommand(client, "%s Usage: sm_rageban", CHAT_BANNER);
	}
	
	return Plugin_Handled;
}

public Action:CheckTimedCTBans(Handle:timer)
{
	new iTimeArraySize = GetArraySize(gA_TimedBanLocalList);
	
	for (new idx = 0; idx < iTimeArraySize; idx++)
	{
		new iBannedClientIndex = GetArrayCell(gA_TimedBanLocalList, idx);
		if (IsClientInGame(iBannedClientIndex))
		{
			if (IsPlayerAlive(iBannedClientIndex))
			{
				gA_LocalTimeRemaining[iBannedClientIndex]--;
				if (debugging) LogMessage("found alive time banned client with %i remaining", gA_LocalTimeRemaining[iBannedClientIndex]);
				if (gA_LocalTimeRemaining[iBannedClientIndex] <= 0)
				{
					RemoveFromArray(gA_TimedBanLocalList, idx);
					iTimeArraySize--;
					Remove_CTBan(0, iBannedClientIndex, true);
					if (debugging) LogMessage("removed CT ban on %N", iBannedClientIndex);
				}
			}
		}
	}
}

public OnConfigsExecuted()
{
	debugging = GetConVarBool(gH_Cvar_Debugger);

	SQL_TConnect(CP_Callback_Connect, "clientprefs");
	
	decl String:sDatabaseDriver[64];
	GetConVarString(gH_Cvar_Database_Driver, sDatabaseDriver, sizeof(sDatabaseDriver));
	SQL_TConnect(DB_Callback_Connect, sDatabaseDriver);
}

public DB_Callback_Connect(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Default database database connection failure: %s", error);
		SetFailState("Error while connecting to default database. Exiting.");
	}
	else
	{
		gH_BanDatabase = hndl;
		
		decl String:sPrefix[64];
		GetConVarString(gH_Cvar_Table_Prefix, sPrefix, sizeof(sPrefix));
		if (strlen(sPrefix) > 0)
		{
			Format(g_sTimesTableName, sizeof(g_sTimesTableName), "%s_TF2Jail_BlueBan_Times", sPrefix);
		}
		else
		{
			Format(g_sTimesTableName, sizeof(g_sTimesTableName), "TF2Jail_BlueBan_Times");
		}
		
		decl String:sQuery[255];
		Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS %s (steamid VARCHAR(22), ban_time INT(16), PRIMARY KEY (steamid))", g_sTimesTableName);
		
		SQL_TQuery(gH_BanDatabase, DB_Callback_Create, sQuery); 
		
		if (strlen(sPrefix) > 0)
		{
			Format(g_sLogTableName, sizeof(g_sLogTableName), "%s_TF2Jail_BlueBan_Logs", sPrefix);
		}
		else
		{
			Format(g_sLogTableName, sizeof(g_sLogTableName), "TF2Jail_BlueBan_Logs");
		}
		
		Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS %s (timestamp INT, offender_steamid VARCHAR(22), offender_name VARCHAR(32), admin_steamid VARCHAR(22), admin_name VARCHAR(32), bantime INT(16), timeleft INT(16), reason VARCHAR(200), PRIMARY KEY (timestamp))", g_sLogTableName);
		SQL_TQuery(gH_BanDatabase, DB_Callback_Create, sQuery);
	}
}

public DB_Callback_Create(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error establishing table creation: %s", error);
		SetFailState("Unable to ascertain creation of table in default database. Exiting.");
	}
}

public CP_Callback_Connect(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Clientprefs database connection failure: %s", error);
		SetFailState("Error while connecting to clientprefs database. Exiting.");
	}
	else
	{
		gH_CP_DataBase = hndl;
		
		SQL_TQuery(gH_CP_DataBase, CP_Callback_FindCookie, "SELECT id FROM sm_cookies WHERE name = 'TF2Jail_GuardBanned'");
	}
}

public CP_Callback_FindCookie(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Cookie query failure: %s", error);
	}
	else
	{
		new iRowCount = SQL_GetRowCount(hndl);
		if (iRowCount)
		{
			SQL_FetchRow(hndl);
			new CookieIDIndex = SQL_FetchInt(hndl, 0);
			if (debugging) LogMessage("found cookie index as %i", CookieIDIndex);
			g_iCookieIndex = CookieIDIndex;
		}
		else
		{
			LogError("Could not find the cookie index. Rageban functionality disabled.");
		}
	}
}

public OnMapStart()
{
   decl String:buffer[PLATFORM_MAX_PATH];
   GetConVarString(gH_Cvar_SoundName, gS_SoundPath, sizeof(gS_SoundPath));
   if (strcmp(gS_SoundPath, ""))
   {
		PrecacheSound(gS_SoundPath, true);
		Format(buffer, sizeof(buffer), "sound/%s", gS_SoundPath);
		AddFileToDownloadsTable(buffer);
   }
}

public OnAdminMenuReady(Handle:topmenu)
{
	if (topmenu == gH_TopMenu)
	{
		return;
	}
	
	gH_TopMenu = topmenu;
	
	new TopMenuObject:frequent_commands = FindTopMenuCategory(gH_TopMenu, "ts_commands");
	
	if (frequent_commands != INVALID_TOPMENUOBJECT)
	{
		AddToTopMenu(gH_TopMenu, 
			"sm_banguard",
			TopMenuObject_Item,
			AdminMenu_CTBan,
			frequent_commands,
			"sm_banguard",
			ADMFLAG_SLAY);
	}
	
	new TopMenuObject:player_commands = FindTopMenuCategory(gH_TopMenu, ADMINMENU_PLAYERCOMMANDS);
	
	if (player_commands != INVALID_TOPMENUOBJECT)
	{
		AddToTopMenu(gH_TopMenu, 
			"sm_rageban",
			TopMenuObject_Item,
			AdminMenu_RageBan,
			player_commands,
			"sm_rageban",
			ADMFLAG_SLAY);
		
		if (frequent_commands == INVALID_TOPMENUOBJECT)
		{
			AddToTopMenu(gH_TopMenu, 
				"sm_banguard",
				TopMenuObject_Item,
				AdminMenu_CTBan,
				player_commands,
				"sm_banguard",
				ADMFLAG_SLAY);		
		}
	}
}

public AdminMenu_CTBan(Handle:topmenu, 
					  TopMenuAction:action,
					  TopMenuObject:object_id,
					  param,
					  String:buffer[],
					  maxlength)
{
	if (action == TopMenuAction_DisplayOption)
	{
		Format(buffer, maxlength, "CT Ban");
	}
	else if (action == TopMenuAction_SelectOption)
	{
		DisplayCTBanPlayerMenu(param);
	}
}

DisplayCTBanPlayerMenu(client)
{
	new Handle:menu = CreateMenu(MenuHandler_CTBanPlayerList);
	
	SetMenuTitle(menu, "%T", "CT Ban Menu Title", client);
	SetMenuExitBackButton(menu, true);
	
	AddTargetsToMenu(menu, client, true, false);
	
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

DisplayCTBanTimeMenu(client, targetUserId)
{
	new Handle:menu = CreateMenu(MenuHandler_CTBanTimeList);

	SetMenuTitle(menu, "%T", "CT Ban Length Menu", client, GetClientOfUserId(targetUserId));
	SetMenuExitBackButton(menu, true);

	AddMenuItem(menu, "0", "Permanent");
	AddMenuItem(menu, "5", "5 Minutes");
	AddMenuItem(menu, "10", "10 Minutes");
	AddMenuItem(menu, "30", "30 Minutes");
	AddMenuItem(menu, "60", "1 Hour");
	AddMenuItem(menu, "120", "2 Hours");
	AddMenuItem(menu, "240", "4 Hours");

	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

DisplayCTBanReasonMenu(client)
{
	new Handle:menu = CreateMenu(MenuHandler_CTBanReasonList);

	SetMenuTitle(menu, "%T", "CT Ban Reason Menu", client, GetClientOfUserId(gA_CTBanTargetUserId[client]));
	SetMenuExitBackButton(menu, true);

	decl String:sMenuReason[128];
	Format(sMenuReason, sizeof(sMenuReason), "%T", "CT Ban Reason 1", client);
	AddMenuItem(menu, "1", sMenuReason);
	Format(sMenuReason, sizeof(sMenuReason), "%T", "CT Ban Reason 2", client);
	AddMenuItem(menu, "2", sMenuReason);
	Format(sMenuReason, sizeof(sMenuReason), "%T", "CT Ban Reason 3", client);
	AddMenuItem(menu, "3", sMenuReason);
	Format(sMenuReason, sizeof(sMenuReason), "%T", "CT Ban Reason 4", client);
	AddMenuItem(menu, "4", sMenuReason);
	Format(sMenuReason, sizeof(sMenuReason), "%T", "CT Ban Reason 5", client);
	AddMenuItem(menu, "5", sMenuReason);
	Format(sMenuReason, sizeof(sMenuReason), "%T", "CT Ban Reason 6", client);
	AddMenuItem(menu, "6", sMenuReason);
	Format(sMenuReason, sizeof(sMenuReason), "%T", "CT Ban Reason 7", client);
	AddMenuItem(menu, "7", sMenuReason);

	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public MenuHandler_CTBanReasonList(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && gH_TopMenu != INVALID_HANDLE)
		{
			DisplayTopMenu(gH_TopMenu, param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		decl String:sBanChoice[10];
		GetMenuItem(menu, param2, sBanChoice, sizeof(sBanChoice));
		new iBanReason = StringToInt(sBanChoice);
		new iTimeToBan = gA_CTBanTimeLength[param1];
		new iTargetIndex = GetClientOfUserId(gA_CTBanTargetUserId[param1]);
		
		decl String:sBanned[3];
		GetClientCookie(iTargetIndex, g_CT_Cookie, sBanned, sizeof(sBanned));
		new banFlag = StringToInt(sBanned);
		if (!banFlag)
		{
			PerformCTBan(iTargetIndex, param1, iTimeToBan, iBanReason);
		}
		else
		{
			PrintToChat(param1, CHAT_BANNER, "Already CT Banned", iTargetIndex);
		}
	}
}

public MenuHandler_CTBanPlayerList(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && gH_TopMenu != INVALID_HANDLE)
		{
			DisplayTopMenu(gH_TopMenu, param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		decl String:info[32];
		new userid, target;
		
		GetMenuItem(menu, param2, info, sizeof(info));
		userid = StringToInt(info);

		if ((target = GetClientOfUserId(userid)) == 0)
		{
			PrintToChat(param1, "%s %t", CHAT_BANNER, "Player no longer available");
		}
		else if (!CanUserTarget(param1, target))
		{
			PrintToChat(param1, "%s %t", CHAT_BANNER, "Unable to target");
		}
		else
		{
			gA_CTBanTargetUserId[param1] = userid;
			DisplayCTBanTimeMenu(param1, userid);
		}
	}
}

public MenuHandler_CTBanTimeList(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && gH_TopMenu != INVALID_HANDLE)
		{
			DisplayTopMenu(gH_TopMenu, param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		decl String:info[32];
		GetMenuItem(menu, param2, info, sizeof(info));
		new iTimeToBan = StringToInt(info);
		gA_CTBanTimeLength[param1] = iTimeToBan;
		DisplayCTBanReasonMenu(param1);
	}
}

public OnPluginEnd()
{
	for (new client = 1; client <= MaxClients; client++)
	{
		if (g_Handles[client] != INVALID_HANDLE)
		{
			CloseHandle(g_Handles[client]);
			g_Handles[client] = INVALID_HANDLE;
		}
	}
}

public OnClientPostAdminCheck(client)
{
	if (GetConVarBool(gH_Cvar_Enabled))
	{
		g_Handles[client] = INVALID_HANDLE;
		CreateTimer(0.0, CheckBanCookies, client, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public OnClientDisconnect(client)
{
	decl String:sDisconnectSteamID[22];
	GetClientAuthString(client, sDisconnectSteamID, sizeof(sDisconnectSteamID));
	
	if (g_Handles[client] != INVALID_HANDLE)
	{
		CloseHandle(g_Handles[client]);
		g_Handles[client] = INVALID_HANDLE;
	}
	
	decl String:sName[MAX_TARGET_LENGTH];
	GetClientName(client, sName, sizeof(sName));
	
	if (FindStringInArray(gA_DSteamIDs, sDisconnectSteamID) == -1)
	{
		PushArrayString(gA_DNames, sName);
		PushArrayString(gA_DSteamIDs, sDisconnectSteamID);
		
		if (GetArraySize(gA_DNames) >= 7)
		{
			RemoveFromArray(gA_DNames, 0);
			RemoveFromArray(gA_DSteamIDs, 0);
		}
	}
	
	new iBannedArrayIndex = FindValueInArray(gA_TimedBanLocalList, client);
	if (iBannedArrayIndex != -1)
	{
		RemoveFromArray(gA_TimedBanLocalList, iBannedArrayIndex);
		
		new Handle:ClientDisconnectPack = CreateDataPack();
		WritePackCell(ClientDisconnectPack, client);
		WritePackString(ClientDisconnectPack, sDisconnectSteamID);
		
		#if USESQL == 1
		decl String:query[255];
		Format(query, sizeof(query), "SELECT ban_time FROM %s WHERE steamid = '%s'", g_sTimesTableName, sDisconnectSteamID);
		SQL_TQuery(gH_BanDatabase, DB_Callback_ClientDisconnect, query, ClientDisconnectPack);
		
		#else
		
		new iSteamArrayIndex = FindStringInArray(gA_TimedBanSteamList, sDisconnectSteamID);
		if (iSteamArrayIndex != -1)
		{
			if (gA_LocalTimeRemaining[client] <= 0)
			{
				RemoveFromArray(gA_TimedBanSteamList, iSteamArrayIndex);
			}
			else
			{
				SetArrayCell(gA_TimedBanSteamList, iSteamArrayIndex, gA_LocalTimeRemaining[client], 22);
			}
		}
		#endif
	}
}

public DB_Callback_ClientDisconnect(Handle:owner, Handle:hndl, const String:error[], any:thePack)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error with query on client disconnect: %s", error);
		CloseHandle(thePack);
	}
	else
	{
		ResetPack(thePack);
		new client = ReadPackCell(thePack);
		decl String:sAuthID[22];
		ReadPackString(thePack, sAuthID, sizeof(sAuthID));
		
		new iRowCount = SQL_GetRowCount(hndl);
		if (iRowCount)
		{
			if (debugging)
			{
				SQL_FetchRow(hndl);
				new iBanTimeRemaining = SQL_FetchInt(hndl, 0);

				if (IsClientInGame(client))
				{
					LogMessage("SQL: %N disconnected with %i time remaining on ban", client, iBanTimeRemaining);
				}
				else
				{
					LogMessage("SQL: %i client index disconnected with %i time remaining on ban", client, iBanTimeRemaining);
				}
			}

			if (gA_LocalTimeRemaining[client] <= 0)
			{
				decl String:query[255];
				Format(query, sizeof(query), "DELETE FROM %s WHERE steamid = '%s'", g_sTimesTableName, sAuthID);
				SQL_TQuery(gH_BanDatabase, DB_Callback_DisconnectAction, query);
				Format(query, sizeof(query), "UPDATE %s SET timeleft=-1 WHERE offender_steamid = '%s' AND timeleft >= 0", g_sLogTableName, sAuthID);
				SQL_TQuery(gH_BanDatabase, DB_Callback_DisconnectAction, query);
			}
			else
			{
				decl String:query[255];
				Format(query, sizeof(query), "UPDATE %s SET ban_time = %d WHERE steamid = '%s'", g_sTimesTableName, gA_LocalTimeRemaining[client], sAuthID);
				SQL_TQuery(gH_BanDatabase, DB_Callback_DisconnectAction, query);
				Format(query, sizeof(query), "UPDATE %s SET timeleft = %d WHERE offender_steamid = '%s' AND timeleft >= 0", g_sLogTableName, gA_LocalTimeRemaining[client], sAuthID);
				SQL_TQuery(gH_BanDatabase, DB_Callback_DisconnectAction, query);
			}
		}
	}
}

public DB_Callback_DisconnectAction(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error with updating/deleting record after client disconnect: %s", error);
	}
}

public Action:CheckBanCookies(Handle:timer, any: client)
{
	if (AreClientCookiesCached(client))
	{
		ProcessBanCookies(client);
	}
	else if (IsClientInGame(client))
	{
		CreateTimer(5.0, CheckBanCookies, client, TIMER_FLAG_NO_MAPCHANGE);
	}
}

ProcessBanCookies(client)
{
	if (client && IsClientInGame(client))
	{
		decl String:cookie[32];
		GetClientCookie(client, g_CT_Cookie, cookie, sizeof(cookie));
		
		if (StrEqual(cookie, "1")) 
		{
			if (GetClientTeam(client) == _:TFTeam_Blue)
			{
				if (IsPlayerAlive(client))
				{
					new wepIdx;
					for (new i; i < 4; i++)
					{
						if ((wepIdx = GetPlayerWeaponSlot(client, i)) != -1)
						{
							RemovePlayerItem(client, wepIdx);
							AcceptEntityInput(wepIdx, "Kill");
						}
					}
				
					ForcePlayerSuicide(client);
				}
				
				ChangeClientTeam(client, _:TFTeam_Red);
				PrintToChat(client, CHAT_BANNER, "Enforcing CT Ban");
			}		
		}
	}
}

public Action:Command_UnCTBan(client, args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "%s Usage: sm_unctban <player>", CHAT_BANNER);
	}
	else
	{
		decl String:target[64];
		GetCmdArg(1, target, sizeof(target));
		
		decl String:clientName[MAX_TARGET_LENGTH], target_list[MAXPLAYERS], target_count, bool:tn_is_ml;
		target_count = ProcessTargetString(target, client, target_list, MAXPLAYERS, 0, clientName, sizeof(clientName), tn_is_ml);
		if (target_count != 1)
		{
			ReplyToTargetError(client, target_count);
		}
		else
		{
			if (AreClientCookiesCached(target_list[0]))
			{
				Remove_CTBan(client, target_list[0]);
			}
			else
			{
				ReplyToCommand(client, CHAT_BANNER, "Cookie Status Unavailable");
			}
		}	
	}
	
	return Plugin_Handled;
}

Remove_CTBan(adminIndex, targetIndex, bExpired=false)
{
	decl String:isBanned[3];
	GetClientCookie(targetIndex, g_CT_Cookie, isBanned, sizeof(isBanned));
	new banFlag = StringToInt(isBanned);
	
	if (banFlag)
	{
		decl String:targetSteam[22];
		GetClientAuthString(targetIndex, targetSteam, sizeof(targetSteam));
		
		#if USESQL == 1
		decl String:logQuery[350];
		Format(logQuery, sizeof(logQuery), "UPDATE %s SET timeleft=-1 WHERE offender_steamid = '%s' and timeleft >= 0", g_sLogTableName, targetSteam);

		if (debugging) LogMessage("log query: %s", logQuery);

		SQL_TQuery(gH_BanDatabase, DB_Callback_RemoveCTBan, logQuery, targetIndex);
		#endif
		
		LogMessage("%N has removed the CT ban on %N (%s).", adminIndex, targetIndex, targetSteam);
		
		if (!bExpired)
		{
			ShowActivity2(adminIndex, CHAT_BANNER, "%t", "CT Ban Removed", targetIndex);
		}
		else
		{
			ShowActivity2(adminIndex, CHAT_BANNER, "%t", "CT Ban Auto Removed", targetIndex);
		}
		
		decl String:query[255];
		Format(query, sizeof(query), "DELETE FROM %s WHERE steamid = '%s'", g_sTimesTableName, targetSteam);
		SQL_TQuery(gH_BanDatabase, DB_Callback_RemoveCTBan, query, targetIndex);	
	}
	
	SetClientCookie(targetIndex, g_CT_Cookie, "0");
}

public DB_Callback_RemoveCTBan(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error handling steamID after CT ban removal: %s", error);
	}
	else
	{
		if (debugging && IsClientInGame(client))
		{
			LogMessage("CTBan on %N was removed in SQL", client);
		}
		else if (debugging	 && !IsClientInGame(client))
		{
			LogMessage("CTBan on --- was removed in SQL");
		}
	}
}

public Action:Command_CTBan(client, args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "%s Usage: sm_banguard <player> <time> <reason>", CHAT_BANNER);
	}
	else
	{
		new numArgs = GetCmdArgs();
		decl String:target[64];
		GetCmdArg(1, target, sizeof(target));
		decl String:sBanTime[16];
		GetCmdArg(2, sBanTime, sizeof(sBanTime));
		new iBanTime = StringToInt(sBanTime);
		new String:sReasonStr[200];
		decl String:sArgPart[200];
		for (new arg = 3; arg <= numArgs; arg++)
		{
			GetCmdArg(arg, sArgPart, sizeof(sArgPart));
			Format(sReasonStr, sizeof(sReasonStr), "%s %s", sReasonStr, sArgPart);
		}
		
		decl String:clientName[MAX_TARGET_LENGTH], target_list[MAXPLAYERS], target_count, bool:tn_is_ml;
		target_count = ProcessTargetString(target, client, target_list, MAXPLAYERS, 0, clientName, sizeof(clientName), tn_is_ml);
		if ((target_count != 1))
		{
			ReplyToTargetError(client, target_count);
		}
		else
		{
			if (target_list[0] && IsClientInGame(target_list[0]))
			{
				if (AreClientCookiesCached(target_list[0]))
				{
					decl String:isBanned[3];
					GetClientCookie(target_list[0], g_CT_Cookie, isBanned, sizeof(isBanned));
					new banFlag = StringToInt(isBanned);	
					if (banFlag)
					{
						ReplyToCommand(client, CHAT_BANNER, "Already CT Banned", target_list[0]);
					}
					else
					{
						PerformCTBan(target_list[0], client, iBanTime, _, sReasonStr);
					}
				}
				else
				{
					ReplyToCommand(client, CHAT_BANNER, "Cookie Status Unavailable");
				}
			}				
		}
	}
	return Plugin_Handled;
}

PerformCTBan(client, adminclient, banTime=0, reason=0, String:manualReason[]="")
{
	SetClientCookie(client, g_CT_Cookie, "1");
	
	decl String:targetSteam[22];
	GetClientAuthString(client, targetSteam, sizeof(targetSteam));

	if (GetClientTeam(client) == _:TFTeam_Blue)
	{
		if (IsPlayerAlive(client))
		{
			ForcePlayerSuicide(client);
		}
		ChangeClientTeam(client, _:TFTeam_Red);
	}
	
	decl String:sReason[128];
	if (strlen(manualReason) > 0)
	{
		Format(sReason, sizeof(sReason), "%s", manualReason);
	}
	else
	{		
		switch (reason)
		{
			case 1:
			{
				Format(sReason, sizeof(sReason), "%T", "CT Ban Reason 1", adminclient);
			}
			case 2:
			{
				Format(sReason, sizeof(sReason), "%T", "CT Ban Reason 2", adminclient);
			}
			case 3:
			{
				Format(sReason, sizeof(sReason), "%T", "CT Ban Reason 3", adminclient);
			}
			case 4:
			{
				Format(sReason, sizeof(sReason), "%T", "CT Ban Reason 4", adminclient);
			}
			case 5:
			{
				Format(sReason, sizeof(sReason), "%T", "CT Ban Reason 5", adminclient);
			}
			case 6:
			{
				Format(sReason, sizeof(sReason), "%T", "CT Ban Reason 6", adminclient);
			}
			case 7:
			{
				Format(sReason, sizeof(sReason), "%T", "CT Ban Reason 7", adminclient);
			}
			default:
			{
				Format(sReason, sizeof(sReason), "No reason given.");
			}
		}
	}
	
	new timestamp = GetTime();
	
	if (adminclient && IsClientInGame(adminclient))
	{
		decl String:adminSteam[32];
		GetClientAuthString(adminclient, adminSteam, sizeof(adminSteam));
		
		#if USESQL == 1
		decl String:logQuery[350];
		Format(logQuery, sizeof(logQuery), "INSERT INTO %s (timestamp, offender_steamid, offender_name, admin_steamid, admin_name, bantime, timeleft, reason) VALUES (%d, '%s', '%N', '%s', '%N', %d, %d, '%s')", g_sLogTableName, timestamp, targetSteam, client, adminSteam, adminclient, banTime, banTime, sReason);
		if (debugging)	LogMessage("log query: %s", logQuery);
		SQL_TQuery(gH_BanDatabase, DB_Callback_CTBan, logQuery, client);
		#endif
		LogMessage("%N (%s) has issued a CT ban on %N (%s) for %d minutes for %s.", adminclient, adminSteam, client, targetSteam, banTime, sReason);
	}
	else
	{
		#if USESQL == 1
		decl String:logQuery[350];
		Format(logQuery, sizeof(logQuery), "INSERT INTO %s (timestamp, offender_steamid, offender_name, admin_steamid, admin_name, bantime, reason) VALUES (%d, '%s', '%N', 'STEAM_0:1:1', 'Console', %d, %d, '%s')", g_sLogTableName, timestamp, targetSteam, client, banTime, banTime, sReason);
		if (debugging)	LogMessage("log query: %s", logQuery);
		SQL_TQuery(gH_BanDatabase, DB_Callback_CTBan, logQuery, client);
		#endif
		LogMessage("Console has issued a CT ban on %N (%s) for %d.", client, targetSteam, banTime);
	}

	if (banTime > 0)
	{
		ShowActivity2(adminclient, CHAT_BANNER, "%t", "Temporary CT Ban", client, banTime);
		PushArrayCell(gA_TimedBanLocalList, client);
		gA_LocalTimeRemaining[client] = banTime;
		
		#if USESQL == 1
		decl String:query[255];
		Format(query, sizeof(query), "INSERT INTO %s (steamid, ban_time) VALUES ('%s', %d)", g_sTimesTableName, targetSteam, banTime);
		if (debugging)	LogMessage("ctban query: %s", query);
		SQL_TQuery(gH_BanDatabase, DB_Callback_CTBan, query, client);
		
		#else
		
		new iSteamArrayIndex = PushArrayString(gA_TimedBanSteamList, targetSteam);
		SetArrayCell(gA_TimedBanSteamList, iSteamArrayIndex, banTime, 22);
		#endif
	}
	else
	{
		ShowActivity2(adminclient, CHAT_BANNER, "%t", "Permanent CT Ban", client);	
	}
}

public DB_Callback_CTBan(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error writing CTBan to Timed Ban database: %s", error);
	}
	else
	{
		if (debugging && IsClientInGame(client))
		{
			LogMessage("SQL CTBan: Updated database with CT Ban for %N", client);
		}
	}
}

public Action:Command_IsCTBanned(client, args)
{
	if ((args < 1) || !args)
	{
		ReplyToCommand(client, "%s Usage: sm_isbanned <player>", CHAT_BANNER);
	}
	else
	{
		decl String:target[64];
		GetCmdArg(1, target, sizeof(target));
		
		decl String:clientName[MAX_TARGET_LENGTH], target_list[MAXPLAYERS], target_count, bool:tn_is_ml;
		target_count = ProcessTargetString(target, client, target_list, MAXPLAYERS, 0, clientName, sizeof(clientName), tn_is_ml);
		if (target_count != 1) 
		{
			ReplyToTargetError(client, target_count);
		}
		else
		{
			if (target_list[0] && IsClientInGame(target_list[0]))
			{
				if (AreClientCookiesCached(target_list[0]))
				{
					decl String:isBanned[3];
					GetClientCookie(target_list[0], g_CT_Cookie, isBanned, sizeof(isBanned));
					new banFlag = StringToInt(isBanned);	
					if (banFlag)
					{
						if (gA_LocalTimeRemaining[target_list[0]] <= 0)
						{
							ReplyToCommand(client, CHAT_BANNER, "Permanent CT Ban", target_list[0]);
						}
						else
						{
							ReplyToCommand(client, CHAT_BANNER, "Temporary CT Ban", target_list[0], gA_LocalTimeRemaining[target_list[0]]);
						}
					}
					else
					{
						ReplyToCommand(client, CHAT_BANNER, "Not CT Banned", target_list[0]);
					}
				}
				else
				{
					ReplyToCommand(client, CHAT_BANNER, "Cookie Status Unavailable");	
				}
			}
			else
			{
				ReplyToCommand(client, CHAT_BANNER, "Unable to target");
			}				
		}
	}
	
	return Plugin_Handled;
}

public Action:PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	new team = GetClientTeam(client);
	
	if (IsClientInGame(client) && IsPlayerAlive(client) && GetConVarBool(gH_Cvar_Enabled))
	{
		decl String:sCookie[5];
		GetClientCookie(client, g_CT_Cookie, sCookie, sizeof(sCookie));
		new iBanStatus = StringToInt(sCookie);
		
		decl String:BanMsg[100];
		GetConVarString(gH_Cvar_JoinBanMessage, BanMsg, sizeof(BanMsg));
		
		if (team == _:TFTeam_Blue && iBanStatus)
		{
			PrintCenterText(client, "%t", "Enforcing CT Ban");
			PrintToChat(client, "%t", BanMsg);
			ChangeClientTeam(client, _:TFTeam_Red);
		}
	}
}

bool:IsSetAuthIdNativePresent()
{
	if (GetFeatureStatus(FeatureType_Native, "SetAuthIdCookie") == FeatureStatus_Available)
	{
		return true;
	}
	return false;
}