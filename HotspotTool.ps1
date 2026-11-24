param(
    [string]$SeedSSID,
    [string]$HotspotSSID = 'MyHotspot',
    [string]$HotspotPassword = '12345678',
    [ValidateSet('5GHz', '2.4GHz')]
    [string]$Band = '5GHz',
    [int]$MaxTry = 3,
    [switch]$SelfTest
)

# 单射频网卡（如 Intel AX210）在网线上行时开启 5GHz 热点的绕行脚本
# 流程：连 5GHz 种子网络 -> 以以太网为共享源起热点 -> 断开 WiFi
# 判定：读取 WLAN 服务事件 8006（承载网络已启动）

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SelfTest) {
    Write-Host '需要管理员权限。请右键“以管理员身份运行”Windows PowerShell 后重试。' -ForegroundColor Red
    exit 1
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGen = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$asActionGen = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
function AwaitTask($op, $t) { $m = $asTaskGen.MakeGenericMethod($t); $k = $m.Invoke($null, @($op)); $k.Wait(-1) | Out-Null; $k.Result }
function AwaitAction($a) { $k = $asActionGen.Invoke($null, @($a)); $k.Wait(-1) | Out-Null }

$ni = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
$tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
$resT = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
$bandT = [Windows.Networking.NetworkOperators.TetheringWiFiBand, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]

$netsh = "$env:SystemRoot\System32\netsh.exe"
$ethName = '以太网'
$wlanName = 'WLAN'

function Get-ProfileByName([string]$name) {
    foreach ($p in $ni::GetConnectionProfiles()) { if ($p.ProfileName -eq $name) { return $p } }
    return $null
}

function Test-WlanIs5G {
    foreach ($line in (& $netsh wlan show interfaces)) { if ($line -match '5 GHz') { return $true } }
    return $false
}

function Get-HotspotRunning {
    $ap = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Wi-Fi Direct' -and $_.Status -eq 'Up' }
    return ($null -ne $ap)
}

function Test-NewEvent([datetime]$from, [int]$id) {
    return ($null -ne (Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = $id; StartTime = $from
    } -ErrorAction SilentlyContinue))
}

if ($SelfTest) {
    $eth = Get-NetAdapter -Name $ethName -ErrorAction SilentlyContinue
    Write-Host ('以太网状态：' + $(if ($eth) { $eth.Status } else { '未找到' }))
    Write-Host ('以太网配置存在：' + ($null -ne (Get-ProfileByName $ethName)))
    Write-Host ('当前是否 5GHz：' + (Test-WlanIs5G))
    Write-Host ('热点是否运行：' + (Get-HotspotRunning))
    return
}

if (-not $SeedSSID) {
    Write-Host '必须指定 -SeedSSID（附近可连接的 5GHz 网络名）。' -ForegroundColor Red
    exit 1
}
if ($HotspotPassword.Length -lt 8) {
    Write-Host '热点密码至少 8 位。' -ForegroundColor Red
    exit 1
}

$eth = Get-NetAdapter -Name $ethName -ErrorAction SilentlyContinue
if (-not $eth -or $eth.Status -ne 'Up') {
    Write-Host '以太网未连通。断开 WiFi 后将无网络，脚本终止。' -ForegroundColor Red
    exit 1
}
$ethProfile = Get-ProfileByName $ethName
if (-not $ethProfile) { Write-Host '未找到以太网连接配置，终止。' -ForegroundColor Red; exit 1 }

if ($Band -eq '5GHz') {
    $wlan = Get-NetAdapter -Name $wlanName -ErrorAction SilentlyContinue
    if (-not $wlan -or $wlan.Status -ne 'Up') {
        Write-Host ('连接种子网络：' + $SeedSSID)
        & $netsh wlan connect name=$SeedSSID | Out-Null
        Start-Sleep -Seconds 14
        if (-not (Test-WlanIs5G)) {
            Write-Host '种子网络未连上或不是 5GHz，终止。' -ForegroundColor Red
            exit 1
        }
        Write-Host '已锁定 5GHz 信道'
    } elseif (-not (Test-WlanIs5G)) {
        Write-Host '当前连接的不是 5GHz，热点可能无法启动。' -ForegroundColor Yellow
    }
}

Write-Host '以以太网为共享源启动热点'
$mgr = $tm::CreateFromConnectionProfile($ethProfile)
try { AwaitTask ($mgr.StopTetheringAsync()) $resT | Out-Null } catch {}
Start-Sleep -Seconds 3

$bandValue = if ($Band -eq '5GHz') { $bandT::FiveGigahertz } else { $bandT::TwoPointFourGigahertz }
$ok = $false
for ($i = 1; $i -le $MaxTry; $i++) {
    $t0 = Get-Date
    $cfg = New-Object Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration
    $cfg.Ssid = $HotspotSSID
    $cfg.Passphrase = $HotspotPassword
    $cfg.Band = $bandValue
    try { AwaitAction ($mgr.ConfigureAccessPointAsync($cfg)) } catch {}
    Start-Sleep -Milliseconds 1500
    try { $null = AwaitTask ($mgr.StartTetheringAsync()) $resT } catch {}
    Start-Sleep -Seconds 8
    if (Test-NewEvent $t0 8006) {
        $ok = $true
        Write-Host ('第 ' + $i + ' 轮成功：承载网络已启动（8006）') -ForegroundColor Green
        break
    }
    Write-Host ('第 ' + $i + ' 轮失败（未见 8006），等待重试') -ForegroundColor Yellow
    try { AwaitTask ($mgr.StopTetheringAsync()) $resT | Out-Null } catch {}
    Start-Sleep -Seconds 10
}

if (-not $ok) {
    Write-Host '全部重试失败。请确认种子网络仍连接，或改用 -Band 2.4GHz。' -ForegroundColor Red
    exit 1
}

if ($Band -eq '5GHz') {
    Write-Host '断开 WiFi，保持热点，上网切回以太网'
    & $netsh wlan disconnect | Out-Null
    Start-Sleep -Seconds 12
    if (Get-HotspotRunning) {
        Write-Host '完成：热点在 5GHz 运行，上行以太网，WiFi 已断开' -ForegroundColor Green
    } else {
        Write-Host '断开 WiFi 后热点丢失。' -ForegroundColor Yellow
    }
}

Write-Host ('SSID：' + $HotspotSSID)
Write-Host '关闭热点：在“设置 - 网络和 Internet - 移动热点”中关闭，或重新运行脚本后再关闭。'
