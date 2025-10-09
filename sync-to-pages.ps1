# Fail fast on errors
$ErrorActionPreference = "Stop"

# ===== CONFIG =====
$Source = "G:\My Drive\Game Design\25.04 - MYTHOS\Prototype"
$Repo   = "G:\My Drive\Game Design\MythosTCG"
$Target = Join-Path $Repo "cards"
$Log    = Join-Path $Repo "sync-log.txt"
$Robo   = Join-Path $Repo "robocopy.txt"

# ===== LOGGING =====
"=== Sync started: $(Get-Date) ===" | Out-File $Log -Encoding UTF8
function Log($m) { Write-Host $m; $m | Out-File $Log -Append -Encoding UTF8 }

# ===== CHECKS =====
if (-not (Test-Path $Source)) { Log "ERROR: Source not found: $Source"; exit 1 }
if (-not (Test-Path $Repo))   { Log "ERROR: Repo not found:   $Repo";   exit 1 }
if (-not (Test-Path (Join-Path $Repo ".git"))) { Log "ERROR: Not a git repo: $Repo"; exit 1 }

New-Item -ItemType Directory -Force -Path $Target | Out-Null

# Count source PNGs (helps spot “nothing to do”)
$srcCount = (Get-ChildItem -Path $Source -Recurse -Filter *.png | Measure-Object).Count
Log "Source PNGs found: $srcCount (at '$Source')"
Log "Target: $Target"

# ===== COPY (mirror PNGs) =====
Log "Running robocopy (mirror *.png)…"
# IMPORTANT: quote paths with spaces
& robocopy "$Source" "$Target" *.png /MIR /FFT /NFL /NDL /NJH /NJS /NP | Out-File $Robo -Encoding UTF8
$rc = $LASTEXITCODE
Log "robocopy exit code: $rc (0/1 are OK). See $Robo"

# ===== BUILD index.json =====
$pngs = Get-ChildItem -Path $Target -Recurse -Filter *.png | ForEach-Object {
  $rel = $_.FullName.Substring($Target.Length + 1).TrimStart('\').Replace('\','/')
  $rel
} | Sort-Object

$IndexPath = Join-Path $Target "index.json"
$pngs | ConvertTo-Json -Depth 1 | Out-File -FilePath $IndexPath -Encoding UTF8 -NoNewline
Log "index.json written with $($pngs.Count) entries at $IndexPath"

# ===== GIT ADD/COMMIT/PUSH =====
Set-Location $Repo
$inside = (& git rev-parse --is-inside-work-tree) 2>$null
if ($inside -ne "true") { Log "ERROR: Not inside a git work tree at $Repo"; exit 1 }

$before = (& git status --porcelain)
if ($before) { Log "Changes before add:`n$before" } else { Log "No changes before add." }

& git add -A
$staged = (& git diff --cached --name-only)
if ([string]::IsNullOrWhiteSpace($staged)) {
  Log "ℹ️ No staged changes; nothing to commit."
} else {
  $msg = "Update cards & index $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  Log "Committing: $msg"
  & git commit -m $msg
  Log "Pushing…"
  & git push
  Log "✅ Push complete."
}

Log "=== Sync finished: $(Get-Date) ==="
Write-Host "Done. See $Log and $Robo for details."
