param(
    [Parameter(Mandatory = $true)][ValidateSet('REGRESSION', 'COUNTS', 'EDGE', 'ABORT')][string]$Campaign,
    [Parameter(Mandatory = $true)][ValidateSet('RED', 'GREEN')][string]$Phase,
    [switch]$SelectOnly,    # rewire campaign selection only; no build/deploy/verify; implies -KeepSelection
    [switch]$ResultsOnly,   # skip build/deploy; fetch + verify existing outputs
    [switch]$KeepSelection, # diagnostic: leave the campaign selection in place on exit
    [switch]$UpdateGolden,  # passed through to Verify-StepZeroXUnit.ps1 (explicit golden replacement)
    [switch]$Restore        # manual recovery: restore selection files from git HEAD and exit
)

$ErrorActionPreference = 'Stop'

# --- Fixed environment (see docs/verification/2026-07-17-step0-verification.md) ---
$twcTests   = 'C:\Users\scott\Documents\TwinCAT_Tests'
$tcTTO      = Join-Path $twcTests 'TwinCAT_Tests\TwinCAT_Tests\TestTask1.TcTTO'
$plcproj    = Join-Path $twcTests 'TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests.plcproj'
$solution   = Join-Path $twcTests 'TwinCAT_Tests\TwinCAT_Tests.sln'
$tpmExe     = 'C:\Users\scott\Documents\ToolPackageManager\src\ToolPackageManager.Cli\bin\Release\net8.0-windows\ToolPackageManager.Cli.exe'
$tpmConfig  = Join-Path $twcTests 'tpm.json'
$verify     = Join-Path $PSScriptRoot 'Verify-StepZeroXUnit.ps1'
$resultsDir = Join-Path $PSScriptRoot 'results'
$targetAms  = '192.168.225.2.1.1'
$plcBootUnc = '\\192.168.225.2\C$\ProgramData\Beckhoff\TwinCAT\3.1\Boot'
$plcLogsUnc = '\\192.168.225.2\Logs'
$xunitName  = 'tcunit_step0_xunit.xml'

$campaigns = @{
    REGRESSION = @{ Prg = 'PRG_TEST_TCUNIT_STEP0';        Suites = 2; XUnit = $true;  GreenOnly = $false }
    COUNTS     = @{ Prg = 'PRG_TEST_TCUNIT_STEP0_COUNTS'; Suites = 2; XUnit = $true;  GreenOnly = $false }
    EDGE       = @{ Prg = 'PRG_TEST_TCUNIT_STEP0_EDGE';   Suites = 3; XUnit = $true;  GreenOnly = $true }
    ABORT      = @{ Prg = 'PRG_TEST_TCUNIT_STEP0_ABORT';  Suites = 1; XUnit = $false; GreenOnly = $true }
}
$c = $campaigns[$Campaign]

if ($Restore) {
    git -C $twcTests checkout -- 'TwinCAT_Tests/TwinCAT_Tests/TestTask1.TcTTO' 'TwinCAT_Tests/TwinCAT_Tests/TwinCAT_Tests.plcproj'
    Write-Host "Selection files restored to git HEAD."
    exit 0
}
if ($c.GreenOnly -and $Phase -eq 'RED') { Write-Host "FAIL  $Campaign is GREEN-only by design" -ForegroundColor Red; exit 1 }

