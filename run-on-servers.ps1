<#
.SYNOPSIS
  Install or update the scripts on servers over SSH, then run one of them.

.DESCRIPTION
  Windows version of run-on-servers.sh, run on your own machine. It uses the
  same local\servers.txt and lib\ files. For each selected server it connects
  with ssh, downloads the latest scripts from GitHub, then runs the chosen
  script there with sudo. Output is shown live and saved under local\logs\.

  With no parameters it asks which action and servers to use. The action menu
  is lib\actions.txt.

  Exit codes: 0 = OK on every server; 2 = review required; 1 = error or SSH failure.

.PARAMETER Servers
  Servers to use: "all", or numbers, ranges, names or hosts separated by
  commas, e.g. "1,3-4,web-2". Skips the server menu.

.PARAMETER Action
  Script in scripts\ and its arguments, e.g. "php-upload-progress.sh --patch".
  Skips the action menu.

.PARAMETER UpdateOnly
  Install or update the scripts without running anything.

.PARAMETER NoUpdate
  Run without updating the scripts first.

.PARAMETER Yes
  Skip the "Continue?" confirmation.

.PARAMETER List
  List the servers in local\servers.txt and exit.

.PARAMETER Ssh
  Path to ssh.exe. Default: Windows OpenSSH, otherwise ssh.exe on PATH.

.EXAMPLE
  .\run-on-servers.cmd

.EXAMPLE
  .\run-on-servers.cmd -Servers all -Action "check-all.sh --refresh"
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Servers = '',
  [string]$Action = '',
  [switch]$UpdateOnly,
  [switch]$NoUpdate,
  [switch]$Yes,
  [switch]$List,
  [string]$Ssh = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RootDir = $PSScriptRoot
$LibDir = Join-Path $RootDir 'lib'
$LocalDir = Join-Path $RootDir 'local'
$ServersFile = Join-Path $LocalDir 'servers.txt'

# Archive each server downloads the scripts from.
$DefaultArchiveUrl = 'https://github.com/jsefton/php-security-audit/archive/refs/heads/main.tar.gz'
$ArchiveUrl = $DefaultArchiveUrl
if ($env:ARCHIVE_URL) { $ArchiveUrl = $env:ARCHIVE_URL }
# Install directory on each server. A relative path is under the SSH user's home.
$InstallDir = 'php-security-audit'
if ($env:INSTALL_DIR) { $InstallDir = $env:INSTALL_DIR }

