-- ============================================
-- PARTY RADIO CLIENT INITIALIZATION
-- ============================================
-- Main client-side file for the Party Radio entity
-- This handles initialization, audio playback, and coordinates
-- between the audio analysis and visual effects modules

-- Include shared definitions and menu
include("shared.lua")
include("cl_menu.lua")

-- Include our modular components
include("cl_audio_analysis.lua")  -- Audio analysis & beat detection
include("cl_visual_effects.lua")  -- Visual effects & rendering

-- ============================================
-- INITIALIZATION
-- ============================================

--[[
    Initialize entity properties and configurations
    Sets up all the data structures needed for audio analysis and visual effects
]]
function ENT:Initialize()
    -- ===== AUDIO ANALYSIS DATA =====
    self.FFTData = {}           -- Current raw FFT data from the audio channel
    self.FFTSmooth = {}         -- Smoothed FFT data (reduces jitter in visuals)
    self.FFTNormalized = {}     -- Normalized FFT data (0-1 range)

    -- Beat detection data structures
    self.FluxHistory = {Kick = {}, Snare = {}, HiHat = {}, Clap = {}} -- Per-band flux histories
    self.FluxHistorySize = 100  -- Longer history for better adaptation
    self.BeatHistory = {}       -- Timestamps of recently detected beats
    self.LastBeatTimes = {
        Kick = 0,
        Snare = 0,
        HiHat = 0,
        Clap = 0
    }

    -- Adaptive threshold data (not used directly, but kept for compatibility)
    self.AdaptiveThresholds = {
        Kick = 1.5,
        Snare = 1.5,
        HiHat = 1.9,
        Clap = 1.5
    }

    -- Energy history for normalization
    self.EnergyHistory = {}
    self.MaxEnergyHistory = 100
    self.CurrentMaxEnergy = 0.01

    -- ===== PLAYBACK STATE =====
    self.SoundChannel = nil
    self.CurrentSong = nil
    self.Volume = 0.5
    self.IsPlaying = false
    self.CalibrationEndTime = 0  -- Time when calibration ends

    -- ===== VISUAL EFFECT PROPERTIES =====
    self.VisualIntensity = 0
    self.BassIntensity = 0
    self.TrebleIntensity = 0
    self.CurrentColor = Color(100, 100, 255)
    self.TargetColor = Color(100, 100, 255)
    self.BeatScale = 1
    self.ModelScale = 2
    self.LODLevel = 0

    -- ===== FFT VISUALIZATION VARIABLES =====
    self.fft_rot = 0
    self.fft_scale = 1
    self.fft_smooth = 0
    self.fft_ring_count = 5
    self.fft_sphere_count = 3
    self.fft_col01 = Color(255, 255, 255)
    self.fft_col02 = Color(255, 255, 255)
    self.fft_col03 = Color(255, 255, 255)
    self.fft_tempo_avg = 1
    self.fft_data = {}

    -- ===== HOLOGRAM AND ANIMATION =====
    self.EpicShaderTime = 0
    self.HoloModelChange = 0
    self.HoloLastOption = false
    self.FlipRotationDir = false
    self.rot_speed_smooth = 0
    self.rot_speed_target = 0
    self.next_rot_target_check = 0
    self.AnimCycle = 0

    -- ===== INITIALIZE DATA ARRAYS =====
    for i = 1, self.Config.FFT.Bands do
        self.FFTSmooth[i] = 0
        self.FFTNormalized[i] = 0
    end

    self.PrevFFTData = {}
    self.PrevFFTSmooth = {}
    for i = 1, self.Config.FFT.Bands do
        self.PrevFFTData[i] = 0
        self.PrevFFTSmooth[i] = 0
    end

    -- Initialize frequency band mappings
    self:InitializeFrequencyBands()
end

--[[
    Clean up resources when entity is removed
    Stops music and removes timers to prevent memory leaks
]]
function ENT:OnRemove()
    self:StopMusic()
    timer.Remove("PartyRadio_NextSong_" .. self:EntIndex())
end

-- ============================================
-- AUDIO PLAYBACK
-- ============================================

--[[
    Stop music playback and clean up audio resources
]]
function ENT:StopMusic()
    if IsValid(self.SoundChannel) then
        self.SoundChannel:Stop()
        self.SoundChannel = nil
    end
    self.IsPlaying = false
    timer.Remove("PartyRadio_NextSong_" .. self:EntIndex())
end

--[[
    Play a song from a URL
    @param url: Direct URL to an audio file (mp3, ogg, etc.)
]]
function ENT:PlaySound(url)
    -- Validate URL
    if not url or type(url) ~= "string" then return end

    -- Stop any currently playing music
    self:StopMusic()

    -- Reset audio analysis data for new song
    self.EnergyHistory = {}
    self.CurrentMaxEnergy = 0.01
    self.FluxHistory = {Kick = {}, Snare = {}, HiHat = {}, Clap = {}}
    self.BeatHistory = {}
    self.CalibrationEndTime = CurTime() + 5  -- 5-second calibration period

    -- Reset vocal tracker for new song calibration
    self.VocalTracker = nil

    -- Start playing the new song
    sound.PlayURL(url, "3d noblock", function(channel, errID, errName)
        if not IsValid(channel) then
            print("[Party Radio] Failed to play URL:", errName or "Unknown error", tostring(errID))
            return
        end

        if not IsValid(self) then
            channel:Stop()
            return
        end

        self.SoundChannel = channel
        self.IsPlaying = true

        channel:SetPos(self:GetPos())
        channel:Set3DEnabled(true)
        channel:Set3DFadeDistance(1200, 2500)
        channel:SetVolume(self.Volume)
        channel:Play()

        local length = channel:GetLength()
        if length > 0 then
            timer.Create("PartyRadio_NextSong_" .. self:EntIndex(), length, 1, function()
                if IsValid(self) then
                    net.Start("PartyRadio_PlayNext")
                    net.WriteEntity(self)
                    net.SendToServer()
                end
            end)
        end
    end)
