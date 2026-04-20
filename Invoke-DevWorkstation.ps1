[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$y,
    [string]$DataDrive,
    [switch]$IncludeChocoLibJunction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# In PowerShell 7+, keep native stderr text from becoming terminating errors.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if (-not $DataDrive) { $DataDrive = "C:" }

$logRoot = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logRoot)) { New-Item -ItemType Directory -Path $logRoot | Out-Null }
$logFile = Join-Path $logRoot ("DevWorkstation-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts  $Message" | Tee-Object -FilePath $logFile -Append | Out-Null
}

if ($DataDrive) {
    if ($DataDrive -notmatch '^[A-Za-z]:$') { throw "Invalid DataDrive '$DataDrive'. Expected format 'D:'." }
    $DataDrive = $DataDrive.ToUpper()
}

function Install-LocalModule {
    param(
        [Parameter(Mandatory)][string]$ModuleName,
        [Parameter(Mandatory)][string]$SourceFolder
    )

    $destRoot = Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$ModuleName\1.0.0"
    if (-not (Test-Path $destRoot)) { New-Item -ItemType Directory -Path $destRoot -Force | Out-Null }
    Copy-Item -Path (Join-Path $SourceFolder '*') -Destination $destRoot -Recurse -Force

    # Ensure copied module files are treated as local/trusted for DSC LCM imports.
    Get-ChildItem -Path $destRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
}

