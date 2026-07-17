param(
    [Parameter(Mandatory = $true)][ValidateSet('REGRESSION', 'COUNTS', 'EDGE', 'ABORT')][string]$Campaign,
    [Parameter(Mandatory = $true)][ValidateSet('RED', 'GREEN')][string]$Phase,
    [switch]$SelectOnly,   # rewire campaign selection only; no build/deploy/verify
    [switch]$ResultsOnly,  # skip build/deploy; fetch + verify existing outputs
    [switch]$Restore       # restore selection files to git HEAD and exit
)

$ErrorActionPreference = 'Stop'

# --- Fixed environment ---
$twcTests   = 'C:\Users\scott\Documents\TwinCAT_Tests'
$tcTTO      = Join-Path $twcTests 'TwinCAT_Tests\TwinCAT_Tests\TestTask1.TcTTO'
$plcproj    = Join-Path $twcTests 'TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests.plcproj'
$tpmExe     = 'C:\Users\scott\Documents\ToolPackageManager\src\ToolPackageManager.Cli\bin\Release\net8.0-windows\ToolPackageManager.Cli.exe'
$tpmConfig  = Join-Path $twcTests 'tpm.json'
$verify     = Join-Path $PSScriptRoot 'Verify-StepZeroXUnit.ps1'
$resultsDir = Join-Path $PSScriptRoot 'results'
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

# --- Step 1: campaign selection via file surgery ---
# 1a. Point TestTask1 at the campaign PRG
$tto = Get-Content $tcTTO -Raw
$newTto = [regex]::Replace($tto, '(<PouCall>\s*<Name>)[^<]+(</Name>)', "`${1}$($c.Prg)`${2}")
if ($newTto -notmatch [regex]::Escape($c.Prg)) { Write-Host "FAIL  could not set PouCall in TestTask1.TcTTO" -ForegroundColor Red; exit 1 }
Set-Content -Path $tcTTO -Value $newTto -NoNewline -Encoding UTF8

