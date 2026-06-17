# One-click setup to make Claude Code send telemetry to the server (Windows).
# Usage:
#   powershell -ExecutionPolicy Bypass -File install-otel.ps1 -Token 'tok_...'
#   (optional) -Machine 'machine-name' -UserId 'user-name' -Endpoint 'https://<OTEL_DOMAIN>'
param(
  [string]$Token    = $env:OTEL_TOKEN,
  [string]$Machine  = $env:COMPUTERNAME,
  [string]$UserId   = $env:USERNAME,
  [string]$Endpoint = "https://<OTEL_DOMAIN>"
)

if ([string]::IsNullOrWhiteSpace($Token)) {
  $Token = Read-Host "Enter the device token (provided by your admin)"
}
if ([string]::IsNullOrWhiteSpace($Token)) { Write-Error "Token missing. Aborting."; exit 1 }

$dir = Join-Path $env:USERPROFILE ".claude"
$settings = Join-Path $dir "settings.json"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$envObj = [ordered]@{
  "CLAUDE_CODE_ENABLE_TELEMETRY" = "1"
  "OTEL_METRICS_EXPORTER"        = "otlp"
  "OTEL_LOGS_EXPORTER"           = "otlp"
  "OTEL_EXPORTER_OTLP_PROTOCOL"  = "http/protobuf"
  "OTEL_EXPORTER_OTLP_ENDPOINT"  = $Endpoint
  "OTEL_EXPORTER_OTLP_HEADERS"   = "Authorization=Bearer $Token"
  "OTEL_RESOURCE_ATTRIBUTES"     = "machine=$Machine,user.id=$UserId"
}

# Merge while keeping the existing config if present.
if (Test-Path $settings) {
  Copy-Item $settings "$settings.bak.$([int][double]::Parse((Get-Date -UFormat %s)))" -ErrorAction SilentlyContinue
  try { $json = Get-Content $settings -Raw | ConvertFrom-Json } catch { $json = [pscustomobject]@{} }
} else {
  $json = [pscustomobject]@{}
}
if (-not ($json.PSObject.Properties.Name -contains "env")) {
  $json | Add-Member -NotePropertyName "env" -NotePropertyValue ([pscustomobject]@{}) -Force
}
foreach ($k in $envObj.Keys) {
  $json.env | Add-Member -NotePropertyName $k -NotePropertyValue $envObj[$k] -Force
}
$json | ConvertTo-Json -Depth 10 | Set-Content -Path $settings -Encoding UTF8
Write-Host "OK: config written to $settings (machine=$Machine, user=$UserId)"

# Connection test.
try {
  $resp = Invoke-WebRequest -Uri "$Endpoint/v1/metrics" -Method POST `
    -Headers @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" } `
    -Body "{}" -TimeoutSec 10 -UseBasicParsing
  $code = $resp.StatusCode
} catch {
  if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = 0 }
}
switch ($code) {
  { $_ -in 200,202,400,415 } { Write-Host "Connection test: HTTP $code -> OK (server reachable, token valid)." }
  { $_ -in 401,403 }         { Write-Host "Connection test: HTTP $code -> WRONG TOKEN / blocked." }
  0                          { Write-Host "Connection test: could not connect to $Endpoint (network/DNS/firewall)." }
  default                    { Write-Host "Connection test: HTTP $code" }
}
Write-Host "Done. Just use Claude Code as usual - data will be sent to the server automatically."
