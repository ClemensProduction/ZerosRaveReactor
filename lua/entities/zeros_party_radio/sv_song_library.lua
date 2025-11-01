-- Server-side Song Library Management
-- This is a global system shared across all Party Radio entities

-- Global song library storage
ZerosRaveReactor = ZerosRaveReactor or {}
ZerosRaveReactor.SongLibrary = ZerosRaveReactor.SongLibrary or {}

-- File paths
local DATA_FOLDER = "zeros_rave_reactor"
local LIBRARY_FILE = DATA_FOLDER .. "/song_library.txt"

-- Initialize the song library system
function ZerosRaveReactor.InitializeSongLibrary(ent)
    -- Create data folder if it doesn't exist
    if not file.Exists(DATA_FOLDER, "DATA") then
        file.CreateDir(DATA_FOLDER)
        print("[Party Radio] Created data folder: " .. DATA_FOLDER)
    end

    -- Check if library file exists
    if file.Exists(LIBRARY_FILE, "DATA") then
        -- Load existing library
        ZerosRaveReactor.LoadSongLibrary()
        print("[Party Radio] Loaded song library with " .. table.Count(ZerosRaveReactor.SongLibrary) .. " songs")
    else
        -- First time setup: Convert DefaultSongs to new format
        print("[Party Radio] No song library found. Creating new library from default songs...")
        ZerosRaveReactor.CreateDefaultLibrary(ent)
        ZerosRaveReactor.SaveSongLibrary()
        print("[Party Radio] Created song library with " .. table.Count(ZerosRaveReactor.SongLibrary) .. " default songs")
    end
end

-- Convert DefaultSongs to hash-based library format
function ZerosRaveReactor.CreateDefaultLibrary(ent)
    ZerosRaveReactor.SongLibrary = {}

    if not ent or not ent.DefaultSongs then
        print("[Party Radio] ERROR: Cannot create library - entity or DefaultSongs is nil")
        return
    end

    for _, song in ipairs(ent.DefaultSongs) do
        -- DefaultSongs format: {name, genre, url, artist}
        local name = song[1]
        local genre = song[2]
        local url = song[3]
        local artist = song[4]

        -- Generate hash from URL
        local hash = util.CRC(url)

        -- Add to library with new format
        ZerosRaveReactor.SongLibrary[tostring(hash)] = {
            name = name,
            artist = artist or "Unknown",
            url = url,
            genre = genre or "Unknown",
            player = "default",
            isDefault = true
        }
    end
end

-- Load song library from disk
function ZerosRaveReactor.LoadSongLibrary()
    local data = file.Read(LIBRARY_FILE, "DATA")

    if data then
        local success, decoded = pcall(util.JSONToTable, data)

        if success and decoded then
            ZerosRaveReactor.SongLibrary = decoded
            return true
        else
            print("[Party Radio] ERROR: Failed to decode song library JSON")
            return false
        end
    end

    return false
end

-- Save song library to disk
function ZerosRaveReactor.SaveSongLibrary()
    local encoded = util.TableToJSON(ZerosRaveReactor.SongLibrary, true)

    if encoded then
        file.Write(LIBRARY_FILE, encoded)
        print("[Party Radio] Saved song library (" .. table.Count(ZerosRaveReactor.SongLibrary) .. " songs)")
        return true
    else
        print("[Party Radio] ERROR: Failed to encode song library to JSON")
        return false
    end
end

-- Add a new song to the library
function ZerosRaveReactor.AddSongToLibrary(url, name, artist, genre, playerSteamID)
    -- Validate URL
    if not url or url == "" then
        return false, "Invalid URL"
    end

    -- Generate hash
    local hash = util.CRC(url)
    local hashStr = tostring(hash)

    -- Check if song already exists
    if ZerosRaveReactor.SongLibrary[hashStr] then
        return false, "Song already exists in library"
    end

    -- Add to library
    ZerosRaveReactor.SongLibrary[hashStr] = {
        name = name or "Unknown Song",
        artist = artist or "Unknown",
        url = url,
        genre = genre or "Unknown",
        player = playerSteamID or "Unknown",
        isDefault = false
    }

    -- Save immediately
    ZerosRaveReactor.SaveSongLibrary()

    -- Broadcast update to all clients
    ZerosRaveReactor.BroadcastLibraryUpdate()

    print("[Party Radio] Added song to library: " .. name .. " by " .. artist)
    return true, hashStr
end

-- Get song by hash
function ZerosRaveReactor.GetSongByHash(hash)
	return ZerosRaveReactor.SongLibrary[tostring(hash)]
end

-- Update song duration in library
function ZerosRaveReactor.UpdateSongDuration(hash, duration)
	local hashStr = tostring(hash)

	-- Check if song exists
	if not ZerosRaveReactor.SongLibrary[hashStr] then
		return false, "Song not found in library"
	end

	-- Validate duration (must be between 1 second and 2 hours)
	duration = tonumber(duration) or 0
	if duration < 1 or duration > 7200 then
		return false, "Invalid duration"
	end

	local song = ZerosRaveReactor.SongLibrary[hashStr]

	-- Only update if duration is not already set (first report wins)
	if not song.duration or song.duration == 0 then
		song.duration = math.Round(duration)

		-- Save to disk
		ZerosRaveReactor.SaveSongLibrary()

		-- Broadcast update to all clients
		ZerosRaveReactor.BroadcastLibraryUpdate()

		print("[Party Radio] Updated duration for '" .. song.name .. "': " .. song.duration .. "s")
		return true, song.duration
	end

	-- Duration already known, return existing value
	return true, song.duration
end

-- Remove a song from the library (SuperAdmin only, custom songs only)
function ZerosRaveReactor.RemoveSongFromLibrary(hash, ply)
    local hashStr = tostring(hash)

    -- Check if song exists
    if not ZerosRaveReactor.SongLibrary[hashStr] then
        return false, "Song not found in library"
    end

    -- Check if player is SuperAdmin
    if IsValid(ply) and not ply:IsSuperAdmin() then
        return false, "Only SuperAdmins can remove songs from library"
    end

	local song = ZerosRaveReactor.GetSongByHash(hash)

    -- Remove from library
    local songName = song.name
    ZerosRaveReactor.SongLibrary[hashStr] = nil

    -- Save immediately
    ZerosRaveReactor.SaveSongLibrary()

    -- Broadcast update to all clients
    ZerosRaveReactor.BroadcastLibraryUpdate()

    print("[Party Radio] Removed song from library: " .. songName)
    return true
end

-- Get song by hash
function ZerosRaveReactor.GetSongByHash(hash)
    return ZerosRaveReactor.SongLibrary[tostring(hash)]
end

-- Get all songs as a table
function ZerosRaveReactor.GetAllSongs()
    return ZerosRaveReactor.SongLibrary
end

-- Get song count
function ZerosRaveReactor.GetSongCount()
    return table.Count(ZerosRaveReactor.SongLibrary)
end

-- Broadcast library update to all clients
function ZerosRaveReactor.BroadcastLibraryUpdate()
    -- Send compressed library to all clients
    net.Start("PartyRadio_UpdateSongLibrary")
    net.WriteTable(ZerosRaveReactor.SongLibrary)
    net.Broadcast()
end

-- Send library to specific player
function ZerosRaveReactor.SendLibraryToPlayer(ply)
    if not IsValid(ply) then return end

    net.Start("PartyRadio_UpdateSongLibrary")
    net.WriteTable(ZerosRaveReactor.SongLibrary)
    net.Send(ply)
end

print("[Party Radio] Song library system loaded")

