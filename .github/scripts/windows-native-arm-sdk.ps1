param([Parameter(Mandatory=$true)][string]$OwnedPathHelper, [Parameter(Mandatory=$true)][string]$SourceRoot, [Parameter(Mandatory=$true)][string]$SourceRevision)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64') { throw 'This provider requires an actual native Windows ARM64 host' }
if ($SourceRevision -notmatch '^[0-9a-f]{40}$') { throw 'Invalid exact owning revision' }
$gitImage=(Get-Command git -CommandType Application -ErrorAction Stop).Source
$gitStream=[IO.FileStream]::new($gitImage,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$gitSHA=(Get-FileHash -LiteralPath $gitImage -Algorithm SHA256).Hash
function Metadata-Git([string[]]$arguments) {
  $info=[Diagnostics.ProcessStartInfo]::new($gitImage);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  foreach ($key in @($info.Environment.Keys)) { if ($key.StartsWith('GIT_', [StringComparison]::OrdinalIgnoreCase)) { $info.Environment.Remove($key)|Out-Null } }
  $info.ArgumentList.Add('-C');$info.ArgumentList.Add($SourceRoot);foreach ($arg in $arguments) {$info.ArgumentList.Add($arg)}
  $child=[Diagnostics.Process]::Start($info);$stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();$child.WaitForExit()
  try {if ($child.ExitCode -ne 0) {throw ('Owning metadata Git failed: '+$stderr.Result)};return $stdout.Result} finally {$child.Dispose()}
}
function Source-State {
  if (-not [IO.Path]::IsPathFullyQualified($SourceRoot)) {throw 'Owning root is not absolute'}
  $canonical=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
  $top=[IO.Path]::GetFullPath((Metadata-Git @('rev-parse','--show-toplevel')).Trim()).TrimEnd('\','/')
  if (-not [StringComparer]::OrdinalIgnoreCase.Equals($canonical,$top)) {throw 'Owning root differs from actual Git toplevel'}
  $rootItem=Get-Item -LiteralPath $SourceRoot -Force
  if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Foreign owning root'}
  $head=(Metadata-Git @('rev-parse','HEAD')).Trim();if ($head -ne $SourceRevision) {throw 'Foreign owning HEAD'}
  $tree=Metadata-Git @('ls-tree','-r','--full-tree','HEAD');$index=Metadata-Git @('ls-files','--stage');$status=Metadata-Git @('status','--porcelain')
  if ($status.Trim().Length) {throw 'Dirty owning source'}
  $treeRows=@($tree.Trim().Split("`n")|ForEach-Object {$_ -replace ' blob ', ' '});$indexRows=@($index.Trim().Split("`n")|ForEach-Object {$_ -replace ' 0\t', "`t"})
  if (($treeRows -join "`n") -ne ($indexRows -join "`n")) {throw 'Owning index differs from pinned tree'}
  $files=@()
  foreach($row in $index.Trim().Split("`n")) {
    if($row -notmatch '^([0-9]{6}) ([0-9a-f]{40}) 0\t(.*)$'){throw 'Unknown index entry'}
    $mode=$Matches[1];$oid=$Matches[2];$name=$Matches[3]
    if($name.StartsWith('"')){throw 'Quoted source pathname requires explicit qualification'}
    $path=Join-Path $SourceRoot $name;$item=Get-Item -LiteralPath $path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      if($mode -ne '120000' -or $null -eq $item.LinkTarget){throw 'Unexpected source reparse point'}
      $bytes=[Text.Encoding]::UTF8.GetBytes([string]$item.LinkTarget);$kind='link'
    } elseif($item.PSIsContainer){throw 'Tracked file replaced by directory'}
    else {$bytes=[IO.File]::ReadAllBytes($path);$kind='file';if($mode -notin @('100644','100755','120000')){throw 'Unknown source mode'}
      if($mode -eq '120000'){if((Metadata-Git @('config','--bool','--get','core.symlinks')).Trim() -ne 'false'){throw 'Undeclared regular-file symlink representation'};$kind='declared-core-symlinks-false-link-bytes'}
    }
    $header=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
    $blob=[byte[]]::new($header.Length+$bytes.Length);[Array]::Copy($header,$blob,$header.Length);[Array]::Copy($bytes,0,$blob,$header.Length,$bytes.Length)
    $actualOID=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($blob)).ToLowerInvariant()
    if($actualOID -ne $oid){throw ('Physical source differs from pinned blob: '+$name)}
    $files += [ordered]@{name=$name;mode=$mode;oid=$oid;kind=$kind;attributes=[int]$item.Attributes;length=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))}
  }
  [ordered]@{root=$canonical;head=$head;tree=$tree;index=$index;files=$files} | ConvertTo-Json -Depth 7 -Compress
}
$sourceBefore=Source-State
$helper=[IO.FileStream]::new($OwnedPathHelper,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$helperBytes=[byte[]]::new($helper.Length)
$read=0
while ($read -lt $helperBytes.Length) { $n=$helper.Read($helperBytes,$read,$helperBytes.Length-$read); if ($n -eq 0) { throw 'Incomplete held helper' }; $read += $n }
$helperSHA=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($helperBytes)).ToLowerInvariant()
if ($helperSHA -ne '10a232fbec8a9c8a16797aa21bc298b914ad7d3721a3201019347d3e7c1f16db') { throw 'Unknown native held-path helper image' }
. ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString($helperBytes)))
$root=Join-Path $env:RUNNER_TEMP ('everywhere-arm-sdk-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
$rootHold=[NativePythonOwnedPath]::new($root,$false)
$holds=[Collections.Generic.List[IDisposable]]::new()
$holds.Add($helper);$holds.Add($rootHold);$holds.Add($gitStream)
function Hash-File([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Tree([string]$path) {
  $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($path);$rows=@()
  while ($queue.Count) {
    $d=$queue.Dequeue();$di=Get-Item -LiteralPath $d -Force
    if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse directory in native SDK' }
    foreach ($entry in Get-ChildItem -LiteralPath $d -Force) {
      if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse member in native SDK' }
      $rel=[IO.Path]::GetRelativePath($path,$entry.FullName).Replace('\','/')
      if ($entry.PSIsContainer) { $rows += [ordered]@{name=$rel;kind='directory';identity=Get-NativeIdentity $entry.FullName};$queue.Enqueue($entry.FullName) }
      else { $rows += [ordered]@{name=$rel;kind='file';identity=Get-NativeIdentity $entry.FullName;size=$entry.Length;sha256=Hash-File $entry.FullName} }
    }
  }
  @($rows | Sort-Object name) | ConvertTo-Json -Depth 5 -Compress
}
function Protect-InputTree([string]$path) {
  $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($path)
  while($queue.Count){$d=$queue.Dequeue();$item=Get-Item -LiteralPath $d -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse input directory'}
    $holds.Add([NativePythonOwnedPath]::new($d,$false))
    foreach($entry in Get-ChildItem -LiteralPath $d -Force){if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse input member'}
      if($entry.PSIsContainer){$queue.Enqueue($entry.FullName)}else{$holds.Add([IO.FileStream]::new($entry.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
    }
  }
}
function Require-PE([string]$path,[uint16]$machine) {
  $item=Get-Item -LiteralPath $path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Foreign compiler image' }
  $hold=[NativePythonOwnedPath]::new($path,$false);$holds.Add($hold)
  $imageStream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($imageStream)
  $b=[byte[]]::new($imageStream.Length);$count=0
  while ($count -lt $b.Length) { $n=$imageStream.Read($b,$count,$b.Length-$count);if ($n -eq 0) {throw 'Incomplete held PE image'};$count += $n }
  if ($b.Length -lt 64 -or $b[0] -ne 77 -or $b[1] -ne 90) { throw 'Missing PE signature' }
  $off=[BitConverter]::ToInt32($b,60)
  if ($off -lt 0 -or $off+6 -gt $b.Length -or [BitConverter]::ToUInt32($b,$off) -ne 17744 -or [BitConverter]::ToUInt16($b,$off+4) -ne $machine) { throw 'Wrong native image architecture' }
  [ordered]@{path=$path;machine=$machine;sha256=Hash-File $path;fileId=$hold.Identity()}
}
$canonicalAuthority=@{
  'llvm'=@{count=9298;digest='a14410c4df537b78c2d710ced4fa8485f0dab788e94ab7f6f7336af5b42da05b'}
  'just'=@{count=14;digest='bf9c3ddcd1f41ed4c31f278efedb03a44c4bbd936ac605f98c81b75d534acbd7'}
  'nim-source'=@{count=5832;digest='2304111131e48f84ce81ce5543369a6afa02c6f0da526a812dc34d5e76147673'}
}
function Canonical-Payload([object[]]$rows) {
  $names=[Collections.Generic.List[string]]::new();$byName=@{}
  foreach($row in $rows){$names.Add($row.name);$byName[$row.name]=$row}
  $names.Sort([StringComparer]::Ordinal);$body=[Text.StringBuilder]::new()
  foreach($name in $names){$row=$byName[$name];if($name.Contains("`t") -or $name.Contains("`n") -or $name.Contains("`r")){throw 'Unsupported canonical archive name'}
    if($row.kind -eq 'directory'){$null=$body.Append("D`t$name`n")}else{$null=$body.Append("F`t$name`t$($row.size)`t$($row.sha256)`n")}
  }
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body.ToString()))).ToLowerInvariant()
}
function Acquire([string]$name,[string]$url,[string]$sha) {
  $archive=Join-Path $root ($name+'.zip')
  Invoke-WebRequest -Uri $url -OutFile $archive -UserAgent 'Metacraft-Everywhere-ARM-Provider/1.0'
  $archiveStream=[IO.FileStream]::new($archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($archiveStream)
  if ((Hash-File $archive) -ne $sha) { throw 'Official archive checksum mismatch' }
  $archiveHold=[NativePythonOwnedPath]::new($archive,$false);$holds.Add($archiveHold)
  $dest=Join-Path $root $name
  $expected=@{};$names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $encoding=[Text.Encoding]::GetEncoding(437)
  $z=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Read,$encoding)
  try {
    foreach ($entry in $z.Entries) {
      $nameParts=$entry.FullName.Replace('\','/').Split('/')
      if ($entry.FullName.Replace('\','/').StartsWith('/') -or $entry.FullName.Contains(':') -or $nameParts.Contains('..') -or $nameParts.Contains('.')) { throw 'Unsafe official archive entry' }
      $relative=$entry.FullName.Replace('\','/').TrimEnd('/')
      if (-not $names.Add($relative)) {throw 'Duplicate or case-colliding archive entry'}
      $directory=$entry.FullName.EndsWith('/')
      $parent=$relative
      while ($parent.Contains('/')) {$parent=$parent.Substring(0,$parent.LastIndexOf('/'));if(-not $expected.ContainsKey($parent)){$expected[$parent]=@{kind='directory'}}}
      if ($directory) {$expected[$relative]=@{kind='directory'}} else {
        $view=$entry.Open();try {$digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($view)).ToLowerInvariant()}finally{$view.Dispose()}
        $expected[$relative]=@{kind='file';size=$entry.Length;sha256=$digest}
      }
      $mode=($entry.ExternalAttributes -shr 16) -band 61440
      if ($mode -notin @(0,16384,32768)) { throw 'Foreign type in official archive' }
    }
  } finally { $z.Dispose() }
  [IO.Compression.ZipFile]::ExtractToDirectory($archive,$dest,$encoding)
  $actual=Tree $dest | ConvertFrom-Json
  if (@($actual).Count -ne $expected.Count) {throw 'Extracted package membership differs from full archive'}
  foreach ($row in $actual) {if(-not $expected.ContainsKey($row.name)){throw 'Unknown extracted member'};$known=$expected[$row.name]
    if($row.kind -ne $known.kind -or ($row.kind -eq 'file' -and ($row.size -ne $known.size -or $row.sha256 -ne $known.sha256))){throw 'Extracted member differs from immutable archive'}
  }
  if(@($actual).Count -ne $canonicalAuthority[$name].count -or (Canonical-Payload @($actual)) -ne $canonicalAuthority[$name].digest){throw 'Extracted source differs from independently canonical official archive authority'}
  $destHold=[NativePythonOwnedPath]::new($dest,$false);$holds.Add($destHold)
  Protect-InputTree $dest
  [ordered]@{archive=$archive;archiveSHA=$sha;root=$dest;fileId=$destHold.Identity();tree=Tree $dest}
}
$sourceHold=[NativePythonOwnedPath]::new($SourceRoot,$false);$holds.Add($sourceHold);$sourceId=$sourceHold.Identity()
$scriptHold=[IO.FileStream]::new($PSCommandPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($scriptHold);$scriptSHA=Hash-File $PSCommandPath
$activeStageChild=$null
$unresolvedStageOwner=$false
function Run-Stage([string]$label,[string]$exe,[string[]]$arguments) {
  $outPath=Join-Path $root ($label+'.stdout');$errPath=Join-Path $root ($label+'.stderr')
  $out=$null;$err=$null;$child=$null
  $row=[ordered]@{name=$label;exe=$exe;argv=$arguments;workingDirectory=$root;stdout=$outPath;stderr=$errPath;started=$false;terminal=$false;pid=$null;birthUTC=$null;exit=$null;descendantScope='Not census qualified; direct process naturally waited only'}
  $record=[IO.FileStream]::new((Join-Path $root ($label+'.ownership.json')),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  function Save-Stage {
    $bytes=[Text.Encoding]::UTF8.GetBytes(($row|ConvertTo-Json -Depth 8));$record.Position=0;$record.SetLength(0);$record.Write($bytes,0,$bytes.Length);$record.Flush($true)
  }
  try {
    $row.imageSHA=Hash-File $exe;Save-Stage
    $out=[IO.FileStream]::new($outPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $err=[IO.FileStream]::new($errPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $info=[Diagnostics.ProcessStartInfo]::new($exe);$info.WorkingDirectory=$root;$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($info);$script:activeStageChild=$child
    $row.started=$true;$row.pid=$child.Id;Save-Stage
    $row.birthUTC=$child.StartTime.ToUniversalTime().Ticks;Save-Stage
    $outCopy=$child.StandardOutput.BaseStream.CopyToAsync($out);$errCopy=$child.StandardError.BaseStream.CopyToAsync($err)
    $child.WaitForExit();$row.exit=$child.ExitCode;$row.terminal=$true;Save-Stage
    $outCopy.GetAwaiter().GetResult();$errCopy.GetAwaiter().GetResult();$out.Flush($true);$err.Flush($true)
    $out.Dispose();$out=$null;$err.Dispose();$err=$null
    $row.stdoutSHA=Hash-File $outPath;$row.stderrSHA=Hash-File $errPath;Save-Stage
    $row.imageAfterSHA=Hash-File $exe;Save-Stage
    if($row.imageAfterSHA -ne $row.imageSHA){throw 'Selected stage image changed'}
    if($row.exit -ne 0){throw ('Native stage failed: '+$label)}
    [IO.File]::ReadAllText($outPath)
  } catch {
    $row.failure=$_.Exception.Message
    if($null -ne $child){try {$row.terminal=$child.HasExited;if($row.terminal){$row.exit=$child.ExitCode}}catch{$row.terminal=$false}}
    if($row.started -and -not $row.terminal){$script:unresolvedStageOwner=$true;$row.unresolvedDirectOwner=$true}
    try {Save-Stage} catch {$script:unresolvedStageOwner=$true}
    throw
  } finally {
    $receipt.stages += $row
    if($null -eq $child -or $row.terminal){if($out){$out.Dispose()};if($err){$err.Dispose()};if($child){$child.Dispose()};$script:activeStageChild=$null;$record.Dispose()}
  }
}
$receipt=[ordered]@{sourceBefore=$sourceBefore;scriptSHA=$scriptSHA;helperSHA=$helperSHA;gitSHA=$gitSHA;success=$false;root=$root;rootId=$rootHold.Identity();scope='Actual native provider construction; original monitored/native corpus remains required';stages=@()}
try {
  $llvm=Acquire 'llvm' 'https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/llvm-mingw-20261006-ucrt-aarch64.zip' '9a835d5179c9f3a5a783c11a7f14062a249b4765dd11add64a66786864e82ab2'
  $just=Acquire 'just' 'https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-aarch64-pc-windows-msvc.zip' '12bf56b5b3463e20a1dbb61e3d14748efaefb49231223ef465fbec4d442e2d20'
  $nim=Acquire 'nim-source' 'https://nim-lang.org/download/nim-2.2.10_x64.zip' 'fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f'
  $clang=Join-Path $llvm.root 'llvm-mingw-20261006-ucrt-aarch64/bin/clang.exe'
  $clangIdentity=Require-PE $clang 43620
  if ($clangIdentity.sha256 -ne 'b9d8bae85fff7df611c1ef2f9ad293f42b4b85e1802cc06d39d411ce1582e0cc') { throw 'Unknown ARM compiler wrapper' }
  $target=(Run-Stage 'clang-target' $clang @('-dumpmachine')).Trim();if ( $target -notmatch '^aarch64-.*(mingw32|windows-gnu)$') { throw 'Wrong ARM compiler target' }
  $version=Run-Stage 'clang-version' $clang @('--version');if ( $version -notmatch 'clang version (\d+)' -or [int]$Matches[1] -lt 14) { throw 'ARM compiler floor not met' }
  $justExe=Join-Path $just.root 'just.exe';$justIdentity=Require-PE $justExe 43620
  $justVersion=(Run-Stage 'just-version' $justExe @('--version')).Trim();if ( $justVersion -ne 'just 1.51.0') { throw 'Wrong native just version' }
  $input=Join-Path $nim.root 'nim-2.2.10';$bootstrap=Join-Path $input 'bin/nim.exe';$bootstrapIdentity=Require-PE $bootstrap 34404
  if ($bootstrapIdentity.sha256 -ne 'ab1bcd5a479e81d2f3c58839b0654a97599aa8c2b015f6b021d6943d5f5b55a2') { throw 'Unknown compatibility bootstrap' }
  $native=Join-Path $root 'native-nim';New-Item -ItemType Directory -Path (Join-Path $native 'bin') | Out-Null
  Copy-Item -LiteralPath (Join-Path $input 'lib') -Destination $native -Recurse
  Copy-Item -LiteralPath (Join-Path $input 'config') -Destination $native -Recurse
  foreach($part in @('lib','config')) {
    $original=Tree (Join-Path $input $part)|ConvertFrom-Json;$copied=Tree (Join-Path $native $part)|ConvertFrom-Json
    $originalBodies=@($original|Select-Object name,kind,size,sha256)|ConvertTo-Json -Depth 5 -Compress;$copiedBodies=@($copied|Select-Object name,kind,size,sha256)|ConvertTo-Json -Depth 5 -Compress
    if($originalBodies -ne $copiedBodies){throw 'Native frontend stdlib/config differs from immutable sources'}
  }
  $nativeHold=[NativePythonOwnedPath]::new($native,$false);$holds.Add($nativeHold)
  $nativeNim=Join-Path $native 'bin/nim.exe'
  Run-Stage 'native-frontend-build' $bootstrap @('c','--skipUserCfg','--skipParentCfg','--cpu:arm64','--os:windows','--cc:clang',"--clang.exe:$clang","--clang.linkerexe:$clang","--lib:$(Join-Path $input 'lib')","--nimcache:$(Join-Path $root 'compiler-cache')","--out:$nativeNim",(Join-Path $input 'compiler/nim.nim')) | Out-Null
  $nativeIdentity=Require-PE $nativeNim 43620
  $nativeTreeBefore=Tree $native
  Protect-InputTree $native
  $nativeVersion=Run-Stage 'native-frontend-version' $nativeNim @('--version');if ( $nativeVersion -notmatch 'Version 2\.2\.10.*Windows: arm64') { throw 'Native frontend version/architecture mismatch' }
  $probe=Join-Path $root 'roundtrip.nim';[IO.File]::WriteAllText($probe,'echo "native-arm-roundtrip"')
  $probeExe=Join-Path $root 'roundtrip.exe'
  Run-Stage 'native-roundtrip-build' $nativeNim @('c','--skipUserCfg','--skipParentCfg','--cc:clang',"--clang.exe:$clang","--clang.linkerexe:$clang","--nimcache:$(Join-Path $root 'probe-cache')","--out:$probeExe",$probe) | Out-Null
  $probeIdentity=Require-PE $probeExe 43620
  $output=(Run-Stage 'native-roundtrip-run' $probeExe @()).Trim();if ( $output -ne 'native-arm-roundtrip') { throw 'Native ARM runtime roundtrip failed' }
  if((Tree $native) -ne $nativeTreeBefore){throw 'Native frontend stdlib/config/runtime changed'}
  foreach ($package in @($llvm,$just,$nim)) { if ((Tree $package.root) -ne $package.tree -or (Hash-File $package.archive) -ne $package.archiveSHA) { throw 'Acquired input source/runtime changed' } }
  if ((Get-NativeIdentity $root) -ne $rootHold.Identity()) { throw 'Native SDK root changed' }
  foreach ($role in @($clangIdentity,$justIdentity,$bootstrapIdentity,$nativeIdentity,$probeIdentity)) { if ((Hash-File $role.path) -ne $role.sha256 -or (Get-NativeIdentity $role.path) -ne $role.fileId) {throw 'Native image authority changed'} }
  if ((Source-State) -ne $sourceBefore -or (Get-NativeIdentity $SourceRoot) -ne $sourceId -or (Hash-File $PSCommandPath) -ne $scriptSHA -or (Get-FileHash -LiteralPath $gitImage -Algorithm SHA256).Hash -ne $gitSHA) {throw 'Owning source/tool authority changed'}
  $receipt.sourceAfter=Source-State;$receipt.nativeFrontendPayload=$nativeTreeBefore;$receipt.packages=@($llvm,$just,$nim)
  $receipt.nativeCompiler=$clangIdentity;$receipt.nativeFrontend=$nativeIdentity;$receipt.compatibilityBootstrap=$bootstrapIdentity;$receipt.nativeJust=$justIdentity;$receipt.nativeProbe=$probeIdentity;$receipt.target=$target;$receipt.success=$true
  $receiptFile=Join-Path $root 'provider.json';$stream=[IO.FileStream]::new($receiptFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try { $b=[Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 10));$stream.Write($b,0,$b.Length);$stream.Flush($true) } finally {$stream.Dispose()}
  Add-Content -LiteralPath $env:GITHUB_ENV -Value "EVERYWHERE_NATIVE_ARM_CLANG=$clang"
  Add-Content -LiteralPath $env:GITHUB_PATH -Value (Join-Path $native 'bin')
  Add-Content -LiteralPath $env:GITHUB_PATH -Value $just.root
  Add-Content -LiteralPath $env:GITHUB_PATH -Value (Split-Path $clang)
} catch {
  $receipt.failure=$_.Exception.Message
  $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'provider-failure.json')
  throw
} finally { if(-not $unresolvedStageOwner -and $null -eq $activeStageChild){foreach ($h in $holds){$h.Dispose()}} }
