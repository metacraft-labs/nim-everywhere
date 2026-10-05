$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Native Windows Node setup requires Windows' }
$actualArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
$arch = switch ($actualArch) { 'X64' { 'x64' }; 'Arm64' { 'arm64' }; default { throw 'Unsupported native Node architecture' } }
if (($env:RUNNER_ARCH -eq 'X64' -and $arch -ne 'x64') -or ($env:RUNNER_ARCH -eq 'ARM64' -and $arch -ne 'arm64')) { throw 'Runner and native process architectures differ' }
if ($env:RUNNER_ARCH -notin @('X64','ARM64') -or -not $env:GITHUB_PATH) { throw 'Missing supported runner architecture or PATH publication file' }
$version = '24.14.0'
$expectedHash = if ($arch -eq 'x64') { '313fa40c0d7b18575821de8cb17483031fe07d95de5994f6f435f3b345f85c66' } else { '88d36e8109736a2fa9bdc596f2cf507a3c52c69cdf96e54f8acd473ec14be853' }
$expectedMachine = if ($arch -eq 'x64') { 0x8664 } else { 0xAA64 }
function HashFile([string]$path) {
    AssertPlain $path
    if (-not [System.IO.File]::Exists($path)) { throw 'Declared Node authority is not a regular file' }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try { $stream = [System.IO.File]::OpenRead($path); return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { if ($null -ne $stream) { $stream.Dispose() }; $algorithm.Dispose() }
}
function AssertPlain([string]$path) {
    $item = Get-Item -LiteralPath $path -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse path in native Node authority' }
        $parent = [System.IO.Directory]::GetParent($item.FullName)
        $item = if ($null -ne $parent) { Get-Item -LiteralPath $parent.FullName -Force } else { $null }
    }
}
$sourceRoot = (Get-Item -LiteralPath $env:GITHUB_WORKSPACE).FullName
if ((Get-Location).Path -ne $sourceRoot) { throw 'Foreign owning source cwd' }
AssertPlain $sourceRoot
$sourceHead = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceHead -ne $env:GITHUB_SHA) { throw 'Owning tested source HEAD mismatch' }
$sourceFiles = @{}
foreach ($name in @('repro.nim','repro.lock','flake.lock','config.nims','.github/scripts/setup-native-node.ps1','.github/workflows/ci-reprobuild.yml')) { $sourceFiles[$name] = HashFile (Join-Path $sourceRoot $name) }
AssertPlain $env:RUNNER_TEMP
$jobRoot = Join-Path $env:RUNNER_TEMP ('nim-everywhere-native-node-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $jobRoot) { throw 'Native Node root already exists' }
$null = New-Item -ItemType Directory -Path $jobRoot
$asset = 'node-v' + $version + '-win-' + $arch
$url = 'https://nodejs.org/dist/v' + $version + '/' + $asset + '.zip'
$archive = Join-Path $jobRoot 'node.zip'
Invoke-WebRequest -Uri $url -OutFile $archive
if ((HashFile $archive) -ne $expectedHash) { throw 'Official native Node archive hash mismatch' }
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName.Replace('\','/')
        if (-not $name.StartsWith($asset + '/', [System.StringComparison]::Ordinal) -or $name.Split('/') -contains '..' -or $name.Split('/') -contains '.') { throw 'Foreign or escaping archive member' }
    }
} finally { $zip.Dispose() }
Expand-Archive -LiteralPath $archive -DestinationPath $jobRoot
$prefix = Join-Path $jobRoot $asset
$node = Join-Path $prefix 'node.exe'
AssertPlain $node
$bytes = [System.IO.File]::ReadAllBytes($node)
if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Node executable lacks PE DOS header' }
$peOffset = [System.BitConverter]::ToInt32($bytes, 60)
if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length -or [System.BitConverter]::ToUInt32($bytes,$peOffset) -ne 0x4550) { throw 'Node executable PE signature invalid' }
$machine = [System.BitConverter]::ToUInt16($bytes,$peOffset + 4)
if ($machine -ne $expectedMachine) { throw 'Node executable is not the native architecture' }
$nativeVersion = (& $node --version).Trim()
if ($LASTEXITCODE -ne 0 -or $nativeVersion -ne ('v' + $version)) { throw 'Node native version mismatch' }
$probe = & $node -e 'process.stdout.write("node-native-ok")'
if ($LASTEXITCODE -ne 0 -or $probe -ne 'node-native-ok') { throw 'Genuine Node JS probe failed' }
$manifest = @{}
foreach ($file in Get-ChildItem -LiteralPath $prefix -Recurse -File) { AssertPlain $file.FullName; $manifest[$file.FullName.Substring($prefix.Length + 1)] = HashFile $file.FullName }
foreach ($name in $sourceFiles.Keys) { if ((HashFile (Join-Path $sourceRoot $name)) -ne $sourceFiles[$name]) { throw 'Owning source changed during Node provisioning' } }
if ((& git rev-parse HEAD).Trim() -ne $sourceHead) { throw 'Owning source HEAD changed during Node provisioning' }
$proofRoot = Join-Path $sourceRoot '.repro/windows-native-provenance'
AssertPlain (Join-Path $sourceRoot '.repro')
if (Test-Path -LiteralPath $proofRoot) { AssertPlain $proofRoot; if (-not (Get-Item -LiteralPath $proofRoot).PSIsContainer) { throw 'Native Node proof root is not a directory' } }
$null = New-Item -ItemType Directory -Force -Path $proofRoot
AssertPlain $proofRoot
@{ sourceHead=$sourceHead; sourceFiles=$sourceFiles; archiveUrl=$url; archiveSHA256=$expectedHash; nativeArchitecture=$actualArch; executable=$node; executableSHA256=(HashFile $node); machine=$machine; version=$nativeVersion; probe=$probe; manifest=$manifest } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $proofRoot 'native-node-sdk.json') -Encoding utf8NoBOM
Add-Content -LiteralPath $env:GITHUB_PATH -Value $prefix -Encoding utf8NoBOM
Write-Output ('Verified owning native Node ' + $nativeVersion + ' ' + $actualArch)
