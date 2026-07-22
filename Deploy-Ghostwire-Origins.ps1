<#
====================================================================================
 GHOSTWIRE - Deploy Origins (Cultures + Careers) into Foundry
 ------------------------------------------------------------------------------------
 Authors the ratified GHOSTWIRE character-creation background layer as Draw Steel
 compendium items so they appear as selectable picks in character generation:

   * ONE "GHOSTWIRE Culture" item  (type: culture)
        - Aspect 1 : Habitat   (chooseN:1 skill)
        - Aspect 2 : Order      (chooseN:1 skill)
        - Aspect 3 : Formation  (chooseN:1 skill)
        - Language  (chooseN:1)
   * FOURTEEN Career items (type: career)
        - 2-of-3 skill choice, one Perk grant, starting wealth/renown,
          d6 Inciting Incident described in the item text.

 Both land in the stock "origins" pack, under our OWN folders (fresh ids) so they
 never collide with the built-in Draw Steel cultures/careers.

 Mirrors the Operator deploy pattern: read live config -> write BOM-less source JSON
 -> npm run build:packs -> robocopy into the Foundry systems folder.

 SAFE TO RE-RUN: it removes only OUR folders + item files (matched by _dsid prefix
 "gw-") before re-authoring; it never touches stock Draw Steel content.

 USAGE (from an elevated-or-devmode PowerShell):
     cd C:\Users\mfran\ghostwire-system
     .\Deploy-Ghostwire-Origins.ps1
   Optional switches:
     -NoBuild      author JSON only (skip npm run build:packs)
     -NoDeploy     build but skip the robocopy into Foundry
     -WhatIfKeys   print the resolved skill/group key mapping and EXIT (dry run)
     -WriteConfig  ALSO rewrite the languages block in src\module\config.mjs to the
                   13 Reach languages (backs up config.mjs.bak first). Omit to leave
                   config.mjs untouched and only print the block for manual paste.
====================================================================================
#>

[CmdletBinding()]
param(
  [string]$RepoRoot   = "C:\Users\mfran\ghostwire-system",
  [string]$FoundryData= "C:\Users\mfran\Dropbox\FoundryVTT",
  [string]$SystemName = "draw-steel",   # folder name in Data\systems (still 'draw-steel' per build log)
  [switch]$NoBuild,
  [switch]$NoDeploy,
  [switch]$WhatIfKeys,
  [switch]$WriteConfig
)

$ErrorActionPreference = "Stop"
function Info($m){ Write-Host "[GW] $m" -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }
function Die ($m){ Write-Host "[XX] $m" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------------ helpers
# 16-char Foundry-style id (A-Za-z0-9)
$script:__idchars = (([char[]](48..57)) + ([char[]](65..90)) + ([char[]](97..122)))
function New-Id16 {
  -join (1..16 | ForEach-Object { $script:__idchars | Get-Random })
}
# Write UTF-8 with NO BOM (Foundry pack compiler chokes on BOMs)
function Write-JsonNoBom([string]$Path,[object]$Obj){
  $json = $Obj | ConvertTo-Json -Depth 40
  # ConvertTo-Json escapes '/', unescape for readability of UUIDs/keys
  $json = $json -replace '\\/','/'
  $enc  = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$json,$enc)
}
function New-SkillAdv($name,[string[]]$groups,[string[]]$choices,[object]$chooseN){
  # chooseN = 1 for a choice, $null for a fixed grant
  [ordered]@{
    type   = "skill"
    name   = $name
    img    = $null
    _id    = (New-Id16)
    chooseN= $chooseN
    skills = [ordered]@{ groups = @($groups); choices = @($choices) }
    description  = ""
    requirements = [ordered]@{ level = $null }
    sort   = 0
    repick = @{}
  }
}
function New-LangAdv($name,[int]$chooseN,[string[]]$langs){
  [ordered]@{
    type   = "language"
    _id    = (New-Id16)
    name   = $name
    img    = $null
    chooseN= $chooseN
    languages = @($langs)
    description  = ""
    requirements = [ordered]@{ level = $null }
    sort   = 0
    repick = @{}
  }
}
function New-PerkGrant($name,[string]$desc,[string[]]$perkFamilies,[string[]]$poolUuids){
  # DS schema: pool = ArrayField(SchemaField({ uuid })). Each entry MUST be an object { uuid = "..." },
  # NOT a bare string. Wrap every UUID accordingly or createLeaves() destructures undefined and the
  # picker renders empty.
  $poolObjs = @()
  foreach($u in @($poolUuids)){ $poolObjs += ,([ordered]@{ uuid = $u }) }
  [ordered]@{
    type   = "itemGrant"
    _id    = (New-Id16)
    name   = $name
    img    = "icons/magic/symbols/fleur-de-lis-yellow.webp"
    chooseN= 1
    pool   = @($poolObjs)
    description = $desc
    additional  = [ordered]@{ type = "perk"; perkType = @($perkFamilies) }
    requirements= [ordered]@{ level = $null }
    sort   = 0
    repick = @{}
  }
}
function New-Stats {
  [ordered]@{
    compendiumSource=$null; duplicateSource=$null; exportSource=$null
    coreVersion="14.361"; systemId="draw-steel"; systemVersion="1.1.0"
    createdTime=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); modifiedTime=$null; lastModifiedBy=$null
  }
}
function New-FolderDoc($id,$name,$parentId,$sort){
  # Foundry pack folder doc
  [ordered]@{
    name=$name; sorting="a"; folder=$parentId; type="Item"; _id=$id
    description=""; sort=$sort; color=$null; flags=@{}
    _stats=(New-Stats); _key="!folders!$id"
  }
}

