Set-StrictMode -Version Latest

function Resolve-DataDrive {
    param([string]$DataDrive)
    if ([string]::IsNullOrWhiteSpace($DataDrive)) { return $null }
    if ($DataDrive -notmatch '^[A-Za-z]:$') { throw "Invalid DataDrive '$DataDrive'. Expected format 'D:'." }
    return $DataDrive.ToUpper()
}

function Get-ChocolateyInstallDirMachine {
    $v = [Environment]::GetEnvironmentVariable('ChocolateyInstall','Machine')
    if ([string]::IsNullOrWhiteSpace($v)) { return 'C:\ProgramData\chocolatey' }
    return $v
}

function Get-ChocoLibPath {
    return (Join-Path (Get-ChocolateyInstallDirMachine) 'lib')
}

function Test-RegistryInstalled3Hives {
    param([Parameter(Mandatory)][string[]]$DisplayNameLikePatterns)

    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $paths) {
        $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] }
        foreach ($entry in $entries) {
            foreach ($pattern in $DisplayNameLikePatterns) {
                if ($entry.DisplayName -like $pattern) { return $true }
            }
        }
    }

    return $false
}

function Test-WinGetInstalledAnyId {
    param([string[]]$Ids)
    return -not [string]::IsNullOrWhiteSpace((Get-WinGetInstalledId -Ids $Ids))
}

function Get-WinGetInstalledId {
    param([string[]]$Ids)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }
    foreach ($id in $Ids) {
        $out = winget list --id $id -e 2>$null | Out-String
        if ([string]::IsNullOrWhiteSpace($out)) { continue }
        if ($out -match '(?im)\bNo installed package\b') { continue }
        return $id
    }
    return $null
}

function Expand-PathsWithOptionalDrive {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string]$DataDrive
    )

    $dd = Resolve-DataDrive $DataDrive
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $result.Add($p)
        if ($dd -and $p.Length -ge 2 -and $p.Substring(0,2) -ieq 'C:') {
            $result.Add($dd + $p.Substring(2))
        }
    }
    $result | Select-Object -Unique
}

function Get-JunctionTarget {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (-not $isReparse) { return $null }

    if ($item.PSObject.Properties.Name -contains 'Target') {
        $t = ($item.Target -join '')
        if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }
    }

    $parent = Split-Path -Parent $Path
    $leaf   = Split-Path -Leaf  $Path
    $dirOut = cmd.exe /c "dir /al `"$parent`"" 2>$null | Out-String
    $pattern = "(?im)^\s*<JUNCTION>\s+\Q$leaf\E\s+\[(.+)\]\s*$"
    $m = [regex]::Match($dirOut, $pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Set-ChocoLibJunctionSafe {
    param(
        [Parameter(Mandatory)][string]$LibPath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    }

    if (Test-Path -LiteralPath $LibPath) {
        $jt = Get-JunctionTarget -Path $LibPath

        if ($jt) {
            if ($jt -ieq $TargetPath) { return }
            cmd.exe /c "rmdir `"$LibPath`"" | Out-Null
        }
        else {
            robocopy $LibPath $TargetPath /MIR | Out-Null
            cmd.exe /c "rmdir /s /q `"$LibPath`"" | Out-Null
        }
    }

    cmd.exe /c "mklink /J `"$LibPath`" `"$TargetPath`"" | Out-Null
}

function Get-JetBrainsToolboxIdeaPaths {
    param([string]$DataDrive)

    $dd = Resolve-DataDrive $DataDrive
    $paths = @()
    $paths += Join-Path $env:LOCALAPPDATA 'JetBrains\Toolbox\apps\IDEA-C'

    if ($dd) {
        $user = Split-Path (Split-Path $env:LOCALAPPDATA -Parent) -Leaf
        $paths += "$dd\Users\$user\AppData\Local\JetBrains\Toolbox\apps\IDEA-C"
        $paths += "$dd\$user\AppData\Local\JetBrains\Toolbox\apps\IDEA-C"
    }

    $paths | Select-Object -Unique
}

