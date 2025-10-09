<#
  Watch-GDrive-To-GitHub.ps1
  Watches a Google Drive–synced subfolder for PNG changes (new/updated/deleted)
  and auto-commits & pushes ONLY that subfolder to origin/main.

  Repo:  G:\My Drive\Game Design\25.04 - MYTHOS\MythosTCG
  Run :  powershell -ExecutionPolicy Bypass -File ".\Watch-GDrive-To-GitHub.ps1"
#>

# =================== SETTINGS ===================
$RepoRoot           = "G:\My Drive\Game Design\25.04 - MYTHOS\MythosTCG"
$WatchSubPath       = "cards"                 # change to your images folder; "." to watch whole repo
$Branch             = "main"
$Remote             = "origin"
$IncludePatterns    = @("*.png")              # add "*.jpg","*.jpeg" if you want
$DebounceMs         = 1500
$MaxLockWaitSeconds = 20
# =================================================

function Write-Info([string]$m) { Write-Host "[INFO] $m" }
function Write-Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err ([string]$m) { Write-Host "[ERR ] $m" -ForegroundColor Red }

function Test-IsTempOrIgnoredFile([string]$path) {
  $name = [IO.Path]::GetFileName($path)
  $ext  = [IO.Path]::GetExtension($path)
  if (-not $ext) { $ext = "" }
  $ext  = $ext.ToLower()

  # Ignore Windows/Drive/temp artifacts
  if ($name -like "~$*") { return $true }
  if ($name -in @("desktop.ini","thumbs.db")) { return $true }
  if ($ext -in @(".tmp",".temp",".crdownload",".part",".partial",".gdtmp",".lnk")) { return $true }

  # Only include files matching IncludePatterns
  $matched = $false
  foreach ($pat in $IncludePatterns) {
    if ($name -like $pat) { $matched = $true; break }
  }
  if (-not $matched) { return $true }

  return $false
}

function Wait-UntilFilesStable([string[]]$paths, [int]$timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)

  foreach ($p in $paths) {
    if (Test-IsTempOrIgnoredFile $p) { continue }

    while ($true) {
      if (-not (Test-Path $p)) { break }  # deleted = stable for our purposes

      try {
        $fs = [IO.File]::Open($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $fs.Close()
        break
      } catch {
        Start-Sleep -Milliseconds 250
        if ((Get-Date) -gt $deadline) {
          Write-Warn "Timeout waiting for unlock: $p"
          break
        }
      }
    }
  }
}

function Get-RepoHasChanges([string]$repo) {
  $status = git -C $repo status --porcelain
  return -not [string]::IsNullOrWhiteSpace($status)
}

# ---- Validate repo & paths ----
try { $RepoRoot = (Resolve-Path $RepoRoot).Path } catch { Write-Err "Repo not found: $RepoRoot"; exit 1 }
if (-not (Test-Path (Join-Path $RepoRoot ".git"))) { Write-Err "Not a git repo: $RepoRoot"; exit 1 }

try { git -C $RepoRoot rev-parse --is-inside-work-tree | Out-Null } catch {
  Write-Err "Git not available or repo invalid."; exit 1
}

# Ensure branch checked out
try {
  $currentBranch = (git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()
  if ($currentBranch -ne $Branch) {
    Write-Info "Checking out '$Branch'…"
    git -C $RepoRoot checkout $Branch 2>$null | Out-Null
  }
} catch { Write-Err "Failed to checkout '$Branch'."; exit 1 }

# Compute watch path
$watchPathString = Join-Path $RepoRoot $WatchSubPath
try { $WatchPath = (Resolve-Path $watchPathString -ErrorAction Stop).Path } catch {
  Write-Err "Watch path does not exist: $watchPathString"; exit 1
}

# ---- Watchers & event queue ----
$script:queue     = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:watchers  = @()
$script:subs      = @()

foreach ($pattern in $IncludePatterns) {
  $fsw = New-Object System.IO.FileSystemWatcher
  $fsw.Path = $WatchPath
  $fsw.Filter = $pattern
  $fsw.IncludeSubdirectories = $true
  $fsw.EnableRaisingEvents = $true
  $fsw.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size, CreationTime'

  foreach ($ev in @("Changed","Created","Deleted","Renamed")) {
    $sub = Register-ObjectEvent -InputObject $fsw -EventName $ev -Action {
      param($sender,$e)
      $script:queue.Enqueue($e.FullPath)
    }
    $script:subs += $sub
  }

  $script:watchers += $fsw
}

Write-Info "Watching: $WatchPath (patterns: $($IncludePatterns -join ', '))"
Write-Info "Repo: $RepoRoot | Branch: $Branch | Remote: $Remote"
Write-Info "Press Ctrl+C to stop."

# ---- Debounce timer ----
$timer = New-Object System.Timers.Timer
$timer.Interval = $DebounceMs
$timer.AutoReset = $false
$timer.add_Elapsed({
  # Drain & dedupe
  $paths = New-Object System.Collections.Generic.List[string]
  while ($true) {
    $ref = ""
    if (-not $script:queue.TryDequeue([ref]$ref)) { break }
    if ([string]::IsNullOrWhiteSpace($ref)) { continue }
    if (Test-IsTempOrIgnoredFile $ref) { continue }
    if (-not $paths.Contains($ref)) { $paths.Add($ref) }
  }

  if ($paths.Count -eq 0) { return }

  Write-Info "Changes detected ($($paths.Count)) → waiting for files to stabilize…"
  Wait-UntilFilesStable $paths $MaxLockWaitSeconds

  # Stage only within the watched subpath (captures adds/edits/deletes)
  git -C $RepoRoot add --all -- ":/$WatchSubPath"

  if (Get-RepoHasChanges $RepoRoot) {
    $msg = "Auto: sync images ($(Get-Date -Format s))"
    git -C $RepoRoot commit -m $msg | Out-Null
    try { git -C $RepoRoot pull --rebase $Remote $Branch 2>$null | Out-Null } catch { Write-Warn "pull --rebase failed; continuing." }
    git -C $RepoRoot push $Remote $Branch
    Write-Info "Pushed: $msg"
  } else {
    Write-Info "No net changes to commit."
  }
})

# ---- Event loop ----
try {
  while ($true) {
    Start-Sleep -Milliseconds 250
    if (-not $script:queue.IsEmpty) {
      $timer.Stop()
      $timer.Start()
    }
  }
}
finally {
  $timer.Dispose()
  foreach ($w in $script:watchers) { $w.Dispose() }
  foreach ($s in $script:subs) { Unregister-Event -SourceIdentifier $s.Name -ErrorAction SilentlyContinue }
}