# ------------------------------------------------------------------ 0. sanity
if(-not (Test-Path $RepoRoot)){ Die "Repo not found: $RepoRoot" }
Set-Location $RepoRoot
$originsSrc = Join-Path $RepoRoot "src\packs\origins"
if(-not (Test-Path $originsSrc)){ Die "origins pack source not found: $originsSrc (expected src\packs\origins)" }
Info "Repo: $RepoRoot"
Info "origins source: $originsSrc"

# ------------------------------------------------------------------ 1. read live skill/group keys from config
# We parse ds.CONFIG.skills out of the built system's config. The skills config is
# defined in src\module\config.mjs (per build log). We extract:
#   groups:  key -> label
#   list:    skillKey -> { label, group }
Info "Reading GHOSTWIRE skill + group keys from live config..."
$configCandidates = @(
  (Join-Path $RepoRoot "src\module\config.mjs"),
  (Join-Path $RepoRoot "src\module\config\skills.mjs"),
  (Join-Path $RepoRoot "src\module\config\_module.mjs")
)
$configText = ""
foreach($c in $configCandidates){ if(Test-Path $c){ $configText += "`n" + (Get-Content $c -Raw) } }
if([string]::IsNullOrWhiteSpace($configText)){ Die "Could not read any config source under src\module. Looked for: $($configCandidates -join ', ')" }

# --- Brace-matched extraction of a named object literal.
# Handles BOTH shapes GHOSTWIRE config uses:
#   const skillList = { ... }        (standalone const)
#   export const skills = { list: skillList, groups: skillGroups }  (assembled)
# We anchor on the object NAME (skillList / skillGroups) rather than a bare
# `list:` / `groups:` key, so we read the real definitions.
function Get-ObjectLiteral([string]$text,[string]$anchor){
  # $anchor is a regex that ends right before the opening brace, e.g. 'skillList\s*=\s*'
  $pattern = [regex]"(?s)$anchor\{"
  $m = $pattern.Match($text)
  if(-not $m.Success){ return $null }
  $start = $m.Index + $m.Length          # just after the opening {
  $depth = 1; $i = $start
  while($i -lt $text.Length -and $depth -gt 0){
    $ch = $text[$i]
    if($ch -eq '{'){ $depth++ } elseif($ch -eq '}'){ $depth-- }
    $i++
  }
  return $text.Substring($start, ($i-1)-$start)
}

# Skill list entries look like:
#   hacking: { label: "DRAW_STEEL.SKILL.List.Hacking", group: "technical" },
# We derive the group set FROM the skills themselves (no separate groups block needed).
function Parse-SkillList([string]$text){
  $list = @{}
  # Prefer the standalone `const skillList = { }`; fall back to a `list:` key.
  $inner = Get-ObjectLiteral $text 'skillList\s*=\s*'
  if(-not $inner){ $inner = Get-ObjectLiteral $text '\blist\s*[:=]\s*' }
  if(-not $inner){ return $list }
  # match  key: { ... label: "lbl" ... group: "grp" ... }  (order-independent)
  $entryRe = [regex]'(?s)["'']?([A-Za-z0-9_]+)["'']?\s*:\s*\{([^{}]*)\}'
  foreach($em in $entryRe.Matches($inner)){
    $key=$em.Groups[1].Value; $body=$em.Groups[2].Value
    $grp = [regex]::Match($body,'group\s*:\s*["'']([A-Za-z0-9_]+)["'']').Groups[1].Value
    $lbl = [regex]::Match($body,'label\s*:\s*["'']([^"'']+)["'']').Groups[1].Value
    if($key -and $grp){ $list[$key] = [ordered]@{ label=$lbl; group=$grp } }
  }
  return $list
}

# Group keys are derived from the skills' group fields (authoritative), then
# optionally enriched by a standalone `const skillGroups = { }` if present.
function Parse-Groups([string]$text,$skillList){
  $g = @{}
  foreach($k in $skillList.Keys){ $grp=$skillList[$k].group; if($grp){ $g[$grp]=$true } }
  $inner = Get-ObjectLiteral $text 'skillGroups\s*=\s*'
  if($inner){
    $keyRe = [regex]'(?m)^\s*["'']?([A-Za-z0-9_]+)["'']?\s*:\s*\{'
    foreach($km in $keyRe.Matches($inner)){ $g[$km.Groups[1].Value]=$true }
  }
  return $g
}

