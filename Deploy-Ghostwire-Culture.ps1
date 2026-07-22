#Requires -Version 5.1
<#
  Deploy-Ghostwire-Culture.ps1
  Three small jobs on the single GHOSTWIRE culture item:
    (1) Rename its label from "GHOSTWIRE Culture" -> "Ghostwire Culture"
    (2) Set its thumbnail to our Ossian Reach cross-section art
    (3) Move it into the "GHOSTWIRE Cultures" folder (out of the Backgrounds root)
  Then rebuild packs + robocopy to Foundry.

  PowerShell 5.1 safe: no ??, ?., ?[, ternary, or inline if() expressions as args.

  USAGE:
    .\Deploy-Ghostwire-Culture.ps1 -ArtDir "$HOME\Downloads\GHOSTWIRE_Art_Bundle" -DryRun
    .\Deploy-Ghostwire-Culture.ps1 -ArtDir "$HOME\Downloads\GHOSTWIRE_Art_Bundle"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ArtDir,
  [string]$RepoRoot     = "C:\Users\mfran\ghostwire-system",
  [string]$FoundryData  = "C:\Users\mfran\Dropbox\FoundryVTT\Data",
  [string]$CulturesFolderId = "cAbsAm5rVtfeybHl",   # GHOSTWIRE Cultures folder id
  [switch]$DryRun,
  [switch]$NoBuild,
  [switch]$NoDeploy
)

