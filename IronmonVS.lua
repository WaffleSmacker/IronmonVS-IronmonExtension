local function IronmonVS()
	local self = {
		version = "1.29",
		name = "Ironmon VS",
		author = "WaffleSmacker",
		description = "Created for Ironmon VS. Used to send data to the website.",
		github = "WaffleSmacker/IronmonVS-IronmonExtension",
	}

	self.url = string.format("https://github.com/%s", self.github)

	-- Executed when the user clicks the "Check for Updates" button while viewing the extension details within the Tracker's UI
	function self.checkForUpdates()
		local versionCheckUrl = string.format("https://api.github.com/repos/%s/releases/latest", self.github)
		local versionResponsePattern = '"tag_name":%s+"%w+(%d+%.%d+)"' -- matches "1.0" in "tag_name": "v1.0"
		local downloadUrl = string.format("https://github.com/%s/releases/latest", self.github)
		local compareFunc = function(a, b) return a ~= b and not Utils.isNewerVersion(a, b) end -- if current version is *older* than online version
		local isUpdateAvailable = Utils.checkForVersionUpdate(versionCheckUrl, self.version, versionResponsePattern, compareFunc)
		return isUpdateAvailable, downloadUrl
	end

	-- Launch the bundled monitor exe (or open the folder if it's missing). Shared by the
	-- extension's "Options" button and the on-screen "monitor not running" warning button.
	function self.launchMonitor()
		if not Main.IsOnBizhawk() then return end

		-- Get the IronmonVS folder path (one level deeper from extensions folder)
		local extFolderPath = FileManager.getCustomFolderPath() .. "IronmonVS" .. FileManager.slash
		local monitorExePath = extFolderPath .. "IronmonVsMonitor.exe"

		-- Try to launch the monitor program directly
		-- If it doesn't exist, open the folder instead so user can see what's there
		local file = io.open(monitorExePath, "r")
		if file then
			-- Monitor exe exists, launch it
			file:close()
			-- Use start command on Windows to launch the exe
			os.execute('start "" "' .. monitorExePath .. '"')
		else
			-- Monitor exe doesn't exist, open the folder in explorer
			os.execute('explorer "' .. extFolderPath .. '"')
		end
	end

	-- Executed when the user clicks the "Options" button while viewing the extension details within the Tracker's UI
	function self.configureOptions()
		self.launchMonitor()
	end

	-- Data output file path
	self.DATA_OUTPUT_FILE = "ironmon_data.json"

	-- Heartbeat the IronmonVsMonitor refreshes (epoch seconds). If it's stale or missing,
	-- the monitor isn't running and runs are NOT being recorded, so we warn on-screen.
	self.HEARTBEAT_FILE = "monitor_heartbeat"
	self.HEARTBEAT_STALE_SECONDS = 12

	-- Current-seed display the monitor writes (order + full seed of the seed in play).
	self.SEED_DISPLAY_FILE = "current_seed.txt"

	self.Paths = {
		DataOutput = "",
		Heartbeat = "",
		SeedDisplay = "",
	}

	-- Cached current-seed info (read throttled from SEED_DISPLAY_FILE).
	self.SeedInfo = { order = nil, seed = nil, total = nil, lastRead = 0 }

	-- Wrong-seed detection: compares the loaded ROM's seed against the expected competition
	-- seed. The expected seed (current_seed.txt) is written by the wrapper jar atomically with
	-- ROM generation, so it never lags a New Run -- only a tiny debounce is needed, making the
	-- warning appear essentially as soon as the loaded seed can be read.
	self.WRONG_SEED_GRACE = 1
	self.WrongSeed = false
	self.LoadedSeed = { value = nil, lastRead = 0 }
	self.SeedCheck = { lastCheck = 0, mismatchSince = nil, lastLoaded = nil, lastExpected = nil }

	-- Monitor-running warning state (throttled file check + current verdict).
	self.MonitorWarn = {
		active = false,
		lastCheck = 0,
		mouseWasDown = false,  -- for click edge-detection on the warning's button
	}

	-- Clickable "Open Monitor" button inside the warning banner (game-screen coords).
	self.WarnButton = { x = 6, y = 23, w = 150, h = 13 }

	-- Milestone order from lowest to highest
	self.MILESTONE_ORDER = {
		"lab",
		"brock",
		"misty", 
		"surge",
		"erika",
		"koga",
		"sabrina",
		"blaine",
		"giovanni",
		"lorelei",
		"bruno",
		"agatha",
		"lance",
		"champ"
	}

	self.MILESTONE_NAMES = {
		lab = "Lab",
		brock = "Brock",
		misty = "Misty",
		surge = "Lt. Surge", 
		erika = "Erika",
		koga = "Koga",
		sabrina = "Sabrina",
		blaine = "Blaine",
		giovanni = "Giovanni",
		lorelei = "Lorelei",
		bruno = "Bruno",
		agatha = "Agatha",
		lance = "Lance",
		champ = "Champion"
	}

	-- Dungeons to track for full clears
	self.DUNGEONS = {
		"MtMoon",
		"RockTunnel",
		"SilphCo",
		"RocketHideout",
		"SSAnne",
		"VictoryRoad",
		"PokemonTower",
		"CinnabarMansion"
	}

	-- First-time setup: patch the player's own FireRed into the IronmonVS base ROM and create a
	-- Tracker "Generate ROM each time" New Run profile (see the FIRST-TIME SETUP section below).
	-- Constants are verified against the shipped RomPatch/IronMonVS.ips.
	self.Setup = {
		patchedName = "PokemonFireRed (IronMonVS).gba", -- base ROM we write (ZX randomizes it each seed)
		stateFile   = "setup_state.json",               -- our tiny idempotency record
		rulesName   = "FRLG Kaizo.rnqs",                -- ships with the Tracker
		profileName = "IronmonVS",
		version     = 1,           -- bump when the base ROM / IPS changes, to force a re-patch
		romSize     = 16777216,    -- 16MB FireRed
		baseAdler   = 0x68b4b387,  -- adler32 of the correctly-patched IronmonVS base ROM
		sourceAdler = 0x57240b31,  -- adler32 of the expected vanilla FireRed (USA) source
		ready       = false,       -- set true by self.checkSetup() once everything is in place
		warnActive  = false,       -- show the "Set up IronmonVS" banner
		Button      = { x = 6, y = 23, w = 150, h = 13 },
	}
	self.SetupPaths = {}   -- absolute paths, resolved in self.startup()

	-- Function to escape JSON strings
	local function escapeJson(str)
		if not str then return "" end
		str = tostring(str)
		str = string.gsub(str, "\\", "\\\\")
		str = string.gsub(str, '"', '\\"')
		str = string.gsub(str, "\n", "\\n")
		str = string.gsub(str, "\r", "\\r")
		str = string.gsub(str, "\t", "\\t")
		return str
	end

	-- Minimal JSON encoder for the nested "extra" payload (scalars + arrays + objects).
	-- A table with contiguous 1..n keys encodes as an array; otherwise as an object.
	local function encodeJson(v)
		local t = type(v)
		if v == nil then
			return "null"
		elseif t == "boolean" then
			return v and "true" or "false"
		elseif t == "number" then
			if v ~= v or v == math.huge or v == -math.huge then return "null" end
			if v == math.floor(v) then return string.format("%d", v) end
			return tostring(v)
		elseif t == "string" then
			return '"' .. escapeJson(v) .. '"'
		elseif t == "table" then
			local n = 0
			for _ in pairs(v) do n = n + 1 end
			if n == 0 then return "[]" end
			if #v == n then
				local parts = {}
				for i = 1, n do parts[i] = encodeJson(v[i]) end
				return "[" .. table.concat(parts, ",") .. "]"
			end
			local parts = {}
			for k, val in pairs(v) do
				parts[#parts + 1] = '"' .. escapeJson(tostring(k)) .. '":' .. encodeJson(val)
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
		return "null"
	end

	-- Get dungeon trainer counts
	local function getDungeonTrainerCounts(areaName)
		if not RouteData.CombinedAreas or not RouteData.CombinedAreas[areaName] then
			return nil, 0, 0, "Area not found in RouteData.CombinedAreas"
		end
		
		-- Get the map ID list from CombinedAreas (this is a table of map IDs)
		local mapIdList = RouteData.CombinedAreas[areaName]
		if not mapIdList or type(mapIdList) ~= "table" then
			return nil, 0, 0, "Area does not contain valid map ID list"
		end
		
		-- Get save block address once for efficiency
		local saveBlock1Addr = Utils.getSaveBlock1Addr()
		
		-- Pass the map ID list to the function (not the area name string)
		local defeatedTrainers, totalTrainers = Program.getDefeatedTrainersByCombinedArea(mapIdList, saveBlock1Addr)
		
		if defeatedTrainers and totalTrainers then
			local defeatedCount = #defeatedTrainers
			local totalCount = totalTrainers
			local isFullCleared = defeatedCount == totalCount and totalCount > 0
			return defeatedTrainers, defeatedCount, totalCount, isFullCleared and "FULLY CLEARED" or "NOT CLEARED"
		end
		
		return nil, 0, 0, "Failed to get trainer data"
	end

	-- Function to write data to JSON file
	local function writeDataToFile(data)
		local file = io.open(self.Paths.DataOutput, "w")
		if not file then
			return false, "Failed to open data file for writing"
		end
		
		-- Build JSON object
		local jsonContent = "{\n"
		jsonContent = jsonContent .. '  "seedNumber": ' .. tostring(data.seedNumber) .. ",\n"
		jsonContent = jsonContent .. '  "playTime": "' .. escapeJson(data.playTime) .. '",\n'
		jsonContent = jsonContent .. '  "currentDate": "' .. escapeJson(data.currentDate) .. '",\n'
		jsonContent = jsonContent .. '  "pokemonName": "' .. escapeJson(data.pokemonName) .. '",\n'
		jsonContent = jsonContent .. '  "pokemonID": ' .. tostring(data.pokemonID) .. ",\n"
		jsonContent = jsonContent .. '  "nickname": "' .. escapeJson(data.nickname or "") .. '",\n'
		jsonContent = jsonContent .. '  "type_1": "' .. escapeJson(data.type_1) .. '",\n'
		jsonContent = jsonContent .. '  "type_2": "' .. escapeJson(data.type_2) .. '",\n'
		jsonContent = jsonContent .. '  "level": ' .. tostring(data.level) .. ",\n"
		jsonContent = jsonContent .. '  "hp": ' .. tostring(data.hp) .. ",\n"
		jsonContent = jsonContent .. '  "atk": ' .. tostring(data.atk) .. ",\n"
		jsonContent = jsonContent .. '  "def": ' .. tostring(data.def) .. ",\n"
		jsonContent = jsonContent .. '  "spa": ' .. tostring(data.spa) .. ",\n"
		jsonContent = jsonContent .. '  "spd": ' .. tostring(data.spd) .. ",\n"
		jsonContent = jsonContent .. '  "spe": ' .. tostring(data.spe) .. ",\n"
		jsonContent = jsonContent .. '  "abilityName": "' .. escapeJson(data.abilityName) .. '",\n'
		jsonContent = jsonContent .. '  "move_1": "' .. escapeJson(data.move_1) .. '",\n'
		jsonContent = jsonContent .. '  "move_2": "' .. escapeJson(data.move_2) .. '",\n'
		jsonContent = jsonContent .. '  "move_3": "' .. escapeJson(data.move_3) .. '",\n'
		jsonContent = jsonContent .. '  "move_4": "' .. escapeJson(data.move_4) .. '",\n'
		jsonContent = jsonContent .. '  "milestone": "' .. escapeJson(data.milestone or "none") .. '",\n'
		jsonContent = jsonContent .. '  "isOngoingRun": ' .. tostring(data.isOngoingRun) .. ",\n"
		jsonContent = jsonContent .. '  "favoritePokemon": "' .. escapeJson(data.favoritePokemon or "None") .. '",\n'
		jsonContent = jsonContent .. '  "trainersDefeated": ' .. tostring(data.trainerCount or 0) .. ",\n"
		jsonContent = jsonContent .. '  "beat_lab": ' .. tostring(data.beat_lab) .. ",\n"
		jsonContent = jsonContent .. '  "beat_brock": ' .. tostring(data.beat_brock) .. ",\n"
		jsonContent = jsonContent .. '  "beat_misty": ' .. tostring(data.beat_misty) .. ",\n"
		jsonContent = jsonContent .. '  "beat_surge": ' .. tostring(data.beat_surge) .. ",\n"
		jsonContent = jsonContent .. '  "beat_erika": ' .. tostring(data.beat_erika) .. ",\n"
		jsonContent = jsonContent .. '  "beat_koga": ' .. tostring(data.beat_koga) .. ",\n"
		jsonContent = jsonContent .. '  "beat_sabrina": ' .. tostring(data.beat_sabrina) .. ",\n"
		jsonContent = jsonContent .. '  "beat_blaine": ' .. tostring(data.beat_blaine) .. ",\n"
		jsonContent = jsonContent .. '  "beat_giovanni": ' .. tostring(data.beat_giovanni) .. ",\n"
		jsonContent = jsonContent .. '  "beat_lorelei": ' .. tostring(data.beat_lorelei) .. ",\n"
		jsonContent = jsonContent .. '  "beat_bruno": ' .. tostring(data.beat_bruno) .. ",\n"
		jsonContent = jsonContent .. '  "beat_agatha": ' .. tostring(data.beat_agatha) .. ",\n"
		jsonContent = jsonContent .. '  "beat_lance": ' .. tostring(data.beat_lance) .. ",\n"
		jsonContent = jsonContent .. '  "beat_champ": ' .. tostring(data.beat_champ) .. ",\n"
		jsonContent = jsonContent .. '  "trainerCount": ' .. tostring(data.trainerCount or 0) .. ",\n"
		jsonContent = jsonContent .. '  "badgeCount": ' .. tostring(data.badgeCount or 0) .. ",\n"
		jsonContent = jsonContent .. '  "routeName": "' .. escapeJson(data.routeName or "Unknown Area") .. '",\n'
		jsonContent = jsonContent .. '  "fullClear_MtMoon": ' .. tostring(data.fullClear_MtMoon or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_RockTunnel": ' .. tostring(data.fullClear_RockTunnel or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_SilphCo": ' .. tostring(data.fullClear_SilphCo or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_RocketHideout": ' .. tostring(data.fullClear_RocketHideout or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_SSAnne": ' .. tostring(data.fullClear_SSAnne or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_VictoryRoad": ' .. tostring(data.fullClear_VictoryRoad or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_PokemonTower": ' .. tostring(data.fullClear_PokemonTower or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_CinnabarMansion": ' .. tostring(data.fullClear_CinnabarMansion or false) .. ",\n"
		jsonContent = jsonContent .. '  "RandomSeed": ' .. (data.RandomSeed and tostring(data.RandomSeed) or "null") .. ",\n"
		-- Encode the nested extra payload defensively: never let it corrupt the data file.
		local extraJson = "null"
		local okExtra, encoded = pcall(encodeJson, data.extra)
		if okExtra and encoded then extraJson = encoded end
		jsonContent = jsonContent .. '  "extra": ' .. extraJson .. "\n"
		jsonContent = jsonContent .. "}"
		
		file:write(jsonContent)
		file:close()
		return true, ""
	end

	------------------------------------ Data Tracking Section ------------------------------------
	local function getTotalDefeatedTrainers(includeSevii)
		includeSevii = includeSevii or false
		local saveBlock1Addr = Utils.getSaveBlock1Addr()
		local totalDefeated = 0

		for mapId, route in pairs(RouteData.Info or {}) do
			if mapId and (mapId < 230 or includeSevii) then
				if route.trainers and #route.trainers > 0 then
					local defeatedTrainers = Program.getDefeatedTrainersByLocation(mapId, saveBlock1Addr)
					if type(defeatedTrainers) == "table" then
						totalDefeated = totalDefeated + #defeatedTrainers
					end
				end
			end
		end

		return totalDefeated
	end
	local function getPokemonOrDefault(input)
		local id
		if not Utils.isNilOrEmpty(input, true) then
			id = DataHelper.findPokemonId(input)
		else
			local pokemon = Tracker.getPokemon(1, true) or {}
			id = pokemon.pokemonID
		end
		return PokemonData.Pokemon[id or false]
	end

	-- Get favorite Pokemon name from StreamerScreen button (first favorite only)
	local function getFavoritePokemonName()
		local faveButton = StreamerScreen.Buttons.PokemonFavorite1
		
		if faveButton and faveButton.pokemonID and PokemonData.isValid(faveButton.pokemonID) then
			return PokemonData.Pokemon[faveButton.pokemonID].name
		else
			return "None"
		end
	end

	-- Check if a dungeon is fully cleared (all trainers defeated)
	local function isDungeonFullCleared(areaName)
		local _, defeatedCount, totalCount, _ = getDungeonTrainerCounts(areaName)
		return defeatedCount == totalCount and totalCount > 0
	end

	-- Get all dungeon full clear statuses
	local function getDungeonFullClears()
		local dungeonClears = {}
		for _, dungeonName in ipairs(self.DUNGEONS) do
			dungeonClears[dungeonName] = isDungeonFullCleared(dungeonName)
		end
		return dungeonClears
	end

	-- Get the highest milestone achieved
	local function getHighestMilestone()
		local beat_lab = Program.hasDefeatedTrainer(326) or Program.hasDefeatedTrainer(327) or Program.hasDefeatedTrainer(328)
		local beat_brock = Program.hasDefeatedTrainer(414)
		local beat_misty = Program.hasDefeatedTrainer(415)
		local beat_surge = Program.hasDefeatedTrainer(416)
		local beat_erika = Program.hasDefeatedTrainer(417)
		local beat_koga = Program.hasDefeatedTrainer(418)
		local beat_sabrina = Program.hasDefeatedTrainer(420)
		local beat_blaine = Program.hasDefeatedTrainer(419)
		local beat_giovanni = Program.hasDefeatedTrainer(350)
		local beat_lorelei = Program.hasDefeatedTrainer(410)
		local beat_bruno = Program.hasDefeatedTrainer(411)
		local beat_agatha = Program.hasDefeatedTrainer(412)
		local beat_lance = Program.hasDefeatedTrainer(413)
		local beat_champ = Program.hasDefeatedTrainer(438) or Program.hasDefeatedTrainer(439) or Program.hasDefeatedTrainer(440)

		local milestones = {
			lab = beat_lab,
			brock = beat_brock,
			misty = beat_misty,
			surge = beat_surge,
			erika = beat_erika,
			koga = beat_koga,
			sabrina = beat_sabrina,
			blaine = beat_blaine,
			giovanni = beat_giovanni,
			lorelei = beat_lorelei,
			bruno = beat_bruno,
			agatha = beat_agatha,
			lance = beat_lance,
			champ = beat_champ
		}

		-- Find the highest milestone achieved
		local highestMilestone = nil
		for i = #self.MILESTONE_ORDER, 1, -1 do
			local milestone = self.MILESTONE_ORDER[i]
			if milestones[milestone] then
				highestMilestone = milestone
				break
			end
		end

		return highestMilestone, milestones
	end

	-- Competition (premade-ROM) seed lookup: when the Tracker is in "Use premade ROMs"
	-- mode, the per-ROM randomizer log sits next to the loaded ROM (e.g. "Name3.gba.log"),
	-- which the Tracker does NOT auto-parse. The IronmonVS monitor generates those ROMs
	-- with a forced seed, so read that log to report the exact RandomSeed. Tracker is
	-- never modified — this only reads files it already writes.
	local function getPremadeRomSeed()
		local ok, result = pcall(function()
			if not (type(Options) == "table" and Options["Use premade ROMs"]) then return nil end
			local romsFolder = Options.FILES and Options.FILES["ROMs Folder"]
			if Utils.isNilOrEmpty(romsFolder) then return nil end
			romsFolder = FileManager.tryAppendSlash(romsFolder)
			local romName = GameSettings.getRomName()
			if Utils.isNilOrEmpty(romName) then return nil end
			-- Same path the Tracker's own LogOverlay uses: "<folder><rom>.gba.log".
			local logPath = romsFolder .. romName .. FileManager.Extensions.GBA_ROM
				.. FileManager.Extensions.RANDOMIZER_LOGFILE
			if not FileManager.fileExists(logPath) then
				logPath = romsFolder .. romName .. FileManager.Extensions.RANDOMIZER_LOGFILE
				if not FileManager.fileExists(logPath) then return nil end
			end
			local logLines = FileManager.readLinesFromFile(logPath)
			if not logLines or #logLines < 2 then return nil end
			local pattern = "Random Seed:%s*(%d+)"
			if type(RandomizerLog) == "table" and type(RandomizerLog.Patterns) == "table"
				and type(RandomizerLog.Patterns.RandomizerSeed) == "string" then
				pattern = RandomizerLog.Patterns.RandomizerSeed
			end
			local seedMatch = string.match(logLines[2] or "", pattern)
			if not seedMatch then
				for _, line in ipairs(logLines) do
					seedMatch = string.match(line, "Random Seed:%s*(%d+)")
					if seedMatch then break end
				end
			end
			return seedMatch and tonumber(seedMatch) or nil
		end)
		if ok then return result end
		return nil
	end

	-- Full level-up learnset + which moves are unlocked at the Pokemon's current level.
	-- Only used for the player's OWN party (their own data), so the full learnset is fine.
	local function getLearnset(pokemonID, level)
		local out = {}
		local ok, learned = pcall(function() return PokemonData.readLevelUpMoves(pokemonID) end)
		if not ok or type(learned) ~= "table" then return out end
		for _, lm in ipairs(learned) do
			-- SEEN-ONLY: never reveal level-up moves above the Pokemon's current level.
			-- The player hasn't reached those yet, so they haven't seen them.
			if lm.level and level and lm.level <= level then
				local md = MoveData.Moves[lm.id]
				out[#out + 1] = { move = (md and md.name) or tostring(lm.id), level = lm.level }
			end
		end
		return out
	end

	-- The player's per-stat +/- markings for a species (their scouting judgment). Maps the
	-- tracker's marking values (1=+, 2=-, 3==) to symbols; omits unmarked stats. Seen-only
	-- (it's the player's own note about a Pokemon they've seen).
	local STAT_MARK_SYM = { [1] = "+", [2] = "-", [3] = "=" }
	local function getStatMarks(pokemonID)
		local out = {}
		local ok, sm = pcall(function() return Tracker.getStatMarkings(pokemonID) end)
		if not ok or type(sm) ~= "table" then return out end
		for _, k in ipairs({ "hp", "atk", "def", "spa", "spd", "spe" }) do
			local sym = STAT_MARK_SYM[sm[k] or 0]
			if sym then out[k] = sym end
		end
		return out
	end

	-- The player's own party: stats, ability, current moves, and learnset. The player owns
	-- these so full detail is fine (no privacy concern).
	local function collectParty()
		local party = {}
		for slot = 1, 6 do
			local okm, member = pcall(function()
				local p = Tracker.getPokemon(slot, true)
				if not p or not PokemonData.isValid(p.pokemonID) then return nil end
				local pd = PokemonData.Pokemon[p.pokemonID]
				local abil = AbilityData.Abilities[PokemonData.getAbilityId(p.pokemonID, p.abilityNum)]
				local m = {
					slot = slot,
					id = p.pokemonID,
					dex = PokemonData.dexMapInternalToNational(p.pokemonID),
					name = (pd and pd.name) or "Unknown",
					level = p.level or 0,
					nickname = p.nickname or "",
					ability = (abil and abil.name) or "",
					type1 = (pd and pd.types and pd.types[1]) or "",
					type2 = (pd and pd.types and pd.types[2]) or "",
					stats = {
						hp = (p.stats and p.stats.hp) or 0,
						atk = (p.stats and p.stats.atk) or 0,
						def = (p.stats and p.stats.def) or 0,
						spa = (p.stats and p.stats.spa) or 0,
						spd = (p.stats and p.stats.spd) or 0,
						spe = (p.stats and p.stats.spe) or 0,
					},
					moves = {},
					learnset = getLearnset(p.pokemonID, p.level),
					marks = getStatMarks(p.pokemonID),
				}
				for _, mv in ipairs(p.moves or {}) do
					if mv.id and mv.id > 0 then
						local md = MoveData.Moves[mv.id]
						m.moves[#m.moves + 1] = (md and md.name) or tostring(mv.id)
					end
				end
				return m
			end)
			if okm and member then party[#party + 1] = member end
		end
		return party
	end

	-- Seen wild encounters on the early pivot routes -- ONLY what the player has actually
	-- seen (Tracker.getRouteEncounters), never the full ROM encounter table.
	local PIVOT_ROUTE_NAMES = {
		["Route 1"] = true, ["Route 2"] = true,
		["Route 22"] = true, ["Viridian Forest"] = true,
	}
	local function collectPivots()
		local out = {}
		if type(RouteData) ~= "table" or type(RouteData.Info) ~= "table" then return out end
		if type(Tracker.getRouteEncounters) ~= "function" then return out end
		local land = RouteData.EncounterArea and RouteData.EncounterArea.LAND
		if not land then return out end
		for mapId, info in pairs(RouteData.Info) do
			local name = info and info.name
			if name and PIVOT_ROUTE_NAMES[name] then
				local seen = Tracker.getRouteEncounters(mapId, land)
				if type(seen) == "table" and #seen > 0 then
					local list = out[name] or {}
					for _, pid in ipairs(seen) do
						if PokemonData.isValid(pid) then
							list[#list + 1] = { id = pid, name = PokemonData.Pokemon[pid].name }
						end
					end
					out[name] = list
				end
			end
		end
		return out
	end

	-- ---- Trainer team capture (SEEN-ONLY) ----
	-- Records the active enemy mon + the moves it actually USED, accumulated across the
	-- battle. Never reads the full ROM trainer party (that would spoil unseen mons).
	-- Name of the map/area the player is currently on (used to group trainer notes by area).
	local function currentAreaName()
		local ok, name = pcall(function()
			local info = RouteData.Info[TrackerAPI.getMapId()]
			return info and info.name
		end)
		if ok and name and name ~= "" then return name end
		return nil
	end

	local function trainerLabel(trainerId)
		local ok, info = pcall(function() return TrainerData.getTrainerInfo(trainerId) end)
		if ok and type(info) == "table" then
			local cls = info.class
			if type(cls) == "table" then cls = cls.name end
			return info.name, (type(cls) == "string" and cls or nil)
		end
		return nil, nil
	end

	local function recordEnemyMon(trainerId, mon)
		if not mon or not PokemonData.isValid(mon.pokemonID) then return end
		local tr = self.SeenTrainers[trainerId]
		if not tr then
			local nm, cls = trainerLabel(trainerId)
			tr = { id = trainerId, name = nm, class = cls, area = currentAreaName(), team = {} }
			self.SeenTrainers[trainerId] = tr
		end
		local key = mon.pokemonID * 1000 + (mon.level or 0)
		local entry = tr.team[key]
		if not entry then
			entry = { id = mon.pokemonID, dex = PokemonData.dexMapInternalToNational(mon.pokemonID),
			          name = PokemonData.Pokemon[mon.pokemonID].name,
			          level = mon.level or 0, moveset = {} }
			tr.team[key] = entry
		end
		-- Merge the moves this enemy species+level has revealed THIS battle.
		local notes = Tracker.BattleNotes and Tracker.BattleNotes.MovesByPokemonAndLevel
		local seen = notes and notes[key]
		if type(seen) == "table" then
			for moveId in pairs(seen) do
				if moveId and moveId ~= 0 then entry.moveset[moveId] = true end
			end
		end
		-- Capture the player's stat markings for this species (latest wins).
		entry.marks = getStatMarks(mon.pokemonID)
	end

	-- Build the JSON-friendly trainer list from the per-seed accumulator.
	local function collectTrainers()
		local out = {}
		for _, tr in pairs(self.SeenTrainers) do
			local team = {}
			for _, entry in pairs(tr.team) do
				local moves = {}
				for moveId in pairs(entry.moveset or {}) do
					local md = MoveData.Moves[moveId]
					moves[#moves + 1] = (md and md.name) or tostring(moveId)
				end
				team[#team + 1] = { id = entry.id, dex = entry.dex, name = entry.name, level = entry.level,
				                    moves = moves, marks = entry.marks or {} }
			end
			out[#out + 1] = { id = tr.id, name = tr.name, class = tr.class,
			                  area = tr.area or "Unknown Area", team = team }
		end
		return out
	end

	-- Assemble the rich "extra" payload. Wrapped so any failure just omits the extra data
	-- rather than breaking the core run report.
	local function collectExtra()
		local ok, extra = pcall(function()
			return {
				pivots = collectPivots(),
				party = collectParty(),
				trainers = collectTrainers(),
			}
		end)
		if ok then return extra end
		return nil
	end

	-- Simplified data collection function
	local function collectSimplifiedData(pokemon)
		local info = {}
		if not PokemonData.isValid(pokemon.pokemonID) then
			return info
		end

		local seedNumber = Main.currentSeed
		local playTime = Program.GameTimer:getText()
		local currentDate = os.date("%Y-%m-%d")
		local pokemonName = PokemonData.Pokemon[pokemon.pokemonID].name or "Unknown Pokemon"
		local abilityName = AbilityData.Abilities[PokemonData.getAbilityId(pokemon.pokemonID, pokemon.abilityNum)].name
		local type_1 = getPokemonOrDefault(pokemon.PokemonId).types[1]
		local type_2 = getPokemonOrDefault(pokemon.PokemonId).types[2]
		local move_1 = MoveData.Moves[pokemon.moves[1].id].name
		local move_2 = MoveData.Moves[pokemon.moves[2].id].name
		local move_3 = MoveData.Moves[pokemon.moves[3].id].name
		local move_4 = MoveData.Moves[pokemon.moves[4].id].name

		local highestMilestone, allMilestones = getHighestMilestone()
		local favoritePokemon = getFavoritePokemonName()
		local trainerCount = getTotalDefeatedTrainers(false)
		local dungeonClears = getDungeonFullClears()
		
		-- Get current route name
		local routeName = RouteData.Info[TrackerAPI.getMapId()].name or "Unknown Area"
		
		-- Get RandomSeed from RandomizerLog if available
		-- The log must be parsed via RandomizerLog.parseLog(filepath) first
		-- Competition premade-ROM mode takes priority: read the seed straight from the
		-- log next to the loaded ROM (set by the IronmonVS monitor's forced-seed generation).
		local randomSeed = getPremadeRomSeed()
		local success, result = pcall(function()
			if randomSeed ~= nil then return randomSeed end
			if type(RandomizerLog) == "table" then
				if type(RandomizerLog.Data) == "table" then
					-- First check if already parsed
					if type(RandomizerLog.Data.Settings) == "table" then
						local seed = RandomizerLog.Data.Settings.RandomSeed
						if seed then
							if type(seed) == "string" and seed ~= "" then
								local numSeed = tonumber(seed)
								if numSeed then return numSeed end
							elseif type(seed) == "number" then
								return seed
							end
						end
					end
					
					-- If RandomSeed is nil, the log may not have been parsed yet
					-- Try to find and read the log file directly
					local logPath = nil
					
					-- Check for the loaded log path (set when tracker loads the log)
					if type(RandomizerLog.loadedLogPath) == "string" and RandomizerLog.loadedLogPath ~= "" then
						logPath = RandomizerLog.loadedLogPath
					end
					
					-- If no loaded path, try to autodetect it using the tracker's built-in function
					-- This uses the same logic the tracker uses to find log files
					if (not logPath or not FileManager.fileExists(logPath)) and type(LogOverlay) == "table" and type(LogOverlay.getLogFileAutodetected) == "function" then
						logPath = LogOverlay.getLogFileAutodetected()
					end
					
					-- Fallback: manually find the log file if autodetect didn't work
					-- The log file is in the tracker folder (parent of extensions folder)
					-- Note: We don't assume any specific tracker folder name - the only constant
					-- is that there's an "extensions" folder inside the tracker folder
					if (not logPath or not FileManager.fileExists(logPath)) then
						-- Get the tracker folder by going up one level from extensions folder
						-- customFolderPath will be something like: "C:\...\TrackerName\extensions\"
						-- We extract the parent directory to get: "C:\...\TrackerName\"
						local customFolderPath = FileManager.getCustomFolderPath()
						if customFolderPath and customFolderPath ~= "" then
							-- Remove trailing slash if present
							local trimmedPath = customFolderPath:match("^(.+)[/\\]$") or customFolderPath
							-- Remove the last directory (extensions) to get the tracker folder
							-- This works regardless of what the tracker folder is named
							local trackerFolder = trimmedPath:match("^(.+)[/\\][^/\\]+$") or trimmedPath
							
							if trackerFolder and trackerFolder ~= "" then
								-- Look for .log files in the tracker folder
								local possibleLogs = FileManager.getFilesInDirectory(trackerFolder, "*.log")
								if possibleLogs and #possibleLogs > 0 then
									-- Use the first .log file found (or try to match ROM name)
									for _, logFile in ipairs(possibleLogs) do
										local fullPath = trackerFolder .. FileManager.slash .. logFile
										if FileManager.fileExists(fullPath) then
											logPath = fullPath
											break
										end
									end
								end
							end
						end
					end
					
					-- If we found a log file, try to read and parse it
					if logPath and FileManager.fileExists(logPath) then
						local logLines = FileManager.readLinesFromFile(logPath)
						if logLines and #logLines >= 2 then
							-- Use parseRandomizerSettings to parse just the settings
							if type(RandomizerLog.parseRandomizerSettings) == "function" then
								RandomizerLog.parseRandomizerSettings(logLines)
								-- Check again after parsing
								if type(RandomizerLog.Data.Settings) == "table" then
									local seed = RandomizerLog.Data.Settings.RandomSeed
									if seed then
										if type(seed) == "string" and seed ~= "" then
											local numSeed = tonumber(seed)
											if numSeed then return numSeed end
										elseif type(seed) == "number" then
											return seed
										end
									end
								end
							end
							
							-- Fallback: parse manually using the pattern
							if type(RandomizerLog.Patterns) == "table" and type(RandomizerLog.Patterns.RandomizerSeed) == "string" then
								local pattern = RandomizerLog.Patterns.RandomizerSeed
								local seedMatch = string.match(logLines[2] or "", pattern)
								if seedMatch then
									local numSeed = tonumber(seedMatch)
									if numSeed then return numSeed end
								end
							end
							
							-- Last resort: try simple pattern matching
							local seedMatch = string.match(logLines[2] or "", "Random Seed:%s*(%d+)")
							if seedMatch then
								local numSeed = tonumber(seedMatch)
								if numSeed then return numSeed end
							end
						end
					end
				end
			end
			return nil
		end)
		if success and result then
			randomSeed = result
		end

		-- Calculate badge count (badges are earned from brock through giovanni)
		local badgeCount = 0
		if allMilestones.brock then badgeCount = badgeCount + 1 end
		if allMilestones.misty then badgeCount = badgeCount + 1 end
		if allMilestones.surge then badgeCount = badgeCount + 1 end
		if allMilestones.erika then badgeCount = badgeCount + 1 end
		if allMilestones.koga then badgeCount = badgeCount + 1 end
		if allMilestones.sabrina then badgeCount = badgeCount + 1 end
		if allMilestones.blaine then badgeCount = badgeCount + 1 end
		if allMilestones.giovanni then badgeCount = badgeCount + 1 end

		-- Determine if run is ongoing: True if Pokemon is alive AND champ is not beaten
		local hpPercentage = (pokemon.curHP or 0) / (pokemon.stats.hp or 100)
		local isPokemonAlive = hpPercentage > 0
		local champBeaten = allMilestones.champ or false
		local isOngoingRun = isPokemonAlive and not champBeaten

		-- Build data structure
		info.seedNumber = seedNumber
		info.playTime = playTime
		info.currentDate = currentDate
		info.pokemonName = pokemonName
		info.pokemonID = pokemon.pokemonID
		info.nickname = pokemon.nickname or ""
		info.type_1 = type_1
		info.type_2 = type_2
		info.level = pokemon.level
		info.hp = pokemon.stats.hp or 0
		info.atk = pokemon.stats.atk or 0
		info.def = pokemon.stats.def or 0
		info.spa = pokemon.stats.spa or 0
		info.spd = pokemon.stats.spd or 0
		info.spe = pokemon.stats.spe or 0
		info.abilityName = abilityName
		info.move_1 = move_1
		info.move_2 = move_2
		info.move_3 = move_3
		info.move_4 = move_4
		info.milestone = highestMilestone
		info.isOngoingRun = isOngoingRun
		info.favoritePokemon = favoritePokemon

		-- Add all milestone data
		info.beat_lab = allMilestones.lab
		info.beat_brock = allMilestones.brock
		info.beat_misty = allMilestones.misty
		info.beat_surge = allMilestones.surge
		info.beat_erika = allMilestones.erika
		info.beat_koga = allMilestones.koga
		info.beat_sabrina = allMilestones.sabrina
		info.beat_blaine = allMilestones.blaine
		info.beat_giovanni = allMilestones.giovanni
		info.beat_lorelei = allMilestones.lorelei
		info.beat_bruno = allMilestones.bruno
		info.beat_agatha = allMilestones.agatha
		info.beat_lance = allMilestones.lance
		info.beat_champ = allMilestones.champ
		info.trainerCount = trainerCount
		info.badgeCount = badgeCount
		info.routeName = routeName

		-- Add dungeon full clear data
		info.fullClear_MtMoon = dungeonClears.MtMoon or false
		info.fullClear_RockTunnel = dungeonClears.RockTunnel or false
		info.fullClear_SilphCo = dungeonClears.SilphCo or false
		info.fullClear_RocketHideout = dungeonClears.RocketHideout or false
		info.fullClear_SSAnne = dungeonClears.SSAnne or false
		info.fullClear_VictoryRoad = dungeonClears.VictoryRoad or false
		info.fullClear_PokemonTower = dungeonClears.PokemonTower or false
		info.fullClear_CinnabarMansion = dungeonClears.CinnabarMansion or false
		
		-- Add RandomSeed (always present, will be null if not available)
		info.RandomSeed = randomSeed

		-- Rich per-seed detail (seen-only pivots + the player's own party). Nested object.
		info.extra = collectExtra()

		return info
	end

	-- Per-seed accumulator of SEEN enemy trainer teams: trainerId -> { id, name, class,
	-- team = { [pokemonID*1000+level] = { id, name, level, moveset = {moveId=true} } } }.
	-- Filled live during trainer battles from the active enemy + its revealed moves.
	self.SeenTrainers = {}

	self.PerSeedVars = {
		PokemonDead = false,
		LastMilestone = nil,
		FirstPokemonChosen = false,
		LastTrainerCount = 0,
		BeatTrainer102 = false,
		BeatTrainer329 = false,
		FullCleared_MtMoon = false,
		FullCleared_RockTunnel = false,
		FullCleared_SilphCo = false,
		FullCleared_RocketHideout = false,
		FullCleared_SSAnne = false,
		FullCleared_VictoryRoad = false,
		FullCleared_PokemonTower = false,
		FullCleared_CinnabarMansion = false,
	}

	function self.getHpPercent()
		local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
		if PokemonData.isValid(leadPokemon.pokemonID) then
			return (leadPokemon.curHP or 0) / (leadPokemon.stats.hp or 100)
		end
	end
	
	function self.resetSeedVars()
		self.SeenTrainers = {}
		local V = self.PerSeedVars
		V.PokemonDead = false
		V.LastMilestone = nil
		V.FirstPokemonChosen = false
		V.LastTrainerCount = 0
		V.BeatTrainer102 = false
		V.BeatTrainer329 = false
		V.FullCleared_MtMoon = false
		V.FullCleared_RockTunnel = false
		V.FullCleared_SilphCo = false
		V.FullCleared_RocketHideout = false
		V.FullCleared_SSAnne = false
		V.FullCleared_VictoryRoad = false
		V.FullCleared_PokemonTower = false
		V.FullCleared_CinnabarMansion = false
	end

	local loadedVarsThisSeed
	local function isPlayingFRLG() return GameSettings.game == 3 end

	-- Check for first pokemon choice and write data to file
	local function checkForFirstPokemonChoice()
		if not Program.isValidMapLocation() then
			return
		end
		
		local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
		if not PokemonData.isValid(leadPokemon.pokemonID) then
			return
		end

		local V = self.PerSeedVars

		-- Check if this is the first pokemon chosen (only trigger once)
		if not V.FirstPokemonChosen then
			local data = collectSimplifiedData(leadPokemon)
			writeDataToFile(data)
			V.FirstPokemonChosen = true
		end
	end

	-- Check for milestone changes and write data to file
	local function checkForMilestoneUpdate()
		if not Program.isValidMapLocation() then
			return
		end
		
		local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
		if not PokemonData.isValid(leadPokemon.pokemonID) then
			return
		end

		local V = self.PerSeedVars
		
		-- Don't send updates if the Pokemon has died
		if V.PokemonDead then
			return
		end

		local currentMilestone = getHighestMilestone()

		-- If milestone changed, send notification
		if currentMilestone and currentMilestone ~= V.LastMilestone then
			local data = collectSimplifiedData(leadPokemon)
			writeDataToFile(data)
			V.LastMilestone = currentMilestone
			-- Update trainer count when milestone changes
			V.LastTrainerCount = data.trainerCount or 0
		end
	end

	-- Check for trainer count updates (every 20 trainers after Brock milestone)
	local function checkForTrainerCountUpdate()
		if not Program.isValidMapLocation() then
			return
		end
		
		local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
		if not PokemonData.isValid(leadPokemon.pokemonID) then
			return
		end

		local V = self.PerSeedVars
		
		-- Don't send updates if the Pokemon has died
		if V.PokemonDead then
			return
		end

		-- Only track trainer count updates after Brock milestone
		local currentMilestone = getHighestMilestone()
		if not currentMilestone then
			return
		end

		-- Check if milestone is past Brock (brock is at index 2, so we need index > 2)
		local milestoneIndex = nil
		for i, milestone in ipairs(self.MILESTONE_ORDER) do
			if milestone == currentMilestone then
				milestoneIndex = i
				break
			end
		end

		-- Only update if milestone is past Brock (index > 2, since lab=1, brock=2)
		if not milestoneIndex or milestoneIndex <= 1 then
			return
		end

		-- Get current trainer count
		local currentTrainerCount = getTotalDefeatedTrainers(false)
		
		-- Check if we've crossed a multiple of 20 trainers
		local lastMultiple = math.floor(V.LastTrainerCount / 20)
		local currentMultiple = math.floor(currentTrainerCount / 20)
		
		if currentMultiple > lastMultiple then
			-- Trainer count crossed a multiple of 20, send update
			local data = collectSimplifiedData(leadPokemon)
			writeDataToFile(data)
			V.LastTrainerCount = currentTrainerCount
		elseif currentTrainerCount > V.LastTrainerCount then
			-- Update last trainer count even if we don't send update
			V.LastTrainerCount = currentTrainerCount
		end
	end

	-- Check for trainer 102 defeat and send update
	local function checkForTrainer102Update()
		if not Program.isValidMapLocation() then
			return
		end
		
		local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
		if not PokemonData.isValid(leadPokemon.pokemonID) then
			return
		end

		local V = self.PerSeedVars
		
		-- Don't send updates if the Pokemon has died
		if V.PokemonDead then
			return
		end

		-- Check if trainer 102 has been defeated
		local beatTrainer102 = Program.hasDefeatedTrainer(102)
		
		if beatTrainer102 and not V.BeatTrainer102 then
			-- Trainer 102 just defeated, send update
			local data = collectSimplifiedData(leadPokemon)
			writeDataToFile(data)
			V.BeatTrainer102 = true
		end
	end

	-- Check for trainer 329, 330, or 331 defeat and send update
	local function checkForTrainer329Update()
		if not Program.isValidMapLocation() then
			return
		end
		
		local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
		if not PokemonData.isValid(leadPokemon.pokemonID) then
			return
		end

		local V = self.PerSeedVars
		
		-- Don't send updates if the Pokemon has died
		if V.PokemonDead then
			return
		end

		-- Check if trainer 329, 330, or 331 has been defeated
		local beatTrainer329 = Program.hasDefeatedTrainer(329) or Program.hasDefeatedTrainer(330) or Program.hasDefeatedTrainer(331)
		
		if beatTrainer329 and not V.BeatTrainer329 then
			-- Trainer 329/330/331 just defeated, send update
			local data = collectSimplifiedData(leadPokemon)
			writeDataToFile(data)
			V.BeatTrainer329 = true
		end
	end

	-- Check for dungeon full clears and send update
	local function checkForDungeonFullClears()
		if not Program.isValidMapLocation() then
			return
		end
		
		local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
		if not PokemonData.isValid(leadPokemon.pokemonID) then
			return
		end

		local V = self.PerSeedVars
		
		-- Don't send updates if the Pokemon has died
		if V.PokemonDead then
			return
		end

		local dungeonClears = getDungeonFullClears()
		local shouldUpdate = false

		-- Check each dungeon for new full clears
		if dungeonClears.MtMoon and not V.FullCleared_MtMoon then
			V.FullCleared_MtMoon = true
			shouldUpdate = true
		end
		if dungeonClears.RockTunnel and not V.FullCleared_RockTunnel then
			V.FullCleared_RockTunnel = true
			shouldUpdate = true
		end
		if dungeonClears.SilphCo and not V.FullCleared_SilphCo then
			V.FullCleared_SilphCo = true
			shouldUpdate = true
		end
		if dungeonClears.RocketHideout and not V.FullCleared_RocketHideout then
			V.FullCleared_RocketHideout = true
			shouldUpdate = true
		end
		if dungeonClears.SSAnne and not V.FullCleared_SSAnne then
			V.FullCleared_SSAnne = true
			shouldUpdate = true
		end
		if dungeonClears.VictoryRoad and not V.FullCleared_VictoryRoad then
			V.FullCleared_VictoryRoad = true
			shouldUpdate = true
		end
		if dungeonClears.PokemonTower and not V.FullCleared_PokemonTower then
			V.FullCleared_PokemonTower = true
			shouldUpdate = true
		end
		if dungeonClears.CinnabarMansion and not V.FullCleared_CinnabarMansion then
			V.FullCleared_CinnabarMansion = true
			shouldUpdate = true
		end

		if shouldUpdate then
			-- Full clear detected! Immediately collect data and save to JSON
			local data = collectSimplifiedData(leadPokemon)
			writeDataToFile(data)
		end
	end

	-- Executed every ~30 frames during a battle. Capture the SEEN enemy team of trainer
	-- battles (active enemy mon + the moves it has revealed). Best-effort; never throws.
	function self.afterBattleDataUpdate()
		pcall(function()
			if type(Battle) ~= "table" or not Battle.inActiveBattle() then return end
			if Battle.isWildEncounter then return end
			local trainerId = Battle.opposingTrainerId
			if not trainerId or trainerId == 0 then return end
			local combatants = Battle.Combatants
			if type(combatants) ~= "table" then return end
			-- Only LeftOther is the active enemy in a single battle. RightOther defaults to
			-- slot 2 and is ONLY refreshed by the tracker in doubles (numBattlers == 4);
			-- reading it in a single battle records the trainer's 2nd party mon -- which was
			-- NEVER sent out -- leaking a Pokemon the player never saw. Mirror the tracker and
			-- only consult RightOther in double battles.
			local slotKeys = { "LeftOther" }
			if Battle.numBattlers == 4 then
				slotKeys[#slotKeys + 1] = "RightOther"
			end
			for _, slotKey in ipairs(slotKeys) do
				local slot = combatants[slotKey]
				if slot then
					local mon = Tracker.getPokemon(slot, false)
					if mon then recordEnemyMon(trainerId, mon) end
				end
			end
		end)
	end

	-- Executed once every 30 frames, after most data from game memory is read in
	function self.afterProgramDataUpdate()
		-- Once per seed, when the player is able to move their character, initialize the seed variables
		if not isPlayingFRLG() or not Program.isValidMapLocation() then
			return
		elseif not loadedVarsThisSeed then
			self.resetSeedVars()
			loadedVarsThisSeed = true
			
			-- Check if player has milestone progress to set LastMilestone and LastTrainerCount
			local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
			if PokemonData.isValid(leadPokemon.pokemonID) then
				local currentMilestone = getHighestMilestone()
				local V = self.PerSeedVars
				if currentMilestone then
					V.LastMilestone = currentMilestone
					-- Initialize trainer count
					V.LastTrainerCount = getTotalDefeatedTrainers(false)
				end
				-- Initialize trainer defeat tracking
				V.BeatTrainer102 = Program.hasDefeatedTrainer(102)
				V.BeatTrainer329 = Program.hasDefeatedTrainer(329) or Program.hasDefeatedTrainer(330) or Program.hasDefeatedTrainer(331)
				
				-- Initialize dungeon full clear tracking
				local dungeonClears = getDungeonFullClears()
				V.FullCleared_MtMoon = dungeonClears.MtMoon or false
				V.FullCleared_RockTunnel = dungeonClears.RockTunnel or false
				V.FullCleared_SilphCo = dungeonClears.SilphCo or false
				V.FullCleared_RocketHideout = dungeonClears.RocketHideout or false
				V.FullCleared_SSAnne = dungeonClears.SSAnne or false
				V.FullCleared_VictoryRoad = dungeonClears.VictoryRoad or false
				V.FullCleared_PokemonTower = dungeonClears.PokemonTower or false
				V.FullCleared_CinnabarMansion = dungeonClears.CinnabarMansion or false
			end
		end

		local V = self.PerSeedVars
		local leadPokemon = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()

		-- Check for first pokemon choice
		checkForFirstPokemonChoice()

		-- Check for milestone updates
		checkForMilestoneUpdate()

		-- Check for trainer count updates (every 20 trainers after Brock)
		checkForTrainerCountUpdate()

		-- Check for trainer 102 defeat
		checkForTrainer102Update()

		-- Check for trainer 329/330/331 defeat
		checkForTrainer329Update()

		-- Check for dungeon full clears
		checkForDungeonFullClears()

		-- Lead Pokemon Died - send final data
		if Program.isValidMapLocation() then
			local hpPercentage = self.getHpPercent()
			if hpPercentage ~= nil and hpPercentage == 0 and V.PokemonDead == false then
				V.PokemonDead = true
				local data = collectSimplifiedData(leadPokemon)
				writeDataToFile(data)
			end
		end
	end

	-- Read the heartbeat file the monitor refreshes; returns its epoch seconds or nil.
	local function readHeartbeat()
		local path = self.Paths.Heartbeat
		if not path or path == "" then return nil end
		local file = io.open(path, "r")
		if not file then return nil end
		local content = file:read("*a")
		file:close()
		if not content then return nil end
		return tonumber((content:gsub("%s+", "")))
	end

	-- Decide (throttled to once/sec) whether the monitor is currently running.
	local function updateMonitorWarning()
		local now = os.time()
		if now - self.MonitorWarn.lastCheck < 1 then return end
		self.MonitorWarn.lastCheck = now
		local beat = readHeartbeat()
		self.MonitorWarn.active = (beat == nil) or ((now - beat) > self.HEARTBEAT_STALE_SECONDS)
	end

	-- Draw a warning banner across the top of the GAME screen when the monitor isn't
	-- running, including a clickable button that launches the monitor. Uses Bizhawk's gui
	-- directly so it overlays the game (where the streamer and viewers will see it). No
	-- Tracker UI is modified.
	local function drawMonitorWarning()
		if not Main.IsOnBizhawk() then return end
		local w = Constants.SCREEN.WIDTH
		gui.drawRectangle(0, 0, w, 38, 0xFFCC0000, 0xFFCC0000)
		Drawing.drawText(6, 2, "IronmonVS monitor NOT running", 0xFFFFFFFF, 0xFF000000)
		Drawing.drawText(6, 12, "Runs are NOT being recorded!", 0xFFFFFF00, 0xFF000000)
		local b = self.WarnButton
		gui.drawRectangle(b.x, b.y, b.w, b.h, 0xFF000000, 0xFFFFFFFF)
		Drawing.drawText(b.x + 4, b.y + 2, "Open IronmonVS Monitor", 0xFFCC0000)
	end

	-- Read the current-seed file the monitor writes (throttled to once/sec).
	local function readSeedDisplay()
		local now = os.time()
		if now - (self.SeedInfo.lastRead or 0) < 1 then return end
		self.SeedInfo.lastRead = now
		self.SeedInfo.order, self.SeedInfo.seed, self.SeedInfo.total = nil, nil, nil
		local path = self.Paths.SeedDisplay
		if not path or path == "" then return end
		local file = io.open(path, "r")
		if not file then return end
		for line in file:lines() do
			local k, v = string.match(line, "^%s*(%w+)%s*=%s*(.-)%s*$")
			if k == "order" then self.SeedInfo.order = v
			elseif k == "seed" then self.SeedInfo.seed = v
			elseif k == "total" then self.SeedInfo.total = v end
		end
		file:close()
	end

	-- Bottom-right info box on the GAME screen:
	--   * Wrong seed loaded -> show Expected vs Current seed so the mismatch is obvious.
	--   * Otherwise -> show "Seed #N" + the full seed from load until the player grabs
	--     their starter (reminds them which seed they're on; resets each new run).
	local function drawSeedDisplay()
		if not Main.IsOnBizhawk() or not isPlayingFRLG() then return end

		if self.WrongSeed then
			local expected = self.SeedInfo.seed or "?"
			local loaded = self.LoadedSeed.value and tostring(self.LoadedSeed.value) or "?"
			local boxW, boxH = 88, 44
			local x = Constants.SCREEN.WIDTH - boxW - 2
			local y = Constants.SCREEN.HEIGHT - boxH - 2
			gui.drawRectangle(x, y, boxW, boxH, 0xFF000000, 0xC0000000)
			Drawing.drawText(x + 3, y + 1, "Expected Seed:", 0xFFFFFF00, 0xFF000000)
			Drawing.drawText(x + 3, y + 11, expected, 0xFFFFFFFF, 0xFF000000)
			Drawing.drawText(x + 3, y + 22, "Current Seed:", 0xFFFFFF00, 0xFF000000)
			Drawing.drawText(x + 3, y + 32, loaded, 0xFFFF5555, 0xFF000000)
			return
		end

		local seed = self.SeedInfo.seed
		if not seed or seed == "" then return end
		local lead = Tracker.getPokemon(1, true) or Tracker.getDefaultPokemon()
		if lead and PokemonData.isValid(lead.pokemonID) then return end

		local boxW, boxH = 88, 22
		local x = Constants.SCREEN.WIDTH - boxW - 2
		local y = Constants.SCREEN.HEIGHT - boxH - 2
		gui.drawRectangle(x, y, boxW, boxH, 0xFF000000, 0xC0000000)
		Drawing.drawText(x + 3, y + 1, "Seed #" .. (self.SeedInfo.order or "?"), 0xFFFFFF00, 0xFF000000)
		Drawing.drawText(x + 3, y + 11, seed, 0xFFFFFFFF, 0xFF000000)
	end

	-- Read the loaded ROM's randomizer seed (throttled). Re-reading each time means a New
	-- Run (which rewrites the constant-name log) is picked up. PERF: this runs every ~2s
	-- for the wrong-seed check, so it must stay cheap. It deliberately does NOT call
	-- LogOverlay.getLogFileAutodetected() -- in "Generate ROM each time" mode with any
	-- quickload path misconfigured, that shells out to `dir` via os.execute (a cmd window
	-- flash + frame hitch on every call). It also never parses the whole multi-MB log:
	-- "Random Seed: N" sits in the log header, so only the first few lines are scanned.
	local LOG_HEADER_LINES = 20

	-- Resolve the loaded ROM's log path with cheap file-existence checks only (no directory
	-- scans). Cached per ROM name; re-resolved if the ROM changes or the file disappears.
	local function findLoadedLogPath()
		local romName = GameSettings.getRomName()
		local C = self.LoadedSeed
		if C.logPath and C.romName == romName and FileManager.fileExists(C.logPath) then
			return C.logPath
		end
		C.romName = romName
		C.logPath = nil
		local candidates = {}
		-- Premade-ROMs mode (how IronmonVS competitions run): the log sits next to the ROM,
		-- named after the CURRENTLY loaded ROM -- so swapping ROMs is reflected immediately.
		if type(Options) == "table" and Options["Use premade ROMs"] and not Utils.isNilOrEmpty(romName) then
			local romsFolder = Options.FILES and Options.FILES["ROMs Folder"]
			if not Utils.isNilOrEmpty(romsFolder) then
				romsFolder = FileManager.tryAppendSlash(romsFolder)
				candidates[#candidates + 1] = romsFolder .. romName .. FileManager.Extensions.GBA_ROM
					.. FileManager.Extensions.RANDOMIZER_LOGFILE
				candidates[#candidates + 1] = romsFolder .. romName .. FileManager.Extensions.RANDOMIZER_LOGFILE
			end
		end
		-- Log the tracker itself last loaded explicitly.
		if type(RandomizerLog) == "table" and type(RandomizerLog.loadedLogPath) == "string"
			and RandomizerLog.loadedLogPath ~= "" then
			candidates[#candidates + 1] = RandomizerLog.loadedLogPath
		end
		-- "Generate ROM each time" mode: the AutoRandomized log's name derives from the
		-- settings file. Build that path directly -- same result getLogFileAutodetected()
		-- computes, minus its directory scan.
		if type(Options) == "table" and Options["Generate ROM each time"]
			and Options.FILES and not Utils.isNilOrEmpty(Options.FILES["Settings File"]) then
			local settingsFileName = FileManager.extractFileNameFromPath(Options.FILES["Settings File"])
			if not Utils.isNilOrEmpty(settingsFileName) then
				local logName = string.format("%s %s%s%s", settingsFileName,
					FileManager.PostFixes.AUTORANDOMIZED, FileManager.Extensions.GBA_ROM,
					FileManager.Extensions.RANDOMIZER_LOGFILE)
				candidates[#candidates + 1] = FileManager.prependDir(logName)
			end
		end
		for _, path in ipairs(candidates) do
			if FileManager.fileExists(path) then
				C.logPath = path
				return path
			end
		end
		return nil
	end

	local function getLoadedSeed()
		local now = os.time()
		if now - (self.LoadedSeed.lastRead or 0) < 2 then
			return self.LoadedSeed.value
		end
		self.LoadedSeed.lastRead = now
		local ok, seed = pcall(function()
			local pattern = "Random Seed:%s*(%d+)"
			if type(RandomizerLog) == "table" and type(RandomizerLog.Patterns) == "table"
				and type(RandomizerLog.Patterns.RandomizerSeed) == "string" then
				pattern = RandomizerLog.Patterns.RandomizerSeed
			end
			local logPath = findLoadedLogPath()
			if logPath then
				local file = io.open(logPath, "r")
				if file then
					for _ = 1, LOG_HEADER_LINES do
						local line = file:read("*l")
						if line == nil then break end
						-- Strip a stray \r so the tracker's $-anchored pattern still matches.
						local match = string.match((line:gsub("\r", "")), pattern)
						if match then
							file:close()
							return tonumber(match)
						end
					end
					file:close()
				end
			end
			-- Fallback: whatever the tracker has already parsed (e.g. via the log overlay).
			if type(RandomizerLog) == "table" and type(RandomizerLog.Data) == "table"
				and type(RandomizerLog.Data.Settings) == "table" then
				local s = RandomizerLog.Data.Settings.RandomSeed
				if type(s) == "number" then return s end
				if type(s) == "string" and s ~= "" then return tonumber(s) end
			end
			return nil
		end)
		self.LoadedSeed.value = (ok and seed) or nil
		return self.LoadedSeed.value
	end

	-- Decide (throttled) whether the loaded seed mismatches the expected competition seed.
	local function updateSeedCheck()
		local now = os.time()
		if now - (self.SeedCheck.lastCheck or 0) < 1 then return end
		self.SeedCheck.lastCheck = now
		local expected = tonumber(self.SeedInfo.seed)
		local loaded = getLoadedSeed()
		if not expected or not loaded or loaded == expected then
			self.WrongSeed = false
			self.SeedCheck.mismatchSince = nil
		else
			-- Restart the grace timer if either seed changed (e.g. just re-rolled).
			if self.SeedCheck.lastLoaded ~= loaded or self.SeedCheck.lastExpected ~= expected
				or not self.SeedCheck.mismatchSince then
				self.SeedCheck.mismatchSince = now
			end
			self.WrongSeed = (now - self.SeedCheck.mismatchSince) >= self.WRONG_SEED_GRACE
		end
		self.SeedCheck.lastLoaded = loaded
		self.SeedCheck.lastExpected = expected
	end

	-- Banner warning the player they've loaded a seed that isn't the competition's current
	-- seed, and to re-create it (a New Run regenerates the correct, server-assigned seed).
	local function drawWrongSeedWarning()
		if not Main.IsOnBizhawk() then return end
		local w = Constants.SCREEN.WIDTH
		gui.drawRectangle(0, 0, w, 38, 0xFFCC0000, 0xFFCC0000)
		Drawing.drawText(6, 2, "WRONG SEED LOADED", 0xFFFFFF00, 0xFF000000)
		Drawing.drawText(6, 12, "Check your New Run setup, then", 0xFFFFFFFF, 0xFF000000)
		Drawing.drawText(6, 23, "press A + B + Start", 0xFFFFFFFF, 0xFF000000)
	end

	-- ===================== GHOST PLAYERS (optional, removable) =====================
	-- Real-time overworld overlay: draws other players (dot + name) on the same map.
	-- To remove entirely: delete this block and its 3 call sites (self.startup path
	-- setup, self.inputCheckBizhawk position write, self.afterRedraw draw). Everything
	-- is wrapped in pcall at the call sites, so a failure here cannot break the extension.
	local GHOST_ENABLED = true
	local GHOST_DEBUG = false                  -- draws my live map/x/y/ghost-count on screen (set true to debug)
	local GHOST_OUT_FILE = "ghost_out.json"   -- written here, read by the monitor
	local GHOST_IN_FILE = "ghost_in.txt"      -- written by the monitor, read here (TSV)
	-- Ghost sprite sheet (ghost_sprite3.png): 64 wide x 384 tall. 4 columns (0=down 1=up
	-- 2=left 3=right), 3 rows per tier (0=still 1=stepA 2=stepB), stacked in 4 opacity tiers
	-- top->bottom (tier 0 = faintest .. tier 3 = steady ~60%), for smooth fade in/out.
	-- NOTE: BizHawk caches drawImageRegion by filename, so bump this name on any image change.
	local GHOST_SPRITE_FILE = "ghost_sprite3.png"
	local GHOST_RED_FILE = "ghost_red3.png"    -- same layout, RED-tinted: drawn during the death fade-out
	local GHOST_TIERS = 4                       -- opacity tiers baked into the sheet (each 96px tall)
	local GHOST_DEATH_FRAMES = 345             -- total death animation length (~5.75s): red hold, then a long slow fade out
	local GHOST_DEATH_HOLD = 45                -- frames to hold full-opacity red before starting to fade (~0.75s)
	local GHOST_WALK_RATE = 8                  -- frames per walk-anim phase (lower = faster legs)
	local GHOST_WALK_HOLD = 24                 -- keep animating this many frames after the last detected move
	local GHOST_EASE = 0.25                     -- per-frame glide toward the target (higher = snappier/tighter, lower = floatier)
	local GHOST_SNAP = 4                        -- if a ghost jumps >= this many tiles (warp/map change), teleport instead of gliding
	local GHOST_MOVE_EPS = 0.12                -- display-vs-target gap below which the ghost is considered "arrived" (idle)
	local GHOST_TTL = 60                        -- frames a ghost survives without a fresh update (~1s) before it's dropped
	                                           -- (guards read/write contention; also the fade-out window on map-leave)
	local GHOST_LEAD = 0.0                      -- motion extrapolation: lead the display this fraction of a tile ahead along
	                                           -- velocity to hide network lag. 0 = OFF (crisper/snappier; a small lead like
	                                           -- 0.2 hides lag but can feel floaty at corners/stops). Tunable.
	local GHOST_LEAD_DECAY = 16                 -- frames over which the lead relaxes to 0 after the last move (avoids stop overshoot)
	local GHOST_FADE_FRAMES = 18               -- frames to fade a ghost in (on appear) / out (as it nears TTL)
	local GHOST_OBJEVENTS = 0x02036E38        -- gObjectEvents[0] base (FRLG); VERIFY in-game
	local GHOST_SCO_X = 0x02021BC8             -- gSpriteCoordOffsetX (s16): camera scroll, for smooth sub-tile drawing
	local GHOST_SCO_Y = 0x02021BCA             -- gSpriteCoordOffsetY (s16)
	local GHOST_SELF_LEAD = 1.0                 -- frames of camera-scroll lead applied to ghosts, to cancel the fixed
	                                           -- overlay-draw latency (ghosts are composited a hair after the game
	                                           -- scrolls the world, so without this they trail you while walking).
	                                           -- 1.0 = advance one frame of scroll; 0 = off. Tunable (try 0.5..1.5).
	local GHOST_COLORS = { 0xFFFF5555, 0xFF55FF66, 0xFF5599FF, 0xFFFFAA33, 0xFFFF66FF, 0xFF66FFFF, 0xFFFFFFFF }
	local GHOST_SHADOW = 0x55101010            -- ARGB drop-shadow color (drawn under the sprite at full tier)
	local ghostOutPath, ghostInPath, ghostSpritePath, ghostRedSpritePath  -- set in self.startup()
	local ghostPlayers = {}                    -- cached other players (from ghost_in.txt)
	local ghostMeta = {}                       -- name -> {name,map,x,y,d,fx,fy,vx,vy,lastMoveFrame,lastSeen,firstSeen,dying,deathFrame,deadDone}
	local ghostFrame = 0
	local gPxStill, gPyStill, gScoxStill, gScoyStill, gLastScox, gLastScoy  -- smooth-scroll calibration
	local gFrameScox, gFrameScoy  -- previous-frame camera offset, to detect when the world is scrolling

	-- Set the alpha byte (0-255) on an ARGB color, arithmetic only (BizHawk Lua 5.1, no bitops).
	local function withAlpha(color, a)
		return (a % 256) * 0x1000000 + (color % 0x1000000)
	end

	local function ghostColor(name)
		local h = 0
		for i = 1, #name do h = h + name:byte(i) end
		return GHOST_COLORS[(h % #GHOST_COLORS) + 1]
	end

	-- Read my overworld tile from gObjectEvents[0]; write ghost_out.json for the monitor.
	local function ghostWriteSelf()
		if not GHOST_ENABLED or not ghostOutPath then return end
		local x = Memory.readword(GHOST_OBJEVENTS + 0x10)
		local y = Memory.readword(GHOST_OBJEVENTS + 0x12)
		local facing = Memory.readbyte(GHOST_OBJEVENTS + 0x18) % 16
		local mapId = TrackerAPI.getMapId() or 0
		-- status flag carried in `f`: 0 = normal, 2 = DEAD (lost the run). The tracker's
		-- GameOverScreen sets status=LOST when the run-ending loss condition is met; other
		-- players' extensions play a red fade-out where we were standing.
		local f = 0
		if GameOverScreen ~= nil and GameOverScreen.Statuses ~= nil
			and GameOverScreen.status == GameOverScreen.Statuses.LOST then
			f = 2
		end
		local out = string.format('{"map":%d,"x":%d,"y":%d,"d":%d,"f":%d}', mapId, x, y, facing, f)
		local file = io.open(ghostOutPath, "w")
		if file then file:write(out); file:close() end
	end

	-- Read other players (TSV: name<TAB>map<TAB>x<TAB>y<TAB>d<TAB>f) into ghostPlayers.
	-- The monitor rewrites this file a few times a second; a read that collides with a
	-- write can come back empty. So we keep each ghost in ghostMeta with a lastSeen frame
	-- and rebuild the visible list from there, only dropping a ghost after GHOST_TTL frames
	-- of silence. A single missed/empty read therefore never makes sprites blink.
	local function ghostReadOthers()
		if not GHOST_ENABLED or not ghostInPath then return end
		local lines = FileManager.readLinesFromFile(ghostInPath)
		if lines then
			for _, line in ipairs(lines) do
				local name, m, x, y, d, f = line:match("^(.-)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)")
				if name and name ~= "" then
					local nx, ny, nd, nm = tonumber(x), tonumber(y), tonumber(d), tonumber(m)
					local nf = tonumber(f) or 0
					local meta = ghostMeta[name]
					if meta ~= nil and meta.dying then
						-- already playing the death fade-out: freeze; ignore all further updates
						-- (incl. the player resetting into a new run) until the animation ends.
					elseif meta ~= nil and meta.deadDone then
						-- death animation already played. The companion keeps relaying the dead
						-- player's last f=2 state, so without this latch the animation would
						-- restart every time it finished. Stay hidden until they revive (f=0).
						if nf == 2 then
							meta.lastSeen = ghostFrame
						else
							ghostMeta[name] = { name = name, map = nm, x = nx, y = ny, d = nd,
								fx = nx, fy = ny, vx = 0, vy = 0,
								lastMoveFrame = ghostFrame, lastSeen = ghostFrame, firstSeen = ghostFrame }
						end
					elseif nf == 2 then
						-- DEATH: latch a red fade-out at the current spot.
						if meta == nil then
							meta = { name = name, map = nm, x = nx, y = ny, d = nd,
								fx = nx, fy = ny, vx = 0, vy = 0,
								lastMoveFrame = ghostFrame, lastSeen = ghostFrame, firstSeen = ghostFrame }
							ghostMeta[name] = meta
						end
						meta.map = nm; meta.x = nx; meta.y = ny; meta.d = nd
						meta.dying = true; meta.deathFrame = ghostFrame; meta.lastSeen = ghostFrame
					elseif meta == nil then
						-- track target tile + display pos (fx,fy) the draw loop eases toward (glide,
						-- not teleport), per-move velocity (vx,vy), and firstSeen for the fade-in.
						ghostMeta[name] = { name = name, map = nm, x = nx, y = ny, d = nd,
							fx = nx, fy = ny, vx = 0, vy = 0,
							lastMoveFrame = ghostFrame, lastSeen = ghostFrame, firstSeen = ghostFrame }
					else
						if nx ~= meta.x or ny ~= meta.y then
							meta.vx = nx - meta.x; meta.vy = ny - meta.y   -- velocity for dead-reckoning
							meta.lastMoveFrame = ghostFrame
							-- warp / map change: don't slide across the screen, just appear there
							if math.abs(nx - meta.fx) >= GHOST_SNAP or math.abs(ny - meta.fy) >= GHOST_SNAP then
								meta.fx = nx; meta.fy = ny; meta.firstSeen = ghostFrame  -- re-fade after a warp
							end
						end
						meta.map = nm; meta.x = nx; meta.y = ny; meta.d = nd
						meta.lastSeen = ghostFrame
					end
				end
			end
		end
		-- Rebuild the visible list. Dying ghosts persist until their death animation ends
		-- (independent of TTL); everyone else is forgotten after GHOST_TTL frames of silence.
		local players = {}
		for name, meta in pairs(ghostMeta) do
			if meta.dying then
				if (ghostFrame - meta.deathFrame) < GHOST_DEATH_FRAMES then
					table.insert(players, meta)
				else
					-- animation finished: keep an invisible tombstone so the still-relayed
					-- f=2 state can't re-trigger the animation (see deadDone in the parser).
					meta.dying = false
					meta.deadDone = true
					meta.lastSeen = ghostFrame
				end
			elseif (ghostFrame - (meta.lastSeen or 0)) < GHOST_TTL then
				if not meta.deadDone then table.insert(players, meta) end
			else
				ghostMeta[name] = nil
			end
		end
		ghostPlayers = players
	end

	local function readS16(addr)
		local v = Memory.readword(addr)
		if v >= 0x8000 then v = v - 0x10000 end
		return v
	end

	-- Fade tier (0=faintest .. GHOST_TIERS-1=steady) from time-since-appear and time-to-TTL.
	local function ghostTier(meta)
		local top = GHOST_TIERS - 1
		local step = GHOST_FADE_FRAMES / top
		local fin = math.floor((ghostFrame - meta.firstSeen) / step)   -- fade IN over GHOST_FADE_FRAMES
		local remain = GHOST_TTL - (ghostFrame - meta.lastSeen)
		local fout = top
		if remain < GHOST_FADE_FRAMES then fout = math.floor(remain / step) end   -- fade OUT near TTL
		local tier = math.min(fin, fout)
		if tier < 0 then tier = 0 elseif tier > top then tier = top end
		return tier
	end

	-- Death fade: hold full-opacity red briefly, then fade the tier down to 0 over the rest.
	local function ghostDeathTier(meta)
		local top = GHOST_TIERS - 1
		local elapsed = ghostFrame - meta.deathFrame
		if elapsed < GHOST_DEATH_HOLD then return top end
		local fadeDur = GHOST_DEATH_FRAMES - GHOST_DEATH_HOLD
		local tier = math.floor(top * (1 - (elapsed - GHOST_DEATH_HOLD) / fadeDur))
		if tier < 0 then tier = 0 elseif tier > top then tier = top end
		return tier
	end

	-- Draw each same-map ghost: drop shadow + greyed walking sprite (fading) + colored name.
	-- Screen pos = still tile offset + live camera-scroll delta (glides with the world) and a
	-- short velocity lead (dead-reckoning) to hide network latency.
	local function ghostDraw()
		if not GHOST_ENABLED then return end
		-- The battle screen replaces the overworld, so ghosts have nowhere sensible to
		-- stand -- hide them until the battle ends (their state keeps updating underneath).
		if Battle ~= nil and Battle.inBattleScreen then return end
		local myMap = TrackerAPI.getMapId() or 0
		local scox = readS16(GHOST_SCO_X)
		local scoy = readS16(GHOST_SCO_Y)
		-- Source ALL camera tracking from this single scox/scoy read (one callback, one frame)
		-- so the still-reference and the live offset can never come from different frames -- that
		-- phase mismatch was the slight lag between you and the ghosts while walking. Capture the
		-- still reference (player tile + camera offset) whenever the camera isn't scrolling; during
		-- a step we hold it and let (scox - gScoxStill) carry the ghosts smoothly with the world.
		local prevScox = gLastScox or scox
		local prevScoy = gLastScoy or scoy
		if gPxStill == nil or (scox == prevScox and scoy == prevScoy) then
			gPxStill = Memory.readword(GHOST_OBJEVENTS + 0x10)
			gPyStill = Memory.readword(GHOST_OBJEVENTS + 0x12)
			gScoxStill = scox
			gScoyStill = scoy
		end
		-- One-frame scroll lead (see GHOST_SELF_LEAD) to cancel the fixed overlay-draw latency.
		local leadSx = (scox - prevScox) * GHOST_SELF_LEAD
		local leadSy = (scoy - prevScoy) * GHOST_SELF_LEAD
		gLastScox = scox
		gLastScoy = scoy
		if GHOST_DEBUG then
			Drawing.drawText(2, 42, string.format("GHOSTv7 m=%s sco=%s,%s n=%s", tostring(myMap), tostring(scox), tostring(scoy), tostring(#ghostPlayers)), 0xFFFFFF00, 0xFF000000)
		end
		if #ghostPlayers == 0 or gPxStill == nil then return end
		local cx = Constants.SCREEN.WIDTH / 2 - 8
		local cy = Constants.SCREEN.HEIGHT / 2 - 8
		for _, g in ipairs(ghostPlayers) do
			local meta = ghostMeta[g.name]
			if g.map == myMap and g.x and g.y and meta then
				-- dead-reckoning: ease toward the target plus a short velocity lead that relaxes
				-- to 0 after the last move (so a stop doesn't overshoot into a wall).
				local leadScale = 1 - (ghostFrame - meta.lastMoveFrame) / GHOST_LEAD_DECAY
				if leadScale < 0 then leadScale = 0 end
				local tx = g.x + meta.vx * GHOST_LEAD * leadScale
				local ty = g.y + meta.vy * GHOST_LEAD * leadScale
				meta.fx = meta.fx + (tx - meta.fx) * GHOST_EASE
				meta.fy = meta.fy + (ty - meta.fy) * GHOST_EASE
				local sx = math.floor(cx + (meta.fx - gPxStill) * 16 + (scox - gScoxStill) + leadSx)
				local sy = math.floor(cy + (meta.fy - gPyStill) * 16 + (scoy - gScoyStill) + leadSy)
				if sx > -20 and sx < Constants.SCREEN.WIDTH and sy > -20 and sy < Constants.SCREEN.HEIGHT + 20 then
					local col = 0                   -- south/down (default)
					if g.d == 2 then col = 1        -- up
					elseif g.d == 3 then col = 2    -- left
					elseif g.d == 4 then col = 3    -- right
					end
					if meta.dying then
						-- DEATH: red sprite (still pose), hold then fade out where they fell.
						local tier = ghostDeathTier(meta)
						local a = math.floor(255 * tier / (GHOST_TIERS - 1))
						local shA = math.floor(85 * (tier + 1) / GHOST_TIERS)
						gui.drawEllipse(sx + 2, sy + 11, 11, 4, withAlpha(GHOST_SHADOW, 0), withAlpha(GHOST_SHADOW, shA))
						gui.drawImageRegion(ghostRedSpritePath, col * 16, tier * 96, 16, 32, sx, sy - 16)  -- row 0 = still
						if a > 8 then
							local nameX = sx + 8 - math.floor(#g.name * 2.5)
							Drawing.drawText(nameX, sy - 26, g.name,
								withAlpha(0xFF5555, a), withAlpha(0x000000, math.floor(a * 0.75)))
						end
					else
						-- walking = still gliding toward the target (or moved very recently);
						-- while walking, cycle still->stepA->still->stepB, else stand still.
						local gliding = math.abs(g.x - meta.fx) > GHOST_MOVE_EPS or math.abs(g.y - meta.fy) > GHOST_MOVE_EPS
						local moving = gliding or (ghostFrame - meta.lastMoveFrame) < GHOST_WALK_HOLD
						local row = 0
						if moving then
							local phase = math.floor(ghostFrame / GHOST_WALK_RATE) % 4
							if phase == 1 then row = 1
							elseif phase == 3 then row = 2 end
						end
						local tier = ghostTier(meta)
						local a = math.floor(255 * tier / (GHOST_TIERS - 1))   -- 0..255 for the nameplate fade
						-- drop shadow (grounds the sprite; faint sprites cast faint shadows)
						local shA = math.floor(85 * (tier + 1) / GHOST_TIERS)
						gui.drawEllipse(sx + 2, sy + 11, 11, 4, withAlpha(GHOST_SHADOW, 0), withAlpha(GHOST_SHADOW, shA))
						-- 16x32 sprite; source row band picks the opacity tier
						gui.drawImageRegion(ghostSpritePath, col * 16, tier * 96 + row * 32, 16, 32, sx, sy - 16)
						-- colored nameplate (per-player), fading with the sprite
						if a > 8 then
							local nameX = sx + 8 - math.floor(#g.name * 2.5)
							Drawing.drawText(nameX, sy - 26, g.name,
								withAlpha(ghostColor(g.name), a), withAlpha(0x000000, math.floor(a * 0.75)))
						end
					end
				end
			end
		end
	end

	-- Called each frame (Bizhawk); throttle the file I/O to ~15 Hz.
	local function ghostFrameUpdate()
		if not GHOST_ENABLED then return end
		-- Ghosts only mean anything while the IronmonVS monitor is running -- it's what relays our
		-- position out (ghost_out.json) and other players' positions in (ghost_in.txt). If the
		-- monitor isn't running, go FULLY dormant: no disk I/O and -- critically -- no forced
		-- redraws. A leftover ghost_in.txt would otherwise keep "immortal" ghosts alive (every
		-- stale read refreshes their lastSeen, so they never hit GHOST_TTL), and #ghostPlayers > 0
		-- then makes waitToDraw=0 below pin the Tracker at a 60 Hz full redraw -- which tanks the
		-- emulator's framerate even with the monitor closed. Clear any stragglers so the draw loop
		-- has nothing left to pin on. updateMonitorWarning() self-throttles to ~1 Hz internally.
		updateMonitorWarning()
		if self.MonitorWarn.active then
			if next(ghostMeta) ~= nil then ghostMeta = {}; ghostPlayers = {} end
			return
		end
		ghostFrame = ghostFrame + 1   -- Lua doubles hold this exactly for years; no wrap needed
		if ghostFrame % 4 == 0 then      -- file I/O throttled to ~15 Hz
			pcall(ghostWriteSelf)
			pcall(ghostReadOthers)
		end
		-- Smoothness without flicker: force a per-frame tracker redraw while anything that moves a
		-- ghost on screen is happening. That's EITHER a ghost animating (moving/gliding/fading) OR
		-- -- crucially -- the world scrolling under a stationary ghost because *you* are walking:
		-- the ghost's screen position is derived from the camera offset, so if we only redrew at
		-- the idle ~2Hz rate while you moved, stationary ghosts would visibly lag behind the world.
		-- When nothing's moving we let the tracker fall back to its ~2Hz redraw (saves CPU).
		-- (Ghosts are drawn in self.afterRedraw, which runs on each redraw.)
		local scoxNow = readS16(GHOST_SCO_X)
		local scoyNow = readS16(GHOST_SCO_Y)
		local active = (gFrameScox ~= nil and (scoxNow ~= gFrameScox or scoyNow ~= gFrameScoy)
			and #ghostPlayers > 0)   -- world is scrolling and there's a ghost to keep pinned
		gFrameScox = scoxNow
		gFrameScoy = scoyNow
		for _, g in ipairs(ghostPlayers) do
			if g.dying                                                               -- death fade-out
				or (ghostFrame - g.lastMoveFrame) < GHOST_WALK_HOLD                   -- moving/gliding
				or (ghostFrame - g.firstSeen) < GHOST_FADE_FRAMES                     -- fading in
				or (ghostFrame - g.lastSeen) > (GHOST_TTL - GHOST_FADE_FRAMES) then   -- fading out
				active = true
				break
			end
		end
		if active and Program and Program.Frames then
			Program.Frames.waitToDraw = 0
		end
	end
	-- =================== END GHOST PLAYERS =========================================

	-- ===================== FIRST-TIME SETUP (ROM patch + Tracker profile) =====================
	-- One-time onboarding: patch the player's own FireRed into the IronmonVS base ROM (via the
	-- bundled RomPatch/IronMonVS.ips), then create a Tracker "Generate ROM each time" New Run
	-- profile pointed at that ROM + our randomizer jar + FRLG Kaizo rules, so they can start
	-- playing immediately. Uses ONLY public Tracker globals (QuickloadScreen / Options / Main /
	-- FileManager / ExternalUI) -- no Tracker source is modified. Idempotent: a cheap check at
	-- startup skips everything once set up, and silently re-creates the profile if only that
	-- goes missing.

	-- Adler-32 of a binary string. Deliberately uses only +/% (no bitwise library, which isn't
	-- guaranteed across Bizhawk's Lua versions). Chunked via multi-return string.byte for speed;
	-- the 256-byte chunk stays well under the Adler NMAX of 5552 (so deferring the modulo to each
	-- chunk boundary is safe) and well under any Lua value-stack limit on multi-returns.
	local function adler32(s)
		local MOD = 65521
		local a, b = 1, 0
		local len = #s
		local i = 1
		local sbyte = string.byte
		while i <= len do
			local j = i + 255
			if j > len then j = len end
			local t = { sbyte(s, i, j) }
			for k = 1, #t do
				a = a + t[k]
				b = b + a
			end
			a = a % MOD
			b = b % MOD
			i = j + 1
		end
		return b * 65536 + a
	end

	local function readWholeFile(path)
		local f = io.open(path, "rb")
		if not f then return nil end
		local data = f:read("*a")
		f:close()
		return data
	end

	local function writeWholeFile(path, data)
		local f = io.open(path, "wb")
		if not f then return false end
		f:write(data)
		f:close()
		return true
	end

	-- Cheap size lookup (no full read): seek to end.
	local function fileSize(path)
		local f = io.open(path, "rb")
		if not f then return nil end
		local sz = f:seek("end")
		f:close()
		return sz
	end

	-- Apply a standard IPS patch (binary string) to a source ROM (binary string). Lua strings are
	-- immutable, so we build the output as a list of unchanged spans + patched bytes and concat
	-- once (O(n)); the shipped patch's records are in-order and non-overlapping (verified), which
	-- this asserts. Returns the patched string, or nil + reason.
	local function applyIps(src, ips)
		if string.sub(ips, 1, 5) ~= "PATCH" then return nil, "not an IPS file" end
		local sbyte, ssub = string.byte, string.sub
		local parts, np = {}, 0
		local cursor = 0
		local srcLen, ipsLen = #src, #ips
		local i = 6
		while true do
			if i + 2 > ipsLen then return nil, "truncated IPS (no EOF)" end
			local b1, b2, b3 = sbyte(ips, i, i + 2)
			if b1 == 0x45 and b2 == 0x4F and b3 == 0x46 then break end  -- "EOF"
			local off = b1 * 65536 + b2 * 256 + b3
			i = i + 3
			local s1, s2 = sbyte(ips, i, i + 1)
			local size = s1 * 256 + s2
			i = i + 2
			local data
			if size == 0 then                       -- RLE record
				local r1, r2 = sbyte(ips, i, i + 1)
				local rle = r1 * 256 + r2
				i = i + 2
				local v = ssub(ips, i, i)
				i = i + 1
				data = string.rep(v, rle)
			else
				data = ssub(ips, i, i + size - 1)
				i = i + size
			end
			if off > cursor then
				np = np + 1; parts[np] = ssub(src, cursor + 1, off)   -- untouched span [cursor, off)
			elseif off < cursor then
				return nil, "overlapping IPS records"
			end
			np = np + 1; parts[np] = data
			cursor = off + #data
		end
		if cursor < srcLen then
			np = np + 1; parts[np] = ssub(src, cursor + 1)            -- tail
		end
		return table.concat(parts)
	end

	-- Blue "Set up IronmonVS" banner across the top of the game screen (mirrors the monitor
	-- warning). The clickable button is hit-tested in self.inputCheckBizhawk.
	local function drawSetupBanner()
		if not Main.IsOnBizhawk() then return end
		local w = Constants.SCREEN.WIDTH
		gui.drawRectangle(0, 0, w, 38, 0xFF1F6FEB, 0xFF1F6FEB)
		Drawing.drawText(6, 2, "Welcome to IronmonVS!", 0xFFFFFFFF, 0xFF000000)
		Drawing.drawText(6, 12, "One-time setup required", 0xFFFFFFFF, 0xFF000000)
		local b = self.Setup.Button
		gui.drawRectangle(b.x, b.y, b.w, b.h, 0xFF000000, 0xFFFFFFFF)
		Drawing.drawText(b.x + 4, b.y + 2, "Set up IronmonVS", 0xFF1F6FEB)
	end

	-- Our tiny idempotency record: { version, rom, size, guid }.
	function self.readSetupState()
		local st = nil
		pcall(function()
			if FileManager.fileExists and not FileManager.fileExists(self.SetupPaths.state) then return end
			if FileManager.decodeJsonFile then st = FileManager.decodeJsonFile(self.SetupPaths.state) end
		end)
		if type(st) == "table" then return st end
		return nil
	end

	function self.writeSetupState(guid)
		local st = { version = self.Setup.version, rom = self.SetupPaths.rom,
		             size = self.Setup.romSize, guid = guid }
		pcall(function() FileManager.encodeToJsonFile(self.SetupPaths.state, st) end)
	end

	-- Create (or, if guid is given, update in place) a Generate-mode New Run profile and set it
	-- active. addUpdateProfile persists NewRunProfiles.json, mirrors the paths into Options.FILES,
	-- flips Generate_ROM_each_time, and calls Main.SaveSettings(true) -- all Tracker-native.
	function self.createProfile(jarPath, romPath, rulesPath, guid)
		local ok, res = pcall(function()
			if type(QuickloadScreen) ~= "table" or type(QuickloadScreen.IProfile) ~= "table"
				or type(QuickloadScreen.addUpdateProfile) ~= "function" then
				return nil
			end
			local gen = (QuickloadScreen.Modes and QuickloadScreen.Modes.GENERATE) or "Generate"
			local profile = QuickloadScreen.IProfile:new({
				Name = self.Setup.profileName,
				Mode = gen,
				GameVersion = "firered",
				Paths = { Jar = jarPath, Rom = romPath, Settings = rulesPath },
			})
			if guid and guid ~= "" then profile.GUID = guid end
			if Options and Options["Game Over condition"] then
				profile.GameOverCondition = Options["Game Over condition"]
			end
			if not QuickloadScreen.addUpdateProfile(profile, true) then return nil end
			return profile.GUID
		end)
		if ok then return res end
		return nil
	end

	-- Click handler: the bare Bizhawk file dialog has no title/description, so first show a small
	-- modal explaining WHAT to pick (your own FireRed ROM), then run the patch flow from its
	-- button. Falls back to opening the picker directly if the Tracker form API is unavailable.
	function self.runSetup()
		if not Main.IsOnBizhawk() then return end

		-- Default the file dialog to the folder of the currently-open ROM.
		local defaultDir = ""
		pcall(function()
			local loaded = FileManager.getLoadedRomPath and FileManager.getLoadedRomPath()
			if loaded and loaded ~= "" and FileManager.getPathParts then
				defaultDir = (FileManager.getPathParts(loaded)) or ""
			end
		end)

		local shown = pcall(function()
			local X = 20
			local form = ExternalUI.BizForms.createForm("IronmonVS First-Time Setup", 440, 180, 60, 30)
			form:createLabel("Choose your own Pokemon FireRed (USA) ROM.", X, 18)
			form:createLabel("IronmonVS patches a COPY of it to build the game ROM used", X, 40)
			form:createLabel("for competitions. Your original FireRed file is not changed.", X, 58)
			form:createButton("Choose FireRed ROM...", X, 98, function()
				ExternalUI.BizForms.destroyForm()
				self.patchFromRom(defaultDir)
			end, 170, 26)
			form:createButton("Cancel", X + 190, 98, function()
				ExternalUI.BizForms.destroyForm()
			end, 90, 26)
		end)
		if not shown then self.patchFromRom(defaultDir) end   -- no form API -> straight to picker
	end

	-- Ask for the FireRed ROM, then patch -> verify -> save base ROM -> create profile.
	function self.patchFromRom(defaultDir)
		local S, P = self.Setup, self.SetupPaths

		-- The filename box is the only text the file dialog itself shows, so seed it with a
		-- reminder (mirrors the Tracker's own "SELECT A ROM" convention; the modal above is the
		-- primary instruction). CheckFileExists keeps this from being openable as a real file.
		local romPath = ""
		pcall(function()
			romPath = ExternalUI.BizForms.openFilePrompt("SELECT YOUR FIRERED ROM", defaultDir or "",
				"GBA ROM (*.gba)|*.gba|All files (*.*)|*.*") or ""
		end)
		if romPath == "" then return end   -- cancelled

		local src = readWholeFile(romPath)
		if not src then gui.addmessage("IronmonVS: couldn't read that ROM."); return end
		if #src ~= S.romSize then
			gui.addmessage("IronmonVS: that's not a 16MB GBA ROM -- pick your FireRed ROM.")
			return
		end

		local ipsBytes = readWholeFile(P.ips)
		if not ipsBytes then gui.addmessage("IronmonVS: missing RomPatch/IronMonVS.ips."); return end

		local patched, perr = applyIps(src, ipsBytes)
		if not patched then gui.addmessage("IronmonVS: patch failed (" .. tostring(perr) .. ")."); return end
		if adler32(patched) ~= S.baseAdler then
			gui.addmessage("IronmonVS: that doesn't look like the correct FireRed (USA) ROM.")
			return
		end
		if not writeWholeFile(P.rom, patched) then
			gui.addmessage("IronmonVS: couldn't save the patched ROM."); return
		end

		if P.rules == "" or not FileManager.fileExists(P.rules) then
			gui.addmessage("IronmonVS: couldn't find the FRLG Kaizo ruleset in the Tracker.")
			return
		end

		local prev = self.readSetupState()
		local guid = self.createProfile(P.jar, P.rom, P.rules, prev and prev.guid)
		if not guid then gui.addmessage("IronmonVS: couldn't create the Tracker profile."); return end

		self.writeSetupState(guid)
		self.Setup.ready = true
		self.Setup.warnActive = false
		gui.addmessage("IronmonVS is ready! Press A + B + Start to load your first seed.")
	end

	-- Startup idempotency check (cheap: state file + fileExists + size). Self-heals the profile
	-- silently if only it went missing (e.g. profiles reset). No prompting when already set up.
	function self.checkSetup()
		self.Setup.ready = false
		self.Setup.warnActive = false
		if not Main.IsOnBizhawk() then return end   -- BizHawk-only flow

		local P = self.SetupPaths
		local st = self.readSetupState()
		local romOk = st and st.version == self.Setup.version
			and FileManager.fileExists(P.rom) and (fileSize(P.rom) == self.Setup.romSize)

		if romOk then
			local haveProfile = false
			pcall(function()
				haveProfile = st.guid and type(QuickloadScreen) == "table"
					and type(QuickloadScreen.Profiles) == "table"
					and QuickloadScreen.Profiles[st.guid] ~= nil
			end)
			if not haveProfile then
				local guid = self.createProfile(P.jar, P.rom, P.rules, st.guid)
				if guid then self.writeSetupState(guid) end
			end
			self.Setup.ready = true
			return
		end
		self.Setup.warnActive = true   -- show the "Set up IronmonVS" banner
	end
	-- =================== END FIRST-TIME SETUP =========================================

	-- Executed once every 30 frames or after any redraw event is scheduled
	function self.afterRedraw()
		updateMonitorWarning()
		readSeedDisplay()
		updateSeedCheck()
		-- Setup-needed is the most fundamental problem (can't play at all), then monitor-down.
		if self.Setup.warnActive and not self.Setup.ready then
			drawSetupBanner()
		elseif self.MonitorWarn.active then
			drawMonitorWarning()
		elseif self.WrongSeed then
			drawWrongSeedWarning()
		end
		drawSeedDisplay()
		pcall(ghostDraw)  -- ghost players (removable)
	end

	-- [Bizhawk only] Executed each frame: detect a click on the warning's "Open Monitor"
	-- button and launch the monitor. Uses the same coordinate space the Tracker uses for
	-- mouse input, so the hit-test matches what's drawn on the game screen.
	function self.inputCheckBizhawk()
		pcall(ghostFrameUpdate)  -- ghost players: read my pos + others (removable)
		local setupBanner = self.Setup.warnActive and not self.Setup.ready
		if not setupBanner and not self.MonitorWarn.active then
			self._bannerMouseDown = false
			return
		end
		local mouseInput = input.getmouse()
		local down = mouseInput["Left"]
		-- Fire once on the press (edge), not every frame the button is held.
		if down and not self._bannerMouseDown then
			local x = mouseInput["X"]
			local y = mouseInput["Y"] + Constants.SCREEN.UP_GAP
			local function hit(b) return x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h end
			-- The setup banner takes precedence over the monitor warning (same as drawing).
			if setupBanner then
				if hit(self.Setup.Button) then pcall(self.runSetup) end
			elseif self.MonitorWarn.active then
				if hit(self.WarnButton) then self.launchMonitor() end
			end
		end
		self._bannerMouseDown = down
	end

	-- Executed only once: When the extension is enabled by the user, and/or when the Tracker first starts up, after it loads all other required files and code
	function self.startup()
		-- Build out paths to files within the extension folder
		local extFolderPath = FileManager.getCustomFolderPath() .. "IronmonVS" .. FileManager.slash
		self.Paths.DataOutput = extFolderPath .. self.DATA_OUTPUT_FILE
		self.Paths.Heartbeat = extFolderPath .. self.HEARTBEAT_FILE
		self.Paths.SeedDisplay = extFolderPath .. self.SEED_DISPLAY_FILE
		ghostOutPath = extFolderPath .. GHOST_OUT_FILE   -- ghost players (removable)
		ghostInPath = extFolderPath .. GHOST_IN_FILE
		ghostSpritePath = extFolderPath .. GHOST_SPRITE_FILE
		ghostRedSpritePath = extFolderPath .. GHOST_RED_FILE

		-- First-time setup paths (see the FIRST-TIME SETUP section). ROM/patch/state live in the
		-- extension folder; the rules file ships with the Tracker under ironmon_tracker/.
		self.SetupPaths = {
			ips   = extFolderPath .. "RomPatch" .. FileManager.slash .. "IronMonVS.ips",
			jar   = extFolderPath .. "IronmonVS-Randomizer" .. FileManager.slash .. "IronmonVS-Randomizer.jar",
			rom   = extFolderPath .. self.Setup.patchedName,
			state = extFolderPath .. self.Setup.stateFile,
			rules = "",
		}
		pcall(function()
			if FileManager.Folders and FileManager.Folders.TrackerCode and FileManager.prependDir then
				self.SetupPaths.rules = FileManager.prependDir(FileManager.Folders.TrackerCode
					.. FileManager.slash .. "RandomizerSettings" .. FileManager.slash .. self.Setup.rulesName)
			end
		end)

		-- Create extension folder if it doesn't exist
		os.execute("mkdir \"" .. extFolderPath .. "\" 2>nul")

		-- Initialize data file with empty JSON object
		local file = io.open(self.Paths.DataOutput, "w")
		if file then
			file:write("{}")
			file:close()
		end

		-- Clear any ghost_in.txt left over from a previous session. A stale file would otherwise
		-- feed "immortal" ghosts (see ghostFrameUpdate) the instant the extension loads, before a
		-- monitor is even up -- the monitor rewrites this with live data once it's running.
		local ghostIn = io.open(ghostInPath, "w")
		if ghostIn then ghostIn:close() end

		-- Decide whether first-time setup is still needed (cheap; self-heals a missing profile).
		pcall(self.checkSetup)
	end

	-- Executed only once: When the extension is disabled by the user, necessary to undo any customizations, if able
	function self.unload()
		-- Nothing to clean up
	end

	return self
end
return IronmonVS