# Classifiche dei titoli: per circa 100 grandi azioni USA (S&P 100), per gli ETF e le obbligazioni della tua lista e per qualche ETF molto diffuso,
# legge dall'API pubblica di onvista (la stessa dei prezzi) il prezzo, la variazione di ieri/oggi, i rendimenti a 1 settimana, 1 mese, 3 mesi,
# 6 mesi, da inizio anno, 1, 3 e 5 anni, il massimo e il minimo di 52 settimane e (per le azioni) il numero di azioni, e scrive classifiche.json.
# Aggiornamento giornaliero, non live. Solo dati pubblici di mercato: niente di personale. Non e' un consiglio.
# Uso:  pwsh ./classifiche.ps1 -Uscita ./site [-Lista ./aziende-lista.json] [-Watch ./watchlist-pubblica.json] [-Forza] [-Max 20]
param([string]$Uscita = './site', [string]$Lista = './aziende-lista.json', [string]$Watch = './watchlist-pubblica.json', [switch]$Forza, [int]$Max = 0, [int]$PausaMs = 150)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ua = 'FinanzeApp/1.0 (ruspiniluca143@gmail.com)'
$out = Join-Path $Uscita 'classifiche.json'
$old = $null; if (Test-Path $out) { try { $old = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $old = $null } }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (-not $Forza -and $old -and $old.ts -and ($now - [long]$old.ts) -lt 18 * 3600) { 'Classifiche di meno di 18 ore fa: le tengo.'; return }

function Api([string]$url) {
  for ($k = 1; $k -le 3; $k++) { try { Start-Sleep -Milliseconds $PausaMs; return Invoke-RestMethod $url -UserAgent $ua -TimeoutSec 40 } catch { if ($k -eq 3) { throw }; Start-Sleep -Seconds (2 * $k) } }
}
# ETF molto diffusi, oltre a quelli della tua lista (se un codice non si trova viene saltato)
$EXTRA = 'IE00B4L5Y983', 'IE00BK5BQT80', 'IE00B5BMR087', 'IE00B53SZB19', 'IE00BKM4GZ66', 'IE00B945VV12', 'IE00B3RBWM25', 'IE00B3XXRP09', 'IE00B0M62Q58', 'IE00B4ND3602', 'IE00B3F81R35', 'IE00B1FZS798', 'IE00B6R52259', 'IE00BF4RFH31', 'IE00B8GKDB10', 'LU0908500753', 'IE00B579F325', 'LU0290358497'

$CAND = [ordered]@{}
if (Test-Path $Lista) { foreach ($a in (Get-Content $Lista -Raw -Encoding UTF8 | ConvertFrom-Json).aziende) { $CAND['T:' + $a.ticker] = @{ q = $a.ticker; nome = $a.nome; set = $a.settore; tk = $a.ticker; isin = '' } } }
if (Test-Path $Watch) { foreach ($s in (Get-Content $Watch -Raw -Encoding UTF8 | ConvertFrom-Json).strumenti) { if ($s.id -match '^[A-Z]{2}[A-Z0-9]{9}[0-9]$' -and $s.classe -ne 'Crypto') { $k = 'I:' + $s.id; if (-not $CAND.Contains($k)) { $CAND[$k] = @{ q = $s.id; nome = $s.nome; set = ''; tk = ''; isin = $s.id } } } } }
foreach ($e in $EXTRA) { $k = 'I:' + $e; if (-not $CAND.Contains($k)) { $CAND[$k] = @{ q = $e; nome = ''; set = ''; tk = ''; isin = $e } } }
$keys = @($CAND.Keys); if ($Max -gt 0) { $keys = $keys | Select-Object -First $Max }
$ids = @{}; if ($old -and $old.ids) { foreach ($p in $old.ids.PSObject.Properties) { $ids[$p.Name] = [string]$p.Value } }