function Test-ChocoPackageByLibFolder {
    param([Parameter(Mandatory)][string[]]$PackageIds)

    $lib = Get-ChocoLibPath
    foreach ($pkg in $PackageIds) {
        $p = Join-Path $lib $pkg
        if (Test-Path -LiteralPath $p) { return $true }
    }
    return $false
}

function Test-WindowsFeatureEnabled {
    param([Parameter(Mandatory)][string]$FeatureName)

    try {
        $feature = Get-WindowsOptionalFeature -FeatureName $FeatureName -Online -ErrorAction SilentlyContinue
        if ($feature) { return $feature.State -eq 'Enabled' }
    } catch {
        # Feature may not exist on all OS versions
    }
    return $false
}

function Test-HyperVSupported {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return $false }
    
    $caption = $os.Caption -as [string]
    # Hyper-V is not available on Home editions
    if ($caption -match 'Home') { return $false }
    
    # Hyper-V is available on Pro, Enterprise, Education, and Server editions
    return $true
}

function Test-KubernetesInDockerDesktop {
    try {
        $configPath = Join-Path $env:APPDATA 'Docker\settings-store.json'
        if (-not (Test-Path -LiteralPath $configPath)) { return $false }
        
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        return ($config.KubernetesEnabled -eq $true)
    } catch {
        return $false
    }
}

function Test-IsLocalSystemContext {
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        return ($sid -eq 'S-1-5-18')
    } catch {
        return $false
    }
}

function Get-WslInstalledDistributions {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }

    $raw = & wsl.exe --list --quiet 2>$null
    if (-not $raw) { return @() }

    $items = @()
    foreach ($line in $raw) {
        $name = ($line -as [string]).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $items += $name
    }

    return @($items | Select-Object -Unique)
}

function Test-WslDistributionInstalled {
    param([Parameter(Mandatory)][string]$DistributionName)

    $installed = Get-WslInstalledDistributions
    if (-not $installed -or $installed.Count -eq 0) { return $false }

    foreach ($d in $installed) {
        if ($d -ieq $DistributionName) { return $true }
        if ($DistributionName -ieq 'Ubuntu' -and $d -imatch '^Ubuntu($|-|\s)') { return $true }
    }

    return $false
}

function Invoke-WslBashAsRoot {
    param(
        [Parameter(Mandatory)][string]$DistributionName,
        [Parameter(Mandatory)][string]$Command
    )

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return 1 }

    & wsl.exe --distribution $DistributionName --user root -- bash -lc $Command 2>$null | Out-Null
    return $LASTEXITCODE
}

function Test-WslUbuntuPackageInstalled {
    param(
        [Parameter(Mandatory)][string]$DistributionName,
        [Parameter(Mandatory)][string]$PackageName
    )

    if (-not (Test-WslDistributionInstalled -DistributionName $DistributionName)) { return $false }

    $exitCode = Invoke-WslBashAsRoot -DistributionName $DistributionName -Command "dpkg -s $PackageName >/dev/null 2>&1"
    return ($exitCode -eq 0)
}

function Test-WslUbuntuJava25JdkInstalled {
    param([Parameter(Mandatory)][string]$DistributionName)

    $cmd = "dpkg -s temurin-25-jdk >/dev/null 2>&1 && command -v javac >/dev/null 2>&1 && javac -version 2>&1 | grep -Eq '^javac 25(\\.|$)'"
    $exitCode = Invoke-WslBashAsRoot -DistributionName $DistributionName -Command $cmd
    return ($exitCode -eq 0)
}

