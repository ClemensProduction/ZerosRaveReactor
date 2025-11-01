AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_menu.lua")

AddCSLuaFile("cl_audio_analysis.lua")
AddCSLuaFile("cl_visual_effects.lua")

AddCSLuaFile("shared.lua")
include("shared.lua")

AddCSLuaFile("sh_config.lua")
include("sh_config.lua")

-- Include server-side song library management
include("sv_song_library.lua")

-- Flag to track if library has been initialized
local LibraryInitialized = false

-- Security: Rate limiting for network messages
local function CreateRateLimiter(interval)
    local limits = {}
    return function(ply)
        local steamID = ply:SteamID()
        local currentTime = CurTime()

        if not limits[steamID] or (currentTime - limits[steamID]) > interval then
            limits[steamID] = currentTime
            return true
        end
        return false
    end
end

local rateLimiters = {
    PlayNext = CreateRateLimiter(1),
    Stop = CreateRateLimiter(1),
    AddURL = CreateRateLimiter(2),
    RemoveSong = CreateRateLimiter(0.5),
    SetVolume = CreateRateLimiter(0.5),
    AddToLibrary = CreateRateLimiter(3),
    RemoveFromLibrary = CreateRateLimiter(2),
    AddFromLibrary = CreateRateLimiter(1),
    EditSongInLibrary = CreateRateLimiter(2),
    ReportDuration = CreateRateLimiter(2),
    SongEnded = CreateRateLimiter(1)
}

function ENT:SpawnFunction(ply, tr, name)
    if not tr.Hit then return end

    local ent = ents.Create(name)
    ent:SetPos(tr.HitPos + tr.HitNormal * 10)
    ent:SetAngles(Angle(0, ply:GetAngles().y, 0))
    ent:Spawn()
    ent:Activate()

    return ent
end

function ENT:Initialize()
    self:SetModel("models/spg/gryffindor/lamp.mdl")
    self:SetModelScale(2)

    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:Wake()
        phys:SetMass(50)
    end

    -- Initialize song library system (only once globally)
    if not LibraryInitialized then
        ZerosRaveReactor.InitializeSongLibrary(self)
        LibraryInitialized = true
    end

    -- Initialize playlist (starts empty - songs added from library via menu)
    self.Playlist = {}
    self.CurrentIndex = 0
    self.IsPlaying = false
    self.Volume = 0.5
    self.Range = 2000
    self.MaxPlaylistSize = 500 -- Security: Limit playlist size
end

function ENT:Use(activator, caller)
    if not IsValid(activator) or not activator:IsPlayer() then return end

    if not activator:IsAdmin() then
        activator:ChatPrint("Only admins can control the radio!")
        return
    end

    self:OpenMenu(activator)
end

function ENT:OnRemove()
    -- Clean up timers
    timer.Remove("PartyRadio_AutoNext_" .. self:EntIndex())
end

-- Networking
util.AddNetworkString("PartyRadio_OpenMenu")
util.AddNetworkString("PartyRadio_UpdateState")
util.AddNetworkString("PartyRadio_PlayNext")
util.AddNetworkString("PartyRadio_Stop")
util.AddNetworkString("PartyRadio_AddURL")
util.AddNetworkString("PartyRadio_RemoveSong")
util.AddNetworkString("PartyRadio_SetVolume")
util.AddNetworkString("PartyRadio_UpdatePlaylist")
util.AddNetworkString("PartyRadio_PlaySpecific")
util.AddNetworkString("PartyRadio_UpdateSongLibrary")
util.AddNetworkString("PartyRadio_AddToLibrary")
util.AddNetworkString("PartyRadio_RemoveFromLibrary")
util.AddNetworkString("PartyRadio_AddFromLibrary")
util.AddNetworkString("PartyRadio_EditSongInLibrary")
util.AddNetworkString("PartyRadio_ReportDuration")
util.AddNetworkString("PartyRadio_SongEnded")