end

--[[
    Check if radio is currently playing music
    @return boolean: true if playing, false otherwise
]]
function ENT:IsRadioPlaying()
    return IsValid(self.SoundChannel) and self.SoundChannel:GetState() == GMOD_CHANNEL_PLAYING
end

-- ============================================
-- MAIN THINK & RENDER LOOP
-- ============================================

--[[
    Main think function - updates model scale and animations
]]
function ENT:Think()
    -- Smooth beat scale back to normal
    if self.BeatScale and self.BeatScale > 1 then
        self.BeatScale = Lerp(FrameTime() * 0.5, self.BeatScale, 1)
    end

    if self:IsRadioPlaying() then
        -- Apply beat scale with smoothing
        local targetScale = self.ModelScale * (self.BeatScale or 1)
        self.SmoothScale = Lerp(FrameTime() * 4, self.SmoothScale or 0, targetScale)
        self:SetModelScale(self.SmoothScale, 0)
    else
        -- Reset to base scale when not playing
        self:SetModelScale(self.ModelScale, 0)
    end

	self.SmoothIntensity = Lerp(FrameTime() * 0.5,self.SmoothIntensity or 0,self.VisualIntensity)
	self.SmoothVocalEnergyIntensity = Lerp(FrameTime() * 0.5,self.SmoothVocalEnergyIntensity or 0,(self.VocalEnergySmooth or 0) * 2)

	if self.VocalEnergySmooth and self.VocalEnergySmooth > 0 then
		local sin = math.sin(CurTime())
		local cos = math.cos(CurTime())

		local intensity = self.SmoothIntensity
		local vocal = self.SmoothVocalEnergyIntensity

		local BaseRad = 100
		local SinRad = math.abs(200 * sin)
		local AnimRad = 400 * intensity

		local radius = math.Clamp(BaseRad + SinRad + AnimRad,BaseRad,5000)

		local numParticles = 12

		local height = (200 * vocal) + math.abs(200 * cos)

		local center = self:LocalToWorld( Vector(0, 0,  radius + height) )
		self.PartyCenter = center
		self.PartyRadius = radius
		self.PartyHeight = -height

	    -- Trigger extra particles during intense moments
	    if ( not self.NextBeat or CurTime() > self.NextBeat) then
			self.NextBeat = CurTime() + 0.01
	        self:CreateCircularParticles(center, "radio_speaker_beat01", radius, numParticles, -height, 0)
	    end
	end

    -- Continue thinking
    self:SetNextClientThink(CurTime())
    return true
end

--[[
    Main rendering function
    Handles LOD and calls appropriate visual effects
]]
function ENT:DrawTranslucent()
    -- Draw the base model
    self:DrawModel()

    -- Skip effects if not playing
    if not self:IsRadioPlaying() then return end

    -- Calculate LOD based on distance
    local distance = self:GetListenerDistance()
    if distance > self.Config.Performance.LODDistance then
        self.LODLevel = 2 -- Low detail
    elseif distance > self.Config.Performance.LODDistance / 2 then
        self.LODLevel = 1 -- Medium detail
    else
        self.LODLevel = 0 -- Full detail
    end

    -- Update FFT analysis at configured rate
    self.NextUpdateTime = CurTime() + self.Config.Performance.UpdateRate
    self:AnalyzeFFT()

    -- Update view angle for 3D2D rendering
    self.LocalViewAng = Angle(90, LocalPlayer():EyeAngles().y - 90, 90)

    -- Draw effects based on LOD
    if self.LODLevel < 2 then
        self:DrawDynamicLighting()
    end

	if self.LODLevel == 0 then
        self:DrawFrequencyBars()

        -- Draw advanced detection visuals
        self:DrawVocalRipples()
        self:DrawGrooveWaves()
        self:DrawTransitionEffects()
    end

	if LocalPlayer():IsSuperAdmin() then
		self:DrawBeatIndicator()
		self:DrawDebugInfo()
	end

    -- Keep audio positioned at entity
    if IsValid(self.SoundChannel) then
        self.SoundChannel:SetPos(self:GetPos())
    end


	if not self.PartyRadius then return end

	local angleStep = 360 / 12
	for i = 0, 12 - 1 do
		local angle = math.rad(i * angleStep + (CurTime() * 10))
		local posX = math.cos(angle) * self.PartyRadius
		local posY = math.sin(angle) * self.PartyRadius
		local particlePos = self.PartyCenter + Vector(posX, posY, self.PartyHeight)
		render.SetMaterial(Material("trails/laser"))
		render.DrawBeam(particlePos, self.PartyCenter, 50, 0, 0, self.fft_col02)
	end
end

-- ============================================
-- NETWORKING
-- ============================================

-- Handle play next song message
net.Receive("PartyRadio_PlayNext", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local songData = net.ReadTable()
    if not istable(songData) then return end

    ent.CurrentSong = songData
    if songData.url then
        ent:PlaySound(songData.url)
    end
end)

-- Handle stop playback message
net.Receive("PartyRadio_Stop", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    ent:StopMusic()
    ent.CurrentSong = nil
end)

-- Handle state update message
net.Receive("PartyRadio_UpdateState", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local isPlaying = net.ReadBool()
    local currentIndex = net.ReadUInt(16)
    local volume = net.ReadFloat()

    ent.Volume = math.Clamp(volume, 0, 1)

    if IsValid(ent.SoundChannel) then
        ent.SoundChannel:SetVolume(ent.Volume)
    end

    ent.IsPlaying = isPlaying
end)