function Get-WslUbuntuJavaHomePath {
    param([Parameter(Mandatory)][string]$DistributionName)

    if (-not (Test-WslDistributionInstalled -DistributionName $DistributionName)) { return $null }

    $cmd = 'if command -v javac >/dev/null 2>&1; then readlink -f "$(command -v javac)" | sed ''s:/bin/javac$::''; fi'
    $out = & wsl.exe --distribution $DistributionName --user root -- bash -lc $cmd 2>$null
    if (-not $out) { return $null }

    $line = ($out | Select-Object -First 1)
    if (-not $line) { return $null }

    $javaHome = ($line -as [string]).Trim()
    if ([string]::IsNullOrWhiteSpace($javaHome)) { return $null }
    if ([string]::IsNullOrWhiteSpace($javaHome)) { return $null }
    return $javaHome
}

function Test-WslUbuntuJavaHomeExported {
    param([Parameter(Mandatory)][string]$DistributionName)

    $javaHome = Get-WslUbuntuJavaHomePath -DistributionName $DistributionName
    if ([string]::IsNullOrWhiteSpace($javaHome)) { return $false }

    $escapedJavaHome = ($javaHome -replace "'", "'\\''")
    $checkCmd = "grep -q '^JAVA_HOME=$escapedJavaHome$' /etc/environment && grep -q '^export JAVA_HOME=$escapedJavaHome$' /etc/profile.d/devtools-java-home.sh"
    $exitCode = Invoke-WslBashAsRoot -DistributionName $DistributionName -Command $checkCmd
    return ($exitCode -eq 0)
}

function Test-WslUbuntuMandrelJdk25Installed {
    param([Parameter(Mandatory)][string]$DistributionName)

    if (-not (Test-WslDistributionInstalled -DistributionName $DistributionName)) { return $false }

    $cmd = 'dpkg -s build-essential >/dev/null 2>&1 && dpkg -s zlib1g-dev >/dev/null 2>&1 && test -x /opt/mandrel/bin/native-image && /opt/mandrel/bin/native-image --version 2>&1 | grep -qi mandrel && /opt/mandrel/bin/native-image --version 2>&1 | grep -Eqi ''25|version 25|jdk-25'''
    $exitCode = Invoke-WslBashAsRoot -DistributionName $DistributionName -Command $cmd
    return ($exitCode -eq 0)
}

function Test-WslUbuntuMandrelPathExported {
    param([Parameter(Mandatory)][string]$DistributionName)

    if (-not (Test-WslUbuntuMandrelJdk25Installed -DistributionName $DistributionName)) { return $false }

    # Check if /opt/mandrel/bin is actually on PATH in a fresh login shell
    $cmd = 'bash -l -c ''printenv PATH'' | grep -q /opt/mandrel/bin'
    $exitCode = Invoke-WslBashAsRoot -DistributionName $DistributionName -Command $cmd
    return ($exitCode -eq 0)
}

function Get-JavaHomeFromJavaExePath {
    param([string]$JavaExePath)

    if ([string]::IsNullOrWhiteSpace($JavaExePath)) { return $null }
    if (-not (Test-Path -LiteralPath $JavaExePath)) { return $null }

    $javaExeName = [IO.Path]::GetFileName($JavaExePath)
    if ($javaExeName -ine 'java.exe') { return $null }

    $binDir = Split-Path -Parent $JavaExePath
    if ([string]::IsNullOrWhiteSpace($binDir)) { return $null }

    $jdkHome = Split-Path -Parent $binDir
    if ([string]::IsNullOrWhiteSpace($jdkHome)) { return $null }
    if (-not (Test-Path -LiteralPath $jdkHome)) { return $null }

    return $jdkHome
}

function Expand-ExistingPathCandidates {
    param([string[]]$Paths)

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        if ($path -match '[*?]') {
            $matches = Resolve-Path -Path $path -ErrorAction SilentlyContinue |
                ForEach-Object { $_.ProviderPath } |
                Sort-Object -Unique
            foreach ($match in $matches) {
                $result.Add($match)
            }
            continue
        }

        if (Test-Path -LiteralPath $path) {
            $resolved = Convert-Path -LiteralPath $path
            if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                $result.Add($resolved)
            }
        }
    }

    return @($result | Select-Object -Unique)
}

