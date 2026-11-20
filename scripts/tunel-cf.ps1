<#
.SYNOPSIS
  Pasa un cliente a un túnel fijo de Cloudflare con subdominio propio
  (ej. https://wa-prueba.destru.online), sin instalar cloudflared: usa la imagen de Docker.

.DESCRIPTION
  1. Si no hay sesión de Cloudflare (cert.pem), corre "cloudflared tunnel login":
     aparece un link, lo abrís, entrás a Cloudflare y elegís el dominio (ej. destru.online).
  2. Crea el túnel "wa-<slug>" (si no existe) y el registro DNS del subdominio.
  3. Guarda el token en clients\<slug>\.env (no se muestra), activa el perfil tunel-cf,
     apaga el túnel temporal y reinicia el entorno del cliente.

.EXAMPLE
  .\scripts\tunel-cf.ps1 -Slug prueba -Dominio destru.online
  .\scripts\tunel-cf.ps1 -Slug prueba -Dominio destru.online -Subdominio bot-prueba
#>
param(
    [Parameter(Mandatory = $true)][string]$Slug,
    [Parameter(Mandatory = $true)][string]$Dominio,
    [string]$Subdominio = '',
    [string]$CertDir = [IO.Path]::Combine($HOME, '.cloudflared')
)
$ErrorActionPreference = 'Continue'
$Root      = Split-Path -Parent $PSScriptRoot
$ClientDir = [IO.Path]::Combine($Root, 'clients', $Slug)
$EnvFile   = Join-Path $ClientDir '.env'
$Image     = 'cloudflare/cloudflared:2026.11.1'
$Tunnel    = "wa-$Slug"
if (-not $Subdominio) { $Subdominio = "wa-$Slug" }
$Hostname  = "$Subdominio.$Dominio"
$CertIn    = '/home/nonroot/.cloudflared/cert.pem'

if (-not (Test-Path $EnvFile)) { throw "No existe el cliente '$Slug' (clients\$Slug\.env)." }
New-Item -ItemType Directory -Force -Path $CertDir | Out-Null

function Cfd {
    # cloudflared dentro de Docker, con la carpeta de credenciales montada.
    # Como root (con el mismo HOME) para poder escribir en carpetas de Windows montadas desde WSL/Kiri.
    docker run --rm -u 0 -e HOME=/home/nonroot -v "${CertDir}:/home/nonroot/.cloudflared" $Image @args
}
function Set-EnvValue([string]$key, [string]$value) {
    $lines = [IO.File]::ReadAllLines($EnvFile)
    $found = $false
    $lines = $lines | ForEach-Object { if ($_ -match "^$key=") { $found = $true; "$key=$value" } else { $_ } }
    if (-not $found) { $lines += "$key=$value" }
    [IO.File]::WriteAllLines($EnvFile, $lines, (New-Object Text.UTF8Encoding $false))
}

# --- 1. Sesión de Cloudflare -----------------------------------------------------
if (-not (Test-Path (Join-Path $CertDir 'cert.pem'))) {
    Write-Host "`n==> Iniciar sesión en Cloudflare" -ForegroundColor Cyan
    Write-Host "Abrí el link que aparece abajo, entrá a Cloudflare y elegí el dominio '$Dominio'." -ForegroundColor Yellow
    Write-Host "(El script sigue solo cuando autorices; tenés unos minutos.)"
    Cfd tunnel login
    if (-not (Test-Path (Join-Path $CertDir 'cert.pem'))) { throw 'No se completó el login de Cloudflare.' }
}

# --- 2. Túnel y DNS --------------------------------------------------------------
Write-Host "`n==> Túnel '$Tunnel' -> https://$Hostname" -ForegroundColor Cyan
$list = (Cfd tunnel --origincert $CertIn list --name $Tunnel --output json 2>$null | Out-String)
# Se busca el nombre en el JSON como texto: en Windows PowerShell 5.1, ConvertFrom-Json de "[]"
# devuelve un objeto que cuenta como 1 y hacía creer que el túnel ya existía.
$exists = $list -match ('"name"\s*:\s*"' + [regex]::Escape($Tunnel) + '"')
if (-not $exists) {
    Cfd tunnel --origincert $CertIn create $Tunnel
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el túnel $Tunnel." }
} else { Write-Host 'El túnel ya existía, se reutiliza.' }

$dns = (Cfd tunnel --origincert $CertIn route dns $Tunnel $Hostname 2>&1 | Out-String)
Write-Host $dns.Trim()
if ($LASTEXITCODE -ne 0 -and $dns -notmatch 'already') {
    throw "No se pudo crear el DNS de $Hostname. ¿El login fue con el dominio '$Dominio'?"
}
# Si la sesión (cert.pem) es de otra zona, cloudflared crea "wa-x.destru.online.<otra-zona>" sin dar error.
if ($dns -match "$([regex]::Escape($Hostname))\.[a-z0-9]") {
    throw ("La sesión de Cloudflare en $CertDir es de otro dominio (se creó '$($Matches[0])...'). " +
           "Borrá ese registro DNS en Cloudflare, renombrá cert.pem y volvé a correr el script para iniciar sesión eligiendo '$Dominio'.")
}

$token = (Cfd tunnel --origincert $CertIn token $Tunnel 2>$null | Out-String).Trim()
if (-not $token -or $token -match '\s') { throw 'No se pudo obtener el token del túnel.' }

# --- 3. Guardar en .env y reiniciar el cliente -----------------------------------
Set-EnvValue 'CLOUDFLARE_TUNNEL_TOKEN' $token
Set-EnvValue 'COMPOSE_PROFILES' 'tunel-cf'
Set-EnvValue 'EVOLUTION_PUBLIC_URL' "https://$Hostname"

docker rm -f "wa-$Slug-tunel" *> $null
Push-Location $ClientDir
try { docker compose up -d } finally { Pop-Location }

Write-Host "`nProbando https://$Hostname (el DNS puede tardar un minuto)..."
$ok = $false
# Un CNAME nuevo tarda en propagarse y Windows puede tener cacheado que no existía.
try { Clear-DnsClientCache -ErrorAction Stop } catch { ipconfig /flushdns | Out-Null }
for ($i = 0; $i -lt 40 -and -not $ok; $i++) {
    if ($i -gt 0 -and $i % 10 -eq 0) { try { Clear-DnsClientCache -ErrorAction Stop } catch { ipconfig /flushdns | Out-Null } }
    try { Invoke-RestMethod "https://$Hostname/" -TimeoutSec 5 | Out-Null; $ok = $true } catch { Start-Sleep 6 }
}
if ($ok) {
    Write-Host "Listo: https://$Hostname  (panel: https://$Hostname/manager, API key en clients\$Slug\.env)" -ForegroundColor Green
} else {
    Write-Warning "El túnel está levantado pero https://$Hostname todavía no responde. Probá en unos minutos o mirá: docker logs wa-$Slug-tunel-cf"
}