function ENT:OpenMenu(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    -- Send menu data
    net.Start("PartyRadio_OpenMenu")
    net.WriteEntity(self)
    net.WriteTable(self.Playlist)
    net.WriteBool(self.IsPlaying)
    net.WriteFloat(self.Volume)
    net.Send(ply)

    -- Send song library to player
    ZerosRaveReactor.SendLibraryToPlayer(ply)
end

function ENT:BroadcastState()
    net.Start("PartyRadio_UpdateState")
    net.WriteEntity(self)
    net.WriteBool(self.IsPlaying)
    net.WriteUInt(self.CurrentIndex, 16)
    net.WriteFloat(self.Volume)
    net.Broadcast()
end

function ENT:BroadcastPlaylist()
    net.Start("PartyRadio_UpdatePlaylist")
    net.WriteEntity(self)
    net.WriteTable(self.Playlist)
    net.Broadcast()
end

function ENT:PlaySong(index)
    -- Validate index
    index = tonumber(index) or 0
    if index < 1 or index > #self.Playlist then return false end

    local song = self.Playlist[index]
    if not song or not song.url then return false end

    self.CurrentIndex = index
    self.IsPlaying = true

    -- Clear any existing auto-play timer
    self:ClearAutoPlayTimer()

    -- Try to schedule next song if duration is known
    if song.hash then
        local librarySong = ZerosRaveReactor.GetSongByHash(song.hash)
        if librarySong and librarySong.duration and librarySong.duration > 0 then
            self:ScheduleNextSong(librarySong.duration)
        end
    end

    net.Start("PartyRadio_PlayNext")
    net.WriteEntity(self)
    net.WriteTable(song)
    net.Broadcast()

    self:BroadcastState()
    return true
end

function ENT:StopPlayback()
    self.IsPlaying = false

    -- Clear auto-play timer
    self:ClearAutoPlayTimer()

    net.Start("PartyRadio_Stop")
    net.WriteEntity(self)
    net.Broadcast()

    self:BroadcastState()
end

function ENT:ScheduleNextSong(duration)
    -- Add 1 second buffer to ensure song has finished
    local delay = duration + 1

    local timerName = "PartyRadio_AutoNext_" .. self:EntIndex()

    timer.Create(timerName, delay, 1, function()
        if IsValid(self) and self.IsPlaying then
            print("[Party Radio] Auto-playing next song after " .. duration .. "s")
            self:PlayNext()
        end
    end)

    print("[Party Radio] Scheduled next song in " .. delay .. " seconds")
end

function ENT:ClearAutoPlayTimer()
    local timerName = "PartyRadio_AutoNext_" .. self:EntIndex()
    if timer.Exists(timerName) then
        timer.Remove(timerName)
    end
end

function ENT:PlayNext()
    if #self.Playlist == 0 then
        self:StopPlayback()
        return
    end

    self.CurrentIndex = self.CurrentIndex + 1
    if self.CurrentIndex > #self.Playlist then
        self.CurrentIndex = 1
    end

    if not self:PlaySong(self.CurrentIndex) then
        self:StopPlayback()
    end
end

function ENT:AddSong(data)
    -- Security: Validate input
    if not istable(data) then return false end

    -- Check playlist size limit
    if #self.Playlist >= self.MaxPlaylistSize then
        return false, "Playlist is full (max " .. self.MaxPlaylistSize .. " songs)"
    end

    -- Sanitize strings
    local name = string.sub(tostring(data.name or "Unknown"), 1, 100)
    local artist = string.sub(tostring(data.artist or "Unknown"), 1, 100)
    local url = tostring(data.url or "")
    local genre = string.sub(tostring(data.genre or "Custom"), 1, 50)

    table.insert(self.Playlist, {
        name = name,
        artist = artist,
        url = url,
        genre = genre,
        hash = data.hash -- Store hash for visual indicator
    })

    self:BroadcastPlaylist()
    return true
end

function ENT:AddSongFromLibrary(hash)
    -- Get song from library
    local song = ZerosRaveReactor.GetSongByHash(hash)
    if not song then
        return false, "Song not found in library"
    end

    -- Check playlist size limit
    if #self.Playlist >= self.MaxPlaylistSize then
        return false, "Playlist is full (max " .. self.MaxPlaylistSize .. " songs)"
    end

    -- Add to playlist
    table.insert(self.Playlist, {
        name = song.name,
        artist = song.artist,
        url = song.url,
        genre = song.genre,
        hash = hash
    })

    self:BroadcastPlaylist()
    return true
end

function ENT:ValidateAndAddToLibrary(data, playerSteamID)
    -- Security: Validate input
    if not istable(data) then return false, "Invalid data" end

    -- Validate URL
    local url = tostring(data.url or "")
    if url == "" or #url > 500 then return false, "Invalid URL" end

    -- Basic URL validation (must start with http/https and contain audio extension)
    if not string.match(url, "^https?://") then
        return false, "URL must start with http:// or https://"
    end

    local validExtensions = {".mp3", ".ogg", ".wav", ".m4a", ".flac"}
    local hasValidExtension = false
    for _, ext in ipairs(validExtensions) do
        if string.find(string.lower(url), ext) then
            hasValidExtension = true
            break
        end
    end

    if not hasValidExtension then
        return false, "URL must point to an audio file (mp3, ogg, wav, etc.)"
    end

    -- Sanitize strings
    local name = string.sub(tostring(data.name or "Unknown"), 1, 100)
    local artist = string.sub(tostring(data.artist or "Unknown"), 1, 100)
    local genre = string.sub(tostring(data.genre or "Custom"), 1, 50)

    -- Add to library
    return ZerosRaveReactor.AddSongToLibrary(url, name, artist, genre, playerSteamID)
end

function ENT:RemoveSong(index)
    -- Validate index
    index = tonumber(index) or 0
    if index < 1 or index > #self.Playlist then return false end

    table.remove(self.Playlist, index)

    -- Adjust current index if needed
    if self.CurrentIndex >= index and self.CurrentIndex > 0 then
        self.CurrentIndex = math.max(0, self.CurrentIndex - 1)
    end

    -- Stop if playlist is empty
    if #self.Playlist == 0 then
        self:StopPlayback()
    end

    self:BroadcastPlaylist()
    return true
end

function ENT:SetVolume(volume)
    volume = tonumber(volume) or 0.5
    self.Volume = math.Clamp(volume, 0, 1)
    self:BroadcastState()
end

-- Network receivers with security checks
net.Receive("PartyRadio_PlayNext", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.PlayNext(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    ent:PlayNext()
end)

net.Receive("PartyRadio_Stop", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.Stop(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    ent:StopPlayback()
end)

net.Receive("PartyRadio_AddURL", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.AddURL(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    -- Read with size limit
    local data = net.ReadTable()

    local success, err = ent:AddSong(data)
    if not success then
        ply:ChatPrint("Failed to add song: " .. (err or "Unknown error"))
    else
        ply:ChatPrint("Song added to playlist!")
    end
end)

net.Receive("PartyRadio_RemoveSong", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.RemoveSong(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local index = net.ReadUInt(16)

    if not ent:RemoveSong(index) then
        ply:ChatPrint("Failed to remove song: Invalid index")
    end
end)

net.Receive("PartyRadio_SetVolume", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.SetVolume(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local volume = net.ReadFloat()
    ent:SetVolume(volume)
end)

net.Receive("PartyRadio_PlaySpecific", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.PlayNext(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local index = net.ReadUInt(16)

    if not ent:PlaySong(index) then
        ply:ChatPrint("Failed to play song: Invalid index")
    end
end)

-- New network receivers for song library management
net.Receive("PartyRadio_AddToLibrary", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.AddToLibrary(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local data = net.ReadTable()

    local success, err = ent:ValidateAndAddToLibrary(data, ply:SteamID64())
    if not success then
        ply:ChatPrint("Failed to add song to library: " .. (err or "Unknown error"))
    else
        ply:ChatPrint("Song added to library!")
        -- Also add to current radio's playlist
        ent:AddSongFromLibrary(err) -- err contains the hash on success
    end
end)

net.Receive("PartyRadio_RemoveFromLibrary", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.RemoveFromLibrary(ply) then return end

    local hash = net.ReadString()

    local success, err = ZerosRaveReactor.RemoveSongFromLibrary(hash, ply)
    if not success then
        ply:ChatPrint("Failed to remove song from library: " .. (err or "Unknown error"))
    else
        ply:ChatPrint("Song removed from library!")
    end
end)

net.Receive("PartyRadio_AddFromLibrary", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.AddFromLibrary(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local hash = net.ReadString()

    local success, err = ent:AddSongFromLibrary(hash)
    if not success then
        ply:ChatPrint("Failed to add song to playlist: " .. (err or "Unknown error"))
    else
        ply:ChatPrint("Song added to playlist!")
    end
end)

net.Receive("PartyRadio_EditSongInLibrary", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not ply:IsSuperAdmin() then return end
    if not rateLimiters.EditSongInLibrary(ply) then return end

    local data = net.ReadTable()
    local hash = data.hash
    local name = data.name
    local artist = data.artist
    local genre = data.genre

    local success, err = ZerosRaveReactor.EditSongInLibrary(hash, name, artist, genre, ply)
    if not success then
        ply:ChatPrint("Failed to edit song: " .. (err or "Unknown error"))
    else
        ply:ChatPrint("Song updated successfully!")
    end
end)

-- Client reports song duration (for auto-play scheduling)
net.Receive("PartyRadio_ReportDuration", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not rateLimiters.ReportDuration(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    -- Only accept from players within range of the radio
    if ent:GetPos():Distance(ply:GetPos()) > ent.Range then return end

    local hash = net.ReadString()
    local duration = net.ReadFloat()

    -- Update duration in library and schedule next song
    local success, actualDuration = ZerosRaveReactor.UpdateSongDuration(hash, duration)

    if success and actualDuration then
        -- If this is the currently playing song and we don't have a timer yet, schedule it
        if ent.IsPlaying and ent.Playlist[ent.CurrentIndex] and ent.Playlist[ent.CurrentIndex].hash == hash then
            local timerName = "PartyRadio_AutoNext_" .. ent:EntIndex()
            if not timer.Exists(timerName) then
                ent:ScheduleNextSong(actualDuration)
            end
        end
    end
end)

-- Client notifies server that song has ended (fallback/verification)
net.Receive("PartyRadio_SongEnded", function(len, ply)
    -- Security checks
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not rateLimiters.SongEnded(ply) then return end

    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    -- Only accept from players within range of the radio
    if ent:GetPos():Distance(ply:GetPos()) > ent.Range then return end

    -- If radio is still marked as playing, trigger next song
    if ent.IsPlaying then
        print("[Party Radio] Song ended notification from client, playing next")
        ent:PlayNext()
    end
end)