function Test-JavaHomeIsJdk25 {
    param([string]$JavaHome)

    if ([string]::IsNullOrWhiteSpace($JavaHome)) { return $false }
    if (-not (Test-Path -LiteralPath $JavaHome)) { return $false }

    $javacPath = Join-Path $JavaHome 'bin\javac.exe'
    if (-not (Test-Path -LiteralPath $javacPath)) { return $false }

    $versionOutput = & $javacPath -version 2>&1 | Out-String
    return ($LASTEXITCODE -eq 0 -and $versionOutput -match '(?im)^javac\s+25(\.|\s|$)')
}

function Get-JavaHomeFromRegistry {
    $registryRoots = @(
        'HKLM:\SOFTWARE\JavaSoft\JDK',
        'HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK'
    )

    foreach ($root in $registryRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $currentVersion = (Get-ItemProperty -LiteralPath $root -Name 'CurrentVersion' -ErrorAction SilentlyContinue).CurrentVersion
        if (-not [string]::IsNullOrWhiteSpace($currentVersion)) {
            $currentKey = Join-Path $root $currentVersion
            $currentHome = (Get-ItemProperty -LiteralPath $currentKey -Name 'JavaHome' -ErrorAction SilentlyContinue).JavaHome
            if (Test-JavaHomeIsJdk25 -JavaHome $currentHome) {
                return $currentHome
            }
        }

        $versionKeys = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($versionKey in $versionKeys) {
            $javaHome = (Get-ItemProperty -LiteralPath $versionKey.PSPath -Name 'JavaHome' -ErrorAction SilentlyContinue).JavaHome
            if (Test-JavaHomeIsJdk25 -JavaHome $javaHome) {
                return $javaHome
            }
        }
    }

    return $null
}

function Resolve-JavaHomePath {
    param(
        [string[]]$CandidateJavaExePaths,
        [string]$DataDrive
    )

    $expandedCandidates = @()
    if ($CandidateJavaExePaths) {
        $expandedCandidates = Expand-PathsWithOptionalDrive -Paths $CandidateJavaExePaths -DataDrive $DataDrive
    }

    $resolvedCandidates = Expand-ExistingPathCandidates -Paths $expandedCandidates
    foreach ($candidate in $resolvedCandidates) {
        $candidateHome = Get-JavaHomeFromJavaExePath -JavaExePath $candidate
        if (Test-JavaHomeIsJdk25 -JavaHome $candidateHome) {
            return $candidateHome
        }
    }

    $javaCmd = Get-Command java -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($javaCmd -and -not [string]::IsNullOrWhiteSpace($javaCmd.Source)) {
        $cmdHome = Get-JavaHomeFromJavaExePath -JavaExePath $javaCmd.Source
        if (Test-JavaHomeIsJdk25 -JavaHome $cmdHome) {
            return $cmdHome
        }
    }

    $registryHome = Get-JavaHomeFromRegistry
    if (Test-JavaHomeIsJdk25 -JavaHome $registryHome) {
        return $registryHome
    }

    return $null
}

[DscResource()]
class DevToolsChocoLibJunction {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty()]
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$DataDrive

    [bool] Test() {
        $dd = Resolve-DataDrive $this.DataDrive
        if (-not $dd -or $dd -eq 'C:') { return $true }

        $lib = Get-ChocoLibPath
        $target = "$dd\ChocolateyLib"
        if (-not (Test-Path -LiteralPath $target)) { return $false }

        $jt = Get-JunctionTarget -Path $lib
        return ($jt -and ($jt -ieq $target))
    }

    [void] Set() {
        $dd = Resolve-DataDrive $this.DataDrive
        if (-not $dd -or $dd -eq 'C:') { return }

        $lib = Get-ChocoLibPath
        $target = "$dd\ChocolateyLib"
        Set-ChocoLibJunctionSafe -LibPath $lib -TargetPath $target
    }

    [DevToolsChocoLibJunction] Get() { return $this }
}

[DscResource()]
class DevToolsPackage {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty(Mandatory)]
    [string]$ChocoPackage

    [DscProperty()]
    [string[]]$AlternateChocoPackages

    [DscProperty()]
    [string[]]$WinGetIds

    [DscProperty()]
    [string[]]$AlternateWinGetIds

    [DscProperty()]
    [string]$DisplayNameLike

    [DscProperty()]
    [string[]]$DisplayNameLikePatterns

    [DscProperty()]
    [string[]]$CandidatePaths

    [DscProperty()]
    [ValidatePattern('^([A-Za-z]:)?$')]
    [string]$DataDrive

    hidden [string] NormalisedDrive() {
        return Resolve-DataDrive $this.DataDrive
    }

    hidden [string[]] AllChocoIds() {
        return [string[]]((@($this.ChocoPackage) + ($this.AlternateChocoPackages | Where-Object { $_ })) | Select-Object -Unique)
    }

    hidden [string[]] AllWingetIds() {
        return [string[]]((@($this.WinGetIds | Where-Object { $_ }) + ($this.AlternateWinGetIds | Where-Object { $_ })) | Select-Object -Unique)
    }

    hidden [bool] TestChocolatey() {
        return Test-ChocoPackageByLibFolder -PackageIds $this.AllChocoIds()
    }

    hidden [bool] TestWinget() {
        $ids = $this.AllWingetIds()
        if (-not $ids -or $ids.Count -eq 0) { return $false }
        return Test-WinGetInstalledAnyId -Ids $ids
    }

    hidden [bool] TestRegistry() {
        $patterns = @()
        if ($this.DisplayNameLikePatterns -and $this.DisplayNameLikePatterns.Count -gt 0) {
            $patterns = $this.DisplayNameLikePatterns
        } elseif (-not [string]::IsNullOrWhiteSpace($this.DisplayNameLike)) {
            $patterns = @($this.DisplayNameLike)
        }
        if ($patterns.Count -eq 0) { return $false }
        return Test-RegistryInstalled3Hives -DisplayNameLikePatterns $patterns
    }

    hidden [bool] TestFileSystem() {
        $expanded = Expand-PathsWithOptionalDrive -Paths $this.CandidatePaths -DataDrive $this.NormalisedDrive()
        foreach ($p in $expanded) {
            $exists = if ($p -match '[*?]') { Test-Path $p } else { Test-Path -LiteralPath $p }
            if ($exists) { return $true }
        }
        return $false
    }

    hidden [bool] TestJetBrainsToolbox() {
        if ($this.Name -ne 'IntelliJCommunity') { return $false }
        foreach ($p in (Get-JetBrainsToolboxIdeaPaths -DataDrive $this.NormalisedDrive())) {
            if (Test-Path -LiteralPath $p) { return $true }
        }
        return $false
    }

    [bool] Test() {
        return (
            $this.TestChocolatey() -or
            $this.TestWinget() -or
            $this.TestRegistry() -or
            $this.TestFileSystem() -or
            $this.TestJetBrainsToolbox()
        )
    }

    [void] Set() {
        if ($this.Test()) { return }

        $props = @{ Name = $this.ChocoPackage; Ensure = 'Present' }
        Invoke-DscResource -Name 'cChocoPackageInstaller' -ModuleName 'cChoco' -Method Set -Property $props | Out-Null
    }

    [DevToolsPackage] Get() { return $this }
}

[DscResource()]
class DevToolsDockerKubernetes {

    [DscProperty(Key)]
    [string]$Name

    [bool] Test() {
        return Test-KubernetesInDockerDesktop
    }

