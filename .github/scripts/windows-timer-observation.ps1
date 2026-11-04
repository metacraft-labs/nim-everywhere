$ErrorActionPreference = 'Stop'
function FileSha([string] $Path) {
  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  $stream = $null
  try {
    $stream = [System.IO.File]::OpenRead($Path)
    return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
    $algorithm.Dispose()
  }
}
$root = (Get-Location).Path
$destination = Join-Path $root '.repro/windows-timer-observation'
New-Item -ItemType Directory -Force $destination | Out-Null
$proof = @{ diagnosticOnly = $true; root = $root; sourceHead = (& git rev-parse HEAD).Trim(); files = @{} }
try {
  foreach ($relative in @('.github/diagnostics/timer_observation.nim', 'tests/test_time_facade.nim', 'src/nim_everywhere/time.nim', 'config.nims', 'repro.nim', 'repro.lock', 'flake.lock')) {
    $path = Join-Path $root $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) { $proof.files[$relative] = FileSha $path }
  }
  $commands = @(Get-Command nim -CommandType Application -All -ErrorAction Stop)
  if ($commands.Count -lt 1) { throw 'No native Nim application is present' }
  $nim = $commands[0].Source
  $proof.nim = @{ path = $nim; sha256 = FileSha $nim }
  $source = '.github/diagnostics/timer_observation.nim'
  $binary = Join-Path $destination 'timer_observation.exe'
  $cache = Join-Path $destination 'nimcache'
  $argv = @('c', '-r', '--path:src', "--nimcache:$cache", "--out:$binary", $source)
  $proof.argv = $argv
  $ErrorActionPreference = 'Continue'
  try {
    & $nim @argv 2>&1 | Tee-Object -FilePath (Join-Path $destination 'native-output.log')
    $proof.exit = $LASTEXITCODE
  } finally { $ErrorActionPreference = 'Stop' }
  $rows = @(Get-Content (Join-Path $destination 'native-output.log') | Where-Object { $_ -match '^\{' })
  if ($rows.Count -ne 1) { throw 'Expected one genuine timer observation JSON record' }
  $observation = $rows[0] | ConvertFrom-Json
  $proof.observation = $observation
  $proof.configs = @{}
  foreach ($line in Get-Content (Join-Path $destination 'native-output.log')) {
    if ($line -match "used config file '([^']+)' \[Conf\]") {
      $configPath = $Matches[1]
      $proof.configs[$configPath] = FileSha $configPath
    }
  }
  if ([System.IO.Path]::GetFullPath($observation.compilerAtBuild) -ne [System.IO.Path]::GetFullPath($nim)) { throw 'Compiled diagnostic used another Nim' }
  $proof.stdlib = @{}
  foreach ($relative in @('pure/times.nim', 'std/monotimes.nim', 'pure/asyncdispatch.nim', 'system.nim')) {
    $path = Join-Path $observation.libraryAtBuild $relative
    $proof.stdlib[$relative] = @{ path = $path; sha256 = FileSha $path }
  }
  $proof.binarySha256 = FileSha $binary
} catch {
  $proof.failure = $_.Exception.Message
} finally {
  $proof.finalHead = (& git rev-parse HEAD).Trim()
  $proof.finalFiles = @{}
  foreach ($relative in $proof.files.Keys) { $proof.finalFiles[$relative] = FileSha (Join-Path $root $relative) }
  $proof.sourceUnchanged = $proof.finalHead -eq $proof.sourceHead
  foreach ($relative in $proof.files.Keys) { if ($proof.files[$relative] -ne $proof.finalFiles[$relative]) { $proof.sourceUnchanged = $false } }
  if (-not $proof.sourceUnchanged) { $proof.failure = 'Measured source changed during diagnostic' }
  $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $destination 'proof.json')
}
if ($proof.ContainsKey('failure')) { throw $proof.failure }
if ($proof.exit -ne 0) { exit $proof.exit }