function Exit-WithError([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

# Quote a value for a POSIX shell (the remote login shell).
function ConvertTo-ShellQuoted([string]$Value) {
  return "'" + $Value.Replace("'", "'\''") + "'"
}

# Build a Windows command line; arguments never contain double quotes here.
function Join-CommandLine([string[]]$Arguments) {
  $parts = foreach ($arg in $Arguments) {
    if ($arg.Contains('"')) { throw "Unsupported character in argument: $arg" }
    if ($arg -eq '' -or $arg -match '\s') { '"' + ($arg -replace '(\\+)$', '$1$1') + '"' } else { $arg }
  }
  return ($parts -join ' ')
}

$doUpdateOnly = [bool]$UpdateOnly
if ($doUpdateOnly -and $NoUpdate) { Exit-WithError '-UpdateOnly and -NoUpdate cannot be combined' }
if ($doUpdateOnly -and $Action) { Exit-WithError '-UpdateOnly cannot be combined with -Action' }
foreach ($file in 'remote-run.sh', 'actions.txt', 'servers.example.txt') {
  if (-not (Test-Path -LiteralPath (Join-Path $LibDir $file) -PathType Leaf)) {
    Exit-WithError "Missing $(Join-Path $LibDir $file)"
  }
}

if (-not $Ssh) {
  $windowsSsh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
  if (Test-Path -LiteralPath $windowsSsh -PathType Leaf) {
    $Ssh = $windowsSsh
  } else {
    $found = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $Ssh = $found.Source }
  }
}
if (-not $Ssh -or -not (Test-Path -LiteralPath $Ssh -PathType Leaf)) {
  Exit-WithError 'ssh.exe not found. Add the Windows "OpenSSH Client" optional feature (Settings > System > Optional features).'
}

# Action menu: "<script and arguments> | <description>" per line.
$Actions = New-Object 'System.Collections.Generic.List[object]'
foreach ($raw in [System.IO.File]::ReadAllLines((Join-Path $LibDir 'actions.txt'))) {
  $line = $raw.Trim()
  if (-not $line -or $line.StartsWith('#')) { continue }
  $parts = @($line -split '\|', 2)
  $description = ''
  if ($parts.Count -gt 1) { $description = $parts[1].Trim() }
  $Actions.Add([pscustomobject]@{ Command = $parts[0].Trim(); Description = $description })
}

# ----- Server list -----

if (-not (Test-Path -LiteralPath $ServersFile -PathType Leaf)) {
  New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
  Copy-Item -LiteralPath (Join-Path $LibDir 'servers.example.txt') -Destination $ServersFile
  Write-Host "Created $ServersFile"
  Write-Host 'Add your servers to it, then run this again.'
  exit 1
}

$ServerList = New-Object 'System.Collections.Generic.List[object]'
$lineNo = 0
foreach ($raw in [System.IO.File]::ReadAllLines($ServersFile)) {
  $lineNo++
  $line = ($raw -split '#', 2)[0].Trim()
  if (-not $line) { continue }
  $cols = @($line -split '\s+')
  $bad = "$ServersFile line ${lineNo}: expected <host> <user> [port] [name]"
  if ($cols.Count -lt 2) { Exit-WithError $bad }
  $hostName = $cols[0]
  $user = $cols[1]
  $port = '22'
  $name = $hostName
  if ($hostName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]*$') { Exit-WithError "$ServersFile line ${lineNo}: invalid host '$hostName'" }
  if ($user -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9._-]*$') { Exit-WithError "$ServersFile line ${lineNo}: invalid user '$user'" }
  if ($cols.Count -ge 3) {
    if ($cols[2] -cmatch '^[0-9]{1,5}$') {
      $port = $cols[2]
      if ($cols.Count -ge 4) { $name = $cols[3] }
      if ($cols.Count -gt 4) { Exit-WithError $bad }
    } else {
      $name = $cols[2]
      if ($cols.Count -gt 3) { Exit-WithError $bad }
    }
  }
  $ServerList.Add([pscustomobject]@{ HostName = $hostName; User = $user; Port = $port; Name = $name })
}
if ($ServerList.Count -eq 0) {
  Exit-WithError "No servers in $ServersFile. Add one per line: <host> <user> [port] [name]"
}

function Show-Servers {
  for ($i = 0; $i -lt $ServerList.Count; $i++) {
    $s = $ServerList[$i]
    $suffix = ''
    if ($s.Port -ne '22') { $suffix = " port $($s.Port)" }
    Write-Host ('  {0,2}) {1,-20} {2}@{3}{4}' -f ($i + 1), $s.Name, $s.User, $s.HostName, $suffix)
  }
}

if ($List) {
  Write-Host "Servers ($ServersFile):"
  Show-Servers
  exit 0
}

# Parse "all", numbers, ranges, names or hosts into server indexes ($null on error).
function Get-Selection([string]$Text) {
  $count = $ServerList.Count
  $picked = New-Object 'System.Collections.Generic.List[int]'
  foreach ($token in ($Text -split '[,\s]+')) {
    if (-not $token) { continue }
    if ($token -eq 'all') {
      $found = @(0..($count - 1))
    } elseif ($token -match '^([0-9]{1,6})-([0-9]{1,6})$') {
      $a = [int]$Matches[1]
      $b = [int]$Matches[2]
      if ($a -lt 1 -or $b -gt $count -or $a -gt $b) { [Console]::Error.WriteLine("Invalid range: $token"); return $null }
      $found = @(($a - 1)..($b - 1))
    } elseif ($token -match '^[0-9]{1,6}$') {
      $a = [int]$token
      if ($a -lt 1 -or $a -gt $count) { [Console]::Error.WriteLine("No server number $token"); return $null }
      $found = @($a - 1)
    } else {
      $found = @(for ($i = 0; $i -lt $count; $i++) {
        if ($ServerList[$i].Name -eq $token -or $ServerList[$i].HostName -eq $token) { $i }
      })
      if ($found.Count -eq 0) { [Console]::Error.WriteLine("Unknown server: $token"); return $null }
    }
    foreach ($i in $found) {
      if (-not $picked.Contains([int]$i)) { $picked.Add([int]$i) }
    }
  }
  if ($picked.Count -eq 0) { [Console]::Error.WriteLine('No servers selected'); return $null }
  return ,$picked
}

function Test-ScriptName([string]$Name) {
  $known = @(Get-ChildItem -LiteralPath (Join-Path $RootDir 'scripts') -Filter '*.sh' -File | ForEach-Object { $_.Name })
  if ($Name -cmatch '^[A-Za-z0-9._-]+\.sh$' -and $known -ccontains $Name) { return $true }
  [Console]::Error.WriteLine("Unknown script: $Name (expected a file in scripts\)")
  return $false
}

# Files in scripts\ that differ from GitHub main (as of the last fetch or push).
function Get-UnpushedScripts {
  if (-not (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)) { return @() }
  $ErrorActionPreference = 'Continue'
  & git.exe -C $RootDir rev-parse -q --verify origin/main 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { return @() }
  $files = @(
    & git.exe -C $RootDir diff --name-only origin/main -- scripts 2>$null
    & git.exe -C $RootDir ls-files --others --exclude-standard -- scripts 2>$null
  )
  return @($files | Where-Object { $_ } | Sort-Object -Unique)
}

function Split-Words([string]$Text) {
  return @($Text -split '\s+' | Where-Object { $_ })
}

# ----- Choose action -----

$ActionWords = @()
if (-not $doUpdateOnly) {
  if ($Action) {
    $ActionWords = @(Split-Words $Action)
    if ($ActionWords.Count -eq 0 -or -not (Test-ScriptName $ActionWords[0])) { exit 1 }
  } else {
    $count = $Actions.Count
    $row = '  {0,2}) {1,-36} {2}'
    Write-Host 'Actions:'
    for ($i = 0; $i -lt $count; $i++) {
      Write-Host ($row -f ($i + 1), $Actions[$i].Command, $Actions[$i].Description)
    }
    Write-Host ($row -f ($count + 1), '(update scripts only)', 'Install or update the scripts; run nothing')
    Write-Host ($row -f ($count + 2), '(other)', 'Type a script and its arguments')
    while ($true) {
      $choice = Read-Host 'Choose an action [1]'
      if (-not $choice) { $choice = '1' }
      if ($choice -notmatch '^[0-9]{1,4}$' -or [int]$choice -lt 1 -or [int]$choice -gt $count + 2) {
        Write-Host "Enter a number from 1 to $($count + 2)."
        continue
      }
      $c = [int]$choice
      if ($c -le $count) {
        $ActionWords = @(Split-Words ($Actions[$c - 1].Command))
        break
      }
      if ($c -eq $count + 1) {
        if ($NoUpdate) { Exit-WithError '-NoUpdate cannot be combined with updating the scripts' }
        $doUpdateOnly = $true
        break
      }
      $custom = Read-Host 'Script and arguments (e.g. php-upload-progress.sh --patch --yes)'
      $ActionWords = @(Split-Words $custom)
      if ($ActionWords.Count -gt 0 -and (Test-ScriptName $ActionWords[0])) { break }
      $ActionWords = @()
    }
  }
}

# ----- Choose servers -----

if ($Servers) {
  $Selected = Get-Selection $Servers
  if ($null -eq $Selected) { exit 1 }
} else {
  Write-Host ''
  Write-Host "Servers ($ServersFile):"
  Show-Servers
  while ($true) {
    $answer = Read-Host 'Select servers (e.g. 1 3, 2-4, web-1, all) [all]'
    if (-not $answer) { $answer = 'all' }
    $Selected = Get-Selection $answer
    if ($null -ne $Selected) { break }
  }
}

# ----- Confirm -----

if ($doUpdateOnly) { $actionText = 'update scripts only' } else { $actionText = $ActionWords -join ' ' }
$selectedNames = @($Selected | ForEach-Object { $ServerList[$_].Name }) -join ' '

Write-Host ''
Write-Host "Action:  $actionText"
Write-Host "Servers: $selectedNames"
if ($NoUpdate) {
  Write-Host 'Scripts: not updated (-NoUpdate)'
} else {
  Write-Host "Scripts: updated from $ArchiveUrl first"
}
if ($ArchiveUrl -eq $DefaultArchiveUrl) {
  $unpushed = @(Get-UnpushedScripts)
  if ($unpushed.Count -gt 0) {
    Write-Host ''
    Write-Host 'WARNING: these files differ from GitHub main, so the servers will run the' -ForegroundColor Yellow
    Write-Host '         GitHub version, not yours. Commit and push them first:' -ForegroundColor Yellow
    foreach ($f in $unpushed) { Write-Host "           $f" -ForegroundColor Yellow }
  }
}
if (-not $Yes) {
  $answer = Read-Host 'Continue? [y/N]'
  if ($answer -notmatch '^(y|yes)$') {
    Write-Host 'Cancelled.'
    exit 0
  }
}

# ----- Run -----

# The server-side script travels base64-encoded so that no quoting has to
# survive Windows command-line parsing. The server decodes it to a temporary
# file, which deletes itself as soon as it starts.
$updateFlag = '1'
if ($NoUpdate) { $updateFlag = '0' }
$remoteArgs = @($ArchiveUrl, $InstallDir, $updateFlag)
if (-not $doUpdateOnly) { $remoteArgs += $ActionWords }
$quotedArgs = ($remoteArgs | ForEach-Object { ConvertTo-ShellQuoted $_ }) -join ' '
$remoteScript = [System.IO.File]::ReadAllText((Join-Path $LibDir 'remote-run.sh')).Replace("`r", '')
$payload = "rm -f -- `"`$0`"`nset -- $quotedArgs`n$remoteScript"
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
$remoteCmd = "f=`$(mktemp) && echo $encoded | base64 -d > `$f && exec bash `$f 2>&1"

# Run ssh, copying its output to the console and a log as it arrives (byte by
# byte, so prompts without a newline, such as sudo's, still appear). Input
# stays on the console so you can answer prompts.
function Invoke-Ssh([string[]]$Arguments, [string]$LogPath) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Ssh
  $psi.Arguments = Join-CommandLine $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $log = New-Object System.IO.StreamWriter($LogPath, $false, (New-Object System.Text.UTF8Encoding($false)))
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $stdout = $proc.StandardOutput.BaseStream
    $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    $buffer = New-Object byte[] 4096
    $chars = New-Object char[] ([System.Text.Encoding]::UTF8.GetMaxCharCount($buffer.Length))
    while (($read = $stdout.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $count = $decoder.GetChars($buffer, 0, $read, $chars, 0)
      $text = [string]::new($chars, 0, $count)
      [Console]::Out.Write($text)
      $log.Write($text.Replace("`r", ''))
    }
    $proc.WaitForExit()
    $errText = $errTask.Result
    if ($errText) {
      [Console]::Error.Write($errText)
      $log.Write($errText.Replace("`r", ''))
    }
    return $proc.ExitCode
  } catch {
    $message = "Could not run ${Ssh}: $($_.Exception.Message)"
    [Console]::Error.WriteLine($message)
    $log.WriteLine($message)
    return 1
  } finally {
    $log.Dispose()
  }
}