$ErrorActionPreference = "Stop"
function Head($m){ Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Say ($m){ Write-Host "[GW] $m" -ForegroundColor Gray }
function Note($m){ Write-Host "[..] $m" -ForegroundColor DarkGray }
function Good($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Flag($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }
function Die ($m){ Write-Host "[XX] $m" -ForegroundColor Red; exit 1 }

# UTF-8 no-BOM writer, LF endings, to match the rest of the pack source.
function Write-JsonNoBom($path,$obj){
  $json = ($obj | ConvertTo-Json -Depth 100)
  $json = $json -replace "`r`n","`n"
  $enc  = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path,$json,$enc)
}

$originsSrc = Join-Path $RepoRoot "src\packs\origins"
if(-not (Test-Path $originsSrc)){ Die "origins pack source not found: $originsSrc" }

# ---- Art staging -------------------------------------------------------------
$thumbName = "ghostwire_culture_thumb.png"
$srcThumb  = Join-Path $ArtDir $thumbName
if(-not (Test-Path $srcThumb)){ Die "Missing culture thumb art: $srcThumb" }

$assetRel = "assets/ghostwire/cultures"                    # under systems/draw-steel/
$assetDir = Join-Path $RepoRoot $assetRel.Replace('/','\')
$imgRel   = "systems/draw-steel/$assetRel/$thumbName"      # forward slashes for Foundry

# ====================================================================================
Head "FIND the GHOSTWIRE culture item"
# ====================================================================================
# The item is a 'culture'-type item whose name is (case-insensitively) "GHOSTWIRE Culture"
# or "Ghostwire Culture". We match on type + name, NOT on a hard-coded id.
$target = $null
foreach($jf in (Get-ChildItem $originsSrc -Recurse -Filter *.json)){
  $raw = Get-Content $jf.FullName -Raw
  if($raw -notmatch '"_key"\s*:\s*"!items!'){ continue }
  try { $d = $raw | ConvertFrom-Json } catch { continue }
  if($d.type -ne "culture"){ continue }
  if($d.name -match '^\s*ghostwire\s+culture\s*$'){       # case-insensitive by default
    $target = [pscustomobject]@{ File=$jf.FullName; Data=$d }
    break
  }
}
if($null -eq $target){ Die "Could not find a 'culture' item named 'GHOSTWIRE Culture' under $originsSrc" }
Say ("Found: '{0}'  (id={1})" -f $target.Data.name, $target.Data._id)
Say ("File : {0}" -f $target.File)
Say ("Current img   : {0}" -f $target.Data.img)
$curFolder = $target.Data.folder
if([string]::IsNullOrWhiteSpace($curFolder)){ $curFolder = "(root / none)" }
Say ("Current folder: {0}" -f $curFolder)

# ====================================================================================
Head "JOB 1 - Rename label -> 'Ghostwire Culture'"
# ====================================================================================
$newName = "Ghostwire Culture"
if($target.Data.name -ceq $newName){ Note "Name already exactly 'Ghostwire Culture' - skip." }
else { if($DryRun){ Note ("WOULD RENAME '{0}' -> '{1}'" -f $target.Data.name,$newName) } }

# ====================================================================================
Head "JOB 2 - Thumbnail -> Ossian Reach cross-section"
# ====================================================================================
if($DryRun){
  Note "WOULD ENSURE asset dir: $assetDir"
  Note ("WOULD COPY {0} -> {1}" -f $thumbName,(Join-Path $assetDir $thumbName))
  Note ("WOULD SET img '{0}' -> '{1}'" -f $target.Data.img,$imgRel)
} else {
  New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
  Copy-Item $srcThumb (Join-Path $assetDir $thumbName) -Force
  Good "Staged culture thumbnail."
}

# ====================================================================================
Head "JOB 3 - Move into 'GHOSTWIRE Cultures' folder"
# ====================================================================================
# Verify the target folder doc exists so we don't orphan the item.
$folderOk = $false
foreach($ff in (Get-ChildItem $originsSrc -Recurse -Filter "Folder_*.json")){
  $fraw = Get-Content $ff.FullName -Raw
  if($fraw -match ('"_id"\s*:\s*"{0}"' -f [regex]::Escape($CulturesFolderId))){ $folderOk = $true; break }
}
if(-not $folderOk){ Flag ("GHOSTWIRE Cultures folder id '{0}' not found - will still set it, but verify in Foundry." -f $CulturesFolderId) }
if($target.Data.folder -eq $CulturesFolderId){ Note "Already in GHOSTWIRE Cultures folder - skip." }
else { if($DryRun){ Note ("WOULD MOVE folder '{0}' -> '{1}' (GHOSTWIRE Cultures)" -f $curFolder,$CulturesFolderId) } }

# ---- Apply all three edits in one write (real run only) ----------------------
if(-not $DryRun){
  $d = $target.Data
  $d.name = $newName
  $d.img  = $imgRel
  if($d.PSObject.Properties.Name -contains "folder"){ $d.folder = $CulturesFolderId }
  else { $d | Add-Member -NotePropertyName folder -NotePropertyValue $CulturesFolderId }
  Write-JsonNoBom $target.File $d
  Good "Renamed -> 'Ghostwire Culture', set thumbnail, moved into GHOSTWIRE Cultures."
}

# ====================================================================================
Head "BUILD + DEPLOY"
# ====================================================================================
if($DryRun){ Flag "DRY RUN complete - no build, no deploy, nothing written."; exit 0 }

if($NoBuild){ Flag "Skipping build (-NoBuild)." }
else {
  Say "Building packs (npm run build:packs)..."
  Push-Location $RepoRoot
  npm run build:packs
  $code = $LASTEXITCODE
  Pop-Location
  if($code -ne 0){ Die "build:packs failed (exit $code)." }
  Good "Packs built."
}

if($NoDeploy){ Flag "Skipping deploy (-NoDeploy)." }
else {
  $sysDest = Join-Path $FoundryData "systems\draw-steel"
  Say "Deploying to $sysDest ..."
  robocopy $RepoRoot $sysDest /E /XD node_modules .git .github .vscode tools | Out-Null
  if($LASTEXITCODE -ge 8){ Die "robocopy failed (exit $LASTEXITCODE)." }
  Good ("Deployed (robocopy exit {0})." -f $LASTEXITCODE)
}

Write-Host "`n===== ALL DONE =====" -ForegroundColor Cyan
Flag "Relaunch the world (return to Setup, then Launch) to see the renamed 'Ghostwire Culture' with its new thumbnail inside GHOSTWIRE Cultures."
Flag "Foundry Data is under Dropbox - give it a moment to sync before relaunching."
Note "If the old thumbnail lingers, hard-refresh with Ctrl+F5."