$skillList = Parse-SkillList $configText
$groupKeys = Parse-Groups   $configText $skillList
Info ("Parsed {0} group keys, {1} skill keys from config." -f $groupKeys.Count, $skillList.Count)
if($skillList.Count -gt 0){ Info ("Group keys: {0}" -f (($groupKeys.Keys | Sort-Object) -join ', ')) }

if($skillList.Count -eq 0){
  Die "Could not parse ds.CONFIG.skills.list from config. Open src\module\config.mjs and paste the skills block to me; the deployer needs the real skill keys."
}

# ------------------------------------------------------------------ 1b. discover LIVE perkType values from the Perks pack
# Careers grant one perk filtered by perkType; if we reference a type that has no
# perk items, Foundry shows an EMPTY picker. Read the real types and validate hard.
$LIVE_PERKTYPES = New-Object System.Collections.Generic.HashSet[string]
# We ALSO harvest each perk's _id + name here so we can PRE-POPULATE each career's
# perk-grant pool with real Compendium UUIDs (fixes the empty picker). UUIDs use the
# COMPILED pack name (character-options) + the system package id (draw-steel):
#   Compendium.draw-steel.character-options.Item.<perkId>
$PERK_PACK_ID = "character-options"                     # compiled compendium name
$PERKS_BY_TYPE = @{}                                    # perkType -> List of [ordered]@{ id; name }
function Add-PerkToType([string]$ptype,[string]$perkId,[string]$pname){
  if(-not $ptype -or -not $perkId){ return }
  if(-not $PERKS_BY_TYPE.ContainsKey($ptype)){ $PERKS_BY_TYPE[$ptype] = New-Object System.Collections.Generic.List[object] }
  # de-dupe by id
  foreach($e in $PERKS_BY_TYPE[$ptype]){ if($e.id -eq $perkId){ return } }
  $PERKS_BY_TYPE[$ptype].Add([ordered]@{ id=$perkId; name=$pname }) | Out-Null
}
$perkGlobRoots = @(
  (Join-Path $RepoRoot "src\packs\character-options\Perks_tb9IiWSEZfQYFh2p"),
  (Join-Path $RepoRoot "src\packs\character-options"),
  (Join-Path $RepoRoot "src\packs")
)
foreach($proot in $perkGlobRoots){
  if(Test-Path $proot){
    Get-ChildItem $proot -Recurse -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object {
      $raw = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
      if(-not $raw){ return }
      # only real perk items (type:perk) with a perkType
      $ptype = [regex]::Match($raw,'"perkType"\s*:\s*"([A-Za-z0-9_]+)"').Groups[1].Value
      if(-not $ptype){ return }
      [void]$LIVE_PERKTYPES.Add($ptype)
      $perkId = [regex]::Match($raw,'"_id"\s*:\s*"([A-Za-z0-9]+)"').Groups[1].Value
      $pname = [regex]::Match($raw,'"name"\s*:\s*"([^"]+)"').Groups[1].Value
      $ptype2 = ($ptype.Substring(0,1).ToLower() + $ptype.Substring(1))   # normalize leading case
      Add-PerkToType $ptype2 $perkId $pname
    }
    if($LIVE_PERKTYPES.Count -gt 0){ break }
  }
}
if($LIVE_PERKTYPES.Count -eq 0){
  Warn "Could not discover any perkType values from the Perks pack; perk-type validation will be skipped."
} else {
  Info ("Live perkTypes: {0}" -f (($LIVE_PERKTYPES | Sort-Object) -join ', '))
  foreach($pt in ($PERKS_BY_TYPE.Keys | Sort-Object)){
    Info ("  perk pool [{0}]: {1} perks -> {2}" -f $pt, $PERKS_BY_TYPE[$pt].Count, (($PERKS_BY_TYPE[$pt] | ForEach-Object { $_.name }) -join ', '))
  }
}

# ------------------------------------------------------------------ 2. map our sourcebook skill NAMES -> config keys
# Build a label/keys lookup that tolerates spacing/casing. We match by label first,
# then by a normalized camel/lower key guess.
function Norm([string]$s){ ($s -replace '[^A-Za-z0-9]','').ToLower() }
$byNormLabel = @{}
$byNormKey   = @{}
foreach($k in $skillList.Keys){
  $byNormKey[(Norm $k)] = $k
  $lbl = $skillList[$k].label
  if($lbl){
    $byNormLabel[(Norm $lbl)] = $k
    # labels are localization keys like 'DRAW_STEEL.SKILL.List.MatrixTheory' ->
    # index the LAST dotted segment ('MatrixTheory') too, which equals the key.
    $seg = ($lbl -split '\.')[-1]
    if($seg){ $byNormLabel[(Norm $seg)] = $k }
  }
}
$groupByNorm = @{}
foreach($g in $groupKeys.Keys){ $groupByNorm[(Norm $g)] = $g }

