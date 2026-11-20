<#
.SYNOPSIS
  Crea el entorno completo de un cliente nuevo: base de datos + WhatsApp (Evolution API)
  + túnel cloudflared, y carga su workflow de chatbot en tu n8n existente.

.EXAMPLE
  .\scripts\nuevo-cliente.ps1 -Slug panaderia -Nombre "Panadería San José"
  .\scripts\nuevo-cliente.ps1 -Slug ferreteria -Nombre "Ferretería Centro" -TunnelToken "eyJh..." -PublicUrl "https://wa-ferreteria.midominio.com"
  .\scripts\nuevo-cliente.ps1 -Slug test -Nombre "Prueba" -SinTunel
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,29}$')][string]$Slug,
    [Parameter(Mandatory = $true)][string]$Nombre,
    [string]$N8nContainer = $(if ($env:N8N_CONTAINER) { $env:N8N_CONTAINER } else { 'n8n' }),
    [string]$OllamaUrl = 'http://host.docker.internal:11434',
    [string]$OllamaModel = 'llama3.2:3b',
    [string]$TunnelToken = '',
    [string]$PublicUrl = '',
    [switch]$SinTunel,
    [switch]$SinN8n
)

# 'Continue' para que los avisos de docker por stderr no corten el script en Windows PowerShell 5.1;
# los errores importantes se controlan con $LASTEXITCODE o -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
$wfActive = $false
$Root      = Split-Path -Parent $PSScriptRoot
$Template  = Join-Path $Root 'template'
$ClientDir = [IO.Path]::Combine($Root, 'clients', $Slug)
$Network   = 'wa-net'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function New-Secret([int]$len = 32) {
    $chars = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    -join (1..$len | ForEach-Object { $chars | Get-Random })
}
function Escape-Json([string]$s) { $j = $s | ConvertTo-Json -Compress; $j.Substring(1, $j.Length - 2) }

if (Test-Path $ClientDir) { throw "Ya existe clients\$Slug. Usá scripts\cliente.ps1 para manejarlo." }
docker version --format '{{.Server.Version}}' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker no responde. ¿Está abierto Docker Desktop?' }

# --- 1. Red compartida entre n8n y los clientes --------------------------------
Step "Red compartida '$Network'"
docker network inspect $Network *> $null
if ($LASTEXITCODE -ne 0) { docker network create $Network | Out-Null; Write-Host "Creada." } else { Write-Host "Ya existe." }

if (-not $SinN8n) {
    docker inspect $N8nContainer *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "No encuentro el contenedor de n8n '$N8nContainer'. Pasá -N8nContainer <nombre> (ver 'docker ps')."
    }
    $nets = docker inspect $N8nContainer --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
    if ($nets -notmatch "(^|\s)$Network(\s|$)") {
        docker network connect $Network $N8nContainer
        Write-Host "n8n ('$N8nContainer') conectado a $Network."
    }
}

# --- 2. Puerto libre y secretos -------------------------------------------------
$usedPorts = Get-ChildItem (Join-Path $Root 'clients') -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName '.env' } | Where-Object { Test-Path $_ } |
    ForEach-Object { (Select-String -Path $_ -Pattern '^EVOLUTION_PORT=(\d+)').Matches.Groups[1].Value } |
    ForEach-Object { [int]$_ }
$port = 8081
while ($usedPorts -contains $port) { $port++ }

$pgPassword = New-Secret 28
$apiKey     = New-Secret 40
$tunnelProfile    = if ($SinTunel) { '' } elseif ($TunnelToken) { 'tunnel' } else { 'quicktunnel' }
if (-not $PublicUrl) { $PublicUrl = "http://localhost:$port" }

# --- 3. Copiar plantilla y generar .env -----------------------------------------
Step "Creando clients\$Slug"
New-Item -ItemType Directory -Force -Path $ClientDir -ErrorAction Stop | Out-Null
Copy-Item (Join-Path $Template 'docker-compose.yml') $ClientDir -ErrorAction Stop
Copy-Item (Join-Path $Template 'db') $ClientDir -Recurse -ErrorAction Stop
Copy-Item (Join-Path $Template 'n8n') $ClientDir -Recurse -ErrorAction Stop

