#Requires -Version 5.1
<#
.SYNOPSIS
    Single-run setup nastroj pro Power Apps Code App dev environment na Windows.

.DESCRIPTION
    Automatizuje kroky z SETUP_TUTORIAL.md / GETTING_STARTED.md:
      1. Overi/nainstaluje Node.js LTS a Git (pres winget).
      2. Naklonuje projekt z templatu (npx degit) nebo pouzije aktualni slozku.
      3. npm install, doinstaluje @microsoft/power-apps-cli pokud chybi.
      4. Schvali lifecycle skripty nativnich modulu (keytar, msal-node-*, esbuild)
         a zkusi je zrebuildovat.
      5. Login do Entra ID + `power-apps init` (propojeni s environmentem).

    Login do Entra ID je vzdy interaktivni krok (otevre browser nebo vypise
    device-code) - to skript nemuze obejit, jen ho spusti ve spravnou chvili.

.PARAMETER ProjectName
    Nazev slozky/projektu, ktery se ma vytvorit pres degit. Vychozi: "my-app".

.PARAMETER TargetDir
    Rodicovska slozka, do ktere se ProjectName vytvori. Vychozi: aktualni slozka.

.PARAMETER SkipScaffold
    Neklonovat template - pouzit uz existujici projekt v (TargetDir\ProjectName),
    napr. kdyz uz mas repo naklonovane z gitu.

.PARAMETER Force
    Pri scaffoldu prepsat neprazdnou cilovou slozku (predano jako `--force` do degit).

.PARAMETER EnvironmentId
    GUID Dataverse environmentu. Pokud je znamy, `power-apps init` se spusti
    non-interaktivne (--non-interactive --environment-id ...).

.PARAMETER EnvironmentUrl
    URL environmentu (https://<org>.crm.dynamics.com). Pokud EnvironmentId neni
    znamy, pouzije se pac CLI (`pac auth create` + `pac env list`) k jeho dohledani.

.PARAMETER DisplayName
    Zobrazovany nazev appky pro `power-apps init --display-name`. Vychozi: ProjectName.

.PARAMETER DeviceCode
    Pouzit `--device-code` login flow (vypise URL + kod misto otevreni browseru) -
    hodi se pro RDP/headless stroje bez lokalniho browseru.

.PARAMETER InstallBuildTools
    Navic nainstaluje Visual Studio Build Tools pres winget pro pripad, ze
    `npm rebuild keytar` selze na chybejici native toolchain (velke stazeni,
    vychozi je to vypnute).

.EXAMPLE
    .\Setup-PowerAppsCodeApp.ps1
    Plne interaktivni beh - scaffold "my-app", login + vyber environmentu v prompte.

.EXAMPLE
    .\Setup-PowerAppsCodeApp.ps1 -ProjectName crm-dashboard -EnvironmentId 4affc3dd-e8ad-e07c-b690-0d0ad5fb5b49
    Non-interaktivni init rovnou proti znamemu environmentu.

.EXAMPLE
    .\Setup-PowerAppsCodeApp.ps1 -SkipScaffold -TargetDir C:\src\my-app -DeviceCode
    Pouzije uz existujici projekt, login pres device-code (headless/RDP).
#>
[CmdletBinding()]
param(
    [string]$ProjectName = "my-app",
    [string]$TargetDir = (Get-Location).Path,
    [switch]$SkipScaffold,
    [switch]$Force,
    [string]$EnvironmentId,
    [string]$EnvironmentUrl,
    [string]$DisplayName,
    [switch]$DeviceCode,
    [switch]$InstallBuildTools
)

$ErrorActionPreference = "Stop"
if (-not $DisplayName) { $DisplayName = $ProjectName }

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    POZOR: $msg" -ForegroundColor Yellow }

function Test-CommandExists([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    # winget/msi instalatory pisou PATH do registru, ale aktualni proces si ho
    # nenacte znova sam - poskladame ho rucne z Machine + User scope.
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = ($machine, $user -join ";")
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$WorkingDirectory = (Get-Location).Path,
        [switch]$AllowFailure
    )
    Write-Info "$FilePath $($ArgumentList -join ' ')"
    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Prikaz '$FilePath $($ArgumentList -join ' ')' selhal s exit code $exitCode."
    }
    return $exitCode
}