# 1b. Exclude every other test PRG from build; include only the campaign PRG.
#     (ExcludeFromBuild is validated empirically: the verify script hard-fails on any
#      unexpected suite, so a wrong exclusion mechanism cannot produce a false pass.)
$proj = Get-Content $plcproj -Raw
$prgNames = [regex]::Matches($proj, 'Compile Include="[^"]*(PRG_TEST_[A-Z0-9_]+)\.TcPOU"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Write-Host "Test PRGs in project: $($prgNames -join ', ')"
foreach ($prg in $prgNames) {
    $blockRx = "(?s)(<Compile Include=`"[^`"]*$prg\.TcPOU`">)(.*?)(</Compile>)"
    $m = [regex]::Match($proj, $blockRx)
    if (-not $m.Success) { continue }
    $inner = $m.Groups[2].Value -replace '\s*<ExcludeFromBuild>true</ExcludeFromBuild>', ''
    if ($prg -ne $c.Prg) { $inner = $inner -replace '(<SubType>Code</SubType>)', "`$1`r`n      <ExcludeFromBuild>true</ExcludeFromBuild>" }
    $proj = $proj.Remove($m.Index, $m.Length).Insert($m.Index, $m.Groups[1].Value + $inner + $m.Groups[3].Value)
}
Set-Content -Path $plcproj -Value $proj -NoNewline -Encoding UTF8
try { [xml](Get-Content $plcproj -Raw) | Out-Null } catch { Write-Host "FAIL  plcproj XML broken after edit: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
Write-Host "Selected campaign $Campaign ($($c.Prg)) on TestTask1; all other test PRGs excluded from build."
if ($SelectOnly) { exit 0 }

# --- Step 2: PLC-side cleanup + log snapshot ---
net use $plcBootUnc.Substring(0, $plcBootUnc.IndexOf('\', 2)) 2>&1 | Out-Null
net use '\\192.168.225.2\C$' /user:Administrator 1 2>&1 | Out-Null
$xunitUnc = Join-Path $plcBootUnc $xunitName
if (Test-Path $xunitUnc) { Remove-Item $xunitUnc -Force; Write-Host "Deleted stale $xunitName on PLC." }
else { Write-Host "No stale $xunitName on PLC (fresh)." }
$logMark = Get-Date
$preLogs = @(Get-ChildItem $plcLogsUnc -Filter 'EventLog_*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1)

# --- Step 3: build + deploy + run + collect via tpm ---
$exitTpm = 0
if (-not $ResultsOnly) {
    Write-Host "`n=== tpm test ($Campaign/$Phase) ==="
    & $tpmExe test --config $tpmConfig
    $exitTpm = $LASTEXITCODE
    Write-Host "=== tpm exit code: $exitTpm (nonzero is EXPECTED when the phase model contains failing tests) ==="
    if ($Campaign -eq 'ABORT') {
        Write-Host @"

ABORT campaign deployed and running. MANUAL steps now (deterministic 5-minute window):
  1. In XAE online view confirm AllTestSuitesFinished = FALSE and 'TEST RUN STARTED' trace present.
  2. Online-write TcUnit.GVL_TcUnit.TcUnitRunner.AbortRunningTestSuites := TRUE.
  3. Expect: AllTestSuitesFinished latches TRUE promptly; 'TEST RUN ABORTED' trace appears.
  4. Record A1; no xUnit/summary expected. Delete any $xunitName on the PLC afterward.
"@
        exit 0
    }
}

# --- Step 4: fetch xUnit + verify ---
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$verdicts = @()
if ($c.XUnit) {
    if (-not (Test-Path $xunitUnc)) { Write-Host "FAIL  $xunitName not produced on PLC" -ForegroundColor Red; exit 1 }
    $item = Get-Item $xunitUnc
    $hash = (Get-FileHash $xunitUnc -Algorithm SHA256).Hash.Substring(0, 16)
    Write-Host "xUnit freshness: created $($item.CreationTime), $($item.Length) bytes, sha256[0..16]=$hash"
    $local = Join-Path $resultsDir "$($Phase.ToLower())-$($Campaign.ToLower())-$xunitName"
    Copy-Item $xunitUnc $local -Force
    $args = @('-File', $verify, '-Path', $local, '-Campaign', $Campaign, '-Phase', $Phase)
    if ($Phase -eq 'GREEN' -and $Campaign -in @('REGRESSION', 'COUNTS')) {
        $args += @('-OutCanonical', (Join-Path $PSScriptRoot "goldens\2026-07-17-step0-$($Campaign.ToLower())-canonical.xml"))
        New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'goldens') | Out-Null
    }
    & pwsh @args
    $verdicts += @{ Name = 'xUnit model'; Pass = ($LASTEXITCODE -eq 0) }
}

# --- Step 5: EventLog marker check (replaces manual online latch observation) ---
Start-Sleep -Seconds 3
$logs = @(Get-ChildItem $plcLogsUnc -Filter 'EventLog_*.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $logMark -or ($preLogs -and $_.Name -eq $preLogs[0].Name) })
$started = $false; $completed = $false
foreach ($f in $logs) {
    try { $txt = Get-Content $f.FullName -Raw -ErrorAction Stop } catch { continue }
    if ($txt -match 'TEST RUN STARTED') { $started = $true }
    if ($txt -match 'TEST RUN COMPLETED') { $completed = $true }
}
$expectCompleted = ($Phase -eq 'GREEN')
Write-Host "EventLog markers: STARTED=$started COMPLETED=$completed (expected COMPLETED=$expectCompleted - the completion latch drives this trace)"
# STARTED is informational only: it fires at activation and can predate file-handler
# readiness on sub-second campaigns (observed COUNTS/RED 2026-07-17). Run evidence is
# already established by collected results + fresh xUnit.
if (-not $started) { Write-Host "WARN  'TEST RUN STARTED' trace not found in flushed logs (flush-latency artifact on fast campaigns)" -ForegroundColor Yellow }
$verdicts += @{ Name = "'TEST RUN COMPLETED' trace matches phase"; Pass = ($completed -eq $expectCompleted) }

# --- Summary ---
Write-Host "`n=== $Campaign/$Phase summary ==="
$fails = 0
foreach ($v in $verdicts) { $s = if ($v.Pass) { 'PASS' } else { $fails++; 'FAIL' }; Write-Host "  $s  $($v.Name)" }
if ($fails -eq 0) { Write-Host "CAMPAIGN VERDICT: PASS"; exit 0 } else { Write-Host "CAMPAIGN VERDICT: $fails check(s) FAILED" -ForegroundColor Red; exit 1 }
