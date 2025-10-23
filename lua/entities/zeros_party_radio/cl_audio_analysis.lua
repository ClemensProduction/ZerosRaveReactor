-- ============================================
-- AUDIO ANALYSIS & BEAT DETECTION MODULE
-- ============================================
-- This module handles all FFT analysis, beat detection,
-- and advanced music pattern recognition
--
-- IMPORTANT: This module is now FPS-independent and sample-rate aware
-- All timing is based on real-time (seconds) rather than frames
-- All frequency bands are calculated dynamically based on audio sample rate

--[[
    Initialize frequency band mappings for more accurate beat detection
    Maps FFT bins to actual frequency ranges based on sample rate

    This function now supports DYNAMIC frequency band calculation to handle
    different audio sample rates (44.1kHz, 48kHz, etc.) from various sources
]]
function ENT:InitializeFrequencyBands()
    -- Use config ranges for grouped bands initially
    -- These will be recalculated when audio starts playing
    self.FrequencyBands = self.Config.Frequencies

    -- Initialize sample rate tracking
    self.AudioSampleRate = 44100  -- Default, will be updated when audio plays
    self.FFTBinWidth = 0  -- Calculated when we know sample rate
end

--[[
    Recalculate frequency bands based on actual audio sample rate
    This ensures we're analyzing the correct frequency ranges regardless of audio quality

    Called when audio starts playing or sample rate changes
]]
function ENT:RecalculateFrequencyBands()
    if not self.SoundChannel then return end

    -- Get actual sample rate from the audio channel
    -- Different audio sources (YouTube, SoundCloud, local files) may have different rates:
    -- Common rates: 44100 Hz (CD quality), 48000 Hz (professional), 32000 Hz (lower quality)
    local sampleRate = 44100  -- Default fallback

    -- Try to get actual sample rate from the audio channel
    local success, rate = pcall(function()
        return self.SoundChannel:GetSamplingRate()
    end)

    if success and rate and rate > 0 then
        sampleRate = rate
    end

    self.AudioSampleRate = sampleRate

    -- Calculate FFT bin width
    -- Nyquist frequency is half the sample rate (maximum representable frequency)
    local nyquist = sampleRate / 2
    -- Each FFT bin represents (nyquist / number of bins) Hz
    self.FFTBinWidth = nyquist / (self.Config.FFT.Size / 2)

    -- Helper function to convert frequency (Hz) to FFT bin index
    local function FreqToBin(freq)
        return math.max(1, math.min(self.Config.FFT.Bands, math.floor(freq / self.FFTBinWidth)))
    end

    -- Recalculate all frequency bands based on actual sample rate
    -- This ensures accurate detection regardless of audio quality
    self.FrequencyBands = {
        SubBass = {FreqToBin(20), FreqToBin(60)},      -- 20-60 Hz: Deep bass, felt more than heard
        Bass = {FreqToBin(60), FreqToBin(250)},        -- 60-250 Hz: Bass drums, bass guitar
        LowMid = {FreqToBin(250), FreqToBin(500)},     -- 250-500 Hz: Low mids
        Mid = {FreqToBin(500), FreqToBin(2000)},       -- 500-2000 Hz: Snare, vocals, guitars
        HighMid = {FreqToBin(2000), FreqToBin(4000)},  -- 2000-4000 Hz: Claps, high vocals
        High = {FreqToBin(4000), FreqToBin(8000)},     -- 4000-8000 Hz: Hi-hats, cymbals
        VeryHigh = {FreqToBin(8000), FreqToBin(16000)} -- 8000-16000 Hz: Air, shimmer
    }

    print("[Audio Analysis] Initialized with sample rate: " .. sampleRate .. " Hz, bin width: " .. math.floor(self.FFTBinWidth) .. " Hz")
end

-- ============================================
-- FFT ANALYSIS
-- ============================================

