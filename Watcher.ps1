# Poll-Debounced.ps1
$watch    = "G:\My Drive\Game Design\25.04 - MYTHOS\MythosTCG\cards"  # folder to watch
$bat      = "G:\My Drive\Game Design\25.04 - MYTHOS\MythosTCG\PushAll.bat"
$include  = @("*.png","*.jpg","*.jpeg")  # file types to track
$interval = 1    # seconds between checks
$quiet    = 4    # seconds of no changes before running once

function Snap {
  Get-ChildItem $watch -Recurse -File -Include $include 2>$null |
    Select-Object FullName, Length, LastWriteTimeUtc |
    ConvertTo-Json -Compress
}

if (!(Test-Path $watch)) { Write-Host "[ERR] Watch path not found: $watch"; exit 1 }
if (!(Test-Path $bat))   { Write-Host "[ERR] BAT not found: $bat"; exit 1 }

$prev = Snap
$quietLeft = 0
Write-Host "Polling $watch (types: $($include -join ', ')). Ctrl+C to stop."

while ($true) {
  Start-Sleep -Seconds $interval
  $now = Snap
  if ($now -ne $prev) {
    # change detected → reset debounce window
    $prev = $now
    $quietLeft = $quiet
    continue
  }

  if ($quietLeft -gt 0) {
    $quietLeft -= $interval
    if ($quietLeft -le 0) {
      Write-Host "[TRIGGER] Running PushAll.bat..."
      Start-Process -FilePath "cmd.exe" -ArgumentList '/c', "`"$bat`"" -Wait
      Write-Host "[DONE] PushAll.bat finished."
    }
  }
}
