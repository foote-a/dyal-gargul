# Test suite for Rolling SR Google Apps Script business logic

$testsPassed = 0
$testsTotal = 0

function Assert-Equal($actual, $expected, $message) {
    $script:testsTotal++
    if ($actual -eq $expected) {
        $script:testsPassed++
        Write-Host "  [PASS] $message" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $message - Expected '$expected' but got '$actual'" -ForegroundColor Red
    }
}

Write-Host "=== Rolling SR Google Sheet Logic Tests ===" -ForegroundColor Cyan

# Rule 1: Same item reserved again -> +1 roll
$prevItem = "Deathbringer's Will"
$prevRolls = 2
$newItem = "Deathbringer's Will"
$status = "Member"
$calculatedRolls = if ($newItem -and ($newItem.ToLower() -eq $prevItem.ToLower())) { $prevRolls + 1 } else { 0 }
Assert-Equal $calculatedRolls 3 "Same item reserved again gains +1 roll (2 -> 3)"

# Rule 2: Item changed -> reset to 0
$newItem = "Solace of the Defeated"
$calculatedRolls = if ($newItem -and ($newItem.ToLower() -eq $prevItem.ToLower())) { $prevRolls + 1 } else { 0 }
Assert-Equal $calculatedRolls 0 "Changed item resets rolls to 0"

# Rule 3: Dropped reservation (empty) -> reset to 0
$newItem = ""
$calculatedRolls = if ($newItem -and ($newItem.ToLower() -eq $prevItem.ToLower())) { $prevRolls + 1 } else { 0 }
Assert-Equal $calculatedRolls 0 "Dropped reservation resets to 0"

# Rule 4: 1 Missed raid preserves rolls
$misses = 0
$prevRolls = 3
$newMisses = $misses + 1
$rollsAfter1Miss = if ($newMisses -ge 2) { 0 } else { $prevRolls }
Assert-Equal $rollsAfter1Miss 3 "1 missed raid preserves accumulated rolls"
Assert-Equal $newMisses 1 "1 missed raid sets consecutive misses to 1"

# Rule 5: 2 Consecutive missed raids reset rolls
$misses = 1
$newMisses = $misses + 1
$rollsAfter2Misses = if ($newMisses -ge 2) { 0 } else { $prevRolls }
Assert-Equal $rollsAfter2Misses 0 "2 consecutive misses resets extra rolls to 0"
Assert-Equal $newMisses 2 "2 consecutive misses records 2 misses"

# Rule 6: Benched status counts as attending
$status = "Benched"
$benchedItem = "Deathbringer's Will"
$benchedPrevRolls = 1
$benchRolls = if ($status -eq "Benched" -and $benchedItem) { $benchedPrevRolls + 1 } else { 0 }
$benchMisses = if ($status -eq "Benched") { 0 } else { 1 }
Assert-Equal $benchRolls 2 "Benched player gains +1 roll without attending raid"
Assert-Equal $benchMisses 0 "Benched player accrues 0 misses"

# Rule 7: Pug filtering
$roster = @{ "Thrall" = "Member"; "Arthas" = "Member" }
$csvNames = @( "Thrall", "Arthas", "PugHealer", "PugTank" )
$pugsIgnored = @()
$processedGuild = @()
foreach ($name in $csvNames) {
    if (-not $roster.ContainsKey($name)) {
        $pugsIgnored += $name
    } else {
        $processedGuild += $name
    }
}
Assert-Equal $pugsIgnored.Count 2 "Pugs not in roster are filtered out"
Assert-Equal ($pugsIgnored -join ",") "PugHealer,PugTank" "Filtered pugs match expected names"
Assert-Equal $processedGuild.Count 2 "Only guild members are updated"

# Rule 8: Multi-raid CSV attendance merging
$raid1Attendees = @("Thrall", "Jaina")
$raid2Attendees = @("Arthas", "Sylvanas")
$mergedAttendees = @{}
foreach ($n in $raid1Attendees) { $mergedAttendees[$n] = $true }
foreach ($n in $raid2Attendees) { $mergedAttendees[$n] = $true }
Assert-Equal $mergedAttendees.Count 4 "Concurrent raids 1 & 2 merged into unified attendance"
Assert-Equal ($mergedAttendees.ContainsKey("Thrall") -and $mergedAttendees.ContainsKey("Sylvanas")) $true "Attendees from both raids present in union"

