local function IronmonVS()
	local self = {
		version = "1.50",
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
	-- Wrong-ROM detection: the loaded ROM isn't the competition's AutoRandomized ROM at all
	-- (e.g. a stale or base ROM opened directly in Bizhawk). The seed-content check alone
	-- MISSES this in "Generate ROM each time" mode -- the seed log is named after the settings
	-- file, so getLoadedSeed() reads the last generated seed's log even when a different ROM is
	-- loaded, making a wrong ROM look correct. Comparing the loaded ROM name catches it.
	self.WrongRom = false
	-- End-of-run grace: for a short window after a run ends, the loaded seed churns (the
	-- tracker/monitor rolls to the next seed while the finished ROM is still up). Show a calm
	-- "End of run detected" instead of alarming "WRONG SEED" during that window.
	self.RUN_END_GRACE = 30
	self.RunEnd = { at = nil }
	self.RunEndRecent = false
	self.LoadedSeed = { value = nil, lastRead = 0 }
	self.SeedCheck = { lastCheck = 0, mismatchSince = nil, lastLoaded = nil, lastExpected = nil, lastWrongRom = false }

	-- Monitor-running warning state (throttled file check + current verdict).
	self.MonitorWarn = {
		active = false,
		lastCheck = 0,
		mouseWasDown = false,  -- for click edge-detection on the warning's button
	}

	-- Clickable "Open Monitor" button inside the warning banner (game-screen coords).
	self.WarnButton = { x = 6, y = 23, w = 150, h = 13 }
	-- The end-of-run / wrong-seed banners can be dismissed with an on-screen "Got it" button so the
	-- player can read the Tracker's log viewer underneath. Auto-resets once the correct seed loads.
	self.SeedBannerDismissed = false
	self.GotItButton = { x = 0, y = 2, w = 40, h = 11 }   -- x resolved at draw time (screen width)

	-- Previous-save carryover guard. A New Run regenerates the ROM under the SAME filename, so
	-- BizHawk keeps loading the same .sav and savestates. If the player Continues from an old save
	-- (or loads an old state) on a fresh seed, the game already holds the PREVIOUS run's badges and
	-- trainers, and the very first snapshot would credit them to the new seed. The guard spots that
	-- and holds every data write until the player resets (New Game) or explicitly confirms.
	-- See the PREVIOUS-SAVE CARRYOVER GUARD section for the logic.
	self.LAST_RUN_FILE = "last_run.json"   -- identity + progress of the last run seen; survives script restarts
	self.CARRYOVER_RESET_GRACE = 3          -- seconds after "Reset Run" before game memory is trusted again
	self.Carryover = {
		stage = nil,             -- nil | "prompt" | "confirm" | "resetconfirm" | "reset"
		blocked = false,         -- true => the data tick is skipped entirely (nothing written)
		accepted = false,        -- player chose "Continue Anyway" + OK for the run in play
		summary = "",            -- e.g. "7 badges, 61 trainers" for the banner
		resetAt = nil,           -- os.time() of the Reset Run click
		lastRun = nil,           -- decoded LAST_RUN_FILE (or nil)
		stateLoadedTicks = 0,    -- >0 for a couple of ticks after BizHawk's onloadstate fires
		lastTick = nil,          -- progress seen on the previous tick (savestate jump detection)
		ResetButton    = { x = 6,   y = 36, w = 66,  h = 13 },
		ContinueButton = { x = 80,  y = 36, w = 100, h = 13 },
		OkButton       = { x = 6,   y = 36, w = 34,  h = 13 },
		BackButton     = { x = 48,  y = 36, w = 56,  h = 13 },
	}

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
		version     = 1,           -- legacy re-patch lever; baseAdler now auto-forces a re-patch on any IPS change
		romSize     = 16777216,    -- 16MB FireRed
		baseAdler   = 0x95ef1c70,  -- adler32 of the correctly-patched IronmonVS base ROM (matches Build/IronMonVS.ips)
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

	-- Randomizer seeds are 48-bit (up to 15 digits). On Lua 5.1 (older BizHawk builds),
	-- tostring()/%.14g renders numbers >= 1e14 in ROUNDED scientific notation ("2.799e+14"),
	-- silently corrupting the seed once it reaches the JSON file. Seeds must therefore be
	-- carried as exact digit STRINGS everywhere; if a number sneaks in, %.0f recovers every
	-- digit exactly (48 bits < 2^53, so the double itself is still exact).
	local function seedToString(seed)
		if seed == nil then return nil end
		if type(seed) == "number" then return string.format("%.0f", seed) end
		return tostring(seed):match("^%s*(%d+)%s*$")
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
		-- Run-end overworld tile (map id + x/y) for the death-puddle overlay other players
		-- see on the same seed. Frozen where the run ends (the finishing snapshot).
		jsonContent = jsonContent .. '  "death_map": ' .. tostring(data.death_map or 0) .. ",\n"
		jsonContent = jsonContent .. '  "death_x": ' .. tostring(data.death_x or 0) .. ",\n"
		jsonContent = jsonContent .. '  "death_y": ' .. tostring(data.death_y or 0) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_MtMoon": ' .. tostring(data.fullClear_MtMoon or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_RockTunnel": ' .. tostring(data.fullClear_RockTunnel or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_SilphCo": ' .. tostring(data.fullClear_SilphCo or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_RocketHideout": ' .. tostring(data.fullClear_RocketHideout or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_SSAnne": ' .. tostring(data.fullClear_SSAnne or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_VictoryRoad": ' .. tostring(data.fullClear_VictoryRoad or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_PokemonTower": ' .. tostring(data.fullClear_PokemonTower or false) .. ",\n"
		jsonContent = jsonContent .. '  "fullClear_CinnabarMansion": ' .. tostring(data.fullClear_CinnabarMansion or false) .. ",\n"
		-- True when the player confirmed a suspected previous-save carryover for this run
		-- (the monitor otherwise refuses a brand-new run that already has badges).
		jsonContent = jsonContent .. '  "carryoverAccepted": ' .. tostring(data.carryoverAccepted or false) .. ",\n"
		-- Extension version, so the monitor can report it to the site's player health board.
		jsonContent = jsonContent .. '  "extVersion": "' .. tostring(self.version or "") .. '",\n'
		-- Seed is written as a JSON STRING: a bare number would be parsed as a float
		-- downstream and lose digits (see seedToString).
		local seedStr = seedToString(data.RandomSeed)
		jsonContent = jsonContent .. '  "RandomSeed": ' .. (seedStr and ('"' .. seedStr .. '"') or "null") .. ",\n"
		-- Cause of death + status counts (see CAUSE OF DEATH + STATUS COUNTS); same defensive encode.
		for _, key in ipairs({ "death_cause", "status_counts" }) do
			local okEnc, enc = pcall(encodeJson, data[key])
			jsonContent = jsonContent .. '  "' .. key .. '": ' .. ((okEnc and enc) or "null") .. ",\n"
		end
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
			return seedToString(seedMatch)
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
	-- The player's own tracker notes on a pivot species, for teammates: stat marks, the moves
	-- they've seen it use (Tracker's per-species move list), abilities they've confirmed, the
	-- free-text note, and the last level / wild-encounter count. All of it is TDAT data the
	-- player built while playing (seen-only); nothing is read from the ROM.
	local function pivotNotes(pid)
		local m = { id = pid, name = PokemonData.Pokemon[pid].name, marks = getStatMarks(pid) }
		pcall(function()
			local moves = {}
			for _, mv in ipairs(Tracker.getMoves(pid) or {}) do
				local md = mv.id and mv.id > 0 and MoveData.Moves[mv.id]
				if md then moves[#moves + 1] = { move = md.name, level = mv.level } end
			end
			if #moves > 0 then m.moves = moves end
		end)
		pcall(function()
			local abilities = {}
			for _, ab in ipairs(Tracker.getAbilities(pid) or {}) do
				local ad = ab.id and ab.id > 0 and AbilityData.Abilities[ab.id]
				if ad then abilities[#abilities + 1] = ad.name end
			end
			if #abilities > 0 then m.abilities = abilities end
		end)
		pcall(function()
			local note = Tracker.getNote(pid)
			if type(note) == "string" and note:match("%S") then m.note = note:sub(1, 200) end
		end)
		pcall(function()
			local lv = tonumber(Tracker.getLastLevelSeen(pid))
			if lv and lv > 0 then m.level = lv end
			local seen = tonumber(Tracker.getEncounters(pid, true))
			if seen and seen > 0 then m.seen = seen end
		end)
		return m
	end

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
							list[#list + 1] = pivotNotes(pid)
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
						local seed = seedToString(RandomizerLog.Data.Settings.RandomSeed)
						if seed then return seed end
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
									local seed = seedToString(RandomizerLog.Data.Settings.RandomSeed)
									if seed then return seed end
								end
							end

							-- Fallback: parse manually using the pattern
							if type(RandomizerLog.Patterns) == "table" and type(RandomizerLog.Patterns.RandomizerSeed) == "string" then
								local pattern = RandomizerLog.Patterns.RandomizerSeed
								local seed = seedToString(string.match(logLines[2] or "", pattern))
								if seed then return seed end
							end

							-- Last resort: try simple pattern matching
							local seed = seedToString(string.match(logLines[2] or "", "Random Seed:%s*(%d+)"))
							if seed then return seed end
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

		-- Run-end overworld tile for the death-puddle overlay: read the player's tile from
		-- gObjectEvents[0] (FRLG), same source the ghost overlay uses. Written on every update;
		-- the final (game-over) snapshot leaves it frozen at the tile where the run ended.
		-- Guarded so a bad memory read can never break the data update; defaults to 0.
		info.death_map = TrackerAPI.getMapId() or 0
		local okDX, dX = pcall(Memory.readword, 0x02036E38 + 0x10)
		local okDY, dY = pcall(Memory.readword, 0x02036E38 + 0x12)
		info.death_x = (okDX and dX) or 0
		info.death_y = (okDY and dY) or 0

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
		info.carryoverAccepted = self.Carryover.accepted and true or false

		-- Rich per-seed detail (seen-only pivots + the player's own party). Nested object.
		info.extra = collectExtra()

		-- What ended the run (nil while alive) + unique status inflictions this run.
		if self.DeathTrack then
			local okDt, cause, counts = pcall(self.DeathTrack.payload)
			if okDt then
				info.death_cause = cause
				info.status_counts = counts
			end
		end

		return info
	end

	-- Per-seed accumulator of SEEN enemy trainer teams: trainerId -> { id, name, class,
	-- team = { [pokemonID*1000+level] = { id, name, level, moveset = {moveId=true} } } }.
	-- Filled live during trainer battles from the active enemy + its revealed moves.
	self.SeenTrainers = {}

	self.PerSeedVars = {
		PokemonDead = false,
		RunEndRecorded = false,   -- run-over (death or champ) recorded once, for the end-of-run grace
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
		if self.DeathTrack then
			-- New seed: zero the counts. Script restart mid-run: run_stats.json brings them back.
			self.DeathTrack.reset()
			pcall(self.DeathTrack.restore)
		end
		local V = self.PerSeedVars
		V.PokemonDead = false
		V.RunEndRecorded = false
		self.RunEnd.at = nil
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

	-- FireRed's "Previously on your quest..." recap (shown after Continue). While it plays, the
	-- game copies each recorded scene's OLD flags/vars over the live ones (QL_CopySaveState) and
	-- swaps in placeholder party mons, then reloads the real save at the end. So during playback
	-- badges and trainers read as a past state that changes scene by scene: a baseline taken
	-- there sees too little, and the real save's badges then look like brand-new wins. Nothing
	-- may be read or written until it ends. gQuestLogState (pret rev1 .sym): 2 = PLAYBACK,
	-- 3 = PLAYBACK_LAST, back to 0 when the player dismisses the recap.
	local QUEST_LOG_STATE = 0x0203ADFA
	local function questLogPlaying()
		local ok, st = pcall(Memory.readbyte, QUEST_LOG_STATE)
		return ok and (st == 2 or st == 3)
	end

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
		if not isPlayingFRLG() or not Program.isValidMapLocation() or questLogPlaying() then
			return
		elseif self.Carryover.blocked then
			-- A suspected previous-save carryover is waiting on the player: write NOTHING until
			-- they reset the game or confirm (see the PREVIOUS-SAVE CARRYOVER GUARD section).
			self.updateCarryover()
			return
		elseif not loadedVarsThisSeed then
			-- Before adopting this game state as the run's baseline, make sure it isn't an old
			-- save's progress sitting on a fresh seed. If it is, the prompt is now up and every
			-- tick returns early above until the player decides.
			if self.checkCarryoverAtStart() then
				return
			end
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

		-- Savestate jump detection + first-progress bookkeeping. May raise the carryover prompt,
		-- in which case this tick must not write anything.
		self.checkCarryoverAfterTick()
		if self.Carryover.blocked then
			return
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
				self.markRunEnded()   -- start the end-of-run grace (suppress "wrong seed" churn)
				local data = collectSimplifiedData(leadPokemon)
				writeDataToFile(data)
			end
		end

		-- Champion win also ends the run; the player will roll to the next seed afterward, so
		-- treat the seed churn that follows as "end of run" rather than "wrong seed".
		if not V.RunEndRecorded and getHighestMilestone() == "champ" then
			self.markRunEnded()
		end
	end

	-- Record that the current run is over (once per seed). Stamps the time so the seed check
	-- can show "End of run detected" for RUN_END_GRACE seconds instead of "WRONG SEED".
	function self.markRunEnded()
		self.PerSeedVars.RunEndRecorded = true
		self.RunEnd.at = os.time()
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

		if self.WrongSeed and not self.RunEndRecent then
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
							return seedToString(match)
						end
					end
					file:close()
				end
			end
			-- Fallback: whatever the tracker has already parsed (e.g. via the log overlay).
			if type(RandomizerLog) == "table" and type(RandomizerLog.Data) == "table"
				and type(RandomizerLog.Data.Settings) == "table" then
				return seedToString(RandomizerLog.Data.Settings.RandomSeed)
			end
			return nil
		end)
		self.LoadedSeed.value = (ok and seed) or nil
		return self.LoadedSeed.value
	end

	-- The ROM name a correct competition New Run produces: "<settings file> AutoRandomized"
	-- (same recipe the tracker uses to name the generated ROM + its log). Only meaningful in
	-- "Generate ROM each time" mode; nil otherwise (premade-ROM mode reads the log next to the
	-- actual loaded ROM, so its seed-content check already can't be fooled by a wrong ROM).
	-- ===================== PREVIOUS-SAVE CARRYOVER GUARD =====================
	-- Why this exists: the seeded randomizer writes every seed to the same ROM filename so the
	-- player's post-intro save carries over (no redoing the intro). The flip side is that an
	-- in-game save made mid-run, or an old savestate, also carries over. On the first tick of a
	-- fresh seed the game then reports the previous run's badges/trainers, and without this guard
	-- that snapshot was written to the data file and uploaded under the NEW seed.
	--
	-- Detection (self.checkCarryoverAtStart, first valid tick after the script starts): the game
	-- shows progress, but LAST_RUN_FILE says the last run we saw was a different seed -- or this
	-- seed before it had earned any progress. A relaunch of BizHawk mid-run (same seed, already
	-- progressed) is NOT flagged. A missing record (first install) with progress IS flagged: one
	-- confirmation click beats silently mis-crediting a run.
	-- Detection (self.checkCarryoverAfterTick, every tick): after BizHawk reports a savestate load,
	-- progress that JUMPS forward between two ticks came from another run's state (a same-run
	-- crash recovery only ever goes backward or stays put).
	--
	-- While flagged, self.Carryover.blocked is true and afterProgramDataUpdate writes nothing.
	-- "Reset Run" power-cycles the core (client.reboot_core) and asks for NEW GAME at the title
	-- screen; the hold releases once the game reads as progress-free. "Continue Anyway" needs a
	-- second OK, then the run is recorded with carryoverAccepted=true so the monitor lets it
	-- through, and the decision is remembered in LAST_RUN_FILE so a relaunch doesn't re-ask.

	local function readLastRun()
		local rec = nil
		pcall(function()
			local path = self.Paths.LastRun
			if not path or path == "" then return end
			if FileManager.fileExists and not FileManager.fileExists(path) then return end
			if FileManager.decodeJsonFile then rec = FileManager.decodeJsonFile(path) end
		end)
		if type(rec) ~= "table" then return nil end
		return rec
	end

	local function writeLastRun(rec)
		pcall(function()
			local path = self.Paths.LastRun
			if path and path ~= "" and FileManager.encodeToJsonFile then
				FileManager.encodeToJsonFile(path, rec)
			end
		end)
	end

	-- Everything the game remembers about run progress. A fresh seed (New Game, or the post-intro
	-- lab save) has none of it; a Continued old save or an old savestate has some.
	local function readProgress()
		local highest, flags = getHighestMilestone()
		flags = flags or {}
		local badges = 0
		for _, k in ipairs({ "brock", "misty", "surge", "erika", "koga", "sabrina", "blaine", "giovanni" }) do
			if flags[k] then badges = badges + 1 end
		end
		local trainers = tonumber(getTotalDefeatedTrainers(false)) or 0
		local clears = 0
		for _, v in pairs(getDungeonFullClears() or {}) do
			if v then clears = clears + 1 end
		end
		local idx = 0
		for i, m in ipairs(self.MILESTONE_ORDER) do
			if m == highest then idx = i end
		end
		local parts = {}
		if badges > 0 then parts[#parts + 1] = badges .. (badges == 1 and " badge" or " badges") end
		if trainers > 0 then parts[#parts + 1] = trainers .. (trainers == 1 and " trainer" or " trainers") end
		local any = (highest ~= nil) or badges > 0 or trainers > 0 or clears > 0
		if any and #parts == 0 then parts[1] = "progress" end
		return {
			any = any, badges = badges, trainers = trainers, milestoneIdx = idx,
			summary = table.concat(parts, ", "),
		}
	end

	-- True once the player's overworld object exists (gObjectEvents[0] active with real tile
	-- coords). FireRed loads the .sav into memory at the MAIN MENU already, so progress flags and
	-- a valid map id are visible before the player has picked Continue or New Game; the object
	-- event only appears when the overworld is actually running. Used so a hold is released or
	-- re-raised on what the player CHOSE, not on what the menu preloaded.
	local function playerInOverworld()
		local ok, active, x = pcall(function()
			return Memory.readbyte(0x02036E38) % 2, Memory.readword(0x02036E38 + 0x10)
		end)
		return ok and active == 1 and (x or 0) > 0
	end

	-- Identity of the run in play: the loaded ROM's randomizer seed (digit string) when
	-- readable, plus the Tracker's attempt counter as a fallback for non-competition play.
	local function currentRunIdentity()
		local seed = nil
		pcall(function() seed = getLoadedSeed() end)
		return seedToString(seed), tonumber(Main.currentSeed) or 0
	end

	local function isSameRun(rec, seed, attempt)
		if type(rec) ~= "table" then return false end
		local recSeed = seedToString(rec.seed)
		if seed and recSeed then return seed == recSeed end
		return (tonumber(rec.attempt) or -1) == attempt
	end

	-- Persist what we know about the run in play (merged into the existing record when it is
	-- the same run, so "progressed"/"accepted" never flip back to false).
	function self.recordLastRun(progressed, accepted)
		local seed, attempt = currentRunIdentity()
		local rec = self.Carryover.lastRun
		if type(rec) ~= "table" or not isSameRun(rec, seed, attempt) then rec = {} end
		rec.seed = seed or rec.seed
		rec.attempt = attempt
		rec.progressed = (rec.progressed or progressed) and true or false
		rec.accepted = (rec.accepted or accepted) and true or false
		rec.updated = os.time()
		self.Carryover.lastRun = rec
		writeLastRun(rec)
	end

	function self.openCarryoverPrompt(prog)
		local C = self.Carryover
		C.stage = "prompt"
		C.blocked = true
		C.accepted = false
		C.summary = (prog and prog.summary) or ""
		C.stateLoadedTicks = 0
		C.lastTick = nil
	end

	-- First valid tick after the script (re)starts. Returns true when the prompt is now up.
	function self.checkCarryoverAtStart()
		local C = self.Carryover
		C.lastRun = readLastRun()
		local ok, prog = pcall(readProgress)
		if not ok or not prog or not prog.any then return false end
		local seed, attempt = currentRunIdentity()
		local rec = C.lastRun
		if isSameRun(rec, seed, attempt) and (rec.progressed or rec.accepted) then
			C.accepted = rec.accepted and true or false
			return false
		end
		self.openCarryoverPrompt(prog)
		return true
	end

	-- Every normal tick: savestate jump detection, and remember the first sign of progress on
	-- this run so a same-seed relaunch is never prompted. May raise the prompt.
	function self.checkCarryoverAfterTick()
		local C = self.Carryover
		local ok, prog = pcall(readProgress)
		if not ok or not prog then return end
		local prev = C.lastTick
		if C.stateLoadedTicks > 0 then
			C.stateLoadedTicks = C.stateLoadedTicks - 1
			-- Between two ticks (~0.5s) a real game advances at most one battle; anything more
			-- came in with the state. Only forward jumps count (rollbacks are crash recovery).
			if prev and not C.accepted and (prog.milestoneIdx > prev.milestoneIdx
					or prog.badges > prev.badges or prog.trainers > prev.trainers + 2) then
				self.openCarryoverPrompt(prog)
				return
			end
		end
		C.lastTick = { milestoneIdx = prog.milestoneIdx, badges = prog.badges, trainers = prog.trainers }
		if prog.any then
			local rec = C.lastRun
			local seed, attempt = currentRunIdentity()
			if not (type(rec) == "table" and rec.progressed and isSameRun(rec, seed, attempt)) then
				self.recordLastRun(true, C.accepted)
			end
		end
	end

	-- Runs instead of the normal tick while the guard holds writes. Once the player is actually
	-- in the overworld: a progress-free game (they chose NEW GAME, via our Reset Run or on their
	-- own) releases the hold from any stage; after Reset Run, progress means Continue was pressed
	-- again, so the prompt comes back.
	function self.updateCarryover()
		local C = self.Carryover
		if C.stage == "reset" and os.time() - (C.resetAt or 0) < self.CARRYOVER_RESET_GRACE then return end
		if not playerInOverworld() then return end
		local ok, prog = pcall(readProgress)
		if not ok or not prog then return end
		if not prog.any then
			C.stage, C.blocked, C.summary = nil, false, ""   -- clean: normal init runs next tick
			loadedVarsThisSeed = false
		elseif C.stage == "reset" then
			self.openCarryoverPrompt(prog)   -- Continue was pressed at the title screen again
		end
	end

	-- "Reset Run": power-cycle the core so the title screen comes up; the player picks NEW GAME.
	function self.carryoverReset()
		local C = self.Carryover
		C.stage = "reset"
		C.resetAt = os.time()
		C.lastTick = nil
		loadedVarsThisSeed = false   -- the game restarts, so the per-seed baseline must be rebuilt
		pcall(function() client.reboot_core() end)
	end

	-- "Continue Anyway" -> OK: record the run as-is from here on.
	function self.carryoverAccept()
		local C = self.Carryover
		C.stage, C.blocked, C.accepted = nil, false, true
		C.lastTick = nil
		self.recordLastRun(true, true)
	end

	local function drawBannerButton(b, label, fg, bg)
		gui.drawRectangle(b.x, b.y, b.w, b.h, 0xFFFFFFFF, bg or 0xFF000000)
		Drawing.drawText(b.x + 4, b.y + 1, label, fg or 0xFFFFFFFF, 0xFF000000)
	end

	-- The carryover banner: red prompt (Reset Run / Continue Anyway), red confirm (OK / Go Back),
	-- or the green "choose NEW GAME" instruction after a reset.
	local function drawCarryoverBanner()
		if not Main.IsOnBizhawk() then return end
		local C = self.Carryover
		local w = Constants.SCREEN.WIDTH
		if C.stage == "reset" then
			gui.drawRectangle(0, 0, w, 38, 0xFF1E7A1E, 0xFF1E7A1E)
			Drawing.drawText(6, 2, "Game reset. At the title screen", 0xFFFFFFFF, 0xFF000000)
			Drawing.drawText(6, 12, "choose NEW GAME (not Continue)", 0xFFFFFF00, 0xFF000000)
			Drawing.drawText(6, 23, "and start from the lab.", 0xFFFFFFFF, 0xFF000000)
			return
		end
		gui.drawRectangle(0, 0, w, 52, 0xFFCC0000, 0xFFCC0000)
		if C.stage == "resetconfirm" then
			Drawing.drawText(6, 2, "RESET THE GAME?", 0xFFFFFF00, 0xFF000000)
			Drawing.drawText(6, 12, "OK restarts the game now.", 0xFFFFFFFF, 0xFF000000)
			Drawing.drawText(6, 23, "Unsaved progress is lost.", 0xFFFFFFFF, 0xFF000000)
			drawBannerButton(C.OkButton, "OK", 0xFFCC0000, 0xFFFFFFFF)
			drawBannerButton(C.BackButton, "Go Back")
		elseif C.stage == "confirm" then
			Drawing.drawText(6, 2, "ARE YOU SURE?", 0xFFFFFF00, 0xFF000000)
			Drawing.drawText(6, 12, "OK will log this run and save", 0xFFFFFFFF, 0xFF000000)
			Drawing.drawText(6, 23, "its data to the server.", 0xFFFFFFFF, 0xFF000000)
			drawBannerButton(C.OkButton, "OK", 0xFFCC0000, 0xFFFFFFFF)
			drawBannerButton(C.BackButton, "Go Back")
		else
			Drawing.drawText(6, 2, "PREVIOUS SAVE LOADED?", 0xFFFFFF00, 0xFF000000)
			local found = (C.summary ~= "") and ("Found: " .. C.summary) or "Found: earlier progress"
			Drawing.drawText(6, 12, found, 0xFFFFFFFF, 0xFF000000)
			Drawing.drawText(6, 23, "Reset and start from the lab.", 0xFFFFFFFF, 0xFF000000)
			drawBannerButton(C.ResetButton, "Reset Run", 0xFFCC0000, 0xFFFFFFFF)
			drawBannerButton(C.ContinueButton, "Continue Anyway")
		end
	end

	local function getExpectedRomName()
		if not (type(Options) == "table" and Options["Generate ROM each time"]
			and Options.FILES and not Utils.isNilOrEmpty(Options.FILES["Settings File"])) then
			return nil
		end
		local settingsFileName = FileManager.extractFileNameFromPath(Options.FILES["Settings File"])
		if Utils.isNilOrEmpty(settingsFileName) then return nil end
		return settingsFileName .. " " .. FileManager.PostFixes.AUTORANDOMIZED
	end

	-- Decide (throttled) whether the wrong ROM or wrong seed is loaded vs the competition's
	-- expected seed. Only enforces when a competition seed is expected (current_seed.txt). Also
	-- flags whether we're within the end-of-run grace window, so the draw code can soften a
	-- transient mismatch into "End of run detected" instead of "WRONG SEED".
	local function updateSeedCheck()
		local now = os.time()
		if now - (self.SeedCheck.lastCheck or 0) < 1 then return end
		self.SeedCheck.lastCheck = now

		-- Digit-string compare, NOT tonumber: seeds stay strings end-to-end (see seedToString).
		local expected = seedToString(self.SeedInfo.seed)

		-- No competition seed expected -> nothing to enforce.
		if not expected then
			self.WrongSeed, self.WrongRom, self.RunEndRecent = false, false, false
			self.SeedCheck.mismatchSince = nil
			self.SeedCheck.lastLoaded, self.SeedCheck.lastExpected = nil, nil
			self.SeedBannerDismissed = false
			return
		end

		-- Just after a run ends, expect the loaded seed to churn -- label mismatches gently.
		self.RunEndRecent = self.RunEnd.at ~= nil and (now - self.RunEnd.at) < self.RUN_END_GRACE

		-- Wrong ROM (name mismatch) takes priority over the seed-content check, since a wrong
		-- ROM makes the seed read unreliable (see getExpectedRomName / findLoadedLogPath notes).
		local wrongRom = false
		local expectedRom = getExpectedRomName()
		if expectedRom then
			local loadedRom = GameSettings.getRomName()
			wrongRom = (not Utils.isNilOrEmpty(loadedRom)) and (loadedRom ~= expectedRom)
		end

		local loaded = getLoadedSeed()
		local wrongSeed = (not wrongRom) and (loaded ~= nil) and (loaded ~= expected)

		if not (wrongRom or wrongSeed) then
			self.WrongSeed, self.WrongRom = false, false
			self.SeedCheck.mismatchSince = nil
			self.SeedBannerDismissed = false   -- correct seed back -> allow the banner again next time
		else
			-- Restart the grace timer if the situation changed (e.g. just re-rolled / swapped).
			if self.SeedCheck.lastLoaded ~= loaded or self.SeedCheck.lastExpected ~= expected
				or self.SeedCheck.lastWrongRom ~= wrongRom or not self.SeedCheck.mismatchSince then
				self.SeedCheck.mismatchSince = now
			end
			local stable = (now - self.SeedCheck.mismatchSince) >= self.WRONG_SEED_GRACE
			self.WrongRom = stable and wrongRom
			self.WrongSeed = stable and wrongSeed
		end
		self.SeedCheck.lastLoaded = loaded
		self.SeedCheck.lastExpected = expected
		self.SeedCheck.lastWrongRom = wrongRom
	end

	-- Small "Got it" dismiss button on the seed/end-of-run banners (top-right so it clears the
	-- left-aligned text). Clicking it (handled in inputCheckBizhawk) hides the banner so the player
	-- can read the Tracker's log viewer underneath. x is resolved here from the live screen width.
	local function drawGotItButton()
		local b = self.GotItButton
		b.x = Constants.SCREEN.WIDTH - b.w - 4
		gui.drawRectangle(b.x, b.y, b.w, b.h, 0xFFFFFFFF, 0xC0303030)
		Drawing.drawText(b.x + 6, b.y + 1, "Got it", 0xFFFFFFFF, 0xFF000000)
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
		drawGotItButton()
	end

	-- Banner warning the player they've loaded the WRONG ROM (not the competition's
	-- AutoRandomized ROM) -- e.g. a stale or base ROM opened directly. A New Run generates
	-- the correct, server-assigned seed ROM.
	local function drawWrongRomWarning()
		if not Main.IsOnBizhawk() then return end
		local w = Constants.SCREEN.WIDTH
		gui.drawRectangle(0, 0, w, 38, 0xFFCC0000, 0xFFCC0000)
		Drawing.drawText(6, 2, "WRONG ROM LOADED", 0xFFFFFF00, 0xFF000000)
		Drawing.drawText(6, 12, "Not your competition ROM.", 0xFFFFFFFF, 0xFF000000)
		Drawing.drawText(6, 23, "Create a new seed (New Run).", 0xFFFFFFFF, 0xFF000000)
		drawGotItButton()
	end

	-- Calm banner shown when a seed mismatch is really just the churn right after a run ends
	-- (death / champ). Avoids alarming the player with "WRONG SEED" for expected end-of-run
	-- behavior; a New Run rolls to the next seed.
	local function drawEndOfRunBanner()
		if not Main.IsOnBizhawk() then return end
		local w = Constants.SCREEN.WIDTH
		gui.drawRectangle(0, 0, w, 27, 0xFF1E7A1E, 0xFF1E7A1E)
		Drawing.drawText(6, 2, "End of run detected", 0xFFFFFFFF, 0xFF000000)
		Drawing.drawText(6, 13, "Start a New Run for your next seed", 0xFFFFFFFF, 0xFF000000)
		drawGotItButton()
	end

	-- ===================== LEAD POKEMON MEMORY =====================================
	-- Direct reads of the Ironmon's (party slot 1) live HP and status, used by the ghost HP bar
	-- and the cause-of-death / status tracking. The tracker's own Tracker.getPokemon only
	-- refreshes every 30 frames; these read RAM on demand. Party "battle stats" (status, HP)
	-- sit in the unencrypted tail of the party struct; in battle the active battler copy in
	-- gBattleMons is the one that changes first. One table so the extension's single big
	-- function doesn't burn a Lua local per helper (5.1 caps them at 200).
	local LeadMem = {
		PARTY = 0x02024284, PARTY_STATUS = 0x50, PARTY_HP = 0x56, PARTY_MAXHP = 0x58,
		BMONS = 0x02023BE4, BMON_SIZE = 0x58, BMON_HP = 0x28, BMON_MAXHP = 0x2C,
		BMON_STATUS1 = 0x4C, BMON_STATUS2 = 0x50,
		BMON_LEVEL = 0x2A, PARTY_LEVEL = 0x54,
		PARTY_IDX = 0x02023BCE,   -- gBattlerPartyIndexes, u16 per battler
	}

	-- Address from the tracker's GameSettings (FireRed v1.0/v1.1 agree), else our fallback.
	function LeadMem.addr(name, fallback)
		local v = GameSettings ~= nil and GameSettings[name] or nil
		if type(v) == "number" and v > 0 then return v end
		return fallback
	end

	-- status1 bits -> small code: 0 none, 1 sleep, 2 poison, 3 burn, 4 freeze, 5 paralysis,
	-- 6 toxic. Arithmetic only (no bitops in BizHawk's Lua 5.1).
	function LeadMem.statusCode(s1)
		s1 = (s1 or 0) % 256
		if s1 % 8 > 0 then return 1 end
		local bits = math.floor(s1 / 8)            -- bit 0 = PSN (0x08) .. bit 4 = TOX (0x80)
		if bits % 2 == 1 then return 2 end
		if math.floor(bits / 16) % 2 == 1 then return 6 end
		if math.floor(bits / 2) % 2 == 1 then return 3 end
		if math.floor(bits / 4) % 2 == 1 then return 4 end
		if math.floor(bits / 8) % 2 == 1 then return 5 end
		return 0
	end

	-- gBattleMons index (0 or 2, the player's side) holding party slot 1, or nil when not in a
	-- battle or the Ironmon isn't on the field (switched out for an HM friend).
	function LeadMem.battler()
		if Battle == nil or not Battle.inActiveBattle() then return nil end
		local idx = LeadMem.addr("gBattlerPartyIndexes", LeadMem.PARTY_IDX)
		if Memory.readword(idx) == 0 then return 0 end
		if Battle.numBattlers == 4 and Memory.readword(idx + 4) == 0 then return 2 end
		return nil
	end

	-- hp, maxHp, statusCode, battlerOrNil for the Ironmon right now. maxHp == 0 means "no valid
	-- Pokemon" (title screen, empty party, garbage) and callers skip it.
	function LeadMem.read()
		local b = LeadMem.battler()
		if b ~= nil then
			local base = LeadMem.addr("gBattleMons", LeadMem.BMONS) + b * LeadMem.BMON_SIZE
			local hp, mhp = Memory.readword(base + LeadMem.BMON_HP), Memory.readword(base + LeadMem.BMON_MAXHP)
			-- gBattlerPartyIndexes flips to slot 1 a frame before gBattleMons is refilled on a
			-- switch-in, so for that frame the battle struct still holds the PREVIOUS mon (e.g. a
			-- fainted HM friend at 0 HP). Only trust it when it is the same mon as party slot 1
			-- (max HP and level; species is encrypted in the party struct). Otherwise fall
			-- through to the party copy, which is correct while the mon is off the field.
			local pp = LeadMem.addr("pstats", LeadMem.PARTY)
			local same = mhp == Memory.readword(pp + LeadMem.PARTY_MAXHP)
				and Memory.readbyte(base + LeadMem.BMON_LEVEL) == Memory.readbyte(pp + LeadMem.PARTY_LEVEL)
			if same and mhp > 0 and mhp <= 999 and hp <= mhp then
				return hp, mhp, LeadMem.statusCode(Memory.readdword(base + LeadMem.BMON_STATUS1)), b
			end
		end
		local p = LeadMem.addr("pstats", LeadMem.PARTY)
		local hp, mhp = Memory.readword(p + LeadMem.PARTY_HP), Memory.readword(p + LeadMem.PARTY_MAXHP)
		if mhp == 0 or mhp > 999 or hp > mhp then return 0, 0, 0, nil end
		return hp, mhp, LeadMem.statusCode(Memory.readdword(p + LeadMem.PARTY_STATUS)), nil
	end
	-- =================== END LEAD POKEMON MEMORY ===================================

	-- ===================== CAUSE OF DEATH + STATUS COUNTS ==========================
	-- What hurt the Ironmon, and how many times it got a status, for the site's end-of-run
	-- stats ("most deaths to Destiny Bond"). Battle scripts only change HP on their
	-- `datahpupdate` command, so on the frame the lead's HP drops, the battle-script PC
	-- (gBattlescriptCurrInstr) sits inside the script that did it: BurnTurnDmg,
	-- DestinyBondTakesLife, DoSelfConfusionDmg, ... SCRIPTS (generated from pret's rev1 symbol
	-- file by Extension/gen_battle_scripts.py, ROM-verified) maps PC ranges to a cause; any
	-- other script is an ordinary move, credited to gCurrentMove + the attacking species.
	-- Poison, burn, wrap, nightmare and curse share one damage tail ("turn"), so the ENTRY
	-- script seen a few frames earlier (its "hurt by poison" message) names those.
	-- Per-frame cost outside battle is one party read; nothing here writes game memory.
	local DeathTrack = {
		DEBUG = false,                 -- true: append every HP drop to damage_log.txt (for testing)
		TEST_FLAG = "deathtest.flag",  -- present (Extension/dev/DeathTest.lua makes it): test mode
		TEST_RESET = "deathtest.reset", -- the harness asks for a fresh slate; consumed when seen
		testOn = false,                -- test mode: log like DEBUG, and every savestate load resets
		diagLeft = 0,                  -- test mode: state lines still to log after a reset
		STATS_FILE = "run_stats.json", -- counts + cause of the run in play; survives script restarts
		PC = 0x02023D74, ATTACKER = 0x02023D6B, CURRENT_MOVE = 0x02023D4A, WEATHER = 0x02023F1C,
		ENTRY_CAUSES = { poison = true, burn = true, trap = true, nightmare = true, curse = true },
		ENTRY_TTL = 300,               -- frames an entry script stays relevant (its message is ~1-2s)
		STATUS_KEYS = { "slp", "psn", "brn", "frz", "par", "tox" },  -- index = LeadMem status code
		frame = 0,
		prevHp = nil, prevSt = nil,    -- last valid read of the lead
		entry = nil,                   -- { cause, frame } of the last entry script seen
		lastHit = nil,                 -- classification of the most recent HP drop
		cause = nil,                   -- frozen once the lead hits 0 HP (the run-ending hit)
		counts = {},                   -- status key -> unique inflictions this run
		path = nil,                    -- set in self.startup()
	}
	-- SCRIPTS is spliced in by Extension/gen_battle_scripts.py; keep the markers.
	-- BEGIN GENERATED BATTLE SCRIPTS (Extension/gen_battle_scripts.py; do not hand-edit)
	-- {start address, cause or false}: sorted; a PC belongs to the last row whose start <= PC.
	DeathTrack.SCRIPTS = {
		{ 0x081D6618, false },  -- gBattleScriptsForMoveEffects
		{ 0x081D6A93, "liquid_ooze" },  -- BattleScript_AbsorbLiquidOoze
		{ 0x081D6AB2, false },  -- BattleScript_AbsorbTryFainting
		{ 0x081D6AE6, "explosion" },  -- BattleScript_EffectExplosion
		{ 0x081D6B57, false },  -- BattleScript_PreserveMissedBitDoMoveAnim
		{ 0x081D7081, "crash" },  -- BattleScript_EffectRecoilIfMiss
		{ 0x081D70D2, false },  -- BattleScript_EffectMist
		{ 0x081D7835, "curse_self" },  -- BattleScript_GhostCurse
		{ 0x081D7886, false },  -- BattleScript_EffectEndure
		{ 0x081D800F, "memento" },  -- BattleScript_EffectMemento
		{ 0x081D8096, false },  -- BattleScript_MementoTargetProtect
		{ 0x081D8AEF, "weather" },  -- BattleScript_DamagingWeatherContinues
		{ 0x081D8B48, false },  -- BattleScript_DamagingWeatherContinuesEnd
		{ 0x081D8BBD, "leech_seed" },  -- BattleScript_LeechSeedTurnDrain
		{ 0x081D8BEF, false },  -- BattleScript_LeechSeedLiquidOoze
		{ 0x081D8BF5, "liquid_ooze" },  -- BattleScript_LeechSeedTurnPrintAndUpdateHp
		{ 0x081D8C19, false },  -- BattleScript_BideStoringEnergy
		{ 0x081D8CDC, "destiny_bond" },  -- BattleScript_DestinyBondTakesLife
		{ 0x081D8CF7, "spikes" },  -- BattleScript_SpikesOnAttacker
		{ 0x081D8D18, false },  -- BattleScript_SpikesOnAttackerFainted
		{ 0x081D8D2E, "spikes" },  -- BattleScript_SpikesOnTarget
		{ 0x081D8D4F, false },  -- BattleScript_SpikesOnTargetFainted
		{ 0x081D8D65, "spikes" },  -- BattleScript_SpikesOnFaintedBattler
		{ 0x081D8D86, false },  -- BattleScript_SpikesOnFaintedBattlerFainted
		{ 0x081D8D9C, "spikes" },  -- BattleScript_PrintHurtBySpikes
		{ 0x081D8DA3, "perish_song" },  -- BattleScript_PerishSongTakesLife
		{ 0x081D8DBE, false },  -- BattleScript_PerishSongCountGoesDown
		{ 0x081D8E82, "future_sight" },  -- BattleScript_MonTookFutureAttack
		{ 0x081D8EDD, false },  -- BattleScript_FutureAttackEnd
		{ 0x081D90C3, "poison" },  -- BattleScript_PoisonTurnDmg
		{ 0x081D90C9, "turn" },  -- BattleScript_DoStatusTurnDmg
		{ 0x081D90E4, false },  -- BattleScript_DoTurnDmgEnd
		{ 0x081D90E5, "burn" },  -- BattleScript_BurnTurnDmg
		{ 0x081D90F0, false },  -- BattleScript_MoveUsedIsFrozen
		{ 0x081D9143, "confusion" },  -- BattleScript_MoveUsedIsConfused
		{ 0x081D9185, false },  -- BattleScript_MoveUsedIsConfusedRet
		{ 0x081D9194, "trap" },  -- BattleScript_WrapTurnDmg
		{ 0x081D91A6, false },  -- BattleScript_WrapEnds
		{ 0x081D91C5, "nightmare" },  -- BattleScript_NightmareTurnDmg
		{ 0x081D91D6, "curse" },  -- BattleScript_CurseTurnDmg
		{ 0x081D91E7, false },  -- BattleScript_TargetPRLZHeal
		{ 0x081D92B3, "recoil" },  -- BattleScript_MoveEffectRecoil
		{ 0x081D92E0, false },  -- BattleScript_RecoilEnd
		{ 0x081D9513, "rough_skin" },  -- BattleScript_RoughSkinActivates
		{ 0x081D952E, false },  -- BattleScript_CuteCharmActivates
		{ 0x081D9A20, false },  -- gBattlescriptsForBallThrow
	}
	-- END GENERATED BATTLE SCRIPTS

	-- Cause tag for a battle-script PC: a cause string, false (an ordinary move script), or nil
	-- (not in the battle-script region at all).
	function DeathTrack.lookup(pc)
		local s = DeathTrack.SCRIPTS
		if #s < 2 or pc < s[1][1] or pc >= s[#s][1] then return nil end
		local lo, hi = 1, #s
		while lo < hi do
			local mid = math.floor((lo + hi + 1) / 2)
			if s[mid][1] <= pc then lo = mid else hi = mid - 1 end
		end
		return s[lo][2]
	end

	local function dtName(tbl, id)
		local ok, name = pcall(function() return tbl[id].name end)
		if ok and type(name) == "string" and name ~= "" then return name end
		return nil
	end

	-- Work out what just took HP off our battler `b`.
	function DeathTrack.classify(b, st)
		local D = DeathTrack
		local pc = Memory.readdword(LeadMem.addr("gBattlescriptCurrInstr", D.PC))
		local attacker = Memory.readbyte(LeadMem.addr("gBattlerAttacker", D.ATTACKER))
		local move = Memory.readword(LeadMem.addr("gCurrentMove", D.CURRENT_MOVE))
		local tag = D.lookup(pc)
		local selfHit = (attacker == b)
		local cause = tag
		if tag == "turn" then
			if D.entry and (D.frame - D.entry.frame) <= D.ENTRY_TTL then
				cause = D.entry.cause
			elseif st == 3 then cause = "burn"
			elseif st == 2 or st == 6 then cause = "poison"
			else cause = "unknown" end
		elseif tag == "weather" then
			local w = Memory.readword(LeadMem.addr("gBattleWeather", D.WEATHER))
			if w % 256 >= 128 then cause = "hail" else cause = "sandstorm" end
		elseif tag == "recoil" and move == 165 then
			cause = "struggle"
		elseif (tag == "explosion" or tag == "memento") and not selfHit then
			cause = false   -- the FOE's Explosion hit us: that's an ordinary move KO
		end
		if cause == "poison" and st == 6 then cause = "toxic" end
		local hit = { cause = cause or "move", pc = pc }
		if cause == false or cause == nil then
			hit.cause = (tag == nil) and "unknown" or "move"
			if not selfHit then
				hit.move_id = move
				hit.move = dtName(MoveData and MoveData.Moves, move)
				local species = Memory.readword(LeadMem.addr("gBattleMons", LeadMem.BMONS) + (attacker % 4) * LeadMem.BMON_SIZE)
				hit.by_id = species
				hit.by = dtName(PokemonData and PokemonData.Pokemon, species)
			end
		elseif cause == "explosion" or cause == "memento" or cause == "recoil" or cause == "struggle"
			or cause == "crash" or cause == "curse_self" then
			hit.move_id = move
			hit.move = dtName(MoveData and MoveData.Moves, move)
		end
		if Battle ~= nil then
			hit.trainer_id = (not Battle.isWildEncounter) and (tonumber(Battle.opposingTrainerId) or 0) or 0
		end
		return hit
	end

	function DeathTrack.reset()
		local D = DeathTrack
		D.prevHp, D.prevSt, D.entry, D.lastHit, D.cause = nil, nil, nil, nil, nil
		D.counts = {}
	end

	function DeathTrack.save()
		local D = DeathTrack
		if not D.path or not FileManager.encodeToJsonFile then return end
		local seed, attempt = nil, 0
		pcall(function() seed, attempt = currentRunIdentity() end)
		pcall(FileManager.encodeToJsonFile, D.path,
			{ seed = seed, attempt = attempt, counts = D.counts, cause = D.cause or false })
	end

	-- Restore the run-in-play's counts/cause after a script restart (same seed only).
	function DeathTrack.restore()
		local D = DeathTrack
		if not D.path or not FileManager.decodeJsonFile then return end
		if FileManager.fileExists and not FileManager.fileExists(D.path) then return end
		local ok, rec = pcall(FileManager.decodeJsonFile, D.path)
		if not ok or type(rec) ~= "table" then return end
		local seed, attempt = nil, 0
		pcall(function() seed, attempt = currentRunIdentity() end)
		if not isSameRun(rec, seed, attempt) then return end
		if type(rec.counts) == "table" then
			for _, k in ipairs(D.STATUS_KEYS) do
				local n = tonumber(rec.counts[k])
				if n and n > 0 then D.counts[k] = math.floor(n) end
			end
		end
		if type(rec.cause) == "table" then D.cause = rec.cause end
	end

	local function dtLog(hp, prev, hit, b)
		if not (DeathTrack.DEBUG or DeathTrack.testOn) or not DeathTrack.path then return end
		local f = io.open(DeathTrack.path:gsub("run_stats%.json$", "damage_log.txt"), "a")
		if not f then return end
		f:write(string.format("%s hp %d->%d battler=%s pc=0x%08X cause=%s move=%s by=%s\n",
			os.date("%H:%M:%S"), prev, hp, tostring(b), hit.pc or 0, tostring(hit.cause),
			tostring(hit.move or hit.move_id), tostring(hit.by)))
		f:close()
	end

	-- Called every frame from self.inputCheckBizhawk.
	function DeathTrack.update()
		local D = DeathTrack
		D.frame = D.frame + 1
		if D.frame % 30 == 0 then D.checkResetRequest() end
		if D.testOn and D.diagLeft > 0 and D.frame % 60 == 0 then D.diag("tick") end
		if not isPlayingFRLG() then return end
		-- Test mode tracks regardless of the run-start guards: the harness lives in savestates.
		if not D.testOn and (self.Carryover.blocked or not loadedVarsThisSeed) then return end
		if questLogPlaying() then return end   -- recap replays old scenes with placeholder mons
		local inBattle = Battle ~= nil and Battle.inActiveBattle()
		-- Outside battle nothing changes fast: a light 1-in-4 frame poll is plenty.
		if not inBattle and D.frame % 4 ~= 0 then return end
		local hp, mhp, st, b = LeadMem.read()
		if mhp == 0 then return end
		if inBattle then
			-- Remember the last entry script (see ENTRY_CAUSES) for the shared damage tail.
			local tag = D.lookup(Memory.readdword(LeadMem.addr("gBattlescriptCurrInstr", D.PC)))
			if tag and D.ENTRY_CAUSES[tag] then D.entry = { cause = tag, frame = D.frame } end
		end
		local changed = false
		if D.prevHp ~= nil and hp < D.prevHp and D.cause == nil then
			local hit
			if b ~= nil then
				hit = D.classify(b, st)
			elseif not inBattle then
				-- Gen 3 field poison ticks HP down while walking (and can faint). The faint clears
				-- the status in the same write, so the status from before the drop counts too.
				local psn = st == 2 or st == 6 or D.prevSt == 2 or D.prevSt == 6
				hit = { cause = psn and "field_poison" or "unknown" }
			end
			if hit then
				dtLog(hp, D.prevHp, hit, b)
				D.lastHit = hit
				if hp == 0 then
					hit.pc = nil   -- debug only; not part of the uploaded result
					D.cause = hit
					changed = true
				end
			end
		end
		-- A status counts once per infliction: a change from anything to a new status.
		if D.prevSt ~= nil and st ~= 0 and st ~= D.prevSt then
			local key = D.STATUS_KEYS[st]
			D.counts[key] = (D.counts[key] or 0) + 1
			if st == 6 then D.counts.psn = (D.counts.psn or 0) + 1 end   -- toxic is a poisoning too
			changed = true
		end
		D.prevHp, D.prevSt = hp, st
		if changed then D.save() end
	end

	-- Test mode (dev harness): a savestate load starts a fresh tracking slate, so one battle
	-- savestate can be replayed into every death cause. Re-checked on each load.
	function DeathTrack.onStateLoaded()
		local D = DeathTrack
		if not D.path or not FileManager.fileExists then return end
		D.testOn = FileManager.fileExists((D.path:gsub("run_stats%.json$", D.TEST_FLAG))) and true or false
		if D.testOn then
			D.reset()
			D.save()
		end
	end

	-- The harness's reset request (a file, so it works however the state got loaded). One
	-- failed io.open every 30 frames when nobody is testing.
	function DeathTrack.checkResetRequest()
		local D = DeathTrack
		if not D.path then return end
		local req = D.path:gsub("run_stats%.json$", D.TEST_RESET)
		local f = io.open(req, "r")
		if not f then return end
		f:close()
		os.remove(req)
		D.testOn = true
		D.reset()
		D.save()
		D.diagLeft = 8
		D.diag("reset")
	end

	-- Test mode: one line of tracking state to damage_log.txt (why a death went unseen).
	function DeathTrack.diag(tag)
		local D = DeathTrack
		D.diagLeft = D.diagLeft - 1
		if not D.path then return end
		local f = io.open((D.path:gsub("run_stats%.json$", "damage_log.txt")), "a")
		if not f then return end
		local okB, inB = pcall(function() return Battle ~= nil and Battle.inActiveBattle() end)
		local okR, hp, mhp, st, b = pcall(LeadMem.read)
		f:write(string.format("%s [%s] frlg=%s blocked=%s loaded=%s inBattle=%s battler=%s hp=%s/%s st=%s prevHp=%s cause=%s\n",
			os.date("%H:%M:%S"), tag, tostring(isPlayingFRLG()), tostring(self.Carryover.blocked),
			tostring(loadedVarsThisSeed), okB and tostring(inB) or "err", tostring(b), tostring(hp),
			tostring(mhp), tostring(st), tostring(D.prevHp), D.cause and tostring(D.cause.cause) or "nil"))
		f:close()
	end

	-- Payload fields: { death_cause = {...} or nil, status_counts = {...} }.
	function DeathTrack.payload()
		local counts = {}
		for _, k in ipairs(DeathTrack.STATUS_KEYS) do counts[k] = DeathTrack.counts[k] or 0 end
		return DeathTrack.cause, counts
	end
	-- Functions declared above this block reach it through self (a local isn't in scope there).
	self.DeathTrack = DeathTrack
	-- =================== END CAUSE OF DEATH + STATUS COUNTS ========================

	-- ===================== GHOST PLAYERS (optional, removable) =====================
	-- Real-time overworld overlay: draws other players (dot + name) on the same map, plus the
	-- chat bubbles typed in the monitor (over their ghosts, and over your own character).
	-- To remove entirely: delete this block and its 4 call sites (self.startup path setup,
	-- self.inputCheckBizhawk position write, and the ghostDraw + ghostSayDrawSelf draws in
	-- self.afterRedraw). Everything is wrapped in pcall at the call sites, so a failure here
	-- cannot break the extension.
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
	local GHOST_PURPLE_FILE = "ghost_purple3.png"  -- same layout, PURPLE: the player's Pokemon is poisoned
	                                           -- (baked by Extension/make_ghost_tint.py)
	-- Character ghosts. Each player picks a character in the ROM patch's new-game menu; other
	-- players' ghosts are drawn as that character, in colour, from ghosts/avNN_{n,p,r}V.png
	-- (normal / poisoned / death; same 64x384 layout as the grey sheet, baked by
	-- Extension/make_avatar_ghosts.py). avdf_* is the colour fallback for players without a
	-- pick (unpatched ROM); the grey sheets above are the last resort if a file is missing.
	-- The pick rides in the high bits of the status flag: f = status + 16 * (avatar + 1). The
	-- monitor and relay pass f through as a plain integer, and older extensions only ever
	-- test f == 2, so they keep working. A dead player always sends a plain f = 2.
	local GHOST_AVATAR_COUNT = 13               -- ids 0..12, menu order (alphabetical)
	local GHOST_AVATAR_VERSION = 2              -- bump with the sheets (BizHawk caches by filename)
	local GHOST_SB2_PTR = 0x0300500C            -- gSaveBlock2Ptr (FRLG)
	local GHOST_AVATAR_SAVE = 0xB20             -- SaveBlock2 offset: magic byte, then the avatar id
	local GHOST_AVATAR_MAGIC = 0xA7             -- written by the ROM patch with the pick
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
	-- Chat bubbles. The monitor passes each bubble's id + remaining time in ghost_in.txt. The relay
	-- caps the text at 60 characters, so it nearly always fits in GHOST_SAY_LINES lines.
	local GHOST_SAY_WRAP = 24                   -- characters per bubble line
	local GHOST_SAY_LINES = 3                   -- max lines (anything past the last is cut with "...")
	local GHOST_SAY_LINE_H = 10                 -- pixels per text line in the Tracker font
	local GHOST_SAY_FADE_IN = 10                -- frames to fade a bubble in
	local GHOST_SAY_FADE_OUT = 30               -- frames to fade it out at the end of its time
	-- HP bar over each ghost's head (Gen 3 thresholds: green > 1/2, yellow > 1/5, else red).
	local GHOST_HP_W = 22                       -- bar width in pixels (fill area; +2 for the border)
	local GHOST_HP_H = 3                        -- fill height
	local GHOST_HP_GREEN, GHOST_HP_YELLOW, GHOST_HP_RED = 0x38D058, 0xF8D030, 0xF85838
	local ghostOutPath, ghostInPath, ghostSpritePath, ghostRedSpritePath, ghostPurpleSpritePath  -- set in self.startup()
	local ghostAvatarSheets = {}               -- avatar id (-1 = default) -> {n=, p=, r=} paths that exist
	local ghostPlayers = {}                    -- cached other players (from ghost_in.txt)
	local ghostVitals = {}                     -- name -> {hp, mhp, st}, from the monitor's "@hp" lines
	local ghostVitalsChanged = false           -- a bar changed since the last frame: force one redraw
	local ghostMeta = {}                       -- name -> {name,map,x,y,d,fx,fy,vx,vy,lastMoveFrame,lastSeen,firstSeen,dying,deathFrame,deadDone}
	local ghostFrame = 0
	local ghostSelfSay = nil                   -- my own bubble {id,text,lines,w,start,stop}, from the "@me" line
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

	-- Word-wrap bubble text into at most GHOST_SAY_LINES lines of GHOST_SAY_WRAP characters.
	-- A word longer than a whole line is hard-split; overflow past the last line ends in "...".
	local function ghostSayWrap(text)
		local lines, cur = {}, ""
		for word in text:gmatch("%S+") do
			while #word > GHOST_SAY_WRAP do
				if cur ~= "" then table.insert(lines, cur); cur = "" end
				table.insert(lines, word:sub(1, GHOST_SAY_WRAP))
				word = word:sub(GHOST_SAY_WRAP + 1)
			end
			if cur == "" then
				cur = word
			elseif #cur + 1 + #word <= GHOST_SAY_WRAP then
				cur = cur .. " " .. word
			else
				table.insert(lines, cur)
				cur = word
			end
		end
		if cur ~= "" then table.insert(lines, cur) end
		if #lines > GHOST_SAY_LINES then
			local last = lines[GHOST_SAY_LINES]
			for i = #lines, GHOST_SAY_LINES + 1, -1 do table.remove(lines, i) end
			lines[GHOST_SAY_LINES] = last:sub(1, GHOST_SAY_WRAP - 3) .. "..."
		end
		return lines
	end

	-- Start a bubble from ghost_in.txt fields, but only when its id changes. The monitor rewrites
	-- a live bubble ~10x/s, so re-reads must never restart its fade or its timer. Returns the
	-- bubble to keep: the existing one, a new one, or nil.
	local function ghostSayFrom(current, id, leftMs, text)
		local nid, nleft = tonumber(id), tonumber(leftMs)
		if nid == nil or nleft == nil or nleft <= 0 or text == nil or text == "" then return current end
		if current ~= nil and current.id == nid then return current end
		local lines = ghostSayWrap(text)
		if #lines == 0 then return current end
		local w = 0
		for _, l in ipairs(lines) do
			local ok, lw = pcall(function() return Utils.calcWordPixelLength(l) end)
			if not ok or type(lw) ~= "number" or lw <= 0 then lw = #l * 5 end
			if lw > w then w = lw end
		end
		return { id = nid, text = text, lines = lines, w = w,
			start = ghostFrame, stop = ghostFrame + math.floor(nleft * 60 / 1000) }
	end

	-- 0..255 opacity for a bubble right now (fade in, hold, fade out); 0 once it's over.
	local function ghostSayAlpha(say)
		if say == nil or ghostFrame >= say.stop then return 0 end
		local a = 1
		local since = ghostFrame - say.start
		if since < GHOST_SAY_FADE_IN then a = since / GHOST_SAY_FADE_IN end
		local left = say.stop - ghostFrame
		if left < GHOST_SAY_FADE_OUT then a = math.min(a, left / GHOST_SAY_FADE_OUT) end
		if a < 0 then a = 0 end
		return math.floor(255 * a)
	end

	-- True while a bubble is fading in or out, so the frame loop forces smooth redraws (a steady
	-- bubble is fine at the Tracker's idle ~2Hz redraw). Includes the frame it ends on, so the
	-- last redraw erases it promptly.
	local function ghostSayAnimating(say)
		if say == nil then return false end
		local since, left = ghostFrame - say.start, say.stop - ghostFrame
		return (since >= 0 and since < GHOST_SAY_FADE_IN) or (left >= 0 and left <= GHOST_SAY_FADE_OUT)
	end

	-- Draw a speech bubble whose tail points down at (anchorX, bottomY): white box, dark border,
	-- black text. Clamped to the game area so it never spills onto the Tracker panel.
	local function ghostSayDraw(say, anchorX, bottomY)
		local a = ghostSayAlpha(say)
		if a <= 8 then return end
		local screenW = Constants.SCREEN.WIDTH
		local w = say.w + 8
		local h = #say.lines * GHOST_SAY_LINE_H + 4
		local bx = math.floor(anchorX - w / 2)
		if bx + w > screenW - 1 then bx = screenW - 1 - w end
		if bx < 1 then bx = 1 end
		local by = math.floor(bottomY) - 4 - h   -- 4px of tail below the box
		if by < 1 then by = 1 end
		local border = withAlpha(0x202020, a)
		gui.drawRectangle(bx, by, w, h, border, withAlpha(0xFFFFFF, math.floor(a * 0.9)))
		local tx = math.floor(anchorX)
		if tx < bx + 4 then tx = bx + 4 elseif tx > bx + w - 4 then tx = bx + w - 4 end
		gui.drawLine(tx - 3, by + h, tx, by + h + 4, border)
		gui.drawLine(tx + 3, by + h, tx, by + h + 4, border)
		for i, line in ipairs(say.lines) do
			Drawing.drawText(bx + 4, by + 1 + (i - 1) * GHOST_SAY_LINE_H, line, withAlpha(0x000000, a))
		end
	end

	-- My character id from the ROM patch's save data, or -1 (unpatched ROM / no save yet).
	local function ghostMyAvatar()
		local sb2 = Memory.readdword(GHOST_SB2_PTR)
		if sb2 == nil or sb2 < 0x02000000 or sb2 >= 0x02040000 then return -1 end
		if Memory.readbyte(sb2 + GHOST_AVATAR_SAVE) ~= GHOST_AVATAR_MAGIC then return -1 end
		local av = Memory.readbyte(sb2 + GHOST_AVATAR_SAVE + 1)
		if av == nil or av >= GHOST_AVATAR_COUNT then return -1 end
		return av
	end

	-- The sheet to draw a ghost with: kind "n" normal, "p" poisoned, "r" death.
	local function ghostSheet(meta, kind)
		local s = ghostAvatarSheets[meta.av or -1] or ghostAvatarSheets[-1]
		if s and s[kind] then return s[kind] end
		if kind == "r" then return ghostRedSpritePath end
		if kind == "p" and ghostPurpleSpritePath then return ghostPurpleSpritePath end
		return ghostSpritePath
	end

	-- Read my overworld tile from gObjectEvents[0]; write ghost_out.json for the monitor.
	local function ghostWriteSelf()
		if not GHOST_ENABLED or not ghostOutPath then return end
		if questLogPlaying() then return end   -- the recap walks a replay, not the player
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
		if f ~= 2 then                          -- alive: carry my character (see GHOST_AVATAR_COUNT)
			local av = ghostMyAvatar()
			if av >= 0 then f = f + 16 * (av + 1) end
		end
		local out = string.format('{"map":%d,"x":%d,"y":%d,"d":%d,"f":%d', mapId, x, y, facing, f)
		-- Lead Pokemon HP + status for the HP bar / poison tint other players draw on our ghost.
		-- Read live every write (~15 Hz), so a battle shows each hit as it lands.
		local okHp, hp, mhp, st = pcall(LeadMem.read)
		if okHp and mhp and mhp > 0 then
			out = out .. string.format(',"hp":%d,"mhp":%d,"st":%d', hp, mhp, st)
		end
		out = out .. "}"
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
			local vitals = {}
			for _, line in ipairs(lines) do
				-- My own bubble. The monitor writes this line only after the relay echoed it back.
				local meId, meLeft, meText = line:match("^@me\t(%d+)\t(%d+)\t(.*)$")
				if meId then
					ghostSelfSay = ghostSayFrom(ghostSelfSay, meId, meLeft, meText)
				end
				-- A player's lead Pokemon HP / max HP / status (its own line; see App/ghost.py).
				local vName, vHp, vMhp, vSt = line:match("^@hp\t([^\t]+)\t(%d+)\t(%d+)\t(%d+)$")
				if vName then
					vitals[vName] = { hp = tonumber(vHp), mhp = tonumber(vMhp), st = tonumber(vSt) }
					local old = ghostVitals[vName]
					if old == nil or old.hp ~= vitals[vName].hp or old.st ~= vitals[vName].st then
						ghostVitalsChanged = true
					end
				end
				local name, m, x, y, d, f = line:match("^(.-)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)")
				-- Optional chat bubble columns 7-9 (id, ms left, text), present while it's live.
				local sayId, sayLeft, sayText = line:match("^[^\t]*\t%-?%d+\t%-?%d+\t%-?%d+\t%-?%d+\t%-?%d+\t(%d+)\t(%d+)\t(.*)$")
				if meId or vName then name = nil end
				if name and name ~= "" then
					local nx, ny, nd, nm = tonumber(x), tonumber(y), tonumber(d), tonumber(m)
					local nf = tonumber(f) or 0
					local nav = math.floor(nf / 16) - 1   -- character id, -1 if none (see GHOST_AVATAR_COUNT)
					nf = nf % 16                           -- status: 0 alive, 2 dead
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
					-- Applied after the branches above, since several of them rebuild the meta table.
					local cur = ghostMeta[name]
					if cur ~= nil and nav >= 0 and nav < GHOST_AVATAR_COUNT then
						cur.av = nav   -- remembered, so the death fade (plain f=2) keeps the character
					end
					if cur ~= nil and sayId then
						cur.say = ghostSayFrom(cur.say, sayId, sayLeft, sayText)
					end
				end
			end
			-- An empty read (collided with the monitor's write) keeps the last known bars.
			if #lines > 0 then ghostVitals = vitals end
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

	-- Gen-3-style HP bar centred on cx with its top at y: dark border, empty track, and a fill
	-- that goes green -> yellow -> red. `a` is the ghost's fade alpha (0..255).
	local function ghostHpDraw(v, cx, y, a)
		if v == nil or not v.mhp or v.mhp <= 0 or a <= 8 then return end
		local frac = math.max(0, math.min(1, (v.hp or 0) / v.mhp))
		local x = math.floor(cx - GHOST_HP_W / 2) - 1
		gui.drawRectangle(x, y, GHOST_HP_W + 1, GHOST_HP_H + 1, withAlpha(0x181818, a), withAlpha(0x505050, math.floor(a * 0.85)))
		local fill = math.floor(GHOST_HP_W * frac + 0.5)
		if fill == 0 and v.hp > 0 then fill = 1 end   -- 1 HP still shows a sliver
		if fill > 0 then
			local color = GHOST_HP_RED
			if frac > 0.5 then color = GHOST_HP_GREEN elseif frac > 0.2 then color = GHOST_HP_YELLOW end
			gui.drawRectangle(x + 1, y + 1, fill - 1, GHOST_HP_H - 1, withAlpha(color, a), withAlpha(color, a))
		end
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
		local bubbles = {}   -- drawn after every ghost, so a bubble is never covered by another sprite
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
						gui.drawImageRegion(ghostSheet(meta, "r"), col * 16, tier * 96, 16, 32, sx, sy - 16)  -- row 0 = still
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
						-- 16x32 sprite; source row band picks the opacity tier. Poisoned (PSN or
						-- toxic) players are drawn from the purple sheet.
						local vit = ghostVitals[g.name]
						local sheet = ghostSheet(meta, "n")
						if vit ~= nil and (vit.st == 2 or vit.st == 6) then
							sheet = ghostSheet(meta, "p")
						end
						gui.drawImageRegion(sheet, col * 16, tier * 96 + row * 32, 16, 32, sx, sy - 16)
						-- colored nameplate (per-player), fading with the sprite
						if a > 8 then
							local nameX = sx + 8 - math.floor(#g.name * 2.5)
							Drawing.drawText(nameX, sy - 26, g.name,
								withAlpha(ghostColor(g.name), a), withAlpha(0x000000, math.floor(a * 0.75)))
						end
						-- HP bar just above the nameplate (only from monitors that send vitals)
						local bubbleY = sy - 27
						if vit ~= nil then
							ghostHpDraw(vit, sx + 8, sy - 31, a)
							bubbleY = sy - 32
						end
						-- chat bubble, tail pointing at the top of the nameplate (or HP bar)
						if meta.say ~= nil and ghostFrame < meta.say.stop then
							table.insert(bubbles, { meta.say, sx + 8, bubbleY })
						end
					end
				end
			end
		end
		for _, b in ipairs(bubbles) do
			ghostSayDraw(b[1], b[2], b[3])
		end
	end

	-- My own bubble, from the monitor's "@me" line. The monitor writes that line only after the
	-- relay echoed the message back, so seeing it means it went out to players on your map. The
	-- camera keeps the player centred, so the anchor is fixed just above the player's sprite.
	local function ghostSayDrawSelf()
		if not GHOST_ENABLED or ghostSelfSay == nil or ghostFrame >= ghostSelfSay.stop then return end
		if Battle ~= nil and Battle.inBattleScreen then return end
		if not Program.isValidMapLocation() then return end
		ghostSayDraw(ghostSelfSay, Constants.SCREEN.WIDTH / 2, Constants.SCREEN.HEIGHT / 2 - 26)
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
			if next(ghostMeta) ~= nil then ghostMeta = {}; ghostPlayers = {}; ghostVitals = {} end
			ghostSelfSay = nil   -- ghostFrame is frozen while dormant, so a bubble would never end
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
		if ghostSayAnimating(ghostSelfSay) then active = true end   -- my bubble fading in/out
		if ghostVitalsChanged and #ghostPlayers > 0 then active = true end   -- an HP bar moved
		ghostVitalsChanged = false
		for _, g in ipairs(ghostPlayers) do
			if g.dying                                                               -- death fade-out
				or (ghostFrame - g.lastMoveFrame) < GHOST_WALK_HOLD                   -- moving/gliding
				or (ghostFrame - g.firstSeen) < GHOST_FADE_FRAMES                     -- fading in
				or (ghostFrame - g.lastSeen) > (GHOST_TTL - GHOST_FADE_FRAMES)       -- fading out
				or ghostSayAnimating(g.say) then                                     -- bubble fading in/out
				active = true
				break
			end
		end
		if active and Program and Program.Frames then
			Program.Frames.waitToDraw = 0
		end
	end
	-- =================== END GHOST PLAYERS =========================================

	-- ===================== DEATH PUDDLES (optional, removable) =====================
	-- Static, faded-red markers where OTHER players' runs ended on the SAME seed. The monitor
	-- fetches them from the server (visibility is a per-competition host setting: off/global/
	-- team) and writes puddle_in.txt as TSV: name<TAB>map<TAB>x<TAB>y<TAB>milestone<TAB>mon<TAB>lvl.
	-- Purely visual. Every call site is pcall-wrapped so a failure here can't break the
	-- extension. Reuses the ghost block's helpers (withAlpha, readS16) + memory constants
	-- (GHOST_OBJEVENTS/GHOST_SCO_*), so keep this block below the GHOST block. To remove:
	-- delete this block and its 3 call sites (startup path, inputCheckBizhawk, afterRedraw).
	local PUDDLE_ENABLED = true
	local PUDDLE_IN_FILE = "puddle_in.txt"     -- written by the monitor, read here (TSV)
	local PUDDLE_NEAR = 1                        -- Chebyshev tile distance that reveals the info panel
	local PUDDLE_READ_EVERY = 30                -- frames between file re-reads (~0.5s; monitor writes ~2/min)
	local PUDDLE_FILL = 0xFFFF3030             -- ARGB red base (alpha applied per-draw)
	local PUDDLE_FILL_A = 70                     -- faded fill opacity
	local PUDDLE_EDGE_A = 120                    -- slightly stronger rim
	local PUDDLE_INFO_MAX = 3                    -- info-panel rows shown at once; extras cycle through
	local PUDDLE_CYCLE_FRAMES = 300             -- frames each page of names shows before cycling (~5s)
	local PUDDLE_TEST = 0                        -- DEV ONLY: inject N fake runs on Oak's Lab (5,13,15) to test the panel; MUST be 0 to release
	local puddleInPath                          -- set in self.startup()
	local puddles = {}                          -- list of {name,map,x,y,milestone,mon,lvl}
	local puddleFrame = 0
	local pPxStill, pPyStill, pScoxStill, pScoyStill, pLastScox, pLastScoy  -- own smooth-scroll calibration
	local pFrameScox, pFrameScoy   -- per-frame scroll detection to force redraws while you walk

	-- Parse puddle_in.txt (TSV, 7 columns) into `puddles`. Independent of the ghost reader.
	local function puddleRead()
		if not PUDDLE_ENABLED or not puddleInPath then return end
		local lines = FileManager.readLinesFromFile(puddleInPath)
		local list = {}
		if lines then
			for _, line in ipairs(lines) do
				local name, m, x, y, rest = line:match("^(.-)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(.*)$")
				if name and name ~= "" then
					local milestone, mon, lvl = "", "", ""
					if rest then
						local ms, mn, lv = rest:match("^(.-)\t(.-)\t(.*)$")
						if ms then milestone, mon, lvl = ms, mn, lv end
					end
					table.insert(list, { name = name, map = tonumber(m), x = tonumber(x),
						y = tonumber(y), milestone = milestone or "", mon = mon or "", lvl = lvl or "" })
				end
			end
		end
		-- DEV test data: pretend a crowd fell on WaffleSmacker's Oak's Lab tile (5,13,15) so the
		-- cycling info panel can be exercised without needing many real runs. PUDDLE_TEST must be 0
		-- for any release (guarded by refresh_bundle.py).
		if PUDDLE_TEST > 0 then
			local names = { "Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Heidi", "Ivan", "Judy" }
			local mons = { "Bulbasaur", "Charmander", "Squirtle", "Pidgey", "Nidoran", "Mankey", "Caterpie", "Pikachu" }
			local miles = { "", "beat_brock", "", "beat_misty", "" }
			for i = 1, PUDDLE_TEST do
				table.insert(list, { name = names[(i - 1) % #names + 1], map = 5, x = 13, y = 15,
					milestone = miles[(i - 1) % #miles + 1], mon = mons[(i - 1) % #mons + 1],
					lvl = tostring(5 + i) })
			end
		end
		puddles = list
	end

	-- Small panel (top-left) naming who fell on/next to the player's tile. Stacks all nearby.
	local function puddleDrawInfo(list)
		local n = #list
		-- When several runs ended on the same tile, show at most PUDDLE_INFO_MAX at once and cycle
		-- through the rest (every PUDDLE_CYCLE_FRAMES) so the panel never runs off the screen.
		local pages = math.ceil(n / PUDDLE_INFO_MAX)
		local page = (pages > 1) and (math.floor(puddleFrame / PUDDLE_CYCLE_FRAMES) % pages) or 0
		local first = page * PUDDLE_INFO_MAX + 1
		local last = math.min(first + PUDDLE_INFO_MAX - 1, n)

		-- Build the display lines first so we can size a translucent background box behind them --
		-- the plain drop-shadow text was hard to read over busy tiles.
		local lines = {}
		local header
		if n == 1 then
			header = "Run ended here:"
		elseif pages > 1 then
			header = string.format("%d ended here (%d-%d):", n, first, last)
		else
			header = n .. " runs ended here:"
		end
		lines[#lines + 1] = { text = header, color = 0xFFFF6666 }
		for i = first, last do
			local p = list[i]
			local detail = p.name
			if p.mon and p.mon ~= "" then
				detail = detail .. " - " .. p.mon
				if p.lvl and p.lvl ~= "" and p.lvl ~= "0" then detail = detail .. " Lv" .. p.lvl end
			end
			if p.milestone and p.milestone ~= "" and p.milestone ~= "none" then
				detail = detail .. " (" .. p.milestone .. ")"
			end
			lines[#lines + 1] = { text = detail, color = 0xFFFFFFFF }
		end
		-- Box sized to the longest line (~5px per glyph in the Tracker font) + padding, matching the
		-- seed-display panel's look (thin black rim + ~75% dark fill).
		local maxChars = 0
		for _, ln in ipairs(lines) do
			if #ln.text > maxChars then maxChars = #ln.text end
		end
		local bx, by = 3, 12
		local boxW, boxH = maxChars * 5 + 9, #lines * 10 + 4
		gui.drawRectangle(bx, by, boxW, boxH, 0xFF000000, 0xC0000000)
		for i, ln in ipairs(lines) do
			Drawing.drawText(bx + 3, by + 2 + (i - 1) * 10, ln.text, withAlpha(ln.color, 255), withAlpha(0x000000, 210))
		end
	end

	-- Draw a faded red puddle on every same-map run-end tile; reveal info for any within
	-- PUDDLE_NEAR tiles. Static (no glide) but slides smoothly with the world via the same
	-- still-reference / camera-scroll trick the ghosts use (own calibration vars).
	local function puddleDraw()
		if not PUDDLE_ENABLED then return end
		if Battle ~= nil and Battle.inBattleScreen then return end
		if #puddles == 0 then return end
		local myMap = TrackerAPI.getMapId() or 0
		local scox = readS16(GHOST_SCO_X)
		local scoy = readS16(GHOST_SCO_Y)
		local prevScox = pLastScox or scox
		local prevScoy = pLastScoy or scoy
		if pPxStill == nil or (scox == prevScox and scoy == prevScoy) then
			pPxStill = Memory.readword(GHOST_OBJEVENTS + 0x10)
			pPyStill = Memory.readword(GHOST_OBJEVENTS + 0x12)
			pScoxStill = scox
			pScoyStill = scoy
		end
		pLastScox = scox
		pLastScoy = scoy
		if pPxStill == nil then return end
		local myX = Memory.readword(GHOST_OBJEVENTS + 0x10)
		local myY = Memory.readword(GHOST_OBJEVENTS + 0x12)
		local cx = Constants.SCREEN.WIDTH / 2 - 8
		local cy = Constants.SCREEN.HEIGHT / 2 - 8
		local near = nil
		for _, p in ipairs(puddles) do
			if p.map == myMap and p.x and p.y then
				local sx = math.floor(cx + (p.x - pPxStill) * 16 + (scox - pScoxStill))
				local sy = math.floor(cy + (p.y - pPyStill) * 16 + (scoy - pScoyStill))
				if sx > -20 and sx < Constants.SCREEN.WIDTH and sy > -20 and sy < Constants.SCREEN.HEIGHT + 20 then
					-- faded red splat sitting on the ground of the tile (two stacked ellipses
					-- give a soft edge without needing an image asset).
					gui.drawEllipse(sx, sy + 8, 15, 8, withAlpha(PUDDLE_FILL, PUDDLE_EDGE_A), withAlpha(PUDDLE_FILL, PUDDLE_FILL_A))
					gui.drawEllipse(sx + 3, sy + 10, 9, 4, withAlpha(PUDDLE_FILL, 0), withAlpha(PUDDLE_FILL, PUDDLE_FILL_A))
				end
				if math.max(math.abs(p.x - myX), math.abs(p.y - myY)) <= PUDDLE_NEAR then
					near = near or {}
					table.insert(near, p)
				end
			end
		end
		if near then puddleDrawInfo(near) end
	end

	-- Called each frame (Bizhawk); throttle the file read (the draw itself runs every frame).
	local function puddleFrameUpdate()
		if not PUDDLE_ENABLED then return end
		puddleFrame = puddleFrame + 1
		if puddleFrame % PUDDLE_READ_EVERY == 1 then   -- read on frame 1 too (no startup delay)
			pcall(puddleRead)
		end
		-- Keep the markers glued to the world while you walk. A puddle's screen position is derived
		-- from the live camera offset (like the ghosts), so at the Tracker's idle ~2Hz redraw the
		-- markers visibly lag the scrolling map -- that's the "puddle lag". Mirror the ghost fix:
		-- force a per-frame redraw, but ONLY while the world is actually scrolling AND a puddle sits
		-- on the current map, so we never pin the emulator at 60Hz for nothing.
		if #puddles == 0 then return end
		local scoxNow = readS16(GHOST_SCO_X)
		local scoyNow = readS16(GHOST_SCO_Y)
		local scrolling = (pFrameScox ~= nil and (scoxNow ~= pFrameScox or scoyNow ~= pFrameScoy))
		pFrameScox = scoxNow
		pFrameScoy = scoyNow
		if not (Program and Program.Frames) then return end
		local myMap = TrackerAPI.getMapId() or 0
		local onMap = false
		for _, p in ipairs(puddles) do
			if p.map == myMap then onMap = true; break end
		end
		-- Force a redraw while the world scrolls (glue markers to the map) or at each info-panel
		-- cycle boundary (so a crowded tile's names rotate visibly even when you're standing still).
		if onMap and (scrolling or (puddleFrame % PUDDLE_CYCLE_FRAMES) <= 1) then
			Program.Frames.waitToDraw = 0
		end
	end
	-- =================== END DEATH PUDDLES =========================================

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
		             size = self.Setup.romSize, guid = guid, baseAdler = self.Setup.baseAdler }
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

		-- The base ROM is "current" only if the recorded patch version AND baseAdler match today's
		-- Setup constants. baseAdler is the checksum of the correctly-patched ROM, so it necessarily
		-- changes whenever the shipped IPS changes -- that's what forces existing players onto the new
		-- ROM after an extension update (patchFromRom verifies the freshly-patched ROM against the same
		-- constant). Cheap path: trust the recorded values, no 16MB re-hash on every load.
		local romPresent = st and FileManager.fileExists(P.rom) and (fileSize(P.rom) == self.Setup.romSize)
		local romOk = romPresent and st.version == self.Setup.version
			and st.baseAdler == self.Setup.baseAdler

		-- One-time migration: state files written before baseAdler tracking have no baseAdler field,
		-- so the check above would needlessly re-prompt those players. Verify the existing ROM's bytes
		-- once (adler32 of 16MB) and, if they already match, re-stamp the state so later loads stay
		-- cheap. A real mismatch falls through to the re-patch banner below.
		if romPresent and not romOk and st.baseAdler == nil and st.version == self.Setup.version then
			pcall(function()
				local bytes = readWholeFile(P.rom)
				if bytes and adler32(bytes) == self.Setup.baseAdler then
					self.writeSetupState(st.guid)   -- stamps baseAdler onto the existing state
					romOk = true
				end
			end)
		end

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
		elseif self.Carryover.blocked then
			-- Data is on hold until the player answers; outranks the monitor warning because
			-- nothing is recorded either way until this is resolved.
			drawCarryoverBanner()
		elseif self.MonitorWarn.active then
			drawMonitorWarning()
		elseif (self.WrongSeed or self.WrongRom) and not self.SeedBannerDismissed then
			-- Dismissable with the "Got it" button so the log viewer can be read underneath.
			if self.RunEndRecent then
				-- Right after a run ends, a mismatch is expected churn -- don't cry "wrong seed".
				drawEndOfRunBanner()
			elseif self.WrongRom then
				drawWrongRomWarning()
			else
				drawWrongSeedWarning()
			end
		end
		drawSeedDisplay()
		pcall(ghostDraw)  -- ghost players (removable)
		pcall(ghostSayDrawSelf)  -- my own ghost chat bubble (removable with ghost players)
		pcall(puddleDraw)  -- death puddles (removable)
	end

	-- [Bizhawk only] Executed each frame: detect a click on the warning's "Open Monitor"
	-- button and launch the monitor. Uses the same coordinate space the Tracker uses for
	-- mouse input, so the hit-test matches what's drawn on the game screen.
	function self.inputCheckBizhawk()
		pcall(ghostFrameUpdate)  -- ghost players: read my pos + others (removable)
		pcall(DeathTrack.update)  -- cause of death + status counts (per frame in battle)
		pcall(puddleFrameUpdate)  -- death puddles: throttled file read (removable)
		local setupBanner = self.Setup.warnActive and not self.Setup.ready
		-- Carryover prompt/confirm have buttons; its post-reset instruction does not.
		local carryBanner = not setupBanner and self.Carryover.blocked and self.Carryover.stage ~= "reset"
		local monitorBanner = not setupBanner and not self.Carryover.blocked and self.MonitorWarn.active
		-- The seed/end-of-run banner shows a "Got it" dismiss button (mirrors the afterRedraw dispatch).
		local seedBanner = not setupBanner and not self.Carryover.blocked and not self.MonitorWarn.active
			and (self.WrongSeed or self.WrongRom) and not self.SeedBannerDismissed
		if not setupBanner and not carryBanner and not monitorBanner and not seedBanner then
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
			elseif carryBanner then
				local C = self.Carryover
				if C.stage == "confirm" then
					if hit(C.OkButton) then self.carryoverAccept()
					elseif hit(C.BackButton) then C.stage = "prompt" end
				elseif C.stage == "resetconfirm" then
					-- Reset power-cycles the core at once, so it needs a second click too.
					if hit(C.OkButton) then self.carryoverReset()
					elseif hit(C.BackButton) then C.stage = "prompt" end
				else
					if hit(C.ResetButton) then C.stage = "resetconfirm"
					elseif hit(C.ContinueButton) then C.stage = "confirm" end
				end
			elseif monitorBanner then
				if hit(self.WarnButton) then self.launchMonitor() end
			elseif seedBanner then
				if hit(self.GotItButton) then self.SeedBannerDismissed = true end
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
		self.Paths.LastRun = extFolderPath .. self.LAST_RUN_FILE
		DeathTrack.path = extFolderPath .. DeathTrack.STATS_FILE
		ghostOutPath = extFolderPath .. GHOST_OUT_FILE   -- ghost players (removable)
		ghostInPath = extFolderPath .. GHOST_IN_FILE
		ghostSpritePath = extFolderPath .. GHOST_SPRITE_FILE
		ghostRedSpritePath = extFolderPath .. GHOST_RED_FILE
		ghostPurpleSpritePath = extFolderPath .. GHOST_PURPLE_FILE
		for av = -1, GHOST_AVATAR_COUNT - 1 do
			local tag = av < 0 and "df" or string.format("%02d", av)
			local set = {}
			for _, kind in ipairs({ "n", "p", "r" }) do
				local path = string.format("%sghosts%sav%s_%s%d.png", extFolderPath, FileManager.slash,
					tag, kind, GHOST_AVATAR_VERSION)
				local fh = io.open(path, "rb")
				if fh then fh:close(); set[kind] = path end
			end
			ghostAvatarSheets[av] = set
		end
		puddleInPath = extFolderPath .. PUDDLE_IN_FILE   -- death puddles (removable)

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

		-- A savestate from an old run can also pull that run's progress into a fresh seed; let
		-- the carryover guard know when one loads (see checkCarryoverAfterTick).
		pcall(function()
			if Main.IsOnBizhawk() and type(event) == "table" and type(event.onloadstate) == "function" then
				event.onloadstate(function()
					self.Carryover.stateLoadedTicks = 2
					pcall(DeathTrack.onStateLoaded)
				end, "IronmonVS_onloadstate")
			end
		end)
	end

	-- Executed only once: When the extension is disabled by the user, necessary to undo any customizations, if able
	function self.unload()
		pcall(function()
			if type(event) == "table" and type(event.unregisterbyname) == "function" then
				event.unregisterbyname("IronmonVS_onloadstate")
			end
		end)
	end

	return self
end
return IronmonVS