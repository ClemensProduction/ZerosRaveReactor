ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Zeros Rave Reactor"
ENT.Category = "Fun + Games"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_BOTH

ZerosRaveReactor = ZerosRaveReactor or {}

----------------------------------------
-- Precache Particle Effects used for Beat Visualization
----------------------------------------

game.AddParticles("particles/zpc2_cake_explosions.pcf")
PrecacheParticleSystem("zpc2_cake_explosion_blue")
PrecacheParticleSystem("zpc2_cake_explosion_red")
PrecacheParticleSystem("zpc2_cake_explosion_green")
PrecacheParticleSystem("zpc2_cake_explosion_orange")
PrecacheParticleSystem("zpc2_cake_explosion_pink")
PrecacheParticleSystem("zpc2_cake_explosion_cyan")
PrecacheParticleSystem("zpc2_cake_explosion_violett")

game.AddParticles("particles/radio_speaker_effects.pcf")
PrecacheParticleSystem("radio_speaker_beat01")
PrecacheParticleSystem("radio_speaker_beat02")
PrecacheParticleSystem("radio_speaker_beat03")
PrecacheParticleSystem("radio_speaker_beat04")
PrecacheParticleSystem("radio_speaker_beat05")


game.AddParticles("particles/zpc2_spark_explosions.pcf")
PrecacheParticleSystem("zpc2_explospark_blue")
PrecacheParticleSystem("zpc2_explospark_green")
PrecacheParticleSystem("zpc2_explospark_orange")
PrecacheParticleSystem("zpc2_explospark_red")
PrecacheParticleSystem("zpc2_explospark_violett")
PrecacheParticleSystem("zpc2_explospark_white")

game.AddParticles("particles/zpc2_sparktower.pcf")
PrecacheParticleSystem("zpc2_sparktower_blue")
PrecacheParticleSystem("zpc2_sparktower_red")
PrecacheParticleSystem("zpc2_sparktower_green")
PrecacheParticleSystem("zpc2_sparktower_orange")
PrecacheParticleSystem("zpc2_sparktower_pink")
PrecacheParticleSystem("zpc2_sparktower_cyan")
PrecacheParticleSystem("zpc2_sparktower_violett")


game.AddParticles("particles/zpc2_oneshot_basic.pcf")
PrecacheParticleSystem("zpc2_oneshot_red")
PrecacheParticleSystem("zpc2_oneshot_green")
PrecacheParticleSystem("zpc2_oneshot_blue")
PrecacheParticleSystem("zpc2_oneshot_white")
PrecacheParticleSystem("zpc2_oneshot_violett")
PrecacheParticleSystem("zpc2_oneshot_orange")

-------------



game.AddParticles("particles/zpc2_burst_green.pcf")
PrecacheParticleSystem("zpc2_burst_tiny_green")
PrecacheParticleSystem("zpc2_burst_medium_green")
PrecacheParticleSystem("zpc2_burst_big_green")

game.AddParticles("particles/zpc2_burst_blue.pcf")
PrecacheParticleSystem("zpc2_burst_tiny_blue")
PrecacheParticleSystem("zpc2_burst_medium_blue")
PrecacheParticleSystem("zpc2_burst_big_blue")

game.AddParticles("particles/zpc2_burst_orange.pcf")
PrecacheParticleSystem("zpc2_burst_tiny_orange")
PrecacheParticleSystem("zpc2_burst_medium_orange")
PrecacheParticleSystem("zpc2_burst_big_orange")

game.AddParticles("particles/zpc2_burst_red.pcf")
PrecacheParticleSystem("zpc2_burst_tiny_red")
PrecacheParticleSystem("zpc2_burst_medium_red")
PrecacheParticleSystem("zpc2_burst_big_red")

game.AddParticles("particles/zpc2_burst_violett.pcf")
PrecacheParticleSystem("zpc2_burst_tiny_violett")
PrecacheParticleSystem("zpc2_burst_medium_violett")
PrecacheParticleSystem("zpc2_burst_big_violett")

game.AddParticles("particles/zpc2_burst_white.pcf")
PrecacheParticleSystem("zpc2_burst_tiny_white")
PrecacheParticleSystem("zpc2_burst_medium_white")
PrecacheParticleSystem("zpc2_burst_big_white")

game.AddParticles("particles/zpc2_burst_pink.pcf")
PrecacheParticleSystem("zpc2_burst_tiny_pink")
PrecacheParticleSystem("zpc2_burst_medium_pink")
PrecacheParticleSystem("zpc2_burst_big_pink")

game.AddParticles("particles/zpc2_burst_cyan.pcf")
PrecacheParticleSystem("zpc2_burst_tiny_cyan")
PrecacheParticleSystem("zpc2_burst_medium_cyan")
PrecacheParticleSystem("zpc2_burst_big_cyan")

----------------------------------------
-- Script Config
----------------------------------------

ENT.Config = {
    -- FFT Analysis Settings
    FFT = {
        Size = FFT_2048,           -- Higher resolution for better frequency analysis
        Bands = 64,                -- Number of frequency bands to analyze
        Smoothing = 0.5,           -- Smoothing factor (0-1)
        BeatThreshold = 0.15,      -- Threshold for beat detection
        BeatCooldown = 0.15,       -- Minimum time between beats
		FluxHistorySize = 50 	   -- Number of frames for flux averaging
    },

    -- Frequency Ranges (FFT indices)
    Frequencies = {
		SubBass = {1, 1},  -- ~0-344 Hz
		Bass = {1, 3},     -- ~0-1032 Hz (bass and low mids)
		LowMid = {4, 8},   -- ~1032-2752 Hz
		Mid = {9, 19},     -- ~2752-4130 Hz
		HighMid = {20, 30},-- ~4300-6450 Hz
		High = {31, 50},   -- ~6450-10750 Hz (treble)
		Presence = {51, 64}-- ~10750-22050 Hz (high treble/brilliance)
    },

    -- Visual Effects Configuration
    Effects = {
        EnableParticles = true,
        EnableLighting = true,
        EnableShaders = true,
        EnableScreenShake = true,
        MaxShakeDistance = 500,
        MaxLightDistance = 1500
    },

    -- Performance Settings
    Performance = {
        UpdateRate = 0.03,         -- How often to update visuals
        MaxParticles = 50,         -- Maximum particle effects
        LODDistance = 4000         -- Distance for level of detail
    }
}

-- Default Songs added to the playlist
-- NOTE Songs are registered from the entities sh_config.lua
ENT.DefaultSongs = ENT.DefaultSongs or {}

-- Custom models used when rendering the animated 3d model over the radio
-- NOTE Model Paths are registered from the entities sh_config.lua
----------------------------------------
-- Dance Model Config
----------------------------------------

ENT.ModelList = {
	"models/konnie/spg/femalesnatcher.mdl",
	"models/konnie/spg/headgirl.mdl",
}

----------------------------------------
-- Helper functions
----------------------------------------

-- Helper function to check if entity is playing
function ENT:IsRadioPlaying()
    if CLIENT then
        return self.SoundChannel and IsValid(self.SoundChannel)
    end
    return self.IsPlaying
end

-- Shared helper for distance calculations
function ENT:GetListenerDistance(listener)
    listener = listener or (CLIENT and LocalPlayer() or nil)
    if not IsValid(listener) then return math.huge end
    return self:GetPos():Distance(listener:GetPos())
end