$MAP_MISSING = New-Object System.Collections.Generic.List[string]
function Resolve-Skill([string]$name){
  $n = Norm $name
  if($byNormLabel.ContainsKey($n)){ return $byNormLabel[$n] }
  if($byNormKey.ContainsKey($n))  { return $byNormKey[$n] }
  # a few known aliases sourcebook<->DS
  $alias = @{ 'readintent'='readIntent'; 'securitysystems'='securitySystems'; 'matrixtheory'='matrixTheory'; 'medicinelore'='medicineLore' }
  if($alias.ContainsKey($n) -and $skillList.ContainsKey($alias[$n])){ return $alias[$n] }
  $MAP_MISSING.Add($name) | Out-Null
  return $null
}
function Resolve-Group([string]$name){
  $n = Norm $name
  if($groupByNorm.ContainsKey($n)){ return $groupByNorm[$n] }
  $MAP_MISSING.Add("GROUP:$name") | Out-Null
  return $null
}

# --- CANON DATA (from master_rules_baseline.md, ratified) -----------------------
# Culture aspect menus: each option offers a small set of skills; player chooses 1.
# We union the per-aspect options into ONE chooseN:1 skill advancement per aspect,
# using skills.choices (explicit skill keys) so the exact ratified skills appear.
$habitatSkills   = @("Corporate","Read Intent","Electronics","Security Systems","Streetwise","Stealth","Perception","Survival","Navigation","Xenology")
$orderSkills     = @("Corporate","Negotiation","Security Systems","Streetwise","Contacts","Intimidation")
$formationSkills = @("Matrix Theory","Religion","Occult","Medicine","Repair","Engineering","Athletics","Stealth","Deception","Streetwise","Firearms","Brawl","Melee","Persuasion","Read Intent","Negotiation")
# NOTE: Formation "Academic" also allows ANY Knowledge skill -> we add the Knowledge
# GROUP to that aspect so the whole group is offered in addition to the explicit list.

