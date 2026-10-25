[CmdletBinding()]
param()

# Test fixture only: fixed Windows TTS, never a microphone or user recording.
$ErrorActionPreference = 'Stop'
$workspace = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$buildPrefix = [System.IO.Path]::GetFullPath((Join-Path $workspace 'app/build')).TrimEnd('\') + '\'
$probeRoot = [System.IO.Path]::GetFullPath((Join-Path $workspace 'app/build/m58-probe'))
if (-not $probeRoot.StartsWith($buildPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Synthetic speech target leaves the application build directory.'
}
foreach ($target in @((Join-Path $workspace 'app/build'), $probeRoot, (Join-Path $probeRoot 'synthetic.wav'))) {
    if ((Test-Path -LiteralPath $target) -and
        ((Get-Item -LiteralPath $target -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw 'Synthetic speech target contains a reparse point.'
    }
}
New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
Add-Type -AssemblyName System.Speech
$synthesizer = [System.Speech.Synthesis.SpeechSynthesizer]::new()
try {
    $voice = $synthesizer.GetInstalledVoices() | Where-Object {
        $_.Enabled -and $_.VoiceInfo.Culture.Name -eq 'zh-CN'
    } | Select-Object -First 1
    if ($null -eq $voice) { throw 'No local zh-CN Windows TTS voice is available.' }
    $synthesizer.SelectVoice($voice.VoiceInfo.Name)
    $format = [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new(
        16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
        [System.Speech.AudioFormat.AudioChannel]::Mono)
    $synthesizer.SetOutputToWaveFile((Join-Path $probeRoot 'synthetic.wav'), $format)
    # ASCII source also works under Windows PowerShell 5's default file encoding.
    $phrase = -join ([char[]]@(0x660e,0x5929,0x4e0b,0x5348,0x4e09,0x70b9,0xff0c,0x5728,0x56fe,0x4e66,0x9986,0x590d,0x4e60,0x4e00,0x4e2a,0x5c0f,0x65f6,0x3002))
    $synthesizer.Speak($phrase)
    $synthesizer.SetOutputToNull()
} finally {
    $synthesizer.Dispose()
}
Write-Output ('Synthetic speech WAV ready: ' + (Join-Path $probeRoot 'synthetic.wav'))