# --- Transactional selection (review H1): snapshot original bytes, restore in finally ---
$snapTto  = [System.IO.File]::ReadAllBytes($tcTTO)
$snapProj = [System.IO.File]::ReadAllBytes($plcproj)
$exitCode = 1
try {

# Step 1a. Point TestTask1 at the campaign PRG (preserve encoding: text surgery on raw string)
$tto = [System.IO.File]::ReadAllText($tcTTO)
$newTto = [regex]::Replace($tto, '(<PouCall>\s*<Name>)[^<]+(</Name>)', "`${1}$($c.Prg)`${2}")
if ($newTto -notmatch [regex]::Escape($c.Prg)) { throw "could not set PouCall in TestTask1.TcTTO" }
[System.IO.File]::WriteAllText($tcTTO, $newTto)

# Step 1b. Exclude every other test PRG from build; include only the campaign PRG.
#          (Fail-safe: the verify script hard-fails on any unexpected suite.)
$proj = [System.IO.File]::ReadAllText($plcproj)
$prgNames = [regex]::Matches($proj, 'Compile Include="[^"]*(PRG_TEST_[A-Z0-9_]+)\.TcPOU"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach ($prg in $prgNames) {
    $blockRx = "(?s)(<Compile Include=`"[^`"]*$prg\.TcPOU`">)(.*?)(</Compile>)"
    $m = [regex]::Match($proj, $blockRx)
    if (-not $m.Success) { continue }
    $inner = $m.Groups[2].Value -replace '\s*<ExcludeFromBuild>true</ExcludeFromBuild>', ''
    if ($prg -ne $c.Prg) { $inner = $inner -replace '(<SubType>Code</SubType>)', "`$1`r`n      <ExcludeFromBuild>true</ExcludeFromBuild>" }
    $proj = $proj.Remove($m.Index, $m.Length).Insert($m.Index, $m.Groups[1].Value + $inner + $m.Groups[3].Value)
}
if ($Campaign -eq 'ABORT') {
    # Aborted runs never reach the TESTS FINISHED flush trigger; flush every entry
    # so the jsonl carries the terminal trace deterministically.
    $proj = [regex]::Replace($proj, '(<Key>SAVEENTRYTHRESHOLD</Key>\s*<Value>)\d+(</Value>)', '${1}1${2}')
    Write-Host "ABORT selection: SAVEENTRYTHRESHOLD forced to 1 (immediate flush)."
}
[System.IO.File]::WriteAllText($plcproj, $proj)
[xml]([System.IO.File]::ReadAllText($plcproj)) | Out-Null
Write-Host "Selected campaign $Campaign ($($c.Prg)) on TestTask1; all other test PRGs excluded from build."
if ($SelectOnly) { $KeepSelection = $true; $exitCode = 0; return }

# Step 2. PLC-side cleanup + log snapshot. Credentials come from the environment
# (review H1): STEP0_PLC_USER / STEP0_PLC_PASSWORD; an already-connected session
# is used as-is.
if (-not (Test-Path $plcBootUnc)) {
    if ($env:STEP0_PLC_PASSWORD) {
        $u = if ($env:STEP0_PLC_USER) { $env:STEP0_PLC_USER } else { 'Administrator' }
        net use '\\192.168.225.2\C$' /user:$u $env:STEP0_PLC_PASSWORD 2>&1 | Out-Null
    }
    if (-not (Test-Path $plcBootUnc)) { throw "PLC admin share unreachable; connect \\192.168.225.2\C$ or set STEP0_PLC_USER/STEP0_PLC_PASSWORD" }
}
$xunitUnc = Join-Path $plcBootUnc $xunitName
if (Test-Path $xunitUnc) { Remove-Item $xunitUnc -Force; Write-Host "Deleted stale $xunitName on PLC." }
else { Write-Host "No stale $xunitName on PLC (fresh)." }
$logMark = Get-Date

# Step 3. Build + deploy + run (+ collect for non-ABORT) via tpm
if (-not $ResultsOnly) {
    if ($Campaign -eq 'ABORT') {
        Write-Host "`n=== tpm deploy (ABORT) ==="
        & $tpmExe deploy $solution --target $targetAms
        if ($LASTEXITCODE -ne 0) { throw "tpm deploy exit $LASTEXITCODE" }
        Write-Host "`n=== A1 abort probe (pyads: window signal, flag write, latch) ==="
        & python (Join-Path $PSScriptRoot 'step0_abort_probe.py')
        if ($LASTEXITCODE -ne 0) { throw "abort probe failed" }
        Write-Host "checking flushed logs (SAVEENTRYTHRESHOLD=1 flushes per entry)..."
        Start-Sleep -Seconds 8
        $aborted = $false; $completed = $false; $summary = $false
        foreach ($f in @(Get-ChildItem $plcLogsUnc -Filter 'EventLog_*.jsonl' | Where-Object { $_.LastWriteTime -gt $logMark })) {
            $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt -match 'TEST RUN ABORTED') { $aborted = $true }
            if ($txt -match 'TEST RUN COMPLETED') { $completed = $true }
            if ($txt -match 'TESTS FINISHED') { $summary = $true }
        }
        $xunitAfterAbort = Test-Path $xunitUnc
        Write-Host "A1 terminal-outcome assertions (review R3): ABORTED=$aborted COMPLETED=$completed SUMMARY=$summary XUNIT=$xunitAfterAbort"
        $a1Pass = $aborted -and (-not $completed) -and (-not $summary) -and (-not $xunitAfterAbort)
        if ($xunitAfterAbort) { Remove-Item $xunitUnc -Force }
        if ($a1Pass) { Write-Host "CAMPAIGN VERDICT: PASS (A1: aborted terminal outcome is distinct - no completion trace, no summary, no xUnit)"; $exitCode = 0 }
        else { Write-Host "CAMPAIGN VERDICT: A1 terminal-outcome assertions failed" -ForegroundColor Red; $exitCode = 1 }
        return
    }
    Write-Host "`n=== tpm test ($Campaign/$Phase) ==="
    & $tpmExe test --config $tpmConfig
    Write-Host "=== tpm exit code: $LASTEXITCODE (nonzero is EXPECTED when the phase model contains failing tests) ==="
}

# Step 4. Fetch xUnit + verify (golden comparison is read-only unless -UpdateGolden)
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$verdicts = @()
if ($c.XUnit) {
    if (-not (Test-Path $xunitUnc)) { throw "$xunitName not produced on PLC" }
    $item = Get-Item $xunitUnc
    $hash = (Get-FileHash $xunitUnc -Algorithm SHA256).Hash.Substring(0, 16)
    Write-Host "xUnit freshness: created $($item.CreationTime), $($item.Length) bytes, sha256[0..16]=$hash"
    $local = Join-Path $resultsDir "$($Phase.ToLower())-$($Campaign.ToLower())-$xunitName"
    Copy-Item $xunitUnc $local -Force
    $args = @('-File', $verify, '-Path', $local, '-Campaign', $Campaign, '-Phase', $Phase)
    if ($UpdateGolden) { $args += '-UpdateGolden' }
    & pwsh @args
    $verdicts += @{ Name = 'xUnit model + golden'; Pass = ($LASTEXITCODE -eq 0) }
}

# Step 5. EventLog completion-marker check
Start-Sleep -Seconds 3
$started = $false; $completed = $false
foreach ($f in @(Get-ChildItem $plcLogsUnc -Filter 'EventLog_*.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $logMark })) {
    try { $txt = Get-Content $f.FullName -Raw -ErrorAction Stop } catch { continue }
    if ($txt -match 'TEST RUN STARTED') { $started = $true }
    if ($txt -match 'TEST RUN COMPLETED') { $completed = $true }
}
$expectCompleted = ($Phase -eq 'GREEN')
Write-Host "EventLog markers: STARTED=$started COMPLETED=$completed (expected COMPLETED=$expectCompleted)"
if (-not $started) { Write-Host "WARN  'TEST RUN STARTED' not found in flushed logs (scan-1 traces predate trace-pipeline readiness)" -ForegroundColor Yellow }
$verdicts += @{ Name = "'TEST RUN COMPLETED' trace matches phase"; Pass = ($completed -eq $expectCompleted) }

Write-Host "`n=== $Campaign/$Phase summary ==="
$fails = 0
foreach ($v in $verdicts) { $s = if ($v.Pass) { 'PASS' } else { $fails++; 'FAIL' }; Write-Host "  $s  $($v.Name)" }
if ($fails -eq 0) { Write-Host "CAMPAIGN VERDICT: PASS"; $exitCode = 0 } else { Write-Host "CAMPAIGN VERDICT: $fails check(s) FAILED" -ForegroundColor Red; $exitCode = 1 }

}
finally {
    if (-not $KeepSelection) {
        [System.IO.File]::WriteAllBytes($tcTTO, $snapTto)
        [System.IO.File]::WriteAllBytes($plcproj, $snapProj)
        Write-Host "Selection files restored byte-exact to pre-run state (transactional)."
    } else {
        Write-Host "KeepSelection: campaign selection left in place (diagnostic mode)."
    }
}
exit $exitCode