function Get-WslInstalledDistributionsLocal {
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

function Test-WslDistributionInstalledLocal {
    param([Parameter(Mandatory)][string]$DistributionName)

    $installed = Get-WslInstalledDistributionsLocal
    if (-not $installed -or $installed.Count -eq 0) { return $false }

    foreach ($d in $installed) {
        if ($d -ieq $DistributionName) { return $true }
        if ($DistributionName -ieq 'Ubuntu' -and $d -imatch '^Ubuntu($|-|\s)') { return $true }
    }

    return $false
}

function Invoke-WslRootCommand {
    param(
        [Parameter(Mandatory)][string]$DistributionName,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSeconds = 1800,
        [string]$StepName = 'WSL',
        [int]$HeartbeatSeconds = 10
    )

    $job = $null
    try {
        Write-Log ("WSL APPLY | {0} | Start (timeout={1}s)" -f $StepName, $TimeoutSeconds)

        $job = Start-Job -ScriptBlock {
            param($Dist, $Cmd)
            $ErrorActionPreference = 'Continue'
            $output = & wsl.exe --distribution $Dist --user root -- bash -lc $Cmd 2>&1
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = @($output | ForEach-Object { ($_ -as [string]) })
            }
        } -ArgumentList $DistributionName, $Command

        $start = Get-Date
        $nextProgressAt = $start.AddSeconds($HeartbeatSeconds)
        while ($true) {
            if (Wait-Job -Job $job -Timeout 5) { break }

            $now = Get-Date
            if ($now -ge $nextProgressAt) {
                $elapsed = [int]($now - $start).TotalSeconds
                Write-Log ("WSL APPLY | {0} | Running ({1}s elapsed)" -f $StepName, $elapsed)
                $nextProgressAt = $now.AddSeconds($HeartbeatSeconds)
            }

            if (($now - $start).TotalSeconds -ge $TimeoutSeconds) {
                Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
                throw "WSL command timed out after $TimeoutSeconds seconds during '$StepName'."
            }
        }

        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($null -eq $result) { return 1 }

        $exitCode = [int]$result.ExitCode
        if ($exitCode -ne 0 -and $result.Output) {
            $lines = @($result.Output | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 5)
            foreach ($line in $lines) {
                Write-Log ("WSL APPLY | {0} | Output: {1}" -f $StepName, $line)
            }
        }

        Write-Log ("WSL APPLY | {0} | End (exit={1})" -f $StepName, $exitCode)
        return $exitCode
    }
    finally {
        if ($job) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Install-WslDistributionLocal {
    param([Parameter(Mandatory)][string]$DistributionName)

    if (Test-WslDistributionInstalledLocal -DistributionName $DistributionName) {
        Write-Log 'WSL APPLY | UbuntuWSL | Action=SKIP'
        return
    }

    Write-Log 'WSL APPLY | UbuntuWSL | Action=SET'
    & wsl.exe --install --distribution $DistributionName --no-launch 2>$null | Out-Null

    if (-not (Test-WslDistributionInstalledLocal -DistributionName $DistributionName)) {
        & wsl.exe --install --distribution $DistributionName 2>$null | Out-Null
    }

    if (-not (Test-WslDistributionInstalledLocal -DistributionName $DistributionName)) {
        throw "Failed to install WSL distribution '$DistributionName'."
    }
}

function Install-WslUbuntuGitLocal {
    param([Parameter(Mandatory)][string]$DistributionName)

    $testCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'dpkg -s git >/dev/null 2>&1' -TimeoutSeconds 120 -StepName 'UbuntuWSLGit Test'
    if ($testCode -eq 0) {
        Write-Log 'WSL APPLY | UbuntuWSLGit | Action=SKIP'
        return
    }

    Write-Log 'WSL APPLY | UbuntuWSLGit | Action=SET'
    $installCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'apt-get -o DPkg::Lock::Timeout=120 update && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y git' -TimeoutSeconds 1200 -StepName 'UbuntuWSLGit Set'
    if ($installCode -ne 0) {
        throw "Failed to install git in WSL distribution '$DistributionName'."
    }
}

function Install-WslUbuntuJavaJdk25Local {
    param([Parameter(Mandatory)][string]$DistributionName)

    $testCmd = 'dpkg -s temurin-25-jdk >/dev/null 2>&1 && command -v javac >/dev/null 2>&1 && javac -version 2>&1 | grep -Eq ''^javac 25(\.|$)'''
    $testCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command $testCmd -TimeoutSeconds 120 -StepName 'UbuntuWSLJavaJDK25 Test'
    if ($testCode -eq 0) {
        Write-Log 'WSL APPLY | UbuntuWSLJavaJDK25 | Action=SKIP'
        return
    }

    Write-Log 'WSL APPLY | UbuntuWSLJavaJDK25 | Action=SET'
        $step0 = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'rm -f /etc/apt/sources.list.d/adoptium.list' -TimeoutSeconds 60 -StepName 'UbuntuWSLJavaJDK25 Set cleanup-adoptium-source'
        if ($step0 -ne 0) { throw "Failed during UbuntuWSLJavaJDK25 source cleanup (step 0)." }

    $step1 = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=120 update' -TimeoutSeconds 300 -StepName 'UbuntuWSLJavaJDK25 Set apt-update-1'
    if ($step1 -ne 0) { throw "Failed during UbuntuWSLJavaJDK25 apt update (step 1)." }

    $step2 = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates wget gpg' -TimeoutSeconds 600 -StepName 'UbuntuWSLJavaJDK25 Set prereqs'
    if ($step2 -ne 0) { throw "Failed during UbuntuWSLJavaJDK25 prerequisite package install (step 2)." }

    $step3 = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'set -e; . /etc/os-release; CODENAME=\${VERSION_CODENAME:-jammy}; mkdir -p /etc/apt/keyrings; wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /etc/apt/keyrings/adopt; echo deb\ [signed-by=/etc/apt/keyrings/adopt]\ https://packages.adoptium.net/artifactory/deb\ \$CODENAME\ main > /etc/apt/sources.list.d/adoptium.list' -TimeoutSeconds 180 -StepName 'UbuntuWSLJavaJDK25 Set adoptium-repo'
    if ($step3 -ne 0) { throw "Failed during UbuntuWSLJavaJDK25 Adoptium repository configuration (step 3)." }

    $step4 = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=120 update' -TimeoutSeconds 300 -StepName 'UbuntuWSLJavaJDK25 Set apt-update-2'
    if ($step4 -ne 0) { throw "Failed during UbuntuWSLJavaJDK25 apt update after repo config (step 4)." }

    $step5 = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=120 install -y temurin-25-jdk' -TimeoutSeconds 900 -StepName 'UbuntuWSLJavaJDK25 Set install-temurin25'
    if ($step5 -ne 0) { throw "Failed during UbuntuWSLJavaJDK25 Temurin install (step 5)." }

    $verifyCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'dpkg -s temurin-25-jdk >/dev/null 2>&1 && command -v javac >/dev/null 2>&1 && javac -version 2>&1 | grep -Eq ''^javac 25(\.|$)''' -TimeoutSeconds 120 -StepName 'UbuntuWSLJavaJDK25 Verify'
    if ($verifyCode -ne 0) {
        throw "Java 25 JDK verification failed in WSL distribution '$DistributionName'."
    }
}

function Get-WslUbuntuJavaHomePathLocal {
    param([Parameter(Mandatory)][string]$DistributionName)

    $cmd = 'if command -v javac >/dev/null 2>&1; then readlink -f "$(command -v javac)" | sed ''s:/bin/javac$::''; fi'
    $out = & wsl.exe --distribution $DistributionName --user root -- bash -lc $cmd 2>$null
    if (-not $out) { return $null }

    $line = ($out | Select-Object -First 1)
    if (-not $line) { return $null }

    $javaHome = ($line -as [string]).Trim()
    if ([string]::IsNullOrWhiteSpace($javaHome)) { return $null }
    return $javaHome
}

function Set-WslUbuntuJavaHomeLocal {
    param([Parameter(Mandatory)][string]$DistributionName)

    $javaHome = Get-WslUbuntuJavaHomePathLocal -DistributionName $DistributionName
    if ([string]::IsNullOrWhiteSpace($javaHome)) {
        throw "Unable to resolve Java home path in WSL distribution '$DistributionName'. Ensure Java 25 JDK is installed."
    }

    $escapedJavaHome = ($javaHome -replace "'", "'\\''")
    $testCmd = "grep -Fxq 'JAVA_HOME=$escapedJavaHome' /etc/environment && grep -Fxq 'export JAVA_HOME=$escapedJavaHome' /etc/profile.d/devtools-java-home.sh"
    $testCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command $testCmd -TimeoutSeconds 120 -StepName 'UbuntuWSLJavaHome Test'
    if ($testCode -eq 0) {
        Write-Log 'WSL APPLY | UbuntuWSLJavaHome | Action=SKIP'
        return
    }

    Write-Log 'WSL APPLY | UbuntuWSLJavaHome | Action=SET'
    $setCmd = @(
        'set -e',
        ('printf ''export JAVA_HOME={0}\nexport PATH=\$JAVA_HOME/bin:\$PATH\n'' > /etc/profile.d/devtools-java-home.sh' -f $escapedJavaHome),
        'chmod 644 /etc/profile.d/devtools-java-home.sh',
        ('grep -q ''^JAVA_HOME='' /etc/environment && sed -i ''s#^JAVA_HOME=.*#JAVA_HOME={0}#'' /etc/environment || printf ''\nJAVA_HOME={1}\n'' >> /etc/environment' -f $javaHome, $escapedJavaHome)
    ) -join '; '
    $setCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command $setCmd -TimeoutSeconds 300 -StepName 'UbuntuWSLJavaHome Set'
    if ($setCode -ne 0) {
        throw "Failed to set JAVA_HOME in WSL distribution '$DistributionName'."
    }
}

function Install-WslUbuntuMandrelJdk25Local {
    param([Parameter(Mandatory)][string]$DistributionName)

    $testCmd = 'dpkg -s build-essential >/dev/null 2>&1 && dpkg -s zlib1g-dev >/dev/null 2>&1 && test -x /opt/mandrel/bin/native-image && /opt/mandrel/bin/native-image --version 2>&1 | grep -qi mandrel && /opt/mandrel/bin/native-image --version 2>&1 | grep -Eqi ''25|version 25|jdk-25'''
    $testCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command $testCmd -TimeoutSeconds 120 -StepName 'UbuntuWSLMandrelJDK25Install Test'
    if ($testCode -eq 0) {
        Write-Log 'WSL APPLY | UbuntuWSLMandrelJDK25Install | Action=SKIP'
        return
    }

    Write-Log 'WSL APPLY | UbuntuWSLMandrelJDK25Install | Action=SET'
    $installCmd = 'set -e; export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y ca-certificates curl tar gzip build-essential zlib1g-dev; if [ -x /opt/mandrel/bin/native-image ]; then exit 0; fi; curl -fL https://github.com/graalvm/mandrel/releases/download/mandrel-25.0.2.0-Final/mandrel-java25-linux-amd64-25.0.2.0-Final.tar.gz -o /tmp/mandrel.tgz; test -s /tmp/mandrel.tgz; rm -rf /opt/mandrel; mkdir -p /opt/mandrel; tar -xzf /tmp/mandrel.tgz -C /opt/mandrel --strip-components=1'
    $installCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command $installCmd -TimeoutSeconds 2400 -StepName 'UbuntuWSLMandrelJDK25Install Set'
    if ($installCode -ne 0) {
        throw "Failed to install Mandrel Java 25 Native JDK in WSL distribution '$DistributionName'."
    }
}

function Set-WslUbuntuMandrelPathLocal {
    param([Parameter(Mandatory)][string]$DistributionName)

    $testCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'bash -l -c ''printenv PATH'' | grep -q /opt/mandrel/bin' -TimeoutSeconds 120 -StepName 'UbuntuWSLMandrelPath Test'
    if ($testCode -eq 0) {
        Write-Log 'WSL APPLY | UbuntuWSLMandrelPath | Action=SKIP'
        return
    }

    Write-Log 'WSL APPLY | UbuntuWSLMandrelPath | Action=SET'
    $setCode = Invoke-WslRootCommand -DistributionName $DistributionName -Command 'set -e; printf ''export MANDREL_HOME=/opt/mandrel\nexport PATH=/opt/mandrel/bin:\$PATH\n'' > /etc/profile.d/mandrel.sh; chmod 644 /etc/profile.d/mandrel.sh' -TimeoutSeconds 300 -StepName 'UbuntuWSLMandrelPath Set'
    if ($setCode -ne 0) {
        throw "Failed to set Mandrel PATH exports in WSL distribution '$DistributionName'."
    }
}

function Invoke-WslUserContextApply {
    param([string]$DistributionName = 'Ubuntu')

    Write-Log 'Applying WSL distro/package resources in user context'

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe not found. Ensure WSL is available before installing a distribution.'
    }

    Install-WslDistributionLocal -DistributionName $DistributionName
    Install-WslUbuntuGitLocal -DistributionName $DistributionName
    Install-WslUbuntuJavaJdk25Local -DistributionName $DistributionName
    Set-WslUbuntuJavaHomeLocal -DistributionName $DistributionName
    Install-WslUbuntuMandrelJdk25Local -DistributionName $DistributionName
    Set-WslUbuntuMandrelPathLocal -DistributionName $DistributionName

    Write-Log 'WSL user-context resource apply completed'
}

Install-LocalModule -ModuleName 'DevTools.CustomDsc' -SourceFolder (Join-Path $PSScriptRoot 'DevTools.CustomDsc')
Install-LocalModule -ModuleName 'DevTools.Plan'      -SourceFolder (Join-Path $PSScriptRoot 'DevTools.Plan')

$runMode = if ($Apply) { 'Apply' } else { 'DryRun' }

Write-Log "Invocation started"
Write-Log "Parameters: Apply=$Apply y=$y DataDrive=$DataDrive"
Write-Log "Resolved run mode: $runMode"

switch ($runMode) {

    'DryRun' {
        Write-Log "Executing PLAN (dry-run)"
        Import-Module DevTools.Plan -Force
        $plan = Get-DevToolsPlan -DataDrive $DataDrive -IncludeChocoLibJunction:$IncludeChocoLibJunction
        foreach ($row in $plan) {
            Write-Log ("PLAN | {0} | Action={1} | DetectedBy={2}" -f $row.Component, $row.Action, $row.DetectedBy)
        }
        $plan | Format-Table -AutoSize
        Write-Log "Dry-run completed"
        return
    }

    'Apply' {
        Write-Log "Apply requested"

        if (-not $y) {
            Write-Log "Interactive confirmation required"
            $confirmation = Read-Host 'CONFIRM APPLY'
            if ($confirmation.Trim().ToUpper() -ne 'YES') {
                Write-Log "Apply aborted by user (confirmation='$confirmation')"
                Write-Host "Aborted. No changes made."
                return
            }
            Write-Log "Interactive confirmation accepted"
        }
        else {
            Write-Log "Non-interactive mode (-y) enabled; skipping confirmation"
        }

        if (-not (Get-Module -ListAvailable -Name cChoco)) {
            Write-Log "Installing cChoco module (required for apply)"
            Install-Module cChoco -Repository PSGallery -Force
        }

        Write-Log "Compiling DSC configuration"
        . (Join-Path $PSScriptRoot 'DevWorkstation.ps1')
        DevWorkstation -DataDrive $DataDrive -IncludeChocoLibJunction $IncludeChocoLibJunction -OutputPath (Join-Path $PSScriptRoot 'DevWorkstation')

        Write-Log "DSC apply initiated (job handed off to LCM)"
        Start-DscConfiguration -Path (Join-Path $PSScriptRoot 'DevWorkstation') -Wait -Force -Verbose

        # LCM runs as LocalSystem. Apply WSL resources as the invoking user so distro/package provisioning can execute.
        Invoke-WslUserContextApply -DistributionName 'Ubuntu'

        Write-Log "DSC execution in progress or completed; final status recorded by LCM"
        return
    }
}
