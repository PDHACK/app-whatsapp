<#
.SYNOPSIS
  Maneja el entorno de un cliente ya creado.

.EXAMPLE
  .\scripts\cliente.ps1 panaderia estado
  .\scripts\cliente.ps1 panaderia qr
  .\scripts\cliente.ps1 panaderia sql
  .\scripts\cliente.ps1 todos lista

  Acciones:
    up       levanta DB + WhatsApp + túnel
    down     los apaga (los datos quedan en los volúmenes)
    restart  reinicia
    logs     muestra logs en vivo (Ctrl+C para salir)
    estado   contenedores + estado de la conexión de WhatsApp
    qr       genera un QR nuevo para vincular el celular (qr.png)
    url      muestra la URL pública del túnel rápido
    sql      abre psql en la base del cliente
    backup   guarda un .sql con los datos en clients\<slug>\backups
    lista    (con slug "todos") lista todos los clientes
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Slug,
    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateSet('up', 'down', 'restart', 'logs', 'estado', 'qr', 'url', 'sql', 'backup', 'lista')][string]$Accion
)
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot

if ($Accion -eq 'lista') {
    Get-ChildItem (Join-Path $Root 'clients') -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.env') } | ForEach-Object {
        $envs = @{}; Get-Content (Join-Path $_.FullName '.env') | Where-Object { $_ -match '^\w+=' } |
            ForEach-Object { $k, $v = $_ -split '=', 2; $envs[$k] = $v }
        $running = (docker ps --filter "name=^wa-$($_.Name)-" --format '{{.Names}}' | Measure-Object).Count
        [pscustomobject]@{ Cliente = $_.Name; Nombre = $envs.CLIENT_NAME; Puerto = $envs.EVOLUTION_PORT; DB = $envs.DB_PORT; Tunel = $envs.COMPOSE_PROFILES; Contenedores = $running }
    } | Format-Table -AutoSize
    return
}

$ClientDir = [IO.Path]::Combine($Root, 'clients', $Slug)
if (-not (Test-Path (Join-Path $ClientDir '.env'))) { throw "No existe el cliente '$Slug' (clients\$Slug\.env)." }
$cfg = @{}
Get-Content (Join-Path $ClientDir '.env') | Where-Object { $_ -match '^\w+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $cfg[$k] = $v }
$base = "http://localhost:$($cfg.EVOLUTION_PORT)"
$headers = @{ apikey = $cfg.EVOLUTION_API_KEY }

Push-Location $ClientDir
try {
    switch ($Accion) {
        'up'      { docker compose up -d }
        'down'    { docker compose down }
        'restart' { docker compose restart }
        'logs'    { docker compose logs -f --tail 100 }
        'estado'  {
            docker compose ps
            try {
                $st = Invoke-RestMethod "$base/instance/connectionState/$($cfg.EVOLUTION_INSTANCE)" -Headers $headers -ErrorAction Stop
                Write-Host "`nWhatsApp: $($st.instance.state)  (open = conectado)" -ForegroundColor Green
            } catch { Write-Warning "No pude consultar Evolution API en $base" }
        }
        'qr' {
            $r = Invoke-RestMethod "$base/instance/connect/$($cfg.EVOLUTION_INSTANCE)" -Headers $headers -ErrorAction Stop
            if ($r.base64) {
                $qrPath = Join-Path $ClientDir 'qr.png'
                [IO.File]::WriteAllBytes($qrPath, [Convert]::FromBase64String(($r.base64 -replace '^data:image/\w+;base64,', '')))
                Start-Process $qrPath
                Write-Host "QR guardado en $qrPath. Escanealo desde WhatsApp > Dispositivos vinculados."
            } elseif ($r.instance.state -eq 'open') {
                Write-Host 'Ya está conectado.'
            } else { Write-Warning "Sin QR todavía (respuesta: $($r | ConvertTo-Json -Compress)). Probá de nuevo en unos segundos." }
        }
        'url' {
            $m = (docker logs "wa-$Slug-tunel" 2>&1 | Out-String) | Select-String 'https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com' -AllMatches
            if ($m) { $m.Matches[-1].Value } else { "Sin túnel rápido. URL configurada: $($cfg.EVOLUTION_PUBLIC_URL)" }
        }
        'sql'    { docker exec -it "wa-$Slug-db" psql -U $cfg.POSTGRES_USER -d $cfg.POSTGRES_DB }
        'backup' {
            $dir = Join-Path $ClientDir 'backups'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $file = Join-Path $dir ("$Slug-" + (Get-Date -Format 'yyyyMMdd-HHmm') + '.sql')
            docker exec "wa-$Slug-db" pg_dump -U $cfg.POSTGRES_USER -d $cfg.POSTGRES_DB --clean --if-exists |
                Out-File -Encoding utf8 $file
            Write-Host "Backup: $file"
        }
    }
} finally { Pop-Location }