$envContent = @"
# Generado por nuevo-cliente.ps1 el $(Get-Date -Format 'yyyy-MM-dd HH:mm'). NO subir a git.
CLIENT_SLUG=$Slug
CLIENT_NAME=$Nombre
COMPOSE_PROFILES=$tunnelProfile
TUNNEL_TOKEN=$TunnelToken
POSTGRES_DB=chatbot
POSTGRES_USER=chatbot
POSTGRES_PASSWORD=$pgPassword
EVOLUTION_PORT=$port
EVOLUTION_API_KEY=$apiKey
EVOLUTION_INSTANCE=$Slug
EVOLUTION_DEVICE_NAME=Chatbot $Nombre
EVOLUTION_PUBLIC_URL=$PublicUrl
N8N_WEBHOOK_URL=http://${N8nContainer}:5678/webhook/wa-$Slug
"@
[IO.File]::WriteAllText((Join-Path $ClientDir '.env'), $envContent, (New-Object Text.UTF8Encoding $false))

# Nombre del negocio y modelo por defecto en la DB del cliente
Add-Content -Encoding UTF8 -Path ([IO.Path]::Combine($ClientDir, 'db', 'init', '01-schema.sql')) -Value @"

UPDATE bot_config SET business_name = '$($Nombre.Replace("'", "''"))', ai_model = '$OllamaModel' WHERE id = 1;
"@

# Workflow y credenciales de n8n para este cliente
$repl = @{
    '__CLIENT_SLUG__'       = $Slug
    '__CLIENT_NAME__'       = (Escape-Json $Nombre)
    '__INSTANCE__'          = $Slug
    '__OLLAMA_URL__'        = $OllamaUrl.TrimEnd('/')
    '__WEBHOOK_ID__'        = [guid]::NewGuid().ToString()
    '__WORKFLOW_ID__'       = (New-Secret 16)
    '__PG_CRED_ID__'        = (New-Secret 16)
    '__EVO_CRED_ID__'       = (New-Secret 16)
    '__POSTGRES_DB__'       = 'chatbot'
    '__POSTGRES_USER__'     = 'chatbot'
    '__POSTGRES_PASSWORD__' = $pgPassword
    '__EVOLUTION_API_KEY__' = $apiKey
}
foreach ($f in 'workflow.json', 'credentials.json') {
    $p = [IO.Path]::Combine($ClientDir, 'n8n', $f)
    $txt = [IO.File]::ReadAllText($p)
    foreach ($k in $repl.Keys) { $txt = $txt.Replace($k, $repl[$k]) }
    [IO.File]::WriteAllText($p, $txt, (New-Object Text.UTF8Encoding $false))
}

# --- 4. Levantar contenedores ---------------------------------------------------
Step 'Levantando base de datos, WhatsApp y túnel'
Push-Location $ClientDir
try { docker compose --env-file .env up -d; if ($LASTEXITCODE -ne 0) { throw 'docker compose falló' } }
finally { Pop-Location }

$base = "http://localhost:$port"
$headers = @{ apikey = $apiKey }
Write-Host 'Esperando a Evolution API...'
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
    try { Invoke-RestMethod "$base/" -TimeoutSec 3 | Out-Null; $ok = $true; break } catch { Start-Sleep 3 }
}
if (-not $ok) { throw "Evolution API no respondió en $base. Mirá: .\scripts\cliente.ps1 $Slug logs" }

# --- 5. Instancia de WhatsApp ---------------------------------------------------
Step 'Creando instancia de WhatsApp'
$body = @{
    instanceName    = $Slug
    integration     = 'WHATSAPP-BAILEYS'
    qrcode          = $true
    groupsIgnore    = $true
    alwaysOnline    = $false   # así el celular sigue recibiendo notificaciones normalmente
    readMessages    = $false   # no marca como leído: lo ves igual que siempre en el celu
    rejectCall      = $false
    syncFullHistory = $false
} | ConvertTo-Json
$created = Invoke-RestMethod "$base/instance/create" -ErrorAction Stop -Method Post -Headers $headers -ContentType 'application/json' -Body $body
$qr = $created.qrcode.base64
for ($i = 0; $i -lt 10 -and -not $qr; $i++) {
    Start-Sleep 3
    try { $qr = (Invoke-RestMethod "$base/instance/connect/$Slug" -Headers $headers).base64 } catch { }
}
if (-not $qr) { Write-Warning "Todavía no hay QR. Probá en un rato: .\scripts\cliente.ps1 $Slug qr" }
if ($qr) {
    $qrPath = Join-Path $ClientDir 'qr.png'
    [IO.File]::WriteAllBytes($qrPath, [Convert]::FromBase64String(($qr -replace '^data:image/\w+;base64,', '')))
    Start-Process $qrPath
}