function Rel($c, [string]$n) { if ($c -and $c.PSObject.Properties[$n] -and $null -ne $c.$n) { return [math]::Round([double]$c.$n, 2) } else { return $null } }
$voci = @(); $seen = @{}; $fail = 0
foreach ($k in $keys) {
  $it = $CAND[$k]
  try {
    if (-not $ids.ContainsKey($k)) {
      $r = Api ('https://api.onvista.de/api/v1/instruments/query?searchValue=' + [Uri]::EscapeDataString($it.q) + '&limit=10')
      if ($it.isin) { $x = @($r.list | Where-Object { $_.isin -eq $it.isin })[0] }
      else { $x = @($r.list | Where-Object { $_.entityType -eq 'STOCK' -and $_.homeSymbol -eq $it.tk -and $_.isin -like 'US*' })[0]; if (-not $x) { $x = @($r.list | Where-Object { $_.entityType -eq 'STOCK' -and $_.homeSymbol -eq $it.tk })[0] } }
      if (-not $x) { $fail++; continue }
      $ids[$k] = $x.entityType + '/' + $x.entityValue
    }
    $s = Api ('https://api.onvista.de/api/v1/instruments/' + $ids[$k] + '/snapshot')
    $q = $s.quote; $c = $s.cnPerformance; $last = [double]$q.last; if (-not ($last -gt 0)) { $fail++; continue }
    $isin = [string]$s.instrument.isin; if ($seen.ContainsKey($isin)) { continue }; $seen[$isin] = 1
    $ty = switch ($s.instrument.entityType) { 'STOCK' { 'azione' } 'FUND' { 'etf' } 'BOND' { 'bond' } default { 'altro' } }
    $hz = @(@(1825, 'Y5'), @(1095, 'Y3'), @(365, 'W52'), @(182, 'M6'), @(91, 'M3'), @(30, 'W4'), @(7, 'W1'))
    $sd = @(); $sp = @(); foreach ($h in $hz) { $v = Rel $c ('performanceRel' + $h[1]); if ($null -ne $v -and $v -gt -99) { $sd += [int]$h[0]; $sp += [math]::Round($last / (1 + $v / 100), 4) } }
    $sd += 0; $sp += [math]::Round($last, 4)
    $cap = $null; if ($ty -eq 'azione' -and $s.stocksFigure -and $s.stocksFigure.numSharesInstrument -and $q.isoCurrency -eq 'EUR') { $cap = [math]::Round([double]$s.stocksFigure.numSharesInstrument * $last) }
    $set = $it.set; if (-not $set -and $s.company -and $s.company.branch -and $s.company.branch.sector) { $set = [string]$s.company.branch.sector.name }
    $voci += [ordered]@{ n = [string]$s.instrument.name; tk = [string]$s.instrument.homeSymbol; isin = $isin; ty = $ty; set = [string]$set; ccy = [string]$q.isoCurrency; p = [math]::Round($last, 4); pd = $(if ($q.previousLast) { [math]::Round([double]$q.previousLast, 4) } else { $null }); d1 = $(if ($null -ne $q.performancePct) { [math]::Round([double]$q.performancePct, 2) } else { $null });
      w1 = (Rel $c 'performanceRelW1'); m1 = (Rel $c 'performanceRelW4'); m3 = (Rel $c 'performanceRelM3'); m6 = (Rel $c 'performanceRelM6'); ytd = (Rel $c 'performanceRelCy'); y1 = (Rel $c 'performanceRelW52'); y3 = (Rel $c 'performanceRelY3'); y5 = (Rel $c 'performanceRelY5');
      hi = $(if ($q.highPrice1Year) { [math]::Round([double]$q.highPrice1Year, 4) } else { $null }); lo = $(if ($q.lowPrice1Year) { [math]::Round([double]$q.lowPrice1Year, 4) } else { $null }); cap = $cap; sd = $sd; sp = $sp }
  } catch { $fail++; 'ERRORE ' + $k + ': ' + $_.Exception.Message }
}
"letti $($voci.Count) titoli, $fail non trovati o in errore"
if ($voci.Count -lt 15) { if ($old -and @($old.voci).Count) { 'Troppo pochi dati: tengo quelli di prima.'; return }; throw 'Troppo pochi titoli letti: non scrivo un file quasi vuoto.' }
$res = [ordered]@{ app = 'finanze-classifiche'; versione = 1; ts = $now; generato = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); fonte = 'onvista'; ids = $ids; voci = $voci }
if (-not (Test-Path $Uscita)) { New-Item -ItemType Directory $Uscita -Force | Out-Null }
[IO.File]::WriteAllText($out, ($res | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
'Scritto ' + $out + ' (' + [math]::Round((Get-Item $out).Length / 1KB) + ' KB)'
