Configuration DevWorkstation {
    param([string]$DataDrive, [bool]$IncludeChocoLibJunction = $false)

    Import-DscResource -ModuleName cChoco
    Import-DscResource -ModuleName DevTools.CustomDsc
    Import-DscResource -ModuleName PSDesiredStateConfiguration

    $chocoLibJunctionDataDrive = if ($IncludeChocoLibJunction) { $DataDrive } else { 'C:' }

    $hypervSupported = Test-HyperVSupported
    $hyperVDependency = if ($hypervSupported) { '[WindowsOptionalFeature]HyperV' } else { $null }

    $chocoDependsOn = (@('[WindowsOptionalFeature]VirtualMachinePlatform','[WindowsOptionalFeature]WSL') + @($hyperVDependency)) |
        Where-Object { $_ } |
        Select-Object -Unique

    $dockerDependsOn = (@('[cChocoInstaller]InstallChocolatey','[WindowsOptionalFeature]VirtualMachinePlatform','[WindowsOptionalFeature]WSL') + @($hyperVDependency) + @('[DevToolsChocoLibJunction]ChocoLib')) |
        Where-Object { $_ } |
        Select-Object -Unique

    $intellijCandidatePaths = @(
        'C:\Program Files\JetBrains\IntelliJ IDEA Community Edition\bin\idea64.exe',
        'C:\Program Files\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe',
        'C:\Program Files (x86)\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe',
        "$env:LOCALAPPDATA\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea64.exe",
        "$env:LOCALAPPDATA\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe",
        "$env:LOCALAPPDATA\Programs\IntelliJ IDEA Community Edition\bin\idea64.exe",
        "$env:LOCALAPPDATA\Programs\IntelliJ IDEA Community Edition\bin\idea.exe"
    )

    if ($DataDrive -and $DataDrive -ne 'C:') {
        $intellijCandidatePaths += @(
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea64.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe",
            "$DataDrive\$env:USERNAME\AppData\Local\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea64.exe",
            "$DataDrive\$env:USERNAME\AppData\Local\Programs\JetBrains\IntelliJ IDEA Community Edition\bin\idea.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\IntelliJ IDEA Community Edition\bin\idea64.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\IntelliJ IDEA Community Edition\bin\idea.exe",
            "$DataDrive\$env:USERNAME\AppData\Local\Programs\IntelliJ IDEA Community Edition\bin\idea64.exe",
            "$DataDrive\$env:USERNAME\AppData\Local\Programs\IntelliJ IDEA Community Edition\bin\idea.exe"
        )
    }

    $dockerCandidatePaths = @(
        'C:\Program Files\Docker\Docker\Docker.exe',
        'C:\Program Files (x86)\Docker\Docker\Docker.exe',
        "$env:LOCALAPPDATA\Docker\Docker.exe"
    )

    if ($DataDrive -and $DataDrive -ne 'C:') {
        $dockerCandidatePaths += @(
            "$DataDrive\Program Files\Docker\Docker\Docker.exe",
            "$DataDrive\Program Files (x86)\Docker\Docker\Docker.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Docker\Docker.exe",
            "$DataDrive\$env:USERNAME\AppData\Local\Docker\Docker.exe"
        )
    }

    $gitCandidatePaths = @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe',
        'C:\Program Files (x86)\Git\cmd\git.exe',
        'C:\Program Files (x86)\Git\bin\git.exe',
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\git.exe"
    )

    if ($DataDrive -and $DataDrive -ne 'C:') {
        $gitCandidatePaths += @(
            "$DataDrive\Program Files\Git\cmd\git.exe",
            "$DataDrive\Program Files\Git\bin\git.exe",
            "$DataDrive\Program Files (x86)\Git\cmd\git.exe",
            "$DataDrive\Program Files (x86)\Git\bin\git.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\Git\cmd\git.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\Git\bin\git.exe",
            "$DataDrive\$env:USERNAME\AppData\Local\Programs\Git\cmd\git.exe",
            "$DataDrive\$env:USERNAME\AppData\Local\Programs\Git\bin\git.exe"
        )
    }

    $terraformCandidatePaths = @(
        'C:\Program Files\HashiCorp\Terraform\terraform.exe',
        'C:\HashiCorp\Terraform\terraform.exe',
        "$env:LOCALAPPDATA\Programs\Terraform\terraform.exe"
    )

    if ($DataDrive -and $DataDrive -ne 'C:') {
        $terraformCandidatePaths += @(
            "$DataDrive\Program Files\HashiCorp\Terraform\terraform.exe",
            "$DataDrive\HashiCorp\Terraform\terraform.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\Terraform\terraform.exe",
            "$DataDrive\$env:USERNAME\AppData\Local\Programs\Terraform\terraform.exe"
        )
    }

    $javaCandidatePaths = @(
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
    )

    if ($DataDrive -and $DataDrive -ne 'C:') {
        $javaCandidatePaths += @(
            "$DataDrive\Program Files\Eclipse Adoptium\jdk-25*\bin\java.exe",
            "$DataDrive\Program Files\Amazon Corretto\jdk25*\bin\java.exe",
            "$DataDrive\Program Files\Java\latest\jdk-25\bin\java.exe",
            "$DataDrive\Program Files\Java\jdk-25*\bin\java.exe",
            "$DataDrive\Program Files\Java\jdk25\bin\java.exe",
            "$DataDrive\Program Files (x86)\Eclipse Adoptium\jdk-25*\bin\java.exe",
            "$DataDrive\Program Files (x86)\Amazon Corretto\jdk25*\bin\java.exe",
            "$DataDrive\Program Files (x86)\Java\latest\jdk-25\bin\java.exe",
            "$DataDrive\Program Files (x86)\Java\jdk-25*\bin\java.exe",
            "$DataDrive\Program Files (x86)\Java\jdk25\bin\java.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\Eclipse Adoptium\jdk-25*\bin\java.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\Amazon Corretto\jdk25*\bin\java.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\Java\latest\jdk-25\bin\java.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\Java\jdk-25*\bin\java.exe",
            "$DataDrive\Users\$env:USERNAME\AppData\Local\Programs\Java\jdk25\bin\java.exe"
        )
    }

    Node localhost {

        WindowsOptionalFeature VirtualMachinePlatform {
            Name = 'VirtualMachinePlatform'
            Ensure = 'Enable'
        }

        WindowsOptionalFeature WSL {
            Name = 'Microsoft-Windows-Subsystem-Linux'
            Ensure = 'Enable'
        }

        if ($hypervSupported) {
            WindowsOptionalFeature HyperV {
                Name = 'Microsoft-Hyper-V'
                Ensure = 'Enable'
                DependsOn = '[WindowsOptionalFeature]VirtualMachinePlatform'
            }
        }


        DevToolsWslDistribution UbuntuWSL {
            Name = 'UbuntuWSL'
            DistributionName = 'Ubuntu'
            DependsOn = '[WindowsOptionalFeature]WSL'
        }

        DevToolsWslUbuntuGit UbuntuWSLGit {
            Name = 'UbuntuWSLGit'
            DistributionName = 'Ubuntu'
            DependsOn = '[DevToolsWslDistribution]UbuntuWSL'
        }

        DevToolsWslUbuntuJavaJdk25 UbuntuWSLJavaJDK25 {
            Name = 'UbuntuWSLJavaJDK25'
            DistributionName = 'Ubuntu'
            DependsOn = '[DevToolsWslDistribution]UbuntuWSL'
        }

        DevToolsWslUbuntuJavaHome UbuntuWSLJavaHome {
            Name = 'UbuntuWSLJavaHome'
            DistributionName = 'Ubuntu'
            DependsOn = '[DevToolsWslUbuntuJavaJdk25]UbuntuWSLJavaJDK25'
        }

        DevToolsWslUbuntuMandrelJdk25Install UbuntuWSLMandrelJDK25Install {
            Name = 'UbuntuWSLMandrelJDK25Install'
            DistributionName = 'Ubuntu'
            DependsOn = '[DevToolsWslUbuntuJavaHome]UbuntuWSLJavaHome'
        }

        DevToolsWslUbuntuMandrelPath UbuntuWSLMandrelPath {
            Name = 'UbuntuWSLMandrelPath'
            DistributionName = 'Ubuntu'
            DependsOn = '[DevToolsWslUbuntuMandrelJdk25Install]UbuntuWSLMandrelJDK25Install'
        }

        cChocoInstaller InstallChocolatey {
            InstallDir = 'C:\ProgramData\chocolatey'
            DependsOn = $chocoDependsOn
        }

        DevToolsChocoLibJunction ChocoLib {
            Name      = 'ChocoLib'
            DataDrive = $chocoLibJunctionDataDrive
            DependsOn = '[cChocoInstaller]InstallChocolatey'
        }

        DevToolsPackage VSCode {
            Name='VSCode'
            ChocoPackage='vscode'
            AlternateChocoPackages=@('vscode.install','vscode.portable','vscode-insiders','vscode-insiders.install')
            WinGetIds=@('Microsoft.VisualStudioCode')
            AlternateWinGetIds=@('Microsoft.VisualStudioCode.CLI','Microsoft.VisualStudioCode.Insiders','Microsoft.VisualStudioCode.Insiders.CLI')
            DisplayNameLike='*Visual Studio Code*'
            CandidatePaths=@(
                'C:\Program Files\Microsoft VS Code\Code.exe',
                'C:\Program Files (x86)\Microsoft VS Code\Code.exe',
                "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
            )
            DataDrive=$DataDrive
            DependsOn = @('[cChocoInstaller]InstallChocolatey','[DevToolsChocoLibJunction]ChocoLib')
        }

        DevToolsPackage IntelliJCommunity {
            Name='IntelliJCommunity'
            ChocoPackage='intellijidea-community'
            AlternateChocoPackages=@('intellijidea-community.install')
            WinGetIds=@('JetBrains.IntelliJIDEA.Community')
            AlternateWinGetIds=@('JetBrains.IntelliJIDEA.Community.EAP')
            DisplayNameLike='*IntelliJ IDEA Community*'
            CandidatePaths=$intellijCandidatePaths
            DataDrive=$DataDrive
            DependsOn = @('[cChocoInstaller]InstallChocolatey','[DevToolsChocoLibJunction]ChocoLib')
        }

        DevToolsPackage Git {
            Name='Git'
            ChocoPackage='git'
            AlternateChocoPackages=@('git.install','git.portable')
            WinGetIds=@('Git.Git')
            AlternateWinGetIds=@('Git.Git.PreRelease')
            DisplayNameLike='*Git*'
            CandidatePaths=$gitCandidatePaths
            DataDrive=$DataDrive
            DependsOn = @('[cChocoInstaller]InstallChocolatey','[DevToolsChocoLibJunction]ChocoLib')
        }

        DevToolsPackage Terraform {
            Name='Terraform'
            ChocoPackage='terraform'
            AlternateChocoPackages=@()
            WinGetIds=@('Hashicorp.Terraform')
            AlternateWinGetIds=@('Hashicorp.Terraform.Alpha','Hashicorp.Terraform.Beta','Hashicorp.Terraform.RC')
            DisplayNameLike='*Terraform*'
            CandidatePaths=$terraformCandidatePaths
            DataDrive=$DataDrive
            DependsOn = @('[cChocoInstaller]InstallChocolatey','[DevToolsChocoLibJunction]ChocoLib')
        }

        DevToolsPackage Kubeseal {
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
            DataDrive=$DataDrive
            DependsOn = @('[cChocoInstaller]InstallChocolatey','[DevToolsChocoLibJunction]ChocoLib')
        }

        DevToolsPackage JavaJDK25 {
            Name='JavaJDK25'
            ChocoPackage='Temurin25'
            AlternateChocoPackages=@('microsoft-openjdk25','corretto25jdk','zulu25')
            WinGetIds=@('EclipseAdoptium.Temurin.25.JDK')
            AlternateWinGetIds=@('Oracle.JDK.25','Microsoft.OpenJDK.25','Amazon.Corretto.25.JDK','Azul.Zulu.25.JDK','Azul.ZuluFX.25.JDK','BellSoft.LibericaJDK.25','BellSoft.LibericaJDK.25.Full','BellSoft.LibericaJDK.25.Lite')
            DisplayNameLikePatterns=@('*Temurin*25*','*Corretto*25*','*Java*25*')
            CandidatePaths=$javaCandidatePaths
            DataDrive=$DataDrive
            DependsOn = @('[cChocoInstaller]InstallChocolatey','[DevToolsChocoLibJunction]ChocoLib')
        }

        DevToolsJavaHome JavaHome {
            Name='JAVA_HOME'
            CandidateJavaExePaths=$javaCandidatePaths
            DataDrive=$DataDrive
            DependsOn='[DevToolsPackage]JavaJDK25'
        }

        DevToolsPackage Docker {
            Name='Docker'
            ChocoPackage='docker-desktop'
            AlternateChocoPackages=@('docker-for-windows')
            WinGetIds=@('Docker.DockerDesktop')
            AlternateWinGetIds=@('Docker.DockerDesktopEdge')
            DisplayNameLike='*Docker Desktop*'
            CandidatePaths=$dockerCandidatePaths
            DataDrive=$DataDrive
            DependsOn = $dockerDependsOn
        }

        DevToolsDockerKubernetes DockerKubernetes {
            Name='DockerKubernetes'
            DependsOn = '[DevToolsPackage]Docker'
        }
    }
}
