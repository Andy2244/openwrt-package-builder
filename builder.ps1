#Requires -RunAsAdministrator

<#
    .SYNOPSIS
    Dockerized automatic Openwrt Package-Builder.

    .DESCRIPTION
    Usage: .\builder.ps1 COMMAND [FILE]
    build        - build packages defined via [FILE]
    build_quick  - quickly build packages defined via [FILE], no (sdk, feeds, patches) updates are performed and build cache is reused.
    shell        - start shell in docker container (allows manual build/debug)
    host         - host the build packages locally via a tiny web server 
    clean        - clean/remove the associated container

    FILE:
    [FILE].txt   - the config file to-be used (must contain valid VERSION, TARGET, SUBTARGET)

    Usage: .\builder.ps1 COMMAND
    cleanall        - remove ALL package builder docker containers
    update          - update docker images (aka pull)
    bundle_patches  - create per feed 'patches-[feed name]-[sdk version].tar.gz' files via '.patches' dir
    - structure: .patches/[feed name]/[sdk version]/[patchfile].patch
    - example:   .patches/packages/18.06.0/mypatch.patch

    .EXAMPLE
    .\builder.ps1 build  example.txt
    .\builder.ps1 host   example.txt
    .\builder.ps1 cleanall

    .NOTES
    

    .LINK
#>

param (
  [string]$CMD = $null,
  [string]$FILE = $null
)

$scriptName = $myInvocation.MyCommand.Name
$scriptPath = $myInvocation.MyCommand.Path

# run 'set-executionpolicy remotesigned' in a admin powershell
& "$env:windir\system32\chcp.com" 65001 1>$null
#[Console]::OutputEncoding = New-Object -typename System.Text.UTF8Encoding

function script:Write-Color {
  [Alias('wc')]
  param (
    [Parameter(Mandatory=$true)][alias ('T')] [String[]]$Text,
    [alias ('C')] [ConsoleColor[]]$Color = 'White',
    [alias ('B')] [ConsoleColor[]]$BackGroundColor = $null,
    [int] $StartTab = 0,
    [int] $LinesBefore = 0,
    [int] $LinesAfter = 0,
    [alias ('L')] [string] $LogFile = '',
    [string] $TimeFormat = 'yyyy-MM-dd HH:mm:ss',
    [switch] $ShowTime,
    [switch] $NoNewLine
  )
  $DefaultColor = $Color[0]
  if ($BackGroundColor -ne $null -and $BackGroundColor.Count -ne $Color.Count) { Write-Error "Colors, BackGroundColors parameters count doesn't match. Terminated." ; return }
  if ($Text.Count -eq 0) { return }
  if ($LinesBefore -ne 0) {  for ($i = 0; $i -lt $LinesBefore; $i++) { Write-Host "`n" -NoNewline } } # Add empty line before
  if ($ShowTime) { Write-Host "[$([datetime]::Now.ToString($TimeFormat))]" -NoNewline} # Add Time before output
  if ($StartTab -ne 0) {  for ($i = 0; $i -lt $StartTab; $i++) { Write-Host "`t" -NoNewLine } }  # Add TABS before text
  if ($Color.Count -ge $Text.Count) {
    # the real deal coloring
    if ($BackGroundColor -eq $null) {
      for ($i = 0; $i -lt $Text.Length; $i++) { Write-Host $Text[$i] -ForegroundColor $Color[$i] -NoNewLine }
    } else {
      for ($i = 0; $i -lt $Text.Length; $i++) { Write-Host $Text[$i] -ForegroundColor $Color[$i] -BackgroundColor $BackGroundColor[$i] -NoNewLine }
    }
  } else {
    if ($BackGroundColor -eq $null) {
      for ($i = 0; $i -lt $Color.Length ; $i++) { Write-Host $Text[$i] -ForegroundColor $Color[$i] -NoNewLine }
      for ($i = $Color.Length; $i -lt $Text.Length; $i++) { Write-Host $Text[$i] -ForegroundColor $DefaultColor -NoNewLine }
    } else {
      for ($i = 0; $i -lt $Color.Length ; $i++) { Write-Host $Text[$i] -ForegroundColor $Color[$i] -BackgroundColor $BackGroundColor[$i] -NoNewLine }
      for ($i = $Color.Length; $i -lt $Text.Length; $i++) { Write-Host $Text[$i] -ForegroundColor $DefaultColor -BackgroundColor $BackGroundColor[0] -NoNewLine }
    }
  }
  if ($NoNewLine -eq $true) { Write-Host -NoNewline } else { Write-Host } # Support for no new line
  if ($LinesAfter -ne 0) {  for ($i = 0; $i -lt $LinesAfter; $i++) { Write-Host "`n" } }  # Add empty line after
  if ($LogFile -ne '') {
    # Save to file
    $TextToFile = ''
    for ($i = 0; $i -lt $Text.Length; $i++) {
      $TextToFile += $Text[$i]
    }
    try {
      Write-Output "[$([datetime]::Now.ToString($TimeFormat))]$TextToFile" | Out-File $LogFile -Encoding unicode -Append
    } catch {
      $_.Exception
    }
  }
}

