$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = 'https://github.com/krakjn/recurse/releases/latest/download'
$name = 'recurse-x86_64-windows'
$archive = "$name.zip"
$dest = Join-Path $env:LOCALAPPDATA 'recurse\bin'

$cpu = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $cpu = $env:PROCESSOR_ARCHITEW6432 }
if ($cpu -ne 'AMD64') {
  throw "no build for $cpu"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("recurse-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $zip = Join-Path $tmp $archive
  $sumsPath = Join-Path $tmp 'SHA256SUMS'
  Invoke-WebRequest "$base/$archive" -OutFile $zip -UseBasicParsing
  Invoke-WebRequest "$base/SHA256SUMS" -OutFile $sumsPath -UseBasicParsing
  $line = Get-Content $sumsPath | Where-Object { $_ -like "* $archive" } | Select-Object -First 1
  if (-not $line) { throw "SHA256SUMS has no $archive" }
  $want = ($line -split '\s+')[0].ToLowerInvariant()
  $got = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
  if ($want -ne $got) { throw "checksum mismatch for $archive" }

  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Copy-Item (Join-Path $tmp "$name.exe") (Join-Path $dest 'recurse.exe') -Force
} finally {
  Remove-Item -Recurse -Force $tmp
}

$user = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = @()
if ($user) { $parts = @($user.Split(';') | Where-Object { $_ -ne '' }) }
if ($parts -notcontains $dest) {
  $joined = (@($parts) + $dest) -join ';'
  [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
}
if (@($env:Path.Split(';')) -notcontains $dest) {
  $env:Path = "$env:Path;$dest"
}

Write-Output "installed $dest\recurse.exe"
