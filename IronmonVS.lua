local function IronmonVS()
	local self = {
		version = "1.2",
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

	-- Executed when the user clicks the "Options" button while viewing the extension details within the Tracker's UI
	function self.configureOptions()
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

	-- Data output file path
	self.DATA_OUTPUT_FILE = "ironmon_data.json"

	self.Paths = {
		DataOutput = "",
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
		jsonContent = jsonContent .. '  "RandomSeed": ' .. (data.RandomSeed and tostring(data.RandomSeed) or "null") .. "\n"
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
		local randomSeed = nil
		local success, result = pcall(function()
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

		return info
	end

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

	-- Executed only once: When the extension is enabled by the user, and/or when the Tracker first starts up, after it loads all other required files and code
	function self.startup()
		-- Build out paths to files within the extension folder
		local extFolderPath = FileManager.getCustomFolderPath() .. "IronmonVS" .. FileManager.slash
		self.Paths.DataOutput = extFolderPath .. self.DATA_OUTPUT_FILE
		
		-- Create extension folder if it doesn't exist
		os.execute("mkdir \"" .. extFolderPath .. "\" 2>nul")
		
		-- Initialize data file with empty JSON object
		local file = io.open(self.Paths.DataOutput, "w")
		if file then
			file:write("{}")
			file:close()
		end
	end

	-- Executed only once: When the extension is disabled by the user, necessary to undo any customizations, if able
	function self.unload()
		-- Nothing to clean up
	end

	return self
end
return IronmonVS