    [void] Set() {
        if ($this.Test()) { return }

        # Enable Kubernetes in Docker Desktop by modifying the settings-store.json
        $configPath = Join-Path $env:APPDATA 'Docker\settings-store.json'
        $configDir = Split-Path $configPath -Parent
        
        if (-not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        if (Test-Path -LiteralPath $configPath) {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        } else {
            $config = @{}
        }

        $config.KubernetesEnabled = $true
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    }

    [DevToolsDockerKubernetes] Get() { return $this }
}

[DscResource()]
class DevToolsWslDistribution {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty(Mandatory)]
    [string]$DistributionName

    [bool] Test() {
        if (Test-IsLocalSystemContext) { return $true }
        return Test-WslDistributionInstalled -DistributionName $this.DistributionName
    }

    [void] Set() {
        if ($this.Test()) { return }

        if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            throw 'wsl.exe not found. Ensure WSL is available before installing a distribution.'
        }

        & wsl.exe --install --distribution $this.DistributionName --no-launch 2>$null | Out-Null

        if (-not $this.Test()) {
            & wsl.exe --install --distribution $this.DistributionName 2>$null | Out-Null
        }

        if (-not $this.Test()) {
            throw "Failed to install WSL distribution '$($this.DistributionName)'."
        }
    }

    [DevToolsWslDistribution] Get() { return $this }
}

[DscResource()]
class DevToolsWslUbuntuGit {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty(Mandatory)]
    [string]$DistributionName

    [bool] Test() {
        if (Test-IsLocalSystemContext) { return $true }
        return Test-WslUbuntuPackageInstalled -DistributionName $this.DistributionName -PackageName 'git'
    }

    [void] Set() {
        if ($this.Test()) { return }

        if (-not (Test-WslDistributionInstalled -DistributionName $this.DistributionName)) {
            throw "WSL distribution '$($this.DistributionName)' is not installed."
        }

        $installCmd = 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y git'
        $exitCode = Invoke-WslBashAsRoot -DistributionName $this.DistributionName -Command $installCmd
        if ($exitCode -ne 0 -or -not $this.Test()) {
            throw "Failed to install git in WSL distribution '$($this.DistributionName)'."
        }
    }

    [DevToolsWslUbuntuGit] Get() { return $this }
}

[DscResource()]
class DevToolsWslUbuntuJavaJdk25 {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty(Mandatory)]
    [string]$DistributionName

    [bool] Test() {
        if (Test-IsLocalSystemContext) { return $true }
        return Test-WslUbuntuJava25JdkInstalled -DistributionName $this.DistributionName
    }

    [void] Set() {
        if ($this.Test()) { return }

        if (-not (Test-WslDistributionInstalled -DistributionName $this.DistributionName)) {
            throw "WSL distribution '$($this.DistributionName)' is not installed."
        }

                $installCmd = 'set -e; export DEBIAN_FRONTEND=noninteractive; rm -f /etc/apt/sources.list.d/adoptium.list; apt-get update; apt-get install -y ca-certificates wget gpg; . /etc/os-release; CODENAME=\${VERSION_CODENAME:-jammy}; mkdir -p /etc/apt/keyrings; wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /etc/apt/keyrings/adopt; echo deb\ [signed-by=/etc/apt/keyrings/adopt]\ https://packages.adoptium.net/artifactory/deb\ \$CODENAME\ main > /etc/apt/sources.list.d/adoptium.list; apt-get update; apt-get install -y temurin-25-jdk'
        $exitCode = Invoke-WslBashAsRoot -DistributionName $this.DistributionName -Command $installCmd
        if ($exitCode -ne 0 -or -not $this.Test()) {
            throw "Failed to install Java 25 JDK in WSL distribution '$($this.DistributionName)'."
        }
    }

    [DevToolsWslUbuntuJavaJdk25] Get() { return $this }
}

