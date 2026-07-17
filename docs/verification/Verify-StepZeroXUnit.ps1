param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][ValidateSet('REGRESSION', 'COUNTS', 'EDGE')][string]$Campaign,
    [Parameter(Mandatory = $true)][ValidateSet('RED', 'GREEN')][string]$Phase,
    [string]$OutCanonical
)

$script:failCount = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "PASS  $Message" }
    else { Write-Host "FAIL  $Message" -ForegroundColor Red; $script:failCount++ }
}

if (-not (Test-Path $Path)) { Write-Host "FAIL  xUnit file not found: $Path" -ForegroundColor Red; exit 1 }
[xml]$doc = Get-Content -Path $Path -Raw
$root = $doc.testsuites

# Expected model per campaign/phase. failing/skippedNames are exact test-name sets.
# RED root semantics (2026.7.17.1 baseline bugs): tests attr = successful count; no skipped attr.
$model = @{}
switch ("$Campaign/$Phase") {
    'REGRESSION/RED' {
        $model['PRG_TEST_TCUNIT_STEP0.TimedSuiteTests']   = @{ tests = 5; failing = @('Test_PaddedNameLookup', 'Test_StaleContextGuard'); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0.TimedOrderedTests'] = @{ tests = 3; failing = @('Test_Ordered3_Guard'); skippedNames = @() }
        $rootTests = '5'; $rootFailures = '3'; $rootSkipped = $null
    }
    'REGRESSION/GREEN' {
        $model['PRG_TEST_TCUNIT_STEP0.TimedSuiteTests']   = @{ tests = 5; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0.TimedOrderedTests'] = @{ tests = 3; failing = @(); skippedNames = @() }
        $rootTests = '8'; $rootFailures = '0'; $rootSkipped = '0'
    }
    'COUNTS/RED' {
        $model['PRG_TEST_TCUNIT_STEP0_COUNTS.PassSuite']              = @{ tests = 1; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0_COUNTS.CountsSuite_ShouldFail'] = @{ tests = 3; failing = @('Test_IntentionalFail'); skippedNames = @('Test_Skipped') }
        $rootTests = '3'; $rootFailures = '1'; $rootSkipped = $null
    }
    'COUNTS/GREEN' {
        $model['PRG_TEST_TCUNIT_STEP0_COUNTS.PassSuite']              = @{ tests = 1; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0_COUNTS.CountsSuite_ShouldFail'] = @{ tests = 3; failing = @('Test_IntentionalFail'); skippedNames = @('Test_Skipped') }
        $rootTests = '4'; $rootFailures = '1'; $rootSkipped = '1'
    }
    'EDGE/GREEN' {
        $model['PRG_TEST_TCUNIT_STEP0_EDGE.EmptyFirstSuite'] = @{ tests = 0; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0_EDGE.MidPassSuite']    = @{ tests = 1; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0_EDGE.EmptyFinalSuite'] = @{ tests = 0; failing = @(); skippedNames = @() }
        $rootTests = '1'; $rootFailures = '0'; $rootSkipped = '0'
    }
    'EDGE/RED' { Write-Host 'FAIL  EDGE campaign is GREEN-only by design' -ForegroundColor Red; exit 1 }
}

# Root attribute assertions
Assert-True ($root.tests -eq $rootTests)       "root tests='$($root.tests)' expected '$rootTests'"
Assert-True ($root.failures -eq $rootFailures) "root failures='$($root.failures)' expected '$rootFailures'"
if ($null -eq $rootSkipped) {
    Assert-True ($null -eq $root.GetAttribute('skipped') -or $root.GetAttribute('skipped') -eq '') "root skipped attribute absent (RED semantics)"
} else {
    Assert-True ($root.skipped -eq $rootSkipped) "root skipped='$($root.skipped)' expected '$rootSkipped'"
}

$suites = @($root.testsuite)

# Campaign isolation: the xUnit file must contain EXACTLY the campaign suites.
# Any other suite means a non-campaign PRG was compiled into the run - hard failure,
# because hidden registered suites make counts and sequence traversal ambiguous.
Assert-True ($suites.Count -eq $model.Count) "suite count=$($suites.Count) expected exactly $($model.Count)"
foreach ($suite in $suites) {
    Assert-True ($model.ContainsKey($suite.name)) "unexpected non-campaign suite present: $($suite.name)"
}

foreach ($name in $model.Keys) {
    $suite = $suites | Where-Object { $_.name -eq $name }
    Assert-True ($null -ne $suite) "suite present: $name"
    if ($null -eq $suite) { continue }
    $m = $model[$name]
    Assert-True ([int]$suite.tests -eq $m.tests)            "$name tests=$($suite.tests) expected $($m.tests)"
    Assert-True ([int]$suite.failures -eq $m.failing.Count) "$name failures=$($suite.failures) expected $($m.failing.Count)"
    if ($Phase -eq 'GREEN') {
        Assert-True ($suite.skipped -eq [string]$m.skippedNames.Count) "$name skipped=$($suite.skipped) expected $($m.skippedNames.Count)"
    }
    $cases = @($suite.testcase)
    Assert-True ($cases.Count -eq $m.tests) "$name testcase count=$($cases.Count) expected $($m.tests)"
    $actualFailing = @($cases | Where-Object { $_.status -eq 'FAIL' } | ForEach-Object { $_.name })
    $actualSkipped = @($cases | Where-Object { $_.status -eq 'SKIP' } | ForEach-Object { $_.name })
    Assert-True (-not (Compare-Object $actualFailing $m.failing))      "$name failing set = [$($actualFailing -join ',')] expected [$($m.failing -join ',')]"
    Assert-True (-not (Compare-Object $actualSkipped $m.skippedNames)) "$name skipped set = [$($actualSkipped -join ',')] expected [$($m.skippedNames -join ',')]"
    foreach ($case in $cases) {
        if ($case.name -in $m.failing) {
            Assert-True ($null -ne $case.failure) "$name/$($case.name) carries a <failure> element"
        } else {
            Assert-True ($null -eq $case.failure) "$name/$($case.name) carries no <failure> element"
        }
    }
}

if ($OutCanonical) {
    $content = Get-Content -Path $Path -Raw
    $canonical = $content -replace 'time="[^"]*"', 'time=""'
    Set-Content -Path $OutCanonical -Value $canonical -NoNewline -Encoding UTF8
    Write-Host "Canonical golden written to $OutCanonical"
}

Write-Host ""
if ($script:failCount -eq 0) { Write-Host "ALL ASSERTIONS PASSED ($Campaign/$Phase)"; exit 0 }
else { Write-Host "$script:failCount ASSERTION(S) FAILED ($Campaign/$Phase)" -ForegroundColor Red; exit 1 }