# 14 Careers: 3-skill menu (choose 2), suggested perk family, wealth, renown.
# perk family strings must match GHOSTWIRE perk types; we map by the sourcebook family label.
$careers = @(
  @{ name="Corp Wageslave";      dsid="gw-corp-wageslave";      skills=@("Corporate","Electronics","Negotiation");        perks=@("lore");          wealth=2; renown=0; langs=@("highwire","grindtalk");       concept="Grid salaryman who knows the machine from the inside." },
  @{ name="Corp Defector";       dsid="gw-corp-defector";       skills=@("Corporate","Security Systems","Read Intent");    perks=@("intrigue");      wealth=3; renown=0; langs=@("highwire","static");          concept="Broke with a conglomerate and landed rough." },
  @{ name="Corp Security";       dsid="gw-corp-security";       skills=@("Firearms","Security Systems","Perception");      perks=@("intrigue");      wealth=2; renown=0; langs=@("highwire","static");          concept="Aureole/Blacklight contract sec, still-employed-adjacent." },
  @{ name="Street Kid";          dsid="gw-street-kid";          skills=@("Stealth","Streetwise","Perception");             perks=@("intrigue");      wealth=1; renown=0; langs=@("static","sinkcant");          concept="Came up on the Flats with nothing but nerve." },
  @{ name="Ganger";              dsid="gw-ganger";              skills=@("Brawl","Streetwise","Intimidation");             perks=@("exploration");   wealth=1; renown=0; langs=@("static","sinkcant");          concept="Ran with a Flats crew." },
  @{ name="Fixer's Apprentice";  dsid="gw-fixers-apprentice";   skills=@("Negotiation","Contacts","Streetwise");           perks=@("interpersonal"); wealth=2; renown=1; langs=@("static","highwire");          concept="Learned the trade under a Switchboard-type broker." },
  @{ name="Ex-Military / PMC";   dsid="gw-ex-military-pmc";      skills=@("Firearms","Survival","Repair");                  perks=@("exploration");   wealth=2; renown=0; langs=@("grindtalk","ashmouth");       concept="Trained and mustered out with gear contacts." },
  @{ name="Mage-for-Hire";       dsid="gw-mage-for-hire";       skills=@("Spellcraft","Rituals","Occult");                 perks=@("supernatural");  wealth=1; renown=0; langs=@("firstWord","static");         concept="Sold arcane talent on the open market." },
  @{ name="Decker";              dsid="gw-decker";              skills=@("Hacking","Matrix Theory","Electronics");         perks=@("lore");          wealth=2; renown=0; langs=@("signalcant","static");        concept="Lived in the Wired more than out of it." },
  @{ name="Wired Medic";         dsid="gw-wired-medic";         skills=@("Medicine","Medicine Lore","Cybertech");          perks=@("crafting");      wealth=2; renown=0; langs=@("grindtalk","signalcant");     concept="Street doc / battlefield triage." },
  @{ name="Ripperdoc's Runner";  dsid="gw-ripperdocs-runner";   skills=@("Cybertech","Repair","Streetwise");               perks=@("crafting");      wealth=1; renown=0; langs=@("static","sinkcant");          concept="Grew up in the chop-shop chrome trade." },
  @{ name="Sinks Scavenger";     dsid="gw-sinks-scavenger";     skills=@("Survival","Perception","Repair");                perks=@("exploration");   wealth=1; renown=0; langs=@("sinkcant","ashmouth");        concept="Salvage diver in the flooded dead levels." },
  @{ name="Churn Smuggler";      dsid="gw-churn-smuggler";      skills=@("Stealth","Negotiation","Piloting");              perks=@("intrigue");      wealth=2; renown=0; langs=@("ashmouth","sinkcant");        concept="Moved goods through Nyx's Undermarket." },
  @{ name="Wastes Courier";      dsid="gw-wastes-courier";      skills=@("Navigation","Survival","Piloting");              perks=@("exploration");   wealth=2; renown=0; langs=@("ashmouth","signalcant");      concept="Ran the outer gate to Cinderhold and the wastes." }
)
# --- REACH LANGUAGES (canon, Michael 2026-07-22: lean/flavorful, evocative single names) ---
# key -> label. These REPLACE the stock Draw Steel fantasy languages in config.mjs.
$REACH_LANGS = [ordered]@{
  reachspeak = "Reachspeak"     # common trade creole - everyone's baseline
  highwire   = "Highwire"       # Halo/Spire corporate register
  grindtalk  = "Grindtalk"      # Grid wage-body dialect
  static     = "Static"         # Flats/Warrens edgerunner street argot
  sinkcant   = "Sinkcant"       # Sinks black-market drip-code
  ashmouth   = "Ashmouth"       # outer-wastes / Cinderhold caravan creole
  deeptongue = "Deeptongue"     # Corran ancestral (guild-clan dialects)
  highform   = "Highform"       # Elvani ancestral (status register)
  ironjaw    = "Ironjaw"        # Goliar ancestral (plain kinship-crew)
  packsign   = "Packsign"       # Changer hybrid vocal/gesture/scent
  gravecant  = "Gravecant"      # Revenant memory-laden formal tongue
  firstWord  = "The First Word" # arcane/sacred ritual tongue (echo of the Word)
  signalcant = "Signalcant"     # Wired/matrix resonance-notation code-tongue
}
# Curated Cultural-Language shortlist (Culture item). Reachspeak + strata cants +
# the species tongues (offered here so the picker is self-contained).
$CULTURE_LANG_CHOICES = @("reachspeak","highwire","grindtalk","static","sinkcant","ashmouth","deeptongue","highform","ironjaw","packsign","gravecant")

$d6 = @(
 "1 - A run went wrong: you were the one who got out, or the one who got blamed.",
 "2 - A corp betrayal: the employer you trusted sold you out or cut you loose.",
 "3 - A debt came due: a favor, a loan, or a mistake put you on the hook.",
 "4 - The Veil touched you: a brush with the Dark One's agents, a haunting, a mark.",
 "5 - The body changed: a mutation surfaced, chrome rejected, or a decay set in.",
 "6 - Someone was taken: a person you loved vanished, was killed, or was disappeared."
)