function script:fail {
  param ([string]$inText = '')
  
  wc -t "ERROR: $inText" -b Red 2>$null
  exit 1
}
########################################################################
# params don't count as args!
if ($args.Count -gt 0 -or [string]::IsNullOrEmpty($CMD)) {
  Get-Help $scriptPath
  fail 'Invalid number of arguments given!'
}

# linux colors (for .cmd)
$_RED = '\033[1;31m'
$_GREEN = '\033[1;32m'
$_YELLOW = '\033[1;33m'
$_NC = '\033[0m' # No Color

##########################################################################
$SCRIPT_DIR = (pwd).Path
$DOCKER_VERSION = (docker version -f '{{.Client.Version}}' 2>$null)
$DOCKER_PLATFORM_SWITCH = $null
$DOCKER_NETWORK_SWITCH = $null
#$MY_TZ = $(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
# xterm-256color
$MY_TERM = 'xterm'
$MY_HOSTNAME = 'docker_pb'
# base Tag to use for docker image
$IMAGE_TAG = 'andy2222/docker-openwrt-sdk-base'
$IMAGE_TAG_HOST = 'pierrezemb/gostatic'
$CPREFIX = 'openwrt_pb'
$VERSION = $null
$TARGET = $null
$SUBTARGET = $null

#Clear-Host
##########################################################################################
# assume mixed or windows CRLF!
function script:import_config {
  param ([Parameter(Mandatory=$true)][string]$inFileName)
  
  if ( Test-Path "$inFileName" ) {
    $script:VERSION = (Select-String -Path $inFileName -CaseSensitive -Pattern '^VERSION ?="?(.*\w)"?').Matches[0].Groups[1].ToString() 2>$null
    $script:TARGET = (Select-String -Path $inFileName -CaseSensitive -Pattern '^TARGET ?="?(.*\w)"?').Matches[0].Groups[1].ToString() 2>$null
    $script:SUBTARGET = (Select-String -Path $inFileName -CaseSensitive -Pattern '^SUBTARGET ?="?(.*\w)"?').Matches[0].Groups[1].ToString() 2>$null
  } else {
    fail "file does not exist: $inFileName"
  }
  # check for required VARS
  if ( [string]::IsNullOrEmpty($script:VERSION) ) { fail "missing VERSION in $inFileName" }
  if ( [string]::IsNullOrEmpty($script:TARGET) ) { fail "missing TARGET in $inFileName" }
  if ( [string]::IsNullOrEmpty($script:SUBTARGET) ) { fail "missing SUBTARGET in $inFileName" }
  wc -t 'Config imported',' with:' -c Green,White
  wc -t 'SDK            ',$script:VERSION -c White,Yellow
  wc -t 'Target         ',$script:TARGET -c White,Green
  wc -t 'Subtarget      ',$script:SUBTARGET -c White,Green
  echo '----------------------------------------------------'
}