function Install-WithWinget {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$FriendlyName)

    if (-not (Test-CommandExists "winget")) {
        throw "winget neni k dispozici. Nainstaluj 'App Installer' z Microsoft Store " +
              "(https://aka.ms/getwinget) a spust skript znovu."
    }
    Write-Info "Instaluji $FriendlyName pres winget ($Id)..."
    & winget install --id $Id -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Instalace $FriendlyName pres winget selhala (exit code $LASTEXITCODE)."
    }
    Update-SessionPath
    Write-Ok "$FriendlyName nainstalovan."
}

# ---------------------------------------------------------------------------
Write-Step "1/6 Prerekvizity: Node.js + Git"

if (Test-CommandExists "node") {
    $nodeVersion = (node --version).TrimStart("v")
    Write-Ok "Node.js $nodeVersion uz je nainstalovany."
    $major = [int]($nodeVersion.Split(".")[0])
    if ($major -lt 20) {
        Write-Warn2 "Node $nodeVersion je starsi nez doporucenych 20 LTS (Vite 7 to vyzaduje). Zvaz upgrade."
    }
} else {
    Install-WithWinget -Id "OpenJS.NodeJS.LTS" -FriendlyName "Node.js LTS"
}

if (Test-CommandExists "git") {
    Write-Ok "Git uz je nainstalovany."
} else {
    Install-WithWinget -Id "Git.Git" -FriendlyName "Git"
}

if (-not (Test-CommandExists "node") -or -not (Test-CommandExists "npm")) {
    throw "Node.js/npm porad nejsou v PATH i po instalaci. Zavri a znovu otevri PowerShell " +
          "(nebo restartuj), pak skript spust znovu."
}

# ---------------------------------------------------------------------------
Write-Step "2/6 Scaffold projektu"

$projectPath = Join-Path $TargetDir $ProjectName

if ($SkipScaffold) {
    if (-not (Test-Path $projectPath)) {
        throw "-SkipScaffold byl zadan, ale slozka '$projectPath' neexistuje."
    }
    Write-Ok "Pouzivam existujici projekt: $projectPath"
} else {
    if (Test-Path $projectPath) {
        $isEmpty = -not (Get-ChildItem $projectPath -Force -ErrorAction SilentlyContinue)
        if (-not $isEmpty -and -not $Force) {
            throw "Slozka '$projectPath' uz existuje a neni prazdna. Pouzij -Force pro prepsani, " +
                  "nebo -SkipScaffold pokud je to uz hotovy projekt."
        }
    }
    $degitArgs = @("--yes", "degit", "github:microsoft/PowerAppsCodeApps/templates/vite", $projectPath)
    if ($Force) { $degitArgs += "--force" }
    Invoke-Checked -FilePath "npx" -ArgumentList $degitArgs -WorkingDirectory $TargetDir
    Write-Ok "Projekt naklonovan do $projectPath"
}

# ---------------------------------------------------------------------------
Write-Step "3/6 npm install"

Invoke-Checked -FilePath "npm" -ArgumentList @("install") -WorkingDirectory $projectPath
Write-Ok "Zavislosti nainstalovany."

$cliPath = Join-Path $projectPath "node_modules\@microsoft\power-apps-cli"
if (-not (Test-Path $cliPath)) {
    Write-Info "@microsoft/power-apps-cli chybi v templatu, doinstalovavam..."
    Invoke-Checked -FilePath "npm" -ArgumentList @("install", "--save-dev", "@microsoft/power-apps-cli") -WorkingDirectory $projectPath
}
Write-Ok "@microsoft/power-apps-cli k dispozici."