# ------------------------------------------------------------------ 2b. rewrite config.mjs languages -> Reach languages
# The stock Draw Steel fantasy languages (Anjali, Proto-Ctholl, Variac, ...) show up
# in the Culture/Career language pickers. We replace the language DEFINITION block in
# config.mjs with our 13 Reach languages so the whole game uses Reach tongues.
# Draw Steel config shape (mirrors the skills shape):
#   const languageList = { anjali: { label: "..." }, ... }   (or a `languages:`/`list:` key)
# We build the replacement inner-body in the SAME entry style and swap it in.
function Build-ReachLangBody(){
  $lines = New-Object System.Collections.Generic.List[string]
  foreach($k in $REACH_LANGS.Keys){
    $lbl = $REACH_LANGS[$k]
    $lines.Add("    $k`: { label: `"$lbl`" },") | Out-Null
  }
  return "`n" + ($lines -join "`n") + "`n  "
}
$configPath = $configCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$reachLangBody = Build-ReachLangBody
# candidate anchors, most specific first
$langAnchors = @('languageList\s*=\s*','languagesList\s*=\s*','const\s+languages\s*=\s*','\blanguages\s*[:=]\s*')
$langAnchorHit = $null
foreach($a in $langAnchors){
  $inner = Get-ObjectLiteral $configText $a
  if($inner -ne $null){ $langAnchorHit = $a; break }
}
if($langAnchorHit){
  Info "Found languages block in config via anchor '$langAnchorHit'."
  if($WriteConfig -and $configPath){
    $orig = Get-Content $configPath -Raw
    # brace-match the block within the ACTUAL file text (not the concatenated $configText)
    $pat = [regex]"(?s)($langAnchorHit)\{"
    $mm = $pat.Match($orig)
    if($mm.Success){
      $bodyStart = $mm.Index + $mm.Length
      $depth = 1; $i = $bodyStart
      while($i -lt $orig.Length -and $depth -gt 0){
        $ch = $orig[$i]; if($ch -eq '{'){ $depth++ } elseif($ch -eq '}'){ $depth-- }; $i++
      }
      $bodyEnd = $i - 1   # index of closing brace
      $newText = $orig.Substring(0,$bodyStart) + $reachLangBody + $orig.Substring($bodyEnd)
      Copy-Item $configPath "$configPath.bak" -Force
      $enc = New-Object System.Text.UTF8Encoding($false)
      [System.IO.File]::WriteAllText($configPath,$newText,$enc)
      Ok "Rewrote languages block in config.mjs ($($REACH_LANGS.Count) Reach languages). Backup: config.mjs.bak"
    } else {
      Warn "Anchor matched in scan but not in file text; skipping rewrite. Paste the block below manually."
    }
  } else {
    Warn "config.mjs NOT modified (no -WriteConfig). To wire the Reach languages, either re-run with -WriteConfig, or replace the languages block body in src\module\config.mjs with:"
    Write-Host $reachLangBody -ForegroundColor Gray
  }
} else {
  Warn "Could not locate a languages block in config.mjs (tried: languageList / languagesList / const languages / languages:)."
  Warn "Open src\module\config.mjs, find the language definitions, and replace their body with these 13 entries:"
  Write-Host $reachLangBody -ForegroundColor Gray
}

# ------------------------------------------------------------------ 3. resolve keys (and optionally dry-run)
function ResolveList([string[]]$names){ $out=@(); foreach($x in $names){ $k=Resolve-Skill $x; if($k){ $out+=$k } }; ,$out }
$habKeys  = ResolveList $habitatSkills
$ordKeys  = ResolveList $orderSkills
$formKeys = ResolveList $formationSkills
$knowledgeGroupKey = Resolve-Group "Knowledge"   # for Academic "any Knowledge"

Info "Resolved Habitat skill keys:   $($habKeys  -join ', ')"
Info "Resolved Order skill keys:     $($ordKeys  -join ', ')"
Info "Resolved Formation skill keys: $($formKeys -join ', ')"
Info "Knowledge group key:           $knowledgeGroupKey"

if($MAP_MISSING.Count -gt 0){
  Warn "Some sourcebook names did not resolve to config keys:"
  $MAP_MISSING | Sort-Object -Unique | ForEach-Object { Warn "   - $_" }
  Warn "These will be SKIPPED. Fix the config labels or add aliases, then re-run."
}
# --- validate every career's perk family against the LIVE perkTypes (hard gate) ---
if($LIVE_PERKTYPES.Count -gt 0){
  $badPerks = New-Object System.Collections.Generic.List[string]
  foreach($c in $careers){
    foreach($pf in $c.perks){
      if(-not $LIVE_PERKTYPES.Contains($pf)){ $badPerks.Add(("{0} -> '{1}'" -f $c.name, $pf)) | Out-Null }
    }
  }
  if($badPerks.Count -gt 0){
    Warn "The following careers reference perkType values that DO NOT exist in the Perks pack:"
    foreach($b in $badPerks){ Warn "   $b" }
    Die ("Aborting: unknown perkType(s) would produce an EMPTY perk picker. Valid types are: {0}" -f (($LIVE_PERKTYPES | Sort-Object) -join ', '))
  }
}

if($WhatIfKeys){
  Info "WhatIfKeys set -> printing career skill + perk resolution and EXITING (no files written)."
  foreach($c in $careers){ Info ("  {0,-22} skills-> {1,-40} perk-> {2}" -f $c.name, ((ResolveList $c.skills) -join ', '), ($c.perks -join ', ')) }
  exit 0
}
if($habKeys.Count -eq 0 -or $ordKeys.Count -eq 0 -or $formKeys.Count -eq 0){
  Die "One or more Culture aspects resolved to ZERO skills. Aborting so we don't author an unpickable culture. Re-run with -WhatIfKeys and check the config skill labels."
}

# ------------------------------------------------------------------ 4. author folders
$backgroundsFolderId = "g8icN9n7dCBGOsej"   # stock DS Backgrounds folder (parent)
$gwCultureFolderId = New-Id16
$gwCareerFolderId  = New-Id16
$cultRoot   = Join-Path $originsSrc "Backgrounds_$backgroundsFolderId"
if(-not (Test-Path $cultRoot)){ Warn "Stock Backgrounds folder not found at $cultRoot; creating our folders at origins root instead."; $cultRoot = $originsSrc; $backgroundsFolderId = $null }

$gwCultureDir = Join-Path $cultRoot "GHOSTWIRE_Cultures_$gwCultureFolderId"
$gwCareerDir  = Join-Path $cultRoot "GHOSTWIRE_Careers_$gwCareerFolderId"

# clean any prior GHOSTWIRE origins (match by folder name prefix + gw- dsid)
Get-ChildItem $cultRoot -Directory -Filter "GHOSTWIRE_Cultures_*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Get-ChildItem $cultRoot -Directory -Filter "GHOSTWIRE_Careers_*"  -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Get-ChildItem $cultRoot -File -Filter "Folder_GHOSTWIRE_*.json"    -ErrorAction SilentlyContinue | Remove-Item -Force
New-Item -ItemType Directory -Path $gwCultureDir -Force | Out-Null
New-Item -ItemType Directory -Path $gwCareerDir  -Force | Out-Null

Write-JsonNoBom (Join-Path $cultRoot "Folder_GHOSTWIRE_Cultures_$gwCultureFolderId.json") (New-FolderDoc $gwCultureFolderId "GHOSTWIRE Cultures" $backgroundsFolderId 100000)
Write-JsonNoBom (Join-Path $cultRoot "Folder_GHOSTWIRE_Careers_$gwCareerFolderId.json")   (New-FolderDoc $gwCareerFolderId  "GHOSTWIRE Careers"  $backgroundsFolderId 200000)
Ok "Authored GHOSTWIRE folders (Cultures $gwCultureFolderId / Careers $gwCareerFolderId)."

# ------------------------------------------------------------------ 5. author the ONE Culture item (3 aspects)
$cultureId = New-Id16
# Formation aspect: explicit skills PLUS the Knowledge group (for Academic "any Knowledge")
$formGroups = @(); if($knowledgeGroupKey){ $formGroups = @($knowledgeGroupKey) }

$adv = [ordered]@{}
$habAdv  = New-SkillAdv "Habitat (where you were raised)" @()        $habKeys  1
$ordAdv  = New-SkillAdv "Order (who governed your life)"  @()        $ordKeys  1
$formAdv = New-SkillAdv "Formation (how you were shaped)" $formGroups $formKeys 1
$langAdv = New-LangAdv  "Cultural Language" 1 $CULTURE_LANG_CHOICES
$adv[$habAdv._id]  = $habAdv
$adv[$ordAdv._id]  = $ordAdv
$adv[$formAdv._id] = $formAdv
$adv[$langAdv._id] = $langAdv

$cultureDesc = @"
<p><em>Every Edgerunner's upbringing is described by three Culture aspects - Habitat, Order, and Formation. Each grants one trained skill (choose below), and together they grant a cultural language and a cultural edge.</em></p>
<p><strong>Two-group cap:</strong> no more than two of your three Culture skills may come from the same skill group; if your picks would give three from one group, choose a different skill for the third aspect.</p>
<ul>
<li><strong>Habitat</strong> - where in the vertical hive you were raised (Halo/Spire, Grid, Flats, Sinks, Off-Grid).</li>
<li><strong>Order</strong> - who governed your daily life (Corporate or Communal).</li>
<li><strong>Formation</strong> - the training or trade that formed you (Academic, Devout, Laboring, Lawless, Martial, Privileged).</li>
</ul>
<p><strong>Cultural edge:</strong> an edge on Power Rolls to recall lore about your own culture, or to trade on your standing inside it.</p>
"@

$cultureItem = [ordered]@{
  folder = $gwCultureFolderId
  name   = "GHOSTWIRE Culture"
  type   = "culture"
  _id    = $cultureId
  img    = "icons/environment/settlement/city.webp"
  system = [ordered]@{
    description = [ordered]@{ value = $cultureDesc; director = "" }
    source      = [ordered]@{ book = "GHOSTWIRE Core"; page = ""; license = "Draw Steel Creator License" }
    _dsid       = "gw-culture"
    advancements= $adv
  }
  effects=@(); sort=0; ownership=[ordered]@{ default=0 }; flags=@{}
  _stats=(New-Stats); _key="!items!$cultureId"
}
Write-JsonNoBom (Join-Path $gwCultureDir "culture_GHOSTWIRE_Culture_$cultureId.json") $cultureItem
Ok "Authored GHOSTWIRE Culture ($cultureId) with Habitat/Order/Formation + Language."

# ------------------------------------------------------------------ 6. author the 14 Career items
$careerCount = 0
foreach($c in $careers){
  $ckeys = ResolveList $c.skills
  if($ckeys.Count -lt 2){ Warn "Career '$($c.name)' resolved <2 skills ($($ckeys -join ',')); skipping."; continue }
  $cid = New-Id16
  $cadv = [ordered]@{}
  # 2-of-3 skill choice: one chooseN:1 advancement offering the explicit menu, count 2
  # DS models "choose 2 from 3" as a single skill advancement with chooseN:2 + choices list.
  $skillAdv = New-SkillAdv "Career Skills (choose 2)" @() $ckeys 2
  $careerLangs = @(); if($c.ContainsKey('langs')){ $careerLangs = @($c.langs) }
  $langAdv2 = New-LangAdv "Career Language" 1 $careerLangs
  $perkFamLabel = ($c.perks -join " or ")
  # Build the curated pool: every perk whose perkType matches this career's family(ies).
  $poolUuids = New-Object System.Collections.Generic.List[string]
  foreach($fam in $c.perks){
    $famNorm = ($fam.Substring(0,1).ToLower() + $fam.Substring(1))
    if($PERKS_BY_TYPE.ContainsKey($famNorm)){
      foreach($p in $PERKS_BY_TYPE[$famNorm]){ $poolUuids.Add("Compendium.draw-steel.$PERK_PACK_ID.Item.$($p.id)") | Out-Null }
    }
  }
  if($poolUuids.Count -eq 0){ Warn "Career '$($c.name)': no perks matched families [$perkFamLabel]; picker will rely on drag-in." }
  $perkAdv  = New-PerkGrant "Career Perk" "<p>One Perk (suggested family: $perkFamLabel - guidance, not a restriction). You may also drop any other perk here.</p>" $c.perks $poolUuids
  $cadv[$skillAdv._id]=$skillAdv
  $cadv[$langAdv2._id]=$langAdv2
  $cadv[$perkAdv._id] =$perkAdv

  $incidentHtml = "<h5>Inciting Incident</h5><p>Roll or choose a d6 Inciting Incident - the event that pushed you into the run economy:</p><ol>" + `
    (($d6 | ForEach-Object { "<li>$_</li>" }) -join "") + "</ol>" + `
    "<p><em>If your rolled incident predates this Career, treat it as the break that ended your old life and started the one this Career describes.</em></p>"

  $desc = "<p>$($c.concept)</p><p><strong>Skills:</strong> choose 2 of: $($c.skills -join ', ').</p><p><strong>Perk:</strong> one Perk (suggested: $perkFamLabel).</p>$incidentHtml"

  $careerItem = [ordered]@{
    folder = $gwCareerFolderId
    name   = $c.name
    type   = "career"
    _id    = $cid
    img    = "icons/tools/scribal/magnifying-glass.webp"
    system = [ordered]@{
      description = [ordered]@{ value = $desc; director = "" }
      source      = [ordered]@{ book = "GHOSTWIRE Core"; page = ""; license = "Draw Steel Creator License" }
      _dsid       = $c.dsid
      advancements= $cadv
      projectPoints = 0
      renown        = [int]$c.renown
      wealth        = [int]$c.wealth
    }
    effects=@(); flags=@{}
    _stats=(New-Stats); ownership=[ordered]@{ default=0 }
    sort=0; _key="!items!$cid"
  }
  Write-JsonNoBom (Join-Path $gwCareerDir "career_$($c.dsid)_$cid.json") $careerItem
  $careerCount++
}
Ok "Authored $careerCount Career items."

# ------------------------------------------------------------------ 7. build packs
if($NoBuild){ Warn "-NoBuild set: skipping 'npm run build:packs'. Source JSON written only."; }
else {
  Info "Building packs (npm run build:packs)..."
  npm run build:packs
  if($LASTEXITCODE -ne 0){ Die "npm run build:packs failed (exit $LASTEXITCODE). Fix the error and re-run." }
  Ok "Packs compiled."
}

# ------------------------------------------------------------------ 8. deploy (robocopy)
if($NoDeploy){ Warn "-NoDeploy set: skipping robocopy into Foundry."; }
elseif($NoBuild){ Warn "Skipping deploy because packs were not built."; }
else {
  $dest = Join-Path $FoundryData "Data\systems\$SystemName"
  if(-not (Test-Path $dest)){ Die "Foundry system folder not found: $dest" }
  Info "Deploying to $dest ..."
  robocopy $RepoRoot $dest /E `
    /XD (Join-Path $RepoRoot "node_modules") (Join-Path $RepoRoot ".git") (Join-Path $RepoRoot ".github") (Join-Path $RepoRoot ".vscode") (Join-Path $RepoRoot "tools") | Out-Null
  $rc = $LASTEXITCODE
  if($rc -ge 8){ Die "robocopy reported failure (exit $rc)." }
  Ok "Deployed (robocopy exit $rc = success)."
}

Write-Host ""
Ok "GHOSTWIRE Origins deploy complete."
Info "In Foundry: relaunch the world, open a hero, and you'll find 'GHOSTWIRE Culture' and the 14 Careers"
Info "in the origins compendium (Backgrounds -> GHOSTWIRE Cultures / GHOSTWIRE Careers). Drag onto the hero;"
Info "the Culture prompts 3 skill picks (Habitat/Order/Formation), each Career prompts 2 skill picks + a Perk."
Warn "Reminder: commit on branch 1.1.x after you verify in Foundry, then paste the hash so I can log it."