# use /.cmd file to allow dynamic cmds on a already started container
function script:prepare_container {
  param ([Parameter(Mandatory=$true)][string]$inContainerName)
  
  check_images
  
  [string] $cid = (docker ps -a -q -f name="$inContainerName")
  if ( [string]::IsNullOrEmpty($cid) ) {
    #-e GOSU_USER=`id -u`:`id -g`
    #-e LANG="$MY_LANG"
    #-e TZ="$MY_TZ"

    docker create -ti $DOCKER_PLATFORM_SWITCH `
    --log-driver=none `
    --name="$inContainerName" `
    -h "${MY_HOSTNAME}_build" `
    -e TERM="$MY_TERM" `
    --mount type=bind,source="$SCRIPT_DIR",target=/hostdir `
    $IMAGE_TAG /bin/bash -C /.cmd

    $cid = (docker ps -a -q -f name="$inContainerName")
  }

  if ( ! [string]::IsNullOrEmpty($cid) ) {
    docker stop "$inContainerName" 2>$null
    wc -t 'updating container config files, this may take a moment' -Color Green
    docker cp "$SCRIPT_DIR\build.in" "${inContainerName}:/workdir/build.sh"
    docker cp "$FILE" "${inContainerName}:/workdir/"
    docker cp "$SCRIPT_DIR\keys.tar.gz" "${inContainerName}:/workdir/"
    $patches = (ls "$SCRIPT_DIR\patches-*-$VERSION.tar.gz" 2>$null)
    foreach ($patch_file in $patches) {
      if ( Test-Path "$patch_file" ) {
        docker cp "$patch_file" "${inContainerName}:/workdir/"
      }
    }
  } else {
    fail "Something went wrong, for $inContainerName"
  }
}

function script:fix_eol {
  param ([Parameter(Mandatory=$true)][string]$inFileName)
  
  $fix_eol = [IO.File]::ReadAllText("$SCRIPT_DIR\$inFileName") -replace "`r`n", "`n"
  [IO.File]::WriteAllText("$SCRIPT_DIR\$inFileName", $fix_eol)  
}

function script:run_shell {
  param ([Parameter(Mandatory=$true)][string]$inContainerName)
  
  prepare_container("$inContainerName")
  $filename = (get-item $FILE).Name
  echo "echo -e `"************* Host script dir ${_YELLOW} $SCRIPT_DIR ${_NC} has been mounted to ${_GREEN} `'/hostdir`' ${_NC} inside the container, for your convenience!  *************`"" > cmd.in
  echo 'echo -e "************* available tools: mc, nano, edit "' >> cmd.in
  echo "chmod 777 /workdir/ /workdir/build.sh && chmod 666 /workdir/$filename && dos2unix -q /workdir/build.sh /workdir/$filename && exec bash" >> cmd.in
  fix_eol('cmd.in')
  docker cp cmd.in "${inContainerName}:/.cmd"
  rm -Force cmd.in 2>$null
  docker start -ai "$inContainerName"
  docker stop "$inContainerName"
}

function script:run_build_packages {
  param ([Parameter(Mandatory=$true)][string]$inContainerName)

  prepare_container("$inContainerName")
  $filename = (get-item $FILE).Name
  echo "chmod 777 /workdir/ /workdir/build.sh && chmod 666 /workdir/$filename && dos2unix -q /workdir/build.sh /workdir/$filename && exec /workdir/build.sh $filename" > cmd.in
  fix_eol('cmd.in')
  docker cp cmd.in "${inContainerName}:/.cmd"
  rm -Force cmd.in 2>$null
  docker start -ai "$inContainerName"
  docker stop "$inContainerName"
}