[DscResource()]
class DevToolsWslUbuntuJavaHome {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty(Mandatory)]
    [string]$DistributionName

    [bool] Test() {
        if (Test-IsLocalSystemContext) { return $true }
        return Test-WslUbuntuJavaHomeExported -DistributionName $this.DistributionName
    }

    [void] Set() {
        if ($this.Test()) { return }

        $javaHome = Get-WslUbuntuJavaHomePath -DistributionName $this.DistributionName
        if ([string]::IsNullOrWhiteSpace($javaHome)) {
            throw "Unable to resolve Java home path in WSL distribution '$($this.DistributionName)'. Ensure Java 25 JDK is installed."
        }

        $escapedJavaHome = ($javaHome -replace "'", "'\\''")

        $setCmd = @(
            'set -e',
            'PROFILE_FILE=/etc/profile.d/devtools-java-home.sh',
            ('printf ''export JAVA_HOME={0}\nexport PATH=\$JAVA_HOME/bin:\$PATH\n'' > "$PROFILE_FILE"' -f $escapedJavaHome),
            'chmod 644 "$PROFILE_FILE"',
            'if grep -q ''^JAVA_HOME='' /etc/environment; then',
            ('  sed -i "s#^JAVA_HOME=.*#JAVA_HOME={0}#" /etc/environment' -f $javaHome),
            'else',
            ('  printf ''\nJAVA_HOME={0}\n'' >> /etc/environment' -f $escapedJavaHome),
            'fi'
        ) -join '; '

        $exitCode = Invoke-WslBashAsRoot -DistributionName $this.DistributionName -Command $setCmd
        if ($exitCode -ne 0 -or -not $this.Test()) {
            throw "Failed to set JAVA_HOME in WSL distribution '$($this.DistributionName)'."
        }
    }

    [DevToolsWslUbuntuJavaHome] Get() { return $this }
}

[DscResource()]
class DevToolsWslUbuntuMandrelJdk25Install {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty(Mandatory)]
    [string]$DistributionName

    [bool] Test() {
        if (Test-IsLocalSystemContext) { return $true }
        return Test-WslUbuntuMandrelJdk25Installed -DistributionName $this.DistributionName
    }

    [void] Set() {
        if ($this.Test()) { return }

        if (-not (Test-WslDistributionInstalled -DistributionName $this.DistributionName)) {
            throw "WSL distribution '$($this.DistributionName)' is not installed."
        }

        if (-not (Test-WslUbuntuJavaHomeExported -DistributionName $this.DistributionName)) {
            throw "JAVA_HOME dependency is not satisfied in WSL distribution '$($this.DistributionName)'."
        }

        $installCmd = @(
            'set -e',
            'export DEBIAN_FRONTEND=noninteractive',
            'apt-get update',
            'apt-get install -y ca-certificates curl python3 tar gzip build-essential zlib1g-dev',
            'INSTALL_DIR=/opt/mandrel',
            'if [ -x "$INSTALL_DIR/bin/native-image" ]; then exit 0; fi',
            'ARCH=$(uname -m)',
            'PATTERN="(amd64|x86_64)"',
            'if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then PATTERN="(aarch64|arm64)"; fi',
            'URL=$(python3 - <<''PY''',
            'import json, re, sys, urllib.request',
            'arch_pattern = sys.argv[1] if len(sys.argv) > 1 else r"(amd64|x86_64)"',
            'releases = json.load(urllib.request.urlopen("https://api.github.com/repos/graalvm/mandrel/releases"))',
            'for rel in releases:',
            '    for asset in rel.get("assets", []):',
            '        name = asset.get("name", "")',
            '        if re.search(r"java25.*linux.*" + arch_pattern + r".*\\.(tar\\.gz|tgz)$", name, re.I):',
            '            print(asset["browser_download_url"])',
            '            sys.exit(0)',
            'sys.exit(2)',
            'PY',
            '$PATTERN)',
            'if [ -z "$URL" ]; then echo "Could not find Mandrel Java 25 Linux release asset" >&2; exit 2; fi',
            'curl -fL "$URL" -o /tmp/mandrel.tgz',
            'mkdir -p /opt',
            'tar -xzf /tmp/mandrel.tgz -C /opt',
            'FOLDER=$(tar -tzf /tmp/mandrel.tgz | head -1 | cut -d/ -f1)',
            'if [ -z "$FOLDER" ] || [ ! -d "/opt/$FOLDER" ]; then echo "Mandrel archive extraction failed" >&2; exit 3; fi',
            'rm -rf "$INSTALL_DIR"',
            'ln -s "/opt/$FOLDER" "$INSTALL_DIR"'
        ) -join '; '

        $exitCode = Invoke-WslBashAsRoot -DistributionName $this.DistributionName -Command $installCmd
        if ($exitCode -ne 0 -or -not $this.Test()) {
            throw "Failed to install Mandrel Java 25 Native JDK in WSL distribution '$($this.DistributionName)'."
        }
    }

    [DevToolsWslUbuntuMandrelJdk25Install] Get() { return $this }
}