# With a console, allocate a terminal on the server so sudo and the scripts can prompt.
$interactive = -not [Console]::IsInputRedirected
$LogDir = Join-Path $LocalDir ('logs\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$results = New-Object 'System.Collections.Generic.List[string]'
$failCount = 0
$reviewCount = 0
foreach ($i in $Selected) {
  $s = $ServerList[$i]
  $label = "$($s.Name) ($($s.User)@$($s.HostName))"
  $logPath = Join-Path $LogDir ('{0:D2}-{1}.log' -f ($i + 1), ($s.Name -replace '[^A-Za-z0-9._-]', '_'))
  Write-Host ''
  Write-Host "################ $label ################"

  if ($interactive) { $sshArgs = @('-t') } else { $sshArgs = @('-T', '-n') }
  $sshArgs += @('-o', 'ConnectTimeout=15', '-p', $s.Port, '-l', $s.User, '--', $s.HostName, $remoteCmd)
  $code = Invoke-Ssh $sshArgs $logPath

  switch ($code) {
    0 { if ($doUpdateOnly) { $result = 'UPDATED' } else { $result = 'OK' } }
    2 { $result = 'REVIEW REQUIRED'; $reviewCount++ }
    255 { $result = 'SSH FAILED'; $failCount++ }
    default { $result = "ERROR (exit $code)"; $failCount++ }
  }
  $results.Add(('{0,-17} {1}' -f $result, $label))
}

Write-Host ''
Write-Host "========== SUMMARY: $actionText =========="
foreach ($line in $results) { Write-Host $line }
Write-Host ''
Write-Host "Logs: $LogDir"

if ($failCount -gt 0) { exit 1 }
if ($reviewCount -gt 0) { exit 2 }
exit 0