function script:run_build_packages_quick {
  param ([Parameter(Mandatory=$true)][string]$inContainerName)

  prepare_container("$inContainerName")
  $filename = (get-item $FILE).Name
  echo "chmod 777 /workdir/ /workdir/build.sh && chmod 666 /workdir/$filename && dos2unix -q /workdir/build.sh /workdir/$filename && echo BUILD_QUICK=1 >> /workdir/$filename && exec /workdir/build.sh $filename" > cmd.in
  fix_eol('cmd.in')
  docker cp cmd.in "${inContainerName}:/.cmd"
  rm -Force cmd.in 2>$null
  docker start -ai "$inContainerName"
  docker stop "$inContainerName"
}

function script:run_cleanall {
  echo 'Cleaning ALL'
  $cids = (docker ps -a -q -f name="$CPREFIX")
  if ($cids -ne $null) {
    docker rm -f $cids
  }
  # full cleanup
  docker image prune -f
}

function script:run_clean {
  param ([Parameter(Mandatory=$true)][string]$inContainerName)
  
  echo "Cleaning $inContainerName"
  docker rm -f "$inContainerName"
}

function script:run_update_images {
  wc -t 'updating Docker images' -c Yellow
  docker pull $DOCKER_PLATFORM_SWITCH $IMAGE_TAG
  docker pull $DOCKER_PLATFORM_SWITCH $IMAGE_TAG_HOST
  docker image prune -f
}

#NOTE: without existing linux containers, bindmount will fail docker start/run on windows!
function script:check_images {
  $cid1 = (docker image ls -a -q -f reference="$IMAGE_TAG_HOST")
  $cid2 = (docker image ls -a -q -f reference="$IMAGE_TAG")
  if ($cid1 -eq $null -or $cid2 -eq $null) {
    run_update_images
  }
}

