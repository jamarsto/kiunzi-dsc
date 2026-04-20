@{
    RootModule = 'DevTools.CustomDsc.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a4b9f4a5-3f15-4c55-9b9a-2d1c2a1b3c01'
    Author = 'jamarsto'
    PowerShellVersion = '5.1'
    DscResourcesToExport = @(
        'DevToolsChocoLibJunction',
        'DevToolsPackage',
        'DevToolsDockerKubernetes',
        'DevToolsJavaHome',
        'DevToolsWslDistribution',
        'DevToolsWslUbuntuGit',
        'DevToolsWslUbuntuJavaJdk25',
        'DevToolsWslUbuntuJavaHome',
        'DevToolsWslUbuntuMandrelJdk25Install',
        'DevToolsWslUbuntuMandrelPath'
    )
}