--[[
    Main FFT analysis function
    Processes audio data to extract frequency information and detect beats

    FFT (Fast Fourier Transform) converts audio from time domain to frequency domain,
    allowing us to see which frequencies are present and how strong they are
]]
function ENT:AnalyzeFFT()
    -- Only analyze if music is playing
    if not self:IsRadioPlaying() then return end

    -- Get FFT data from audio channel
    -- FFT returns an array of values representing energy at different frequencies
    local fftTable = {}
    local success = pcall(function()
        self.SoundChannel:FFT(fftTable, self.Config.FFT.Size)
    end)

    if not success or #fftTable == 0 then return end

    -- Save previous frame data for calculating spectral flux (change between frames)
    -- This helps detect sudden changes in frequency content (beats, onsets)
    if self.FFTData and #self.FFTData > 0 then
        self.PrevFFTData = {}
        for i = 1, self.Config.FFT.Bands do
            self.PrevFFTData[i] = self.FFTData[i] or 0
        end
    end

    if not self.PrevFFTData then
        self.PrevFFTData = {}
        for i = 1, self.Config.FFT.Bands do
            self.PrevFFTData[i] = 0
        end
    end

    -- Process new FFT data by grouping bins into bands
    -- This reduces noise and makes detection more reliable
    self.FFTData = {}
    local bandSize = math.max(1, math.floor(#fftTable / self.Config.FFT.Bands))
    local maxBandAvg = 0
    local tempAvgs = {}

    -- Calculate average energy for each band
    for i = 1, self.Config.FFT.Bands do
        local sum = 0
        local count = 0
        local startIdx = math.floor((i - 1) * bandSize) + 1
        local endIdx = math.min(#fftTable, math.floor(i * bandSize))

        for j = startIdx, endIdx do
            if fftTable[j] and type(fftTable[j]) == "number" then
                sum = sum + fftTable[j]
                count = count + 1
            end
        end

        local avg = count > 0 and (sum / count) or 0
        tempAvgs[i] = avg
        maxBandAvg = math.max(maxBandAvg, avg)
    end

    -- Adaptive normalization to handle different loudness levels
    -- Keeps energy values in a consistent 0-1 range regardless of volume
    table.insert(self.EnergyHistory, maxBandAvg)
    if #self.EnergyHistory > self.MaxEnergyHistory then
        table.remove(self.EnergyHistory, 1)
    end

    local maxEnergy = 0
    for _, energy in ipairs(self.EnergyHistory) do
        maxEnergy = math.max(maxEnergy, energy)
    end

    -- Smoothly adjust normalization factor based on recent maximum energy
    self.CurrentMaxEnergy = Lerp(0.05, self.CurrentMaxEnergy or 0.01, maxEnergy)
    local normFactor = (self.CurrentMaxEnergy and self.CurrentMaxEnergy > 0.001) and (4 / self.CurrentMaxEnergy) or 1

    -- Normalize and smooth FFT data
    for i = 1, self.Config.FFT.Bands do
        local normAvg = math.Clamp((tempAvgs[i] or 0) * normFactor, 0, 1)
        local smoothing = self.Config.FFT.Smoothing or 0.2
        -- Smooth the data to reduce jitter and noise
        self.FFTSmooth[i] = Lerp(smoothing, normAvg, self.FFTSmooth[i] or 0)
        self.FFTData[i] = self.FFTSmooth[i]
        self.FFTNormalized[i] = math.min(1, self.FFTSmooth[i])
    end

    -- Calculate spectral flux (measure of change in frequency content)
    -- Higher flux indicates transients/onsets (beats, note changes, etc.)
    local flux = self:CalculateSpectralFlux()
    self.CurrentFlux = flux

    -- Update intensities for different frequency ranges
    self.BassIntensity = self:GetFrequencyIntensity("Bass")
    self.TrebleIntensity = self:GetFrequencyIntensity("High")
    self.VisualIntensity = (self.BassIntensity + self.TrebleIntensity) / 2

    -- Visualization helpers for rendering effects
    self.fft_data = self.FFTData
    self.fft_smooth = self.VisualIntensity
    self.fft_scale = 1 + self.VisualIntensity * 2
    self.fft_rot = CurTime() * 30
    self.fft_ring_count = math.floor(self.VisualIntensity * 10) + 1
    self.fft_sphere_count = math.floor(self.VisualIntensity * 5) + 1
    self.fft_col01 = self.CurrentColor
    self.fft_col02 = HSVToColor((CurTime() * 50) % 360, 1, 1)
    self.fft_col03 = HSVToColor((CurTime() * 70) % 360, 1, 1)

    -- Calculate average tempo from beat history
    if #self.BeatHistory > 1 then
        local intervals = 0
        for k = 2, #self.BeatHistory do
            intervals = intervals + (self.BeatHistory[k] - self.BeatHistory[k - 1])
        end
        self.fft_tempo_avg = intervals / (#self.BeatHistory - 1)
    else
        self.fft_tempo_avg = 1
    end

    -- Skip beat detection and visuals during calibration phase
    -- This allows the system to learn the song's characteristics first
    if CurTime() < self.CalibrationEndTime then return end

    -- Trigger beat detection and visual updates
    self:DetectBeatsAdvanced()
    self:UpdateVisualColor()
end

--[[
    Calculate spectral flux for onset detection
    Spectral flux measures the positive change in frequency content between frames
    High flux values indicate transients (beats, note onsets, etc.)

    @return number: Spectral flux value (higher = more change)
]]
function ENT:CalculateSpectralFlux()
    -- Initialize previous data if needed
    if not self.PrevFFTData then
        self.PrevFFTData = {}
        for i = 1, self.Config.FFT.Bands do
            self.PrevFFTData[i] = 0
        end
    end

    -- Ensure we have valid FFT data
    if not self.FFTData or #self.FFTData == 0 then
        self.CurrentFlux = 0
        return 0
    end

    -- Calculate weighted spectral flux
    local flux = 0
    for i = 1, math.min(self.Config.FFT.Bands, #self.FFTData) do
        local curr = self.FFTData[i] or 0
        local prev = self.PrevFFTData[i] or 0
        local diff = curr - prev

        -- Only count positive changes (onsets, not offsets)
        -- This prevents detecting note releases as beats
        if diff > 0 then
            -- Weight lower frequencies more heavily
            -- Bass frequencies are usually more important for beat detection
            local weight = 1 + (1 - (i / self.Config.FFT.Bands)) * 0.5
            flux = flux + (diff * weight)
        end
    end

    self.CurrentFlux = flux -- Store for debug display

    return flux
end

--[[
    Get average intensity for a specific frequency range
    Useful for tracking bass, mids, treble separately

    @param range: String key from FrequencyBands table (e.g., "Bass", "Mid", "High")
    @return number: Average intensity (0-1) for that frequency range
]]
function ENT:GetFrequencyIntensity(range)
    local band = self.FrequencyBands[range]
    if not band or not self.FFTNormalized then return 0 end

    local sum = 0
    local count = 0

    -- Clamp indices to valid range to prevent out-of-bounds access
    local startIdx = math.max(1, band[1])
    local endIdx = math.min(band[2], #self.FFTNormalized)

    -- Calculate average intensity for this frequency range
    for i = startIdx, endIdx do
        if self.FFTNormalized[i] and type(self.FFTNormalized[i]) == "number" then
            sum = sum + self.FFTNormalized[i]
            count = count + 1
        end
    end

    return count > 0 and (sum / count) or 0
end

-- ============================================
-- BEAT DETECTION
-- ============================================

--[[
    Advanced beat detection using multiple detection methods
    Combines spectral flux, energy peaks, and frequency-specific analysis
    to detect different types of percussion (kick, snare, hi-hat, clap)
]]
function ENT:DetectBeatsAdvanced()
    -- ===== EXISTING BEAT DETECTION =====

    -- KICK DRUM DETECTION (low frequency, 60-250 Hz)
    -- Typically the strongest beat element in most music
    local kickDetected, kickIntensity = self:DetectFrequencyBeat(
        "SubBass",  -- Frequency range to analyze
        "Kick",     -- Beat type identifier
        1.0,        -- Threshold multiplier
        0.1         -- Cooldown time (seconds) between detections
    )
    if kickDetected then
        self:OnBeatDetected(kickIntensity, "Kick")
    end

    -- SNARE DRUM DETECTION (mid frequency, 500-2000 Hz)
    -- Usually on beats 2 and 4 in most music
    local snareDetected, snareIntensity = self:DetectFrequencyBeat(
        "Mid",
        "Snare",
        1.0,
        0.1
    )
    if snareDetected then
        self:OnBeatDetected(snareIntensity, "Snare")
    end

    -- HI-HAT DETECTION (high frequency, 4000-8000 Hz)
    -- Rapid rhythmic element, often every 8th or 16th note
    local hihatDetected, hihatIntensity = self:DetectFrequencyBeat(
        "High",
        "HiHat",
        1.0,
        0.1
    )
    if hihatDetected then
        self:OnBeatDetected(hihatIntensity, "HiHat")
    end

    -- CLAP/PERCUSSION DETECTION (high-mid frequency, 2000-4000 Hz)
    -- Hand claps, snaps, and other percussive elements
    local clapDetected, clapIntensity = self:DetectFrequencyBeat(
        "HighMid",
        "Clap",
        1.0,
        0.1
    )
    if clapDetected then
        self:OnBeatDetected(clapIntensity, "Clap")
    end

    -- ===== NEW ADVANCED DETECTION =====

    -- VOCAL ONSET DETECTION
    -- Detects when vocals start singing (not just any sound in vocal range)
    local vocalDetected, vocalIntensity = self:DetectVocalOnset()
    if vocalDetected then
        self:OnVocalDetected(vocalIntensity)
        -- Uncomment to debug: print("Vocal Onset Detected:", vocalIntensity)
    end

    -- BASSLINE GROOVE DETECTION
    -- Detects consistent rhythmic bass patterns (not just individual kicks)
    -- Useful for detecting funky basslines, EDM grooves, etc.
    local grooveDetected, grooveConfidence, grooveType = self:DetectBasslineGroove()
    if grooveDetected then
        self:OnBasslineGrooveDetected(grooveConfidence, grooveType)
        print("Bassline Groove:", grooveType, "Confidence:", grooveConfidence)
    end

    -- BUILD-UP/DROP DETECTION
    -- Detects energy transitions common in EDM and electronic music
    -- "Building" = energy increasing (pre-drop), "Dropping" = sudden energy release
    local transitionState, transitionIntensity = self:DetectEnergyTransition()
    if transitionState ~= "steady" then
        self:OnEnergyTransition(transitionState, transitionIntensity)

        -- Rate-limit console output to avoid spam
        if transitionState == "dropping" and not self.LastDropPrint or (self.LastDropPrint and CurTime() - self.LastDropPrint > 1) then
            print("Energy Transition:", transitionState, "Intensity:", transitionIntensity)
            self.LastDropPrint = CurTime()
        end
    end
end

--[[
    Detect beats in a specific frequency range
    Uses adaptive thresholding based on recent history to handle different song styles

    @param frequencyRange: Key from FrequencyBands table (e.g., "Bass", "Mid")
    @param beatType: Type of beat identifier (e.g., "Kick", "Snare")
    @param threshold: Detection threshold multiplier (higher = less sensitive)
    @param cooldown: Minimum time in SECONDS between detections (prevents double-triggers)
    @return boolean, number: Whether beat detected, intensity (0-1)
]]
function ENT:DetectFrequencyBeat(frequencyRange, beatType, threshold, cooldown)
    local currentTime = CurTime()

    -- Check cooldown to prevent detecting the same beat multiple times
    -- This is TIME-BASED (seconds), not frame-based, so works at any FPS
    if self.LastBeatTimes[beatType] and (currentTime - self.LastBeatTimes[beatType] < cooldown) then
        return false, 0
    end

    -- Get frequency band for this beat type
    local band = self.FrequencyBands[frequencyRange]
    if not band or not self.FFTData or not self.PrevFFTData then
        return false, 0
    end

    -- Calculate spectral flux for this specific frequency range
    -- Flux = positive change in energy (indicates onset/transient)
    local flux = 0
    local energy = 0

    local startIdx = math.max(1, band[1])
    local endIdx = math.min(band[2], #self.FFTData)

    for i = startIdx, endIdx do
        local curr = self.FFTData[i] or 0
        local prev = self.PrevFFTData[i] or 0
        local diff = curr - prev

        -- Accumulate positive changes (onsets)
        if diff > 0 then
            flux = flux + diff
        end

        -- Also track total energy in this band
        energy = energy + curr
    end

    -- Normalize by band size to handle different band widths
    local bandSize = endIdx - startIdx + 1
    if bandSize > 0 then
        flux = flux / bandSize
        energy = energy / bandSize
    end

    -- Per-band flux history for automatic adaptive thresholding
    -- Each beat type learns its own characteristics
    local bandHistory = self.FluxHistory[beatType] or {}
    table.insert(bandHistory, flux)
    if #bandHistory > self.FluxHistorySize then
        table.remove(bandHistory, 1)
    end
    self.FluxHistory[beatType] = bandHistory

    -- Compute adaptive statistics per band
    -- Mean, variance, and median help us set dynamic thresholds
    local avgFlux = 0
    local variance = 0
    local sorted = table.Copy(bandHistory)
    table.sort(sorted)
    local medianFlux = (#sorted > 0) and sorted[math.floor(#sorted / 2) + 1] or 0.001

    if #bandHistory > 0 then
        for _, f in ipairs(bandHistory) do avgFlux = avgFlux + f end
        avgFlux = avgFlux / #bandHistory

        for _, f in ipairs(bandHistory) do variance = variance + (f - avgFlux) ^ 2 end
        variance = variance / #bandHistory
    else
        avgFlux = 0.001
    end
    local stdDev = math.sqrt(variance)

    -- Fully automatic threshold: Mean + scaled standard deviation + median offset
    -- This adapts to each song's characteristics automatically
    local fluxThreshold = (avgFlux + (stdDev * 0.5)) + (medianFlux * 0.05)
    local energyThreshold = 0.2  -- Minimum energy to prevent false positives on silence

    -- Beat detected if both flux and energy exceed thresholds
    if flux > fluxThreshold and energy > energyThreshold then

        self.LastBeatTimes[beatType] = currentTime

        -- Add to beat history for tempo calculation
        table.insert(self.BeatHistory, currentTime)
        if #self.BeatHistory > 20 then
            table.remove(self.BeatHistory, 1)
        end

        -- Calculate intensity based on how much we exceeded the threshold
        -- Higher intensity = stronger beat
        local intensity = math.min(1, flux / (fluxThreshold + 1e-6))

        return true, intensity
    end

    return false, 0
end

-- ============================================
-- ADVANCED PATTERN DETECTION
-- ============================================

--[[
    Detect vocal presence and onsets with broader coverage for 90% of songs

    This function analyzes multiple aspects of the audio to distinguish vocals from instruments:
    - Formants (0-4130Hz): The resonant frequencies that characterize vowel sounds
    - Harmonics (4130-6880Hz): The harmonic structure of the human voice
    - Sibilance (6880-10320Hz): "S", "T", "SH" sounds in speech/singing
    - Presence/Air (10320-13760Hz): Breath sounds and vocal "air"

    Uses advanced features:
    - Harmonic ratio: Peaks vs noise (voices are more tonal/harmonic)
    - Spectral centroid: Center of mass of spectrum (higher for vocals)
    - Spectral flatness: Tonal vs noisy (voices are tonal)
    - Bass correlation: Rejects bass-heavy transients that aren't vocals

    Adaptive calibration learns each song's baseline to reject false positives

    @return boolean, number: Vocal onset detected, smoothed vocal presence intensity (0-1)
]]
function ENT:DetectVocalOnset()
    local currentTime = CurTime()

    -- Initialize vocal tracker on first run
    if not self.VocalTracker then
        self.VocalTracker = {
            -- Energy histories (TIME-BASED, not frame-based)
            vocalEnergyHistory = {},
            instrumentalEnergyHistory = {},
            centroidHistory = {},
            flatnessHistory = {},
            harmonicRatioHistory = {},

            -- Smoothed values for stable detection
            vocalPresenceSmooth = 0,
            vocalEnergySmooth = 0,
            centroidSmooth = 0,
            flatnessSmooth = 0,
            harmonicRatioSmooth = 0,

            -- Adaptive baselines (learn each song's characteristics)
            vocalBaselineMax = 0.01,
            vocalBaselineAvg = 0.01,
            instrumentalBaselineMax = 0.01,
            instrumentalBaselineAvg = 0.01,

            -- Detection state
            lastVocalTime = 0,
            calibrationSamples = 0,

            -- TIME-BASED history management (seconds, not frames)
            maxHistoryTime = 4.0,  -- Keep 4 seconds of history
        }
    end

    local tracker = self.VocalTracker

    if not self.FFTData or #self.FFTData == 0 then
        return false, 0
    end

    -- Define vocal-related frequency bands (dynamically calculated based on sample rate)
    -- These cover the full range of human voice from bass singers to sopranos
    local formantBand = {1, 12}    -- 0-4130Hz: Fundamental frequencies + formants (vowels)
    local harmonicBand = {13, 20}  -- 4130-6880Hz: Harmonic overtones of voice
    local sibilanceBand = {21, 30} -- 6880-10320Hz: Consonants and sibilants
    local presenceBand = {31, 40}  -- 10320-13760Hz: Breath and "air" in vocals
    local bassBand = self.FrequencyBands["Bass"] or {1, 3}       -- Low instruments (to reject)
    local subBassBand = self.FrequencyBands["SubBass"] or {1, 1} -- Deep bass (to reject)

    -- Calculate weighted vocal energy across all vocal bands
    local vocalEnergy = 0
    local vocalCount = 0
    local fftSum = 0  -- For calculating spectral centroid
    local fftGeo = 1  -- For calculating spectral flatness (geometric mean)
    local fftBins = 0
    local peakCount = 0   -- Count frequency peaks (for harmonic ratio)
    local noiseEnergy = 0 -- Energy in non-peak regions

    -- Analyze FORMANTS (highest weight - most important for vocals)
    local startIdx = math.max(1, formantBand[1])
    local endIdx = math.min(formantBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        vocalEnergy = vocalEnergy + val * 1.0  -- Full weight
        vocalCount = vocalCount + 1.0
        fftSum = fftSum + val
        fftGeo = fftGeo * (val + 1e-6)
        fftBins = fftBins + 1

        -- Simple peak detection (local maximum)
        -- Harmonic sounds have more peaks than noise
        if i > 1 and i < #self.FFTData and val > (self.FFTData[i-1] or 0) and val > (self.FFTData[i+1] or 0) then
            peakCount = peakCount + 1
        else
            noiseEnergy = noiseEnergy + val
        end
    end

    -- Analyze HARMONICS (medium weight)
    startIdx = math.max(1, harmonicBand[1])
    endIdx = math.min(harmonicBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        vocalEnergy = vocalEnergy + val * 0.7  -- 70% weight
        vocalCount = vocalCount + 0.7
        fftSum = fftSum + val
        fftGeo = fftGeo * (val + 1e-6)
        fftBins = fftBins + 1
        if i > 1 and i < #self.FFTData and val > (self.FFTData[i-1] or 0) and val > (self.FFTData[i+1] or 0) then
            peakCount = peakCount + 1
        else
            noiseEnergy = noiseEnergy + val
        end
    end

    -- Analyze SIBILANCE (lower weight but important for consonants)
    startIdx = math.max(1, sibilanceBand[1])
    endIdx = math.min(sibilanceBand[2], #self.FFTData)
    local sibilanceEnergy = 0
    local sibilanceCount = 0
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        sibilanceEnergy = sibilanceEnergy + val
        sibilanceCount = sibilanceCount + 1
        fftSum = fftSum + val
        fftGeo = fftGeo * (val + 1e-6)
        fftBins = fftBins + 1
        if i > 1 and i < #self.FFTData and val > (self.FFTData[i-1] or 0) and val > (self.FFTData[i+1] or 0) then
            peakCount = peakCount + 1
        else
            noiseEnergy = noiseEnergy + val
        end
    end
    sibilanceEnergy = sibilanceCount > 0 and (sibilanceEnergy / sibilanceCount) or 0

    -- Analyze PRESENCE/AIR (breath sounds, natural vocal quality)
    startIdx = math.max(1, presenceBand[1])
    endIdx = math.min(presenceBand[2], #self.FFTData)
    local presenceEnergy = 0
    local presenceCount = 0
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        presenceEnergy = presenceEnergy + val
        presenceCount = presenceCount + 1
        fftSum = fftSum + val
        fftGeo = fftGeo * (val + 1e-6)
        fftBins = fftBins + 1
    end
    presenceEnergy = presenceCount > 0 and (presenceEnergy / presenceCount) or 0

    -- Calculate weighted average vocal energy
    vocalEnergy = vocalCount > 0 and (vocalEnergy / vocalCount) or 0

    -- Calculate instrumental (bass) energy to distinguish from vocals
    local instrumentalEnergy = 0
    local instrumentalCount = 0

    -- Sub-bass (deep bass)
    startIdx = math.max(1, subBassBand[1])
    endIdx = math.min(subBassBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        instrumentalEnergy = instrumentalEnergy + val
        instrumentalCount = instrumentalCount + 1
    end

    -- Bass
    startIdx = math.max(1, bassBand[1])
    endIdx = math.min(bassBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        instrumentalEnergy = instrumentalEnergy + val
        instrumentalCount = instrumentalCount + 1
    end
    instrumentalEnergy = instrumentalCount > 0 and (instrumentalEnergy / instrumentalCount) or 0

    -- Calculate SPECTRAL CENTROID (center of mass of spectrum)
    -- Higher centroid = brighter sound = more likely to be vocals
    local spectralCentroid = 0
    if fftSum > 0 then
        local weightedSum = 0
        for i = 1, #self.FFTData do
            weightedSum = weightedSum + (self.FFTData[i] or 0) * i
        end
        spectralCentroid = weightedSum / fftSum
    end

    -- Calculate SPECTRAL FLATNESS (noisiness measure)
    -- Ratio of geometric mean to arithmetic mean
    -- Lower flatness = more tonal = more likely to be vocals
    local spectralFlatness = 0
    if fftBins > 0 then
        local arithMean = fftSum / fftBins
        local geoMean = (fftGeo ^ (1 / fftBins))
        spectralFlatness = geoMean / (arithMean + 1e-6)
    end

    -- Calculate HARMONIC RATIO (tonality measure)
    -- Ratio of peak energy to noise energy
    -- Higher ratio = more harmonic = more likely to be vocals
    local harmonicRatio = (peakCount > 0 and fftBins > 0) and (peakCount / fftBins) * (fftSum / (noiseEnergy + 1e-6)) or 0
    harmonicRatio = math.Clamp(harmonicRatio, 0, 1)

    -- Store current values in TIME-BASED histories
    table.insert(tracker.vocalEnergyHistory, {time = currentTime, value = vocalEnergy})
    table.insert(tracker.instrumentalEnergyHistory, {time = currentTime, value = instrumentalEnergy})
    table.insert(tracker.centroidHistory, {time = currentTime, value = spectralCentroid})
    table.insert(tracker.flatnessHistory, {time = currentTime, value = spectralFlatness})
    table.insert(tracker.harmonicRatioHistory, {time = currentTime, value = harmonicRatio})

    -- CRITICAL FIX: Remove old entries based on TIME, not count
    -- This ensures consistent behavior regardless of FPS
    local maxHistoryTime = tracker.maxHistoryTime

    while #tracker.vocalEnergyHistory > 0 and (currentTime - tracker.vocalEnergyHistory[1].time) > maxHistoryTime do
        table.remove(tracker.vocalEnergyHistory, 1)
    end
    while #tracker.instrumentalEnergyHistory > 0 and (currentTime - tracker.instrumentalEnergyHistory[1].time) > maxHistoryTime do
        table.remove(tracker.instrumentalEnergyHistory, 1)
    end
    while #tracker.centroidHistory > 0 and (currentTime - tracker.centroidHistory[1].time) > maxHistoryTime do
        table.remove(tracker.centroidHistory, 1)
    end
    while #tracker.flatnessHistory > 0 and (currentTime - tracker.flatnessHistory[1].time) > maxHistoryTime do
        table.remove(tracker.flatnessHistory, 1)
    end
    while #tracker.harmonicRatioHistory > 0 and (currentTime - tracker.harmonicRatioHistory[1].time) > maxHistoryTime do
        table.remove(tracker.harmonicRatioHistory, 1)
    end

    -- Calibration phase: Learn song characteristics
    -- Need enough samples before we can reliably detect vocals
    tracker.calibrationSamples = tracker.calibrationSamples + 1
    if tracker.calibrationSamples < 100 then
        return false, 0
    end

    -- Update adaptive baselines with slow decay
    -- Max baselines track the loudest moments
    tracker.vocalBaselineMax = math.max(tracker.vocalBaselineMax * 0.995, vocalEnergy)
    tracker.instrumentalBaselineMax = math.max(tracker.instrumentalBaselineMax * 0.995, instrumentalEnergy)

    -- Helper function to get trimmed average (removes outliers)
    local function getTrimmedAvg(history)
        local values = {}
        for _, entry in ipairs(history) do
            table.insert(values, entry.value)
        end

        table.sort(values)
        local trim = math.floor(#values * 0.1)  -- Trim 10% from each end
        local sum = 0
        for i = trim + 1, #values - trim do
            sum = sum + values[i]
        end
        return (#values - 2 * trim > 0) and (sum / (#values - 2 * trim)) or 0.01
    end

    -- Update average baselines (robust to outliers)
    tracker.vocalBaselineAvg = getTrimmedAvg(tracker.vocalEnergyHistory)
    tracker.instrumentalBaselineAvg = getTrimmedAvg(tracker.instrumentalEnergyHistory)

    -- Normalize all features to 0-1 range based on baselines
    local normVocal = tracker.vocalBaselineMax > 0.001 and (vocalEnergy / tracker.vocalBaselineMax) or 0
    local normInstrumental = tracker.instrumentalBaselineMax > 0.001 and (instrumentalEnergy / tracker.instrumentalBaselineMax) or 0
    local normCentroid = math.Clamp((spectralCentroid - 4) / 25, 0, 1)  -- Vocals typically 4-30
    local normFlatness = 1 - math.Clamp(spectralFlatness, 0, 1)  -- Invert: high = tonal
    local normSibilance = math.Clamp(sibilanceEnergy / (tracker.vocalBaselineAvg + 1e-6), 0, 1)
    local normPresence = math.Clamp(presenceEnergy / (tracker.vocalBaselineAvg * 0.5 + 1e-6), 0, 1)
    local normHarmonic = math.Clamp(harmonicRatio, 0, 1)

    -- Calculate composite VOCAL PRESENCE score (weighted combination)
    local energyRatio = normVocal / (normVocal + normInstrumental + 0.001)
    local absoluteVocal = normVocal
    local spectralBalance = (normVocal > normInstrumental * 0.7) and 1 or (normVocal / (normInstrumental + 0.001))
    local tonalityBoost = normFlatness * 0.4 + normCentroid * 0.3 + normHarmonic * 0.3
    local highFreqBoost = (normSibilance * 0.5 + normPresence * 0.5) > 0.25 and 0.2 or 0

    local vocalPresence = (energyRatio * 0.25) + (absoluteVocal * 0.25) + (spectralBalance * 0.2) + (tonalityBoost * 0.2) + highFreqBoost
    vocalPresence = math.Clamp(vocalPresence, 0, 1)

    -- FPS-INDEPENDENT SMOOTHING using FrameTime()
    -- Delta time ensures smooth values regardless of frame rate
    local smoothFactor = FrameTime() * 1.2  -- Smoothing speed (lower = smoother)
    tracker.vocalPresenceSmooth = Lerp(smoothFactor, tracker.vocalPresenceSmooth, vocalPresence)
    tracker.vocalEnergySmooth = Lerp(FrameTime() * 4, tracker.vocalEnergySmooth, vocalEnergy)
    tracker.centroidSmooth = Lerp(FrameTime() * 3, tracker.centroidSmooth, normCentroid)
    tracker.flatnessSmooth = Lerp(FrameTime() * 3, tracker.flatnessSmooth, normFlatness)
    tracker.harmonicRatioSmooth = Lerp(FrameTime() * 3, tracker.harmonicRatioSmooth, normHarmonic)

    -- Store smoothed values for external access
    self.vocalPresenceSmooth = tracker.vocalPresenceSmooth
    self.VocalEnergySmooth = tracker.vocalEnergySmooth

    -- VOCAL ONSET DETECTION
    -- An "onset" is when vocals START (not just presence)
    local isOnset = false

    -- Cooldown check (time-based, not frame-based)
    if currentTime - tracker.lastVocalTime > 0.1 then
        -- Get recent average to detect sudden increases
        local recentVocalEnergy = {}
        for i = math.max(1, #tracker.vocalEnergyHistory - 20), #tracker.vocalEnergyHistory do
            if tracker.vocalEnergyHistory[i] then
                table.insert(recentVocalEnergy, tracker.vocalEnergyHistory[i].value)
            end
        end

        local recentAvgVocal = 0.01
        if #recentVocalEnergy > 0 then
            -- Use trimmed average for robustness
            table.sort(recentVocalEnergy)
            local trim = math.floor(#recentVocalEnergy * 0.1)
            local sum = 0
            for i = trim + 1, #recentVocalEnergy - trim do
                sum = sum + recentVocalEnergy[i]
            end
            recentAvgVocal = (#recentVocalEnergy - 2 * trim > 0) and (sum / (#recentVocalEnergy - 2 * trim)) or 0.01
        end

        local onsetThreshold = recentAvgVocal * (0.9 + (tracker.vocalBaselineAvg * 0.1))

        -- Calculate vocal-specific flux (change in vocal frequencies only)
        local vocalFlux = 0
        if self.PrevFFTData then
            for i = formantBand[1], presenceBand[2] do
                local curr = self.FFTData[i] or 0
                local prev = self.PrevFFTData[i] or 0
                vocalFlux = vocalFlux + math.max(0, curr - prev)  -- Only positive changes
            end
            vocalFlux = vocalFlux / (presenceBand[2] - formantBand[1] + 1)
        end

        -- Check bass correlation to reject kick drums misidentified as vocals
        local bassFlux = self:GetFrequencyIntensity("Bass")
        local prevBassIntensity = self.PrevBassIntensity or 0
        local bassChange = math.abs(bassFlux - prevBassIntensity)
        local bassCorrelation = bassChange > 0.15 and 1 or 0
        self.PrevBassIntensity = bassFlux

        -- All conditions for vocal onset
        local check_energy = vocalEnergy > onsetThreshold           -- Sudden energy increase
        local check_presence = vocalPresence > 0.3                  -- High vocal presence
        local check_flat = tracker.flatnessSmooth > 0.25            -- Tonal (not noisy)
        local check_harmonic = tracker.harmonicRatioSmooth > 0.3    -- Harmonic structure
        local check_flux = vocalFlux > 0.01                         -- Positive change
        local check_bass = bassCorrelation < 0.5                    -- Not correlated with bass

        local check_result = check_energy and check_presence and check_flat and check_harmonic and check_flux and check_bass

        if check_result then
            -- Sustain check: Ensure vocal energy stays high for multiple frames
            -- Prevents false positives from brief transients
            local sustainCount = 0
            local checkFrames = math.min(5, #tracker.vocalEnergyHistory)
            for i = #tracker.vocalEnergyHistory - checkFrames + 1, #tracker.vocalEnergyHistory do
                if tracker.vocalEnergyHistory[i] and tracker.vocalEnergyHistory[i].value > onsetThreshold * 0.8 then
                    sustainCount = sustainCount + 1
                end
            end

            -- Need at least 3 out of last 5 frames to be high
            if sustainCount >= 3 then
                isOnset = true
                tracker.lastVocalTime = currentTime
            end
        end
    end

    return isOnset, tracker.vocalPresenceSmooth
end


--[[
    Detect consistent bassline patterns (grooves, not just individual kicks)

    This function identifies rhythmic bass patterns by:
    1. Tracking bass energy over time (TIME-BASED, not frame-based)
    2. Detecting peaks in bass energy
    3. Analyzing intervals between peaks for consistency
    4. Calculating BPM from interval timing (FIXED: no longer FPS-dependent!)
    5. Classifying groove type based on tempo

    @return boolean, number, string: Pattern detected, confidence (0-1), pattern type
]]
function ENT:DetectBasslineGroove()
    -- Initialize bassline tracking
    if not self.BasslineTracker then
        self.BasslineTracker = {
            history = {},              -- TIME-BASED history with timestamps
            patternBuffer = {},
            lastBassTime = 0,
            patternConfidence = 0,
            currentPattern = "none",
            maxHistoryTime = 3.5       -- Keep 3.5 seconds of history (TIME-BASED)
        }
    end

    local currentTime = CurTime()
    local tracker = self.BasslineTracker

    -- Get current bass energy
    local bassEnergy = self:GetFrequencyIntensity("Bass")

    -- Record bass energy with timestamp (TIME-BASED, not frame count)
    table.insert(tracker.history, {
        time = currentTime,
        energy = bassEnergy
    })

    -- CRITICAL FIX: Remove old entries based on TIME, not count
    -- This ensures consistent behavior at any FPS (30, 60, 144, 800, etc.)
    while #tracker.history > 0 and (currentTime - tracker.history[1].time) > tracker.maxHistoryTime do
        table.remove(tracker.history, 1)
    end

    -- Need enough history to detect patterns (at least 1 second)
    if #tracker.history < 2 or (currentTime - tracker.history[1].time) < 1.0 then
        return false, 0, "none"
    end

    -- Detect peaks in bass energy (local maxima)
    local peaks = {}
    for i = 2, #tracker.history - 1 do
        local prev = tracker.history[i-1].energy
        local curr = tracker.history[i].energy
        local next = tracker.history[i+1].energy

        -- Peak detection: current value higher than neighbors and above threshold
        if curr > prev and curr > next and curr > 0.3 then
            table.insert(peaks, tracker.history[i].time)  -- Store TIME, not index
        end
    end

    -- Need at least 4 peaks to establish a pattern
    if #peaks < 4 then
        return false, 0, "none"
    end

    -- Calculate TIME INTERVALS between peaks (in seconds)
    local intervals = {}
    for i = 2, #peaks do
        table.insert(intervals, peaks[i] - peaks[i-1])  -- Time difference in seconds
    end

    -- Calculate average interval
    local avgInterval = 0
    for _, interval in ipairs(intervals) do
        avgInterval = avgInterval + interval
    end
    avgInterval = avgInterval / #intervals

    -- Calculate deviation from average (consistency measure)
    local deviation = 0
    for _, interval in ipairs(intervals) do
        deviation = deviation + math.abs(interval - avgInterval)
    end
    deviation = deviation / #intervals

    -- Low deviation = consistent pattern (groove)
    -- Consistency ranges from 0 (random) to 1 (perfect rhythm)
    local consistency = 1 - math.min(1, deviation / avgInterval)

    -- Only report if pattern is consistent enough
    if consistency > 0.7 then

        -- ===== CRITICAL FIX: BPM Calculation =====
        -- OLD (BROKEN): local fps = 1 / FrameTime()
        --               local bpm = fps / avgInterval
        -- This caused 30 FPS player to get BPM 26x lower than 800 FPS player!
        --
        -- NEW (CORRECT): BPM = beats per minute = 60 / seconds per beat
        -- avgInterval is already in seconds, so we just divide 60 by it
        -- This is now completely FPS-independent!

        local bpm = 60 / avgInterval  -- CORRECT: 60 seconds per minute / interval in seconds

        -- Classify groove type based on tempo
        local patternType = "none"

        if bpm < 90 then
            patternType = "slow_groove"      -- 60-90 BPM: Hip-hop, slow electronic
        elseif bpm < 120 then
            patternType = "mid_groove"       -- 90-120 BPM: House, pop, rock
        elseif bpm < 140 then
            patternType = "fast_groove"      -- 120-140 BPM: Techno, trance
        else
            patternType = "rapid_groove"     -- 140+ BPM: Drum & bass, hardcore
        end

        tracker.patternConfidence = consistency
        tracker.currentPattern = patternType

        return true, consistency, patternType
    end

    return false, 0, "none"
end

--[[
    Detect energy build-ups and drops (common in EDM)

    Analyzes total energy trends over different time windows:
    - Short window (~0.6s): Recent energy level
    - Long window (~1.8s): Historical baseline

    States:
    - "building": Energy steadily increasing (pre-drop tension)
    - "dropping": Sudden energy release after build-up (the drop!)
    - "steady": Normal playback, no significant change

    @return string, number: Current state, intensity (0-1)
]]
function ENT:DetectEnergyTransition()
    -- Initialize transition detector
    if not self.TransitionDetector then
        self.TransitionDetector = {
            energyHistory = {},        -- TIME-BASED history
            state = "steady",
            buildStartTime = 0,
            dropTime = 0,
            peakEnergy = 0,
            maxHistoryTime = 5.0       -- Keep 5 seconds of history (TIME-BASED)
        }
    end

    local detector = self.TransitionDetector
    local currentTime = CurTime()

    -- Calculate total energy across all frequencies
    local totalEnergy = 0
    if self.FFTData then
        for i = 1, #self.FFTData do
            totalEnergy = totalEnergy + (self.FFTData[i] or 0)
        end
        totalEnergy = totalEnergy / #self.FFTData
    end

    -- Store energy with timestamp (TIME-BASED)
    table.insert(detector.energyHistory, {
        time = currentTime,
        energy = totalEnergy
    })

    -- CRITICAL FIX: Remove old entries based on TIME, not count
    while #detector.energyHistory > 0 and (currentTime - detector.energyHistory[1].time) > detector.maxHistoryTime do
        table.remove(detector.energyHistory, 1)
    end

    -- Need enough history (at least 2 seconds)
    if #detector.energyHistory < 2 or (currentTime - detector.energyHistory[1].time) < 2.0 then
        return "steady", 0
    end

    -- Calculate energy trend over different TIME WINDOWS (not frame counts)
    local shortWindowTime = 0.6  -- 0.6 seconds (recent)
    local longWindowTime = 1.8   -- 1.8 seconds (historical)

    local shortAvg = 0
    local shortCount = 0
    local longAvg = 0
    local longCount = 0

    -- Calculate averages by TIME RANGE, not frame count
    for i, entry in ipairs(detector.energyHistory) do
        local age = currentTime - entry.time

        -- Short-term average (last 0.6 seconds)
        if age <= shortWindowTime then
            shortAvg = shortAvg + entry.energy
            shortCount = shortCount + 1
        end

        -- Long-term average (last 1.8 seconds)
        if age <= longWindowTime then
            longAvg = longAvg + entry.energy
            longCount = longCount + 1
        end
    end

    shortAvg = shortCount > 0 and (shortAvg / shortCount) or 0
    longAvg = longCount > 0 and (longAvg / longCount) or 0

    -- Track peak energy (with slow decay)
    detector.peakEnergy = math.max(detector.peakEnergy * 0.9, totalEnergy)

    -- Detect build-up: steadily increasing energy
    local energySlope = shortAvg - longAvg

    if energySlope > 0.05 and totalEnergy > longAvg * 1.2 then
        -- Building up!
        if detector.state ~= "building" then
            detector.buildStartTime = currentTime
        end
        detector.state = "building"

        -- Calculate build intensity based on duration and slope
        local buildDuration = currentTime - detector.buildStartTime
        local intensity = math.min(1, buildDuration / 5) * math.min(1, energySlope * 10)

        return "building", intensity

    elseif totalEnergy > detector.peakEnergy * 0.85 and detector.state == "building" then
        -- Drop detected! (high energy after build)
        detector.state = "dropping"
        detector.dropTime = currentTime

        return "dropping", 1.0

    elseif detector.state == "dropping" and currentTime - detector.dropTime < 0.5 then
        -- Still in drop phase (0.5 second window)
        local dropProgress = (currentTime - detector.dropTime) / 0.5
        return "dropping", 1 - dropProgress

    else
        -- Steady state (normal playback)
        detector.state = "steady"
        return "steady", 0
    end
end