function script:run_host_packages {
  param ([Parameter(Mandatory=$true)][string]$inContainerName)
  
  check_images
  
  $bin_dir = "bin-$VERSION-$TARGET-$SUBTARGET"
  $host_dir = "$SCRIPT_DIR\$bin_dir\bin"
  $hostname = ([System.Net.Dns]::GetHostByName(($env:computerName))).Hostname
  if ( ! (Test-Path "$host_dir\packages") ) {
    fail "$host_dir\packages does not exist!"
  }
  [bool] $has_core = Test-Path "$host_dir\targets\$TARGET\$SUBTARGET\packages\Packages.manifest"
  [Collections.ArrayList] $custom_feeds = @(dir -ad -Path "$host_dir\packages\*\" -Exclude 'base','luci','packages','routing','telephony')
  $custom_feeds.Remove($null)
  [Collections.ArrayList] $all_feeds = @(dir -ad -Path "$host_dir\packages\*\*")
  [Collections.ArrayList] $official_feeds = @((Compare-Object $all_feeds $custom_feeds).InputObject)
  $official_feeds.Remove($null)
  [string] $arch = (dir -ad "$host_dir\packages\*\").BaseName
  
  if ($official_feeds.Count -eq 0 -and $custom_feeds.Count -eq 0 -and $has_core -eq $false ) {
    fail "Nothing to host found in $host_dir"
  }
  
  wc -t 'Hosting ',"$host_dir",' via URL ',"http://${hostname}:8043/$VERSION/" -c White,Yellow,White,Green
  wc -t 'This URL can be used via your router',' luci UI',' under ',"`'System/Software/Configuration`'",' in the ',"`'Custom feeds`'",' field.' -c White,Yellow,White,Yellow,White,Yellow,White
  wc -t 'IMPORTANT:',' Make sure you'," disable `'Distribution feeds`'",' that contain packages with the',' same name',". (add `'#`' at the beginning)" -c Yellow,White,Yellow,White,Yellow,White
  wc -t "Otherwise your rebuild packages will NOT be listed and overwritten by the default `'Distribution feeds`'!" -StartTab 1
  echo '------------------------------------------------------------------------------------------------------------------------------------------------------'
  if ($official_feeds.Count -gt 0 -or $has_core -eq $true) {
    wc -t 'If you',' did',' customize or patch',' official packages, use these lines, otherwise',' not needed.' -c Yellow,Red,Yellow,White,Red
    wc -t 'NOTE:',' Those should also be added via the ',"`'Custom feeds`'",' field.' -c Yellow,White,Yellow,White
    wc -t 'Custom official feeds entries' -c Yellow
    if ( $has_core -eq $true ) {
      wc -t "src/gz local_core http://${hostname}:8043/$VERSION/targets/$TARGET/$SUBTARGET/packages" -c Green -StartTab 1
    }
    foreach ($ofeed in $official_feeds) {
      if (Test-Path "$ofeed\Packages.manifest") {
        $feed_name = ($ofeed).Basename
        wc -t "src/gz local_${feed_name} http://${hostname}:8043/$VERSION/packages/$arch/$feed_name" -c Green -StartTab 1
      }
    }
    echo '------------------------------------------------------------------------------------------------------------------------------------------------------'
  }
  if ($custom_feeds.Count -gt 0) {
    wc -t 'Custom feeds entries' -c Yellow
    foreach ($cfeed in $custom_feeds) {
      if (Test-Path "$cfeed\Packages.manifest") {
        $feed_name = ($cfeed).Basename
        wc -t "src/gz local_${feed_name} http://${hostname}:8043/$VERSION/packages/$arch/$feed_name" -c Green -StartTab 1
      }
    }
    echo '------------------------------------------------------------------------------------------------------------------------------------------------------'
  }
  wc -t 'NOTE:'," Make sure to disable `'Distribution feeds`' that contain packages with the same names, or you wont see your updated versions!" -c Yellow,White
  wc -t 'use ','CTRL-C',' to stop hosting!' -c White,Red,White
  # -ti needed on windows or container wont be removed?
  docker run --rm -ti $DOCKER_PLATFORM_SWITCH $DOCKER_NETWORK_SWITCH `
  --log-driver=none `
  --name="$inContainerName" `
  -p 8043:8043 `
  -h "${MY_HOSTNAME}_host" `
  --mount type=bind,source="$host_dir",target="/srv/http/$VERSION",readonly `
  $IMAGE_TAG_HOST

  docker rm -f "$inContainerName" 2>$null
}

function script:copy_packages {
  param ([Parameter(Mandatory=$true)][string]$inContainerName)
 
  $sdk_dir = "sdk-$VERSION-$TARGET-$SUBTARGET"
  $bin_dir = "bin-$VERSION-$TARGET-$SUBTARGET"
  $dst_dir = "/workdir/$sdk_dir/bin/"
  rm -Force build_result.out 2>$null
  docker cp "${inContainerName}:/workdir/.build_result" build_result.out
  
  if ( Test-Path build_result.out ) {
    [int] $build_code = (cat build_result.out)
    if ( $build_code -eq 0 ) {
      rm -Force -Recurse "$SCRIPT_DIR\$bin_dir\" 2>$null
      mkdir -Force "$SCRIPT_DIR\$bin_dir\" 1>$null
      docker cp "${inContainerName}:$dst_dir" "$SCRIPT_DIR\$bin_dir\"
      # chmod -fR `id -u`:`id -g` "$SCRIPT_DIR/$bin_dir/"
      wc -t '************* ','Valid build result',' found, copying packages to'," $SCRIPT_DIR\$bin_dir\" -c White,Green,White,Green
      wc -t '************* Build results can now be locally hosted for installation via:'," .\$scriptName host $FILE" -c White,Green
    }
  } else {
    wc -t 'Problem detected you can debug by setting'," 'DEBUG=2' in $FILE",' or open a shell via:'," .\$scriptName shell $FILE" -c White,Yellow,White,Green
    fail "No .build_result found in $inContainerName or last build failed, skipping copy!"
  }
  rm -Force build_result.out 2>$null
}

# HELP: per feed patches can be added via a '.patches' dir, with subdirs of the feednames (base, luci, packages ...) and subdirs of the SDK version (snapshots, 18.06.0, 18.06.1)
# Examples: 
#	.patches/packages/18.06.0/mypatch.patch
#	.patches/base/snapshots/mypatch2.patch
# The generated files will be automatically used by 'builder.sh build' command and applied to the downloaded feeds
function script:create_patches {
  if ( Test-Path "$SCRIPT_DIR\.patches" ) { 
    rm -Force "patches-*.tar.gz" 2>$null
  } else { 
    fail 'Error: no .patches dir found.'
  }
	
  [Collections.ArrayList] $patch_feeds = @((dir -ad -Path "$SCRIPT_DIR/.patches/*"))
  $patch_feeds.Remove($null)
  if ( $patch_feeds.Count -eq 0 ) { 
    fail "Nothing todo empty .patches dir!"
  }
  foreach ($feed_dir in $patch_feeds) { 
    [Collections.ArrayList] $patch_versions = @((dir -ad -Path $feed_dir/*))
    $patch_versions.Remove($null)
    foreach ($version_dir in $patch_versions) {
      [string] $feed_name = $feed_dir.Basename
      [string] $version_name = $version_dir.Basename
      echo "Creating patches-$feed_name-$version_name from $version_dir"
      #chmod 644 "$version_dir"/*.patch
      cd "$version_dir"
      tar -zcf "$SCRIPT_DIR/patches-$feed_name-$version_name.tar.gz" "*.patch"
    }
  }
  cd $SCRIPT_DIR
}

function script:has_docker {
  if ( [string]::IsNullOrEmpty($DOCKER_VERSION) ) {
    wc -t '----------------------------------------------------------------------------------------------'
    wc -t 'Install ',"`'Docker Community Edition for Windows`'", ' first, check: ','https://docs.docker.com/docker-for-windows/install/' -c White,Yellow,White,Green
    wc -t 'Select ',"`'use Windows Containers instead of Linux Containers`'",' during installation and enable ',"`'Experimental features`'",' in the docker Settings/Daemon!' -c White,Green,White,Green
    wc -t 'Direct download link: ','https://download.docker.com/win/stable/Docker%20for%20Windows%20Installer.exe' -c White,Green
    wc -t 'Make sure you meet the requirements, see: ','https://docs.docker.com/docker-for-windows/install/#what-to-know-before-you-install' -c White,Green
    wc -t '64bit Windows 10 Pro, Enterprise and Education, (Build > 1607)' -c Yellow -StartTab 1
    wc -t 'Virtualisation capable CPU and enabled in Bios (Intel VT or AMD-V)' -c Yellow -StartTab 1
    wc -t 'Hyper-V enabled ','(will be enabled by Docker for Windows installer)' -c Yellow,White -StartTab 1
    wc -t '----------------------------------------------------------------------------------------------'
    wc -t 'Detecting requirements' -Color Yellow
    [int] $win_version = [Environment]::OSVersion.Version.Major
    [int] $win_build = [Environment]::OSVersion.Version.Build
    [string] $win_edition = (Get-WindowsEdition -Online).Edition
    [bool] $win_64bit = [Environment]::Is64BitOperatingSystem
    $win_isbit = '32bit'
    if ($win_64bit -eq $true) {
      $win_isbit = '64bit'
    }
    if ( $win_version -ge 10 -and $win_build -ge 1607 -and $win_edition -ne 'core' -and $win_64bit -eq $true) {
      wc -t 'Compatible Windows version detected: ',"${win_version},${win_build},${win_edition},${win_isbit}" -c Green,Yellow -StartTab 1
    } else {
      wc -t 'Your current Windows 10 version/edition is incompatible with Docker for Windows.',"${win_version},${win_build},${win_edition},${win_isbit}" -c Red,Yellow -StartTab 1
    }
    [bool] $virt = (Get-CimInstance win32_processor ).VirtualizationFirmwareEnabled
    [bool] $hyperv = (gcim Win32_ComputerSystem).HypervisorPresent
    if ( $hyperv -eq $true) {
      wc -t 'Virtualisation detected' -c Green -StartTab 1
      wc -t 'Hyper-V detected' -c Green -StartTab 1
    } elseif ( $virt -eq $true ) {
      wc -t 'Virtualisation detected' -c Green -StartTab 1
    } else {
      wc -t 'Virtualisation not detected, incompatible CPU or disabled via Bios.' -c Red -StartTab 1
    }
    wc -t '------------------------------------'
    fail 'Could not get Docker Version.'
  }
}

function script:start_docker {
  docker ps -q 2>$null 1>$null
  # $? last cmd exitcode (true, false)
  if ( $? -eq $false ) {
    fail "Docker daemon is not running. Please start `'Docker for Windows`' on your computer."
  }
}

# tested mainly in lcow mode, so warn about 'MobyVM' default mode.
function script:check_lcow {
  [string] $docker_os = (docker info -f '{{.OSType}}' 2>$null)
  $docker_lcow = (docker version -f '{{.Server.Experimental}}' 2>$null)
  if ($docker_os -ne 'windows') {
    echo '---------------------------------------------------------------------------------------------------------------------'
    wc -t 'Docker is not running in LCOW/Windows-Mode.' -c Yellow
    wc -t 'This script was mainly tested in LCOW/Windows-Mode, so you may want to switch into it, to avoid potential problems.'
    wc -t 'Docker tray icon Switch to',' Windows Containers',' and than Settings/Daemon enable',' Experimental features.' -c White,Green,White,Green
    echo '---------------------------------------------------------------------------------------------------------------------'
    Start-Sleep 3
  } elseif ($docker_lcow -eq 'false') {
    wc -t 'Please enable','  Experimental features',' via Docker Settings/Daemon' -c White,Green,White
    fail 'Docker needs to have LCOW enabled!'
  }
  
  if ($docker_os -eq 'windows' -and $docker_lcow -eq 'true') {
    $script:DOCKER_PLATFORM_SWITCH = '--platform=linux'
    # 'nat' 'Default Switch'
    #$script:DOCKER_NETWORK_SWITCH = '--network=nat'
  }
}

#Set-Executionpolicy -Scope CurrentUser -ExecutionPolicy UnRestricted
#set-executionpolicy remotesigned
############################# Main #############################
has_docker
start_docker
check_lcow

if ( ! [string]::IsNullOrEmpty($CMD) -and ! [string]::IsNullOrEmpty($FILE) ) {
  import_config($FILE)
  $CONTAINER_NAME = "$CPREFIX-build-$VERSION-$TARGET-$SUBTARGET"
  $CONTAINER_NAME_HOSTING = "$CPREFIX-host-$VERSION-$TARGET-$SUBTARGET"
  switch ( $CMD )
  {
    'build' {
      run_build_packages("$CONTAINER_NAME")
      copy_packages("$CONTAINER_NAME")
      break
    }
    'build_quick' {
      run_build_packages_quick("$CONTAINER_NAME")
      copy_packages("$CONTAINER_NAME")
      break
    }
    'shell' {
      run_shell("$CONTAINER_NAME")
      break
    }
    'host' {
      run_host_packages("$CONTAINER_NAME_HOSTING")
      break
    }
    'clean' {
      run_clean("$CONTAINER_NAME")
      break
    }
    default { Get-Help $scriptPath }
  }
} elseif (! [string]::IsNullOrEmpty($CMD)) {
  switch ( $CMD )
  {
    'cleanall' { run_cleanall ; break }
    'update' { run_update_images ; break }
    'bundle_patches' { create_patches ; break }
    default { Get-Help $scriptPath }
  }
} else {
  fail "Invalid arguments `'CMD:$CMD`', `'FILE:$FILE`'"
}