# --- 6. Cargar workflow en n8n --------------------------------------------------
if (-not $SinN8n) {
    Step "Importando workflow y credenciales en n8n ('$N8nContainer')"
    docker cp ([IO.Path]::Combine($ClientDir, 'n8n', 'credentials.json')) "${N8nContainer}:/tmp/wa-$Slug-cred.json" | Out-Null
    docker cp ([IO.Path]::Combine($ClientDir, 'n8n', 'workflow.json'))    "${N8nContainer}:/tmp/wa-$Slug-wf.json"   | Out-Null
    docker exec $N8nContainer n8n import:credentials --input=/tmp/wa-$Slug-cred.json
    $okCred = $LASTEXITCODE -eq 0
    docker exec $N8nContainer n8n import:workflow    --input=/tmp/wa-$Slug-wf.json
    if (-not $okCred -or $LASTEXITCODE -ne 0) {
        Write-Warning "No se pudo importar en n8n. Importá a mano clients\$Slug\n8n\workflow.json y creá las credenciales de credentials.json."
    }
    # Activar el workflow: n8n 2.x usa publish:workflow, n8n 1.x usa update:workflow
    docker exec $N8nContainer n8n publish:workflow --id=$($repl['__WORKFLOW_ID__']) *> $null
    if ($LASTEXITCODE -ne 0) { docker exec $N8nContainer n8n update:workflow --id=$($repl['__WORKFLOW_ID__']) --active=true *> $null }
    if ($LASTEXITCODE -eq 0 -and $okCred) { $wfActive = $true; Write-Host 'Workflow activado (si n8n no lo toma, reiniciá el contenedor de n8n).' }
    docker exec -u root $N8nContainer rm -f /tmp/wa-$Slug-cred.json /tmp/wa-$Slug-wf.json | Out-Null
}

# --- 7. Resumen -----------------------------------------------------------------
$tunnelUrl = ''
if ($tunnelProfile -eq 'quicktunnel') {
    for ($i = 0; $i -lt 15 -and -not $tunnelUrl; $i++) {
        Start-Sleep 2
        $m = (docker logs "wa-$Slug-quicktunnel" 2>&1 | Out-String) | Select-String 'https://[a-z0-9-]+\.trycloudflare\.com'
        if ($m) { $tunnelUrl = $m.Matches[0].Value }
    }
}

Write-Host "`n================ Cliente '$Nombre' listo ================" -ForegroundColor Green
Write-Host "Carpeta:        clients\$Slug  (el .env tiene las claves)"
Write-Host "Evolution API:  $base   (manager: $base/manager , API key en .env)"
if ($tunnelUrl) { Write-Host "Túnel público:  $tunnelUrl  (cambia si se reinicia; para fija usá -TunnelToken)" }
if ($tunnelProfile -eq 'tunnel') { Write-Host "Túnel público:  $PublicUrl" }
Write-Host ''
Write-Host 'Pasos que faltan:' -ForegroundColor Yellow
Write-Host "  1. En el celu del cliente: WhatsApp > Dispositivos vinculados > Vincular > escanear qr.png"
Write-Host "     (si venció: .\scripts\cliente.ps1 $Slug qr)"
if (-not $wfActive) { Write-Host "  2. En n8n: abrir 'WA $Nombre - Chatbot IA' y activarlo (Active / Publish)." }
Write-Host "  3. Cargar la info del negocio: .\scripts\cliente.ps1 $Slug sql"
Write-Host "  4. Ollama en Windows con el modelo: ollama pull $OllamaModel"
