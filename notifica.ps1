# Manda sul telefono (con ntfy.sh: gratuito, senza account) il recap della mattina o della sera: qualche numero di mercato e gli articoli da leggere, con i link.
# - Usa SOLO i dati pubblici gia' raccolti in mercati.json: non conosce i tuoi conti, i tuoi importi o i tuoi strumenti.
# - Serve il nome di un "argomento" segreto (variabile NTFY_TOPIC). Senza, non fa nulla.
# - Sono spunti presi da testate e ricerche pubbliche: non sono consigli personalizzati di acquisto o vendita.
# Uso:  powershell -File notifica.ps1 [-Sito cartella] [-Momento mattina|sera] [-SoloProva]
param([string]$Sito = './site', [string]$Argomento = $env:NTFY_TOPIC, [string]$Momento = '', [switch]$SoloProva)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$inv = [Globalization.CultureInfo]::InvariantCulture
$itc = [Globalization.CultureInfo]::GetCultureInfo('it-IT')
if (-not $Argomento -and -not $SoloProva) { 'Nessun argomento ntfy impostato: niente notifica.'; return }

function JStr([string]$s) { '"' + (((($s -replace '\\', '\\') -replace '"', '\"') -replace "`r?`n", '\n') -replace '[\x00-\x1f]', ' ') + '"' }          # gli "a capo" restano a capo nel messaggio
function ToJson($o) {
  if ($null -eq $o) { return 'null' }
  if ($o -is [string]) { return (JStr $o) }
  if ($o -is [System.Collections.IDictionary]) { return '{' + (($o.Keys | ForEach-Object { (JStr ([string]$_)) + ':' + (ToJson $o[$_]) }) -join ',') + '}' }
  if ($o -is [System.Collections.IEnumerable]) { return '[' + (($o | ForEach-Object { ToJson $_ }) -join ',') + ']' }
  return (JStr ([string]$o))
}
function Fmt([double]$n, [int]$d = 2) { $n.ToString('N' + $d, $itc) }

$ora = (Get-Date).ToUniversalTime()
if (-not $Momento) { $Momento = if ($ora.Hour -lt 13) { 'mattina' } else { 'sera' } }
$oggi = $ora.ToString('yyyy-MM-dd')
$stFile = Join-Path $Sito 'stato-notifiche.json'; $st = @{}
if (Test-Path $stFile) { try { $o = Get-Content $stFile -Raw | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $st[$p.Name] = [string]$p.Value } } catch { } }
if (-not $SoloProva -and $st[$Momento] -eq $oggi) { "Il recap della $Momento e' gia' stato mandato oggi."; return }