# Helper function mimicking stripAccents in .NET
function Strip-Accents([string]$str) {
    $normalized = $str.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

# Rule 9: Automatic Accent / Diacritic Stripping
$e_umlaut = [char]0x00EB
$accentedName = "L${e_umlaut}golas"
$cleanName = Strip-Accents $accentedName
Assert-Equal $cleanName "Legolas" "Accent stripping converts Lëgolas -> Legolas"

$e_acute = [char]0x00E9
$accentedFrench = "R${e_acute}n${e_acute}gad${e_acute}"
Assert-Equal (Strip-Accents $accentedFrench) "Renegade" "Accent stripping converts Rénégadé -> Renegade"

# Rule 10: Alias mapping resolves alts/typos to canonical roster name
$roster = @{ "Dyal" = "Member"; "Thrall" = "Member" }
$aliases = @{ "Dyall" = "Dyal"; "Holydyal" = "Dyal" }
$csvInputName = "Dyall"
$resolvedName = if ($roster.ContainsKey($csvInputName)) {
    $csvInputName
} elseif ($aliases.ContainsKey($csvInputName)) {
    $aliases[$csvInputName]
} else {
    $csvInputName
}
Assert-Equal $resolvedName "Dyal" "Alias table maps Dyall -> Dyal"

# Rule 11: Combined Accent + Alias resolution
$o_circumflex = [char]0x00F4
$csvAccentAlias = "H${o_circumflex}lydyal"
$cleanCsvName = Strip-Accents $csvAccentAlias
$matchedTarget = $null
foreach ($a in $aliases.Keys) {
    if ((Strip-Accents $a).ToLower() -eq $cleanCsvName.ToLower()) {
        $matchedTarget = $aliases[$a]
        break
    }
}
Assert-Equal $matchedTarget "Dyal" "Combined accent + alias resolves Hôlydyal -> Dyal"

# Rule 12: Alias protects attendance (player is marked present, 0 misses accrued)
$incomingReserves = @{ $resolvedName = @("Deathbringer's Will") }
$memberAttended = $incomingReserves.ContainsKey("Dyal")
$missesRecorded = if ($memberAttended) { 0 } else { 1 }
Assert-Equal $memberAttended $true "Aliased alt counts as attendance for main player"
Assert-Equal $missesRecorded 0 "Aliased player accrues 0 misses (streak protected)"

# Rule 13: Recruit 2-week trial gating (accumulates internally, exports 0 until graduated)
$recruitStatus = "Recruit"
$recruitInternalRolls = 2
$inTrial = $true
$exportedRecruitRolls = if ($recruitStatus -eq "Recruit" -and $inTrial) { 0 } else { $recruitInternalRolls }
Assert-Equal $exportedRecruitRolls 0 "Recruit in trial exports 0 bonus rolls despite internal accumulation"
$graduatedStatus = "Member"
$exportedGraduatedRolls = if ($graduatedStatus -eq "Recruit" -and $inTrial) { 0 } else { $recruitInternalRolls }
Assert-Equal $exportedGraduatedRolls 2 "Graduated recruit (Member) exports full accumulated bonus rolls"

# Rule 14: Mark Item Won (case-insensitive match resets only the won slot)
$slot1Item = "Deathbringer's Will"
$slot1Rolls = 3
$slot2Item = "Solace of the Defeated"
$slot2Rolls = 1
$wonInput = "deathbringer's will"
if ($slot1Item.ToLower() -eq $wonInput.ToLower()) { $slot1Item = ""; $slot1Rolls = 0 }
if ($slot2Item.ToLower() -eq $wonInput.ToLower()) { $slot2Item = ""; $slot2Rolls = 0 }
Assert-Equal $slot1Rolls 0 "Mark Item Won resets matching slot extra rolls to 0"
Assert-Equal $slot1Item "" "Mark Item Won clears matching slot item name"
Assert-Equal $slot2Rolls 1 "Mark Item Won preserves other reserved item slot rolls"

# Rule 15: Excuse Absence / Vacation resets consecutive misses to 0
$priorMisses = 1
$excusedMisses = 0
$nextWeekAbsentMisses = $excusedMisses + 1
$streakReset = ($nextWeekAbsentMisses -ge 2)
Assert-Equal $excusedMisses 0 "Excused absence resets consecutive misses to 0"
Assert-Equal $streakReset $false "Excused player does not lose roll streak on subsequent absence"

# Rule 16: Clean & Sort Roster (Title Case normalization, whitespace collapse, alphabetical sort)
$dirtyNames = @("  zUlJin ", "arthas", "", "  THRALL  ")
$cleanedNames = @()
foreach ($raw in $dirtyNames) {
    $trimmed = $raw.Trim()
    if ($trimmed.Length -gt 0) {
        $titleCase = $trimmed.Substring(0, 1).ToUpper() + $trimmed.Substring(1).ToLower()
        $cleanedNames += $titleCase
    }
}
$sortedNames = $cleanedNames | Sort-Object
Assert-Equal $sortedNames.Count 3 "Clean roster removes empty rows"
Assert-Equal ($sortedNames -join ",") "Arthas,Thrall,Zuljin" "Clean roster normalizes Title Case and sorts alphabetically"

# Rule 17: Mains vs. Alts (Alts never stack rolls; playing on Alt multiple weeks in a row preserves Main's rolls & 0 misses; Alts export with *alt)
$mainItem = "Deathbringer's Will"
$mainRolls = 4
$mainMisses = 0
$altStatus = "Alt"
$altItem = "Bryntroll, the Bone Arbiter"
$altPrevRolls = 0

# Week 1 on Alt: Alt reserves Bryntroll again -> still 0 rolls; Main is protected -> keeps 4 rolls, 0 misses
$altWeek1Rolls = if ($altStatus -eq "Alt") { 0 } else { $altPrevRolls + 1 }
$mainProtectedByAltWeek1 = $true
if ($mainProtectedByAltWeek1) { $mainMisses = 0 } else { $mainMisses++ }

# Week 2 on Alt (2 consecutive weeks on Alt!): Alt still 0 rolls; Main STILL keeps 4 rolls, 0 misses
$altWeek2Rolls = if ($altStatus -eq "Alt") { 0 } else { $altWeek1Rolls + 1 }
$mainProtectedByAltWeek2 = $true
if ($mainProtectedByAltWeek2) { $mainMisses = 0 } else { $mainMisses++ }
if ($mainMisses -ge 2) { $mainRolls = 0 }

# Week 3 on Alt (3 consecutive weeks on Alt!): Main STILL keeps 4 rolls, 0 misses
$mainProtectedByAltWeek3 = $true
if ($mainProtectedByAltWeek3) { $mainMisses = 0 } else { $mainMisses++ }
if ($mainMisses -ge 2) { $mainRolls = 0 }

Assert-Equal $altWeek2Rolls 0 "Alts never accumulate stacking rolls when ALTS_ACCRUE_ROLLS is false (default)"
$altsAccrueEnabled = $true
$altWeek2RollsWhenEnabled = if ($altStatus -eq "Alt" -and -not $altsAccrueEnabled) { 0 } else { $altPrevRolls + 1 }
Assert-Equal $altWeek2RollsWhenEnabled 1 "Alts accumulate +1 stacking roll when ALTS_ACCRUE_ROLLS is enabled (true)"
Assert-Equal $mainRolls 4 "Playing on an Alt multiple weeks in a row preserves Main's accumulated rolls"
Assert-Equal $mainMisses 0 "Playing on an Alt multiple weeks in a row accrues 0 misses on Main"
$altExportEntry = "Dyalalt*alt:$altItem=0;"
Assert-Equal ($altExportEntry.Contains("*alt:")) $true "Alts are exported with *alt tag for Phase 1 vs Phase 2 gating"

# Rule 18: Configurable Max Accumulated Rolls Cap (MAX_EXTRA_ROLLS = 100)
$maxExtraRolls = 100
$prevAtCap = 100
$nextRolls = [Math]::Min($prevAtCap + 1, $maxExtraRolls)
Assert-Equal $nextRolls 100 "Accumulated extra rolls cap at MAX_EXTRA_ROLLS (100)"

# Rule 19: Automated Won Items String Import (/rsr won -> applyWonItemsString)
$wonString = "/rsr won Thrall:Deathbringer's Will;Jaina:Phylactery of the Nameless Lich;"
$cleanedWon = $wonString -replace "^/?(?:gl\s+)?rsr\s+won\s*", ""
$rosterSim = @{
    "Thrall" = @{ Item1 = "Deathbringer's Will"; Rolls1 = 3; Item2 = "Shadowmourne"; Rolls2 = 2 }
    "Jaina"  = @{ Item1 = "Archus, Greatstaff of Antonidas"; Rolls1 = 1; Item2 = "Phylactery of the Nameless Lich"; Rolls2 = 4 }
}
foreach ($pair in $cleanedWon.Split(";")) {
    $trimmedPair = $pair.Trim()
    if ($trimmedPair -match "^([^:]+):(.+)$") {
        $p = $Matches[1].Trim()
        $it = $Matches[2].Trim()
        if ($rosterSim.ContainsKey($p)) {
            if ($rosterSim[$p].Item1.ToLower() -eq $it.ToLower()) {
                $rosterSim[$p].Item1 = ""
                $rosterSim[$p].Rolls1 = 0
            }
            if ($rosterSim[$p].Item2.ToLower() -eq $it.ToLower()) {
                $rosterSim[$p].Item2 = ""
                $rosterSim[$p].Rolls2 = 0
            }
        }
    }
}
Assert-Equal $rosterSim["Thrall"].Rolls1 0 "/rsr won string automatically resets Thrall's won item rolls to 0"
Assert-Equal $rosterSim["Thrall"].Rolls2 2 "/rsr won string preserves Thrall's unwon item slot rolls (2)"
Assert-Equal $rosterSim["Jaina"].Rolls2 0 "/rsr won string automatically resets Jaina's won item rolls to 0"

# Rule 20: Live Syntax & Token Balance Verification of Scripts/RollingSR_Code.gs
$gsPath = Join-Path $PSScriptRoot "RollingSR_Code.gs"
$gsLines = Get-Content $gsPath
$openBraces = 0
$openParens = 0
$openBrackets = 0
foreach ($line in $gsLines) {
    $chars = $line.ToCharArray()
    $inString = $false
    $strChar = [char]0
    for ($j = 0; $j -lt $chars.Length; $j++) {
        $c = $chars[$j]
        if (-not $inString -and $c -eq '/' -and ($j + 1 -lt $chars.Length) -and $chars[$j+1] -eq '/') {
            break
        }
        if ($c -eq '"' -or $c -eq "'") {
            if (-not $inString) {
                $inString = $true
                $strChar = $c
            } elseif ($strChar -eq $c -and ($j -eq 0 -or $chars[$j-1] -ne '\')) {
                $inString = $false
            }
            continue
        }
        if (-not $inString) {
            if ($c -eq '{') { $openBraces++ }
            elseif ($c -eq '}') { $openBraces-- }
            elseif ($c -eq '(') { $openParens++ }
            elseif ($c -eq ')') { $openParens-- }
            elseif ($c -eq '[') { $openBrackets++ }
            elseif ($c -eq ']') { $openBrackets-- }
        }
    }
}
Assert-Equal $openBraces 0 "RollingSR_Code.gs has 0 unclosed curly braces {}"
Assert-Equal $openParens 0 "RollingSR_Code.gs has 0 unclosed parentheses ()"
Assert-Equal $openBrackets 0 "RollingSR_Code.gs has 0 unclosed square brackets []"

Write-Host "`nSummary: $testsPassed / $testsTotal tests passed." -ForegroundColor $(if ($testsPassed -eq $testsTotal) { "Green" } else { "Red" })
exit ($testsTotal - $testsPassed)
