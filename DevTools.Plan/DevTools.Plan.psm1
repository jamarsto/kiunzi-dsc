using module DevTools.CustomDsc

Set-StrictMode -Version Latest

function New-PlanRow {
    param(
        [string]$Component,
        [string]$Action,
        [string]$DetectedBy,
        [string]$Detail
    )
    [PSCustomObject]@{
        Component  = $Component
        Action     = $Action
        DetectedBy = $DetectedBy
        Detail     = $Detail
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

function Get-WslUbuntuExpectedTemurin25JavaHomePath {
    param([Parameter(Mandatory)][string]$DistributionName)

    $current = Get-WslUbuntuJavaHomePath -DistributionName $DistributionName
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        return $current
    }

    $archOut = & wsl.exe --distribution $DistributionName --user root -- bash -lc 'dpkg --print-architecture' 2>$null
    $arch = ($archOut | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = 'amd64' }
    $arch = ($arch -as [string]).Trim()
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = 'amd64' }

    return "/usr/lib/jvm/temurin-25-jdk-$arch"
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

function Get-DevToolsPlan {
    param([string]$DataDrive, [switch]$IncludeChocoLibJunction)

    $dd = Resolve-DataDrive $DataDrive
    $rows = @()

    # Windows Features (installed first)
    # Virtual Machine Platform
    $vmpEnabled = Test-WindowsFeatureEnabled -FeatureName 'VirtualMachinePlatform'
    $vmpAction = if ($vmpEnabled) { 'SKIP' } else { 'INSTALL / FIX' }
    $vmpDet = if ($vmpEnabled) { 'Enabled' } else { 'Disabled' }
    $rows += New-PlanRow 'Virtual Machine Platform' $vmpAction 'WindowsFeature' $vmpDet

    # WSL (Windows Subsystem for Linux)
    $wslEnabled = Test-WindowsFeatureEnabled -FeatureName 'Microsoft-Windows-Subsystem-Linux'
    $wslAction = if ($wslEnabled) { 'SKIP' } else { 'INSTALL / FIX' }
    $wslDet = if ($wslEnabled) { 'Enabled' } else { 'Disabled' }
    $rows += New-PlanRow 'WSL (Windows Subsystem for Linux)' $wslAction 'WindowsFeature' $wslDet

    # Hyper-V (ordered after VMP/WSL in DSC; only available on non-Home editions)
    $hypervSupported = Test-HyperVSupported
    if ($hypervSupported) {
        $hypervEnabled = Test-WindowsFeatureEnabled -FeatureName 'Microsoft-Hyper-V'
        $hypervAction = if ($hypervEnabled) { 'SKIP' } else { 'INSTALL / FIX' }
        $hypervDet = if ($hypervEnabled) { 'Enabled' } else { 'Disabled' }
    } else {
        $hypervAction = 'SKIP'
        $hypervDet = 'Not supported on this Windows edition'
    }
    $rows += New-PlanRow 'Hyper-V' $hypervAction 'WindowsFeature' $hypervDet

    # Ubuntu distribution on WSL
    if (-not $wslEnabled) {
        $rows += New-PlanRow 'WSL Ubuntu Distribution' 'SKIP' 'Dependency' 'WSL feature not enabled'
    }
    elseif (Test-WslDistributionInstalled -DistributionName 'Ubuntu') {
        $rows += New-PlanRow 'WSL Ubuntu Distribution' 'SKIP' 'WSL' 'Ubuntu distribution installed'
    }
    else {
        $rows += New-PlanRow 'WSL Ubuntu Distribution' 'INSTALL' 'WSL' 'Ubuntu distribution not installed'
    }

    # Git and Java in Ubuntu WSL
    if (-not (Test-WslDistributionInstalled -DistributionName 'Ubuntu')) {
        $rows += New-PlanRow 'WSL Ubuntu Git' 'SKIP' 'Dependency' 'Ubuntu distribution not installed'
        $rows += New-PlanRow 'WSL Ubuntu Java JDK 25' 'SKIP' 'Dependency' 'Ubuntu distribution not installed'
        $rows += New-PlanRow 'WSL Ubuntu JAVA_HOME' 'SKIP' 'Dependency' 'Ubuntu Java JDK 25 not installed'
        $rows += New-PlanRow 'WSL Ubuntu Mandrel Java 25 Native JDK' 'SKIP' 'Dependency' 'WSL Ubuntu JAVA_HOME not configured'
        $rows += New-PlanRow 'WSL Ubuntu Mandrel PATH' 'SKIP' 'Dependency' 'WSL Ubuntu Mandrel Java 25 Native JDK not installed'
    }
    else {
        if (Test-WslUbuntuPackageInstalled -DistributionName 'Ubuntu' -PackageName 'git') {
            $rows += New-PlanRow 'WSL Ubuntu Git' 'SKIP' 'WSL' 'git installed'
        }
        else {
            $rows += New-PlanRow 'WSL Ubuntu Git' 'INSTALL' 'WSL' 'git not installed'
        }

        if (Test-WslUbuntuJava25JdkInstalled -DistributionName 'Ubuntu') {
            $rows += New-PlanRow 'WSL Ubuntu Java JDK 25' 'SKIP' 'WSL' 'temurin-25-jdk installed'
        }
        else {
            $rows += New-PlanRow 'WSL Ubuntu Java JDK 25' 'INSTALL' 'WSL' 'temurin-25-jdk not installed'
        }

        if (-not (Test-WslUbuntuJava25JdkInstalled -DistributionName 'Ubuntu')) {
            $expectedWslJavaHome = Get-WslUbuntuExpectedTemurin25JavaHomePath -DistributionName 'Ubuntu'
            $rows += New-PlanRow 'WSL Ubuntu JAVA_HOME' 'FIX' 'WSL' "JAVA_HOME should be exported as '$expectedWslJavaHome' after temurin-25-jdk install"
        }
        else {
            $wslJavaHome = Get-WslUbuntuJavaHomePath -DistributionName 'Ubuntu'
            if ([string]::IsNullOrWhiteSpace($wslJavaHome)) {
                $rows += New-PlanRow 'WSL Ubuntu JAVA_HOME' 'FIX' 'WSL' 'Unable to resolve Temurin 25 Java home path in Ubuntu'
            }
            elseif (Test-WslUbuntuJavaHomeExported -DistributionName 'Ubuntu') {
            $rows += New-PlanRow 'WSL Ubuntu JAVA_HOME' 'SKIP' 'WSL' $wslJavaHome
            }
            else {
                $rows += New-PlanRow 'WSL Ubuntu JAVA_HOME' 'FIX' 'WSL' "JAVA_HOME not exported as '$wslJavaHome'"
            }
        }

        if (Test-WslUbuntuMandrelJdk25Installed -DistributionName 'Ubuntu') {
            $rows += New-PlanRow 'WSL Ubuntu Mandrel Java 25 Native JDK' 'SKIP' 'WSL' '/opt/mandrel'
            if (Test-WslUbuntuMandrelPathExported -DistributionName 'Ubuntu') {
                $rows += New-PlanRow 'WSL Ubuntu Mandrel PATH' 'SKIP' 'WSL' 'export PATH="/opt/mandrel/bin:$PATH"'
            }
            else {
                $rows += New-PlanRow 'WSL Ubuntu Mandrel PATH' 'FIX' 'WSL' 'Expected line: export PATH="/opt/mandrel/bin:$PATH"'
            }
        }
        else {
            $rows += New-PlanRow 'WSL Ubuntu Mandrel Java 25 Native JDK' 'INSTALL' 'WSL' '/opt/mandrel not installed'
            $rows += New-PlanRow 'WSL Ubuntu Mandrel PATH' 'FIX' 'WSL' 'Expected after install: export PATH="/opt/mandrel/bin:$PATH"'
        }
    }

    # Chocolatey (installed after Windows features)
    $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $chocoCmd) {
        $rows += New-PlanRow 'Chocolatey' 'INSTALL / FIX' 'PATH' 'choco not resolvable on PATH'
    }
    else {
        $expected = 'C:\ProgramData\chocolatey'
        $envInstall = [Environment]::GetEnvironmentVariable('ChocolateyInstall','Machine')
        if ($envInstall -ne $expected) {
            $rows += New-PlanRow 'Chocolatey' 'INSTALL / FIX' 'EnvVar' "ChocolateyInstall='$envInstall' (expected '$expected')"
        }
        else {
            $rows += New-PlanRow 'Chocolatey' 'SKIP' 'PATH+EnvVar' "choco OK; ChocolateyInstall='$envInstall'"
        }
    }

    if (-not $IncludeChocoLibJunction) {
        $rows += New-PlanRow 'Chocolatey lib junction' 'SKIP' 'NotApplicable' 'Junction creation not enabled'
    }
    elseif (-not $dd) {
        $rows += New-PlanRow 'Chocolatey lib junction' 'SKIP' 'NotApplicable' 'No DataDrive supplied'
    }
    elseif ($dd -eq 'C:') {
        $rows += New-PlanRow 'Chocolatey lib junction' 'SKIP' 'NotApplicable' 'DataDrive is C:; junction not required'
    }
    else {
        $lib = Get-ChocoLibPath
        $target = "$dd\ChocolateyLib"
        $jt = Get-JunctionTarget -Path $lib
        if ($jt -ne $target) {
            $detail = if ($jt) { "junction -> '$jt' (expected '$target')" } else { "not a junction (expected junction -> '$target')" }
            $rows += New-PlanRow 'Chocolatey lib junction' 'FIX' 'Junction' $detail
        }
        else {
            $rows += New-PlanRow 'Chocolatey lib junction' 'SKIP' ("Junction(" + $dd + ")") "$lib -> $jt"
        }
    }

    $vsCandidatePaths = @(
        'C:\Program Files\Microsoft VS Code\Code.exe',
        'C:\Program Files (x86)\Microsoft VS Code\Code.exe',
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
    )

    if ($dd -and $dd -ne 'C:') {
        $vsCandidatePaths += @(
            "$dd\Program Files\Microsoft VS Code\Code.exe",
            "$dd\Program Files (x86)\Microsoft VS Code\Code.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Microsoft VS Code\Code.exe",
            "$dd\$env:USERNAME\AppData\Local\Programs\Microsoft VS Code\Code.exe"
        )
    }

    $vs = [DevToolsPackage]@{
        Name='VSCode'
        ChocoPackage='vscode'
        AlternateChocoPackages=@('vscode.install','vscode.portable','vscode-insiders','vscode-insiders.install')
        WinGetIds=@('Microsoft.VisualStudioCode')
        AlternateWinGetIds=@('Microsoft.VisualStudioCode.CLI','Microsoft.VisualStudioCode.Insiders','Microsoft.VisualStudioCode.Insiders.CLI')
        DisplayNameLike='*Visual Studio Code*'
        CandidatePaths=$vsCandidatePaths
        DataDrive=$dd
    }

        $det = if ($vs.TestChocolatey()) { @{By='Chocolatey';Detail=($vs.AllChocoIds() -join ',')} }
            elseif ($vs.TestWinget()) {
              $wingetId = Get-WinGetInstalledId -Ids $vs.AllWingetIds()
              @{By='Winget';Detail=($(if ($wingetId) { $wingetId } else { $vs.AllWingetIds() -join ',' }))}
            }
           elseif ($vs.TestRegistry()) { @{By='Registry';Detail=$vs.DisplayNameLike} }
           elseif ($vs.TestFileSystem()) {
                $existing = Expand-PathsWithOptionalDrive -Paths $vs.CandidatePaths -DataDrive $dd | Where-Object { Test-Path $_ }
                $drives = $existing | ForEach-Object { $_.Substring(0,2).ToUpper() } | Select-Object -Unique | Sort-Object
                @{By=("FileSystem(" + ($drives -join ',') + ")");Detail=($existing -join ', ')}
           } else { @{By='NotDetected';Detail='No detection mechanisms matched'} }

    $action = if ($vs.Test()) { 'SKIP' } else { 'INSTALL' }
    $rows += New-PlanRow 'VS Code' $action $det.By $det.Detail

    $ideaCandidatePaths = @(
        'C:\Program Files\JetBrains\IntelliJ IDEA Community Edition\bin\idea64.exe',
        'C:\Program Files\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe',
        'C:\Program Files (x86)\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe',
        "$env:LOCALAPPDATA\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea64.exe",
        "$env:LOCALAPPDATA\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe",
        "$env:LOCALAPPDATA\Programs\IntelliJ IDEA Community Edition\bin\idea64.exe",
        "$env:LOCALAPPDATA\Programs\IntelliJ IDEA Community Edition\bin\idea.exe"
    )

    if ($dd -and $dd -ne 'C:') {
        $ideaCandidatePaths += @(
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea64.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe",
            "$dd\$env:USERNAME\AppData\Local\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea64.exe",
            "$dd\$env:USERNAME\AppData\Local\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\IntelliJ IDEA Community Edition\bin\idea64.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\IntelliJ IDEA Community Edition\bin\idea.exe",
            "$dd\$env:USERNAME\AppData\Local\Programs\IntelliJ IDEA Community Edition\bin\idea64.exe",
            "$dd\$env:USERNAME\AppData\Local\Programs\IntelliJ IDEA Community Edition\bin\idea.exe"
        )
    }

    $idea = [DevToolsPackage]@{
        Name='IntelliJCommunity'
        ChocoPackage='intellijidea-community'
        AlternateChocoPackages=@('intellijidea-community.install')
        WinGetIds=@('JetBrains.IntelliJIDEA.Community')
        AlternateWinGetIds=@('JetBrains.IntelliJIDEA.Community.EAP')
        DisplayNameLike='*IntelliJ IDEA Community*'
        CandidatePaths=$ideaCandidatePaths
        DataDrive=$dd
    }

        $det = if ($idea.TestChocolatey()) { @{By='Chocolatey';Detail=($idea.AllChocoIds() -join ',')} }
            elseif ($idea.TestWinget()) {
              $wingetId = Get-WinGetInstalledId -Ids $idea.AllWingetIds()
              @{By='Winget';Detail=($(if ($wingetId) { $wingetId } else { $idea.AllWingetIds() -join ',' }))}
            }
           elseif ($idea.TestJetBrainsToolbox()) {
                $existing = Get-JetBrainsToolboxIdeaPaths -DataDrive $dd | Where-Object { Test-Path $_ }
                $drives = $existing | ForEach-Object { $_.Substring(0,2).ToUpper() } | Select-Object -Unique | Sort-Object
                @{By=("JetBrainsToolbox(" + ($drives -join ',') + ")");Detail=($existing -join ', ')}
           }
           elseif ($idea.TestRegistry()) { @{By='Registry';Detail=$idea.DisplayNameLike} }
           elseif ($idea.TestFileSystem()) {
                $existing = Expand-PathsWithOptionalDrive -Paths $idea.CandidatePaths -DataDrive $dd | Where-Object { Test-Path $_ }
                $drives = $existing | ForEach-Object { $_.Substring(0,2).ToUpper() } | Select-Object -Unique | Sort-Object
                @{By=("FileSystem(" + ($drives -join ',') + ")");Detail=($existing -join ', ')}
           } else { @{By='NotDetected';Detail='No detection mechanisms matched'} }

    $action = if ($idea.Test()) { 'SKIP' } else { 'INSTALL' }
    $rows += New-PlanRow 'IntelliJ IDEA Community' $action $det.By $det.Detail

    # Git
    $gitCandidatePaths = @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe',
        'C:\Program Files (x86)\Git\cmd\git.exe',
        'C:\Program Files (x86)\Git\bin\git.exe',
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\git.exe"
    )

    if ($dd -and $dd -ne 'C:') {
        $gitCandidatePaths += @(
            "$dd\Program Files\Git\cmd\git.exe",
            "$dd\Program Files\Git\bin\git.exe",
            "$dd\Program Files (x86)\Git\cmd\git.exe",
            "$dd\Program Files (x86)\Git\bin\git.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Git\cmd\git.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Git\bin\git.exe",
            "$dd\$env:USERNAME\AppData\Local\Programs\Git\cmd\git.exe",
            "$dd\$env:USERNAME\AppData\Local\Programs\Git\bin\git.exe"
        )
    }

    $git = [DevToolsPackage]@{
        Name='Git'
        ChocoPackage='git'
        AlternateChocoPackages=@('git.install','git.portable')
        WinGetIds=@('Git.Git')
        AlternateWinGetIds=@('Git.Git.PreRelease')
        DisplayNameLike='*Git*'
        CandidatePaths=$gitCandidatePaths
        DataDrive=$dd
    }

        $det = if ($git.TestChocolatey()) { @{By='Chocolatey';Detail=($git.AllChocoIds() -join ',')} }
            elseif ($git.TestWinget()) {
              $wingetId = Get-WinGetInstalledId -Ids $git.AllWingetIds()
              @{By='Winget';Detail=($(if ($wingetId) { $wingetId } else { $git.AllWingetIds() -join ',' }))}
            }
           elseif ($git.TestRegistry()) { @{By='Registry';Detail=$git.DisplayNameLike} }
           elseif ($git.TestFileSystem()) {
                $existing = Expand-PathsWithOptionalDrive -Paths $git.CandidatePaths -DataDrive $dd | Where-Object { Test-Path $_ }
                $drives = $existing | ForEach-Object { $_.Substring(0,2).ToUpper() } | Select-Object -Unique | Sort-Object
                @{By=("FileSystem(" + ($drives -join ',') + ")");Detail=($existing -join ', ')}
           } else { @{By='NotDetected';Detail='No detection mechanisms matched'} }

    $action = if ($git.Test()) { 'SKIP' } else { 'INSTALL' }
    $rows += New-PlanRow 'Git' $action $det.By $det.Detail

    # Terraform
    $terraformCandidatePaths = @(
        'C:\Program Files\HashiCorp\Terraform\terraform.exe',
        'C:\HashiCorp\Terraform\terraform.exe',
        "$env:LOCALAPPDATA\Programs\Terraform\terraform.exe"
    )

    if ($dd -and $dd -ne 'C:') {
        $terraformCandidatePaths += @(
            "$dd\Program Files\HashiCorp\Terraform\terraform.exe",
            "$dd\HashiCorp\Terraform\terraform.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Terraform\terraform.exe",
            "$dd\$env:USERNAME\AppData\Local\Programs\Terraform\terraform.exe"
        )
    }

    $terraform = [DevToolsPackage]@{
        Name='Terraform'
        ChocoPackage='terraform'
        AlternateChocoPackages=@()
        WinGetIds=@('Hashicorp.Terraform')
        AlternateWinGetIds=@('Hashicorp.Terraform.Alpha','Hashicorp.Terraform.Beta','Hashicorp.Terraform.RC')
        DisplayNameLike='*Terraform*'
        CandidatePaths=$terraformCandidatePaths
        DataDrive=$dd
    }

        $det = if ($terraform.TestChocolatey()) { @{By='Chocolatey';Detail=($terraform.AllChocoIds() -join ',')} }
            elseif ($terraform.TestWinget()) {
              $wingetId = Get-WinGetInstalledId -Ids $terraform.AllWingetIds()
              @{By='Winget';Detail=($(if ($wingetId) { $wingetId } else { $terraform.AllWingetIds() -join ',' }))}
            }
           elseif ($terraform.TestRegistry()) { @{By='Registry';Detail=$terraform.DisplayNameLike} }
           elseif ($terraform.TestFileSystem()) {
                $existing = Expand-PathsWithOptionalDrive -Paths $terraform.CandidatePaths -DataDrive $dd | Where-Object { Test-Path $_ }
                $drives = $existing | ForEach-Object { $_.Substring(0,2).ToUpper() } | Select-Object -Unique | Sort-Object
                @{By=("FileSystem(" + ($drives -join ',') + ")");Detail=($existing -join ', ')}
           } else { @{By='NotDetected';Detail='No detection mechanisms matched'} }

    $action = if ($terraform.Test()) { 'SKIP' } else { 'INSTALL' }
    $rows += New-PlanRow 'Terraform' $action $det.By $det.Detail

    # Kubeseal (Bitnami Sealed Secrets CLI)
    $kubeseal = [DevToolsPackage]@{
        Name='Kubeseal'
        ChocoPackage='sealed-secrets'
        AlternateChocoPackages=@()
        WinGetIds=@()
        AlternateWinGetIds=@()
        DisplayNameLike='*sealed-secrets*'
        CandidatePaths=@(
            'C:\ProgramData\chocolatey\bin\kubeseal.exe',
            'C:\ProgramData\chocolatey\lib\sealed-secrets\tools\kubeseal.exe'
        )
        DataDrive=$dd
    }

        $det = if ($kubeseal.TestChocolatey()) { @{By='Chocolatey';Detail=($kubeseal.AllChocoIds() -join ',')} }
            elseif ($kubeseal.TestWinget()) {
              $wingetId = Get-WinGetInstalledId -Ids $kubeseal.AllWingetIds()
              @{By='Winget';Detail=($(if ($wingetId) { $wingetId } else { $kubeseal.AllWingetIds() -join ',' }))}
            }
           elseif ($kubeseal.TestRegistry()) { @{By='Registry';Detail=$kubeseal.DisplayNameLike} }
           elseif ($kubeseal.TestFileSystem()) {
                $existing = Expand-PathsWithOptionalDrive -Paths $kubeseal.CandidatePaths -DataDrive $dd | Where-Object { Test-Path $_ }
                $drives = $existing | ForEach-Object { $_.Substring(0,2).ToUpper() } | Select-Object -Unique | Sort-Object
                @{By=("FileSystem(" + ($drives -join ',') + ")");Detail=($existing -join ', ')}
           } else { @{By='NotDetected';Detail='No detection mechanisms matched'} }

    $action = if ($kubeseal.Test()) { 'SKIP' } else { 'INSTALL' }
    $rows += New-PlanRow 'Kubeseal (Sealed Secrets CLI)' $action $det.By $det.Detail

    # Java JDK 25
    $java = [DevToolsPackage]@{
        Name='JavaJDK25'
        ChocoPackage='Temurin25'
        AlternateChocoPackages=@('microsoft-openjdk25','corretto25jdk','zulu25')
        WinGetIds=@('EclipseAdoptium.Temurin.25.JDK')
        AlternateWinGetIds=@('Oracle.JDK.25','Microsoft.OpenJDK.25','Amazon.Corretto.25.JDK','Azul.Zulu.25.JDK','Azul.ZuluFX.25.JDK','BellSoft.LibericaJDK.25','BellSoft.LibericaJDK.25.Full','BellSoft.LibericaJDK.25.Lite')
        DisplayNameLikePatterns=@('*Temurin*25*','*Corretto*25*','*Java*25*')
        CandidatePaths=@(
            'C:\Program Files\Eclipse Adoptium\jdk-25*\bin\java.exe',
            'C:\Program Files\Amazon Corretto\jdk25*\bin\java.exe',
            'C:\Program Files\Java\latest\jdk-25\bin\java.exe',
            'C:\Program Files\Java\jdk-25*\bin\java.exe',
            'C:\Program Files\Java\jdk25\bin\java.exe',
            'C:\Program Files (x86)\Eclipse Adoptium\jdk-25*\bin\java.exe',
            'C:\Program Files (x86)\Amazon Corretto\jdk25*\bin\java.exe',
            'C:\Program Files (x86)\Java\latest\jdk-25\bin\java.exe',
            'C:\Program Files (x86)\Java\jdk-25*\bin\java.exe',
            'C:\Program Files (x86)\Java\jdk25\bin\java.exe',
            "$env:LOCALAPPDATA\Programs\Eclipse Adoptium\jdk-25*\bin\java.exe",
            "$env:LOCALAPPDATA\Programs\Amazon Corretto\jdk25*\bin\java.exe",
            "$env:LOCALAPPDATA\Programs\Java\latest\jdk-25\bin\java.exe",
            "$env:LOCALAPPDATA\Programs\Java\jdk-25*\bin\java.exe",
            "$env:LOCALAPPDATA\Programs\Java\jdk25\bin\java.exe"
        ) + $(if ($dd -and $dd -ne 'C:') { @(
            "$dd\Program Files\Eclipse Adoptium\jdk-25*\bin\java.exe",
            "$dd\Program Files\Amazon Corretto\jdk25*\bin\java.exe",
            "$dd\Program Files\Java\latest\jdk-25\bin\java.exe",
            "$dd\Program Files\Java\jdk-25*\bin\java.exe",
            "$dd\Program Files\Java\jdk25\bin\java.exe",
            "$dd\Program Files (x86)\Eclipse Adoptium\jdk-25*\bin\java.exe",
            "$dd\Program Files (x86)\Amazon Corretto\jdk25*\bin\java.exe",
            "$dd\Program Files (x86)\Java\latest\jdk-25\bin\java.exe",
            "$dd\Program Files (x86)\Java\jdk-25*\bin\java.exe",
            "$dd\Program Files (x86)\Java\jdk25\bin\java.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Eclipse Adoptium\jdk-25*\bin\java.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Amazon Corretto\jdk25*\bin\java.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Java\latest\jdk-25\bin\java.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Java\jdk-25*\bin\java.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Programs\Java\jdk25\bin\java.exe"
        )} else { @() })
        DataDrive=$dd
    }

        $det = if ($java.TestChocolatey()) { @{By='Chocolatey';Detail=($java.AllChocoIds() -join ',')} }
            elseif ($java.TestWinget()) {
              $wingetId = Get-WinGetInstalledId -Ids $java.AllWingetIds()
              @{By='Winget';Detail=($(if ($wingetId) { $wingetId } else { $java.AllWingetIds() -join ',' }))}
            }
           elseif ($java.TestRegistry()) { @{By='Registry';Detail=($java.DisplayNameLikePatterns -join ',')} }
           elseif ($java.TestFileSystem()) {
                $existing = Expand-PathsWithOptionalDrive -Paths $java.CandidatePaths -DataDrive $dd | Where-Object { Test-Path $_ }
                $drives = $existing | ForEach-Object { $_.Substring(0,2).ToUpper() } | Select-Object -Unique | Sort-Object
                @{By=("FileSystem(" + ($drives -join ',') + ")");Detail=($existing -join ', ')}
           } else { @{By='NotDetected';Detail='No detection mechanisms matched'} }

    $action = if ($java.Test()) { 'SKIP' } else { 'INSTALL' }
    $rows += New-PlanRow 'Java JDK 25' $action $det.By $det.Detail

    $resolvedJavaHome = Resolve-JavaHomePath -CandidateJavaExePaths $java.CandidatePaths -DataDrive $dd
    $currentJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME','Machine')

    if ([string]::IsNullOrWhiteSpace($resolvedJavaHome)) {
        $rows += New-PlanRow 'JAVA_HOME' 'FIX' 'JavaDetection' 'Unable to resolve Java install path for JAVA_HOME'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($currentJavaHome) -and ($currentJavaHome.Trim().TrimEnd('\\') -ieq $resolvedJavaHome.Trim().TrimEnd('\\'))) {
        $rows += New-PlanRow 'JAVA_HOME' 'SKIP' 'Environment(Machine)' $currentJavaHome
    }
    else {
        $rows += New-PlanRow 'JAVA_HOME' 'FIX' 'Environment(Machine)' "JAVA_HOME='$currentJavaHome' (expected '$resolvedJavaHome')"
    }

    # Docker Desktop
    $dockerCandidatePaths = @(
        'C:\Program Files\Docker\Docker\Docker.exe',
        'C:\Program Files (x86)\Docker\Docker\Docker.exe',
        "$env:LOCALAPPDATA\Docker\Docker.exe"
    )

    if ($dd -and $dd -ne 'C:') {
        $dockerCandidatePaths += @(
            "$dd\Program Files\Docker\Docker\Docker.exe",
            "$dd\Program Files (x86)\Docker\Docker\Docker.exe",
            "$dd\Users\$env:USERNAME\AppData\Local\Docker\Docker.exe",
            "$dd\$env:USERNAME\AppData\Local\Docker\Docker.exe"
        )
    }

    $docker = [DevToolsPackage]@{
        Name='Docker'
        ChocoPackage='docker-desktop'
        AlternateChocoPackages=@('docker-for-windows')
        WinGetIds=@('Docker.DockerDesktop')
        AlternateWinGetIds=@('Docker.DockerDesktopEdge')
        DisplayNameLike='*Docker Desktop*'
        CandidatePaths=$dockerCandidatePaths
        DataDrive=$dd
    }

        $det = if ($docker.TestChocolatey()) { @{By='Chocolatey';Detail=($docker.AllChocoIds() -join ',')} }
            elseif ($docker.TestWinget()) {
              $wingetId = Get-WinGetInstalledId -Ids $docker.AllWingetIds()
              @{By='Winget';Detail=($(if ($wingetId) { $wingetId } else { $docker.AllWingetIds() -join ',' }))}
            }
           elseif ($docker.TestRegistry()) { @{By='Registry';Detail=$docker.DisplayNameLike} }
           elseif ($docker.TestFileSystem()) {
                $existing = Expand-PathsWithOptionalDrive -Paths $docker.CandidatePaths -DataDrive $dd | Where-Object { Test-Path $_ }
                $drives = $existing | ForEach-Object { $_.Substring(0,2).ToUpper() } | Select-Object -Unique | Sort-Object
                @{By=("FileSystem(" + ($drives -join ',') + ")");Detail=($existing -join ', ')}
           } else { @{By='NotDetected';Detail='No detection mechanisms matched'} }

    $action = if ($docker.Test()) { 'SKIP' } else { 'INSTALL' }
    $rows += New-PlanRow 'Docker Desktop' $action $det.By $det.Detail

    if (-not $docker.Test()) {
        $rows += New-PlanRow 'Docker Desktop Kubernetes' 'SKIP' 'Dependency' 'Docker Desktop not installed'
    }
    elseif (Test-KubernetesInDockerDesktop) {
        $rows += New-PlanRow 'Docker Desktop Kubernetes' 'SKIP' 'DockerConfig' 'Enabled'
    }
    else {
        $rows += New-PlanRow 'Docker Desktop Kubernetes' 'INSTALL / FIX' 'DockerConfig' 'Kubernetes not enabled'
    }

    return $rows
}