[DscResource()]
class DevToolsWslUbuntuMandrelPath {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty(Mandatory)]
    [string]$DistributionName

    [bool] Test() {
        if (Test-IsLocalSystemContext) { return $true }
        return Test-WslUbuntuMandrelPathExported -DistributionName $this.DistributionName
    }

    [void] Set() {
        if ($this.Test()) { return }

        if (-not (Test-WslUbuntuMandrelJdk25Installed -DistributionName $this.DistributionName)) {
            throw "Mandrel Java 25 Native JDK is not installed in WSL distribution '$($this.DistributionName)'."
        }

        $setCmd = @(
            'set -e',
            'PROFILE_FILE=/etc/profile.d/mandrel.sh',
            'printf ''export MANDREL_HOME="/opt/mandrel"\nexport PATH="/opt/mandrel/bin:\$PATH"\n'' > "$PROFILE_FILE"',
            'chmod 644 "$PROFILE_FILE"'
        ) -join '; '

        $exitCode = Invoke-WslBashAsRoot -DistributionName $this.DistributionName -Command $setCmd
        if ($exitCode -ne 0 -or -not $this.Test()) {
            throw "Failed to configure Mandrel PATH in WSL distribution '$($this.DistributionName)'."
        }
    }

    [DevToolsWslUbuntuMandrelPath] Get() { return $this }
}

[DscResource()]
class DevToolsJavaHome {

    [DscProperty(Key)]
    [string]$Name

    [DscProperty()]
    [string[]]$CandidateJavaExePaths

    [DscProperty()]
    [ValidatePattern('^([A-Za-z]:)?$')]
    [string]$DataDrive

    hidden [string] DesiredJavaHome() {
        return Resolve-JavaHomePath -CandidateJavaExePaths $this.CandidateJavaExePaths -DataDrive (Resolve-DataDrive $this.DataDrive)
    }

    hidden [string] NormalisePath([string]$PathValue) {
        if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
        return $PathValue.Trim().TrimEnd('\\').ToUpperInvariant()
    }

    [bool] Test() {
        $desired = $this.DesiredJavaHome()
        if ([string]::IsNullOrWhiteSpace($desired)) { return $false }

        $current = [Environment]::GetEnvironmentVariable('JAVA_HOME','Machine')
        if ([string]::IsNullOrWhiteSpace($current)) { return $false }

        return ($this.NormalisePath($current) -eq $this.NormalisePath($desired))
    }

    [void] Set() {
        $desired = $this.DesiredJavaHome()
        if ([string]::IsNullOrWhiteSpace($desired)) {
            throw 'Unable to resolve JAVA_HOME from installed Java. Ensure Java JDK 25 is installed and discoverable.'
        }

        [Environment]::SetEnvironmentVariable('JAVA_HOME', $desired, 'Machine')
        $env:JAVA_HOME = $desired
    }

    [DevToolsJavaHome] Get() { return $this }
}