$m = Get-Content (Join-Path $Sito 'mercati.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$I = $m.indicatori; $righe = New-Object Collections.Generic.List[string]
if ($I.tassi_usa) { $t = $I.tassi_usa; $righe.Add('Tassi USA: 10 anni ' + (Fmt $t.y10) + '%, 2 anni ' + (Fmt $t.y2) + '% (differenza ' + (Fmt $t.spread_2_10) + ').') }
if ($I.crypto) { $c = $I.crypto; $txt = 'Crypto: ' + (Fmt $c.var_24h_pct 1) + '% in 24 ore'; if ($I.paura_avidita_crypto) { $txt += ', paura/avidita ' + $I.paura_avidita_crypto.valore + ' (' + $I.paura_avidita_crypto.classe + ')' }; $righe.Add($txt + '.') }
if ($I.calendario) { $n = @($I.calendario) | Where-Object { $_.data -ge $oggi } | Select-Object -First 1; if ($n) { $righe.Add('Prossimo appuntamento: ' + ([datetime]::ParseExact($n.data, 'yyyy-MM-dd', $inv)).ToString('d MMM', $itc) + ' - ' + $n.titolo + '.') } }

# movimenti forti: strumenti seguiti che dall'ultima seduta si sono mossi piu' del 3% (8% per le crypto). Solo prezzi pubblici.
$forti = @(); $stor = Join-Path $Sito 'storico-prezzi.csv'
if (Test-Path $stor) {
  $ult = @{}
  foreach ($l in (Get-Content $stor -Encoding UTF8 | Select-Object -Skip 1)) { $p = $l.Split(';'); if ($p.Count -lt 7) { continue }; $k = $p[2]; if (-not $ult[$k]) { $ult[$k] = @{ nome = $p[1]; fonte = $p[6]; date = @{} } }; $ult[$k].date[$p[5]] = [double]::Parse($p[3], $inv) }
  foreach ($k in $ult.Keys) { $x = $ult[$k]; $ds = @($x.date.Keys | Sort-Object -Descending); if ($ds.Count -lt 2) { continue }
    $ch = $x.date[$ds[0]] / $x.date[$ds[1]] - 1; $soglia = if ($x.fonte -eq 'coingecko') { 0.08 } else { 0.03 }
    if ([Math]::Abs($ch) -ge $soglia -and [Math]::Abs($ch) -lt 0.6) { $forti += [pscustomobject]@{ nome = $x.nome; ch = $ch } } }
  $forti = @($forti | Sort-Object { [Math]::Abs($_.ch) } -Descending | Select-Object -First 4)
}
if ($forti.Count) { $righe.Insert(0, 'Movimenti forti: ' + (($forti | ForEach-Object { $_.nome + ' ' + $(if ($_.ch -gt 0) { '+' } else { '' }) + (Fmt ($_.ch * 100) 1) + '%' }) -join ', ') + '.') }

# promemoria del mese: nei primi 3 giorni del mese (ora italiana), una volta sola
$roma = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($ora, $(if ($IsLinux -or $IsMacOS) { 'Europe/Rome' } else { 'W. Europe Standard Time' }))
$mese = $roma.ToString('yyyy-MM'); $promemoria = ($roma.Day -le 3 -and $st['promemoria'] -ne $mese)
if ($promemoria) {
  $t = 'Promemoria del mese: apri l''app, guarda "Da aggiornare" e aggiorna i saldi dei conti fermi.'
  if (@(1, 4, 7, 10) -contains $roma.Month) { $t += ' Tocca anche ai conti trimestrali: mandami gli estratti di fine trimestre.' }
  $righe.Insert(0, $t)
}

# articoli: 1-2 di ricerca (professori, banche centrali), 1 dagli Stati Uniti, 1 dall'Europa; i piu' recenti, con la fonte
function Pick($fonti, $re, $n) {
  $v = foreach ($f in $fonti) { if ($f.ok -and $f.nome -match $re) { foreach ($x in @($f.voci)) { [pscustomobject]@{ fonte = $f.nome; titolo = $x.titolo; link = $x.link; data = [string]$x.data } } } }
  @($v | Sort-Object data -Descending | Select-Object -First $n)
}
$ric = @(Pick $m.fonti 'Damodaran|VoxEU|Project Syndicate|lavoce|Liberty|BIS|FEDS|NBER|blog|Underground|Dollars|Common Sense' 6)
$usa = @(Pick $m.fonti 'New York Times|Bloomberg|MarketWatch|CNBC|Wall Street' 6)
$eur = @(Pick $m.fonti 'Financial Times|Economist|Sole 24|Handelsblatt|Guardian|BBC' 6)
$sel = New-Object Collections.Generic.List[object]
$vis = @{}
foreach ($grp in @(@('Ricerca', $ric, 2), @('USA', $usa, 1), @('Europa', $eur, 1))) {
  $k = 0; foreach ($a in $grp[1]) { if ($k -ge $grp[2]) { break }; if ($vis[$a.fonte]) { continue }; $vis[$a.fonte] = 1; $sel.Add([pscustomobject]@{ tag = $grp[0]; a = $a }); $k++ }
}
$testo = ($righe -join "`n")
if ($sel.Count) { $testo += "`n`nDa leggere:"; foreach ($s in $sel) { $testo += "`n- [" + $s.tag + '] ' + $s.a.titolo + ' (' + ($s.a.fonte -replace ' - .*$', '') + ')' } }
$testo += "`n`nSpunti dalle fonti, non consigli personalizzati."

$sito = if ($env:GITHUB_REPOSITORY) { 'https://' + ($env:GITHUB_REPOSITORY -split '/')[0] + '.github.io/' + ($env:GITHUB_REPOSITORY -split '/')[1] + '/' } else { '' }
$azioni = @(); foreach ($s in ($sel | Select-Object -First 3)) { $azioni += [ordered]@{ action = 'view'; label = $s.tag; url = $s.a.link } }
$titolo = if ($promemoria) { 'Promemoria del mese e recap della ' + $Momento } elseif ($forti.Count) { 'Movimenti forti - recap della ' + $Momento } else { 'Recap della ' + $Momento + ' - mercati e articoli' }
$msg = [ordered]@{ topic = $(if ($Argomento) { $Argomento } else { 'prova' }); title = $titolo; message = $testo; tags = @($(if ($forti.Count) { 'warning' } elseif ($promemoria) { 'calendar' } else { 'chart_with_upwards_trend' })) }
if ($forti.Count -or $promemoria) { $msg['priority'] = '4' }
if ($sito) { $msg['click'] = $sito }
if ($azioni.Count) { $msg['actions'] = $azioni }
$json = ToJson $msg
if ($SoloProva) { $json; return }

$body = [Text.Encoding]::UTF8.GetBytes($json)
$null = Invoke-RestMethod -Uri 'https://ntfy.sh/' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
$st[$Momento] = $oggi
if ($promemoria) { $st['promemoria'] = $mese }
$out = '{' + (($st.Keys | Sort-Object | ForEach-Object { (JStr $_) + ':' + (JStr $st[$_]) }) -join ',') + '}'
[IO.File]::WriteAllText($stFile, $out, (New-Object Text.UTF8Encoding($false)))
"Recap della $Momento mandato (" + $sel.Count + ' articoli).'