# ---------------------------------------------------------------------------
Write-Step "4/6 Schvaleni lifecycle skriptu (keytar, msal-node-*, esbuild)"

Invoke-Checked -FilePath "npm" -ArgumentList @(
    "install-scripts", "approve",
    "@azure/msal-node-extensions", "@azure/msal-node-runtime", "esbuild", "keytar"
) -WorkingDirectory $projectPath -AllowFailure | Out-Null

$rebuildExit = Invoke-Checked -FilePath "npm" -ArgumentList @("rebuild", "keytar") -WorkingDirectory $projectPath -AllowFailure

if ($rebuildExit -ne 0) {
    Write-Warn2 "npm rebuild keytar selhal - chybi native build toolchain."
    if ($InstallBuildTools) {
        Install-WithWinget -Id "Microsoft.VisualStudio.2022.BuildTools" -FriendlyName "VS Build Tools"
        Invoke-Checked -FilePath "npm" -ArgumentList @("rebuild", "keytar") -WorkingDirectory $projectPath
    } else {
        Write-Warn2 "Spust skript znovu s -InstallBuildTools, nebo rucne nainstaluj " +
                     "'Desktop development with C++' workload z Visual Studio Build Tools."
    }
} else {
    Write-Ok "keytar zrebuildovan."
}

# ---------------------------------------------------------------------------
Write-Step "5/6 Login + init"

if ($EnvironmentId -or $EnvironmentUrl) {

    $loginArgs = @("--yes", "power-apps", "login")
    if ($DeviceCode) { $loginArgs += "--device-code" }
    Write-Info "Otevira se prihlaseni do Entra ID - dokonci ho v browseru / podle vypsaneho kodu."
    Invoke-Checked -FilePath "npx" -ArgumentList $loginArgs -WorkingDirectory $projectPath
    Write-Ok "Prihlaseno."

    if (-not $EnvironmentId) {
        Write-Info "EnvironmentId neni znamy, dohledavam pres pac CLI ($EnvironmentUrl)..."
        if (-not (Test-CommandExists "pac")) {
            Install-WithWinget -Id "Microsoft.PowerAppsCLI" -FriendlyName "Power Platform CLI (pac)"
        }
        Invoke-Checked -FilePath "pac" -ArgumentList @("auth", "create", "--environment", $EnvironmentUrl) -WorkingDirectory $projectPath
        Invoke-Checked -FilePath "pac" -ArgumentList @("env", "list") -WorkingDirectory $projectPath
        $EnvironmentId = Read-Host "`nZkopiruj Environment ID z tabulky vyse a vloz sem"
        if (-not $EnvironmentId) { throw "Environment ID nebylo zadano." }
    }

    Invoke-Checked -FilePath "npx" -ArgumentList @(
        "--yes", "power-apps", "init",
        "--non-interactive",
        "--environment-id", $EnvironmentId,
        "--app-type", "CodeApp",
        "--display-name", $DisplayName
    ) -WorkingDirectory $projectPath
    Write-Ok "power.config.json vytvoren pro environment $EnvironmentId."

} else {
    Write-Info "Zadny EnvironmentId/EnvironmentUrl nebyl zadan - spoustim plne interaktivni 'power-apps init'"
    Write-Info "(sam se zepta na displayName + environment a otevre login do Entra ID)."
    Invoke-Checked -FilePath "npx" -ArgumentList @("--yes", "power-apps", "init") -WorkingDirectory $projectPath
    Write-Ok "power.config.json vytvoren."
}

# ---------------------------------------------------------------------------
Write-Step "6/6 Hotovo"

Write-Host ""
Write-Host "Projekt je pripraveny v: $projectPath" -ForegroundColor Green
Write-Host ""
Write-Host "Dalsi kroky:" -ForegroundColor White
Write-Host "  cd `"$projectPath`""
Write-Host "  npx power-apps run              # lokalni dev (Local Play, hot reload)"
Write-Host "  npm run build; npx power-apps push   # build + nasazeni do environmentu"
Write-Host ""
