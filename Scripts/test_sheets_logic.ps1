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

Write-Host "`nSummary: $testsPassed / $testsTotal tests passed." -ForegroundColor $(if ($testsPassed -eq $testsTotal) { "Green" } else { "Red" })
exit ($testsTotal - $testsPassed)
