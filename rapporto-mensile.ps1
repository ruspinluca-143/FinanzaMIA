# Rapporto del mese sui MERCATI, mandato sul telefono con ntfy (gratuito). Gira nel cloud il primo di ogni mese, anche a PC spento.
# - Usa SOLO dati pubblici gia' raccolti dal sito: storico-prezzi.csv (strumenti seguiti), mercati.json (tassi, crypto, calendario), analisi.json (articoli).
# - Non conosce i tuoi conti, i tuoi importi o i pesi del tuo portafoglio: non puo' dirti quanto hai guadagnato TU (quello sta nell'app: Laboratorio > Settimana).
# - Serve il nome dell'"argomento" segreto (NTFY_TOPIC). Senza, non fa nulla (tranne con -SoloProva, che stampa il messaggio).
# - Spunti da dati pubblici, non consigli personalizzati.
# Uso:  pwsh ./rapporto-mensile.ps1 [-Sito ./site] [-SoloProva]
param([string]$Sito = './site', [string]$Watch = './watchlist-pubblica.json', [string]$Argomento = $env:NTFY_TOPIC, [switch]$SoloProva)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$inv = [Globalization.CultureInfo]::InvariantCulture; $itc = [Globalization.CultureInfo]::GetCultureInfo('it-IT')
if (-not $Argomento -and -not $SoloProva) { 'Nessun argomento ntfy impostato: niente rapporto.'; return }
function JStr([string]$s) { '"' + (((($s -replace '\\', '\\') -replace '"', '\"') -replace "`r?`n", '\n') -replace '[\x00-\x1f]', ' ') + '"' }
function ToJson($o) {
  if ($null -eq $o) { return 'null' }
  if ($o -is [string]) { return (JStr $o) }
  if ($o -is [System.Collections.IDictionary]) { return '{' + (($o.psbase.Keys | ForEach-Object { (JStr ([string]$_)) + ':' + (ToJson $o[$_]) }) -join ',') + '}' }
  if ($o -is [int] -or $o -is [long] -or $o -is [double]) { return ([string]$o).Replace(',', '.') }
  if ($o -is [System.Collections.IEnumerable]) { return '[' + (($o | ForEach-Object { ToJson $_ }) -join ',') + ']' }
  return (JStr ([string]$o))
}
function Fmt([double]$n, [int]$d = 1) { $n.ToString('N' + $d, $itc) }
function Sg([double]$n) { $(if ($n -gt 0) { '+' } else { '' }) + (Fmt $n 1) + '%' }

$tz = [TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsLinux -or $IsMacOS) { 'Europe/Rome' } else { 'W. Europe Standard Time' }))
$roma = [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
$mesi = 'gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre'
$mp = $roma.AddMonths(-1).Month - 1; $nomeMese = $mesi[$mp]

# 1) variazione a 30 giorni degli strumenti seguiti (storico pubblico dei prezzi)
$stor = Join-Path $Sito 'storico-prezzi.csv'; $var = @(); $corto = $false
if (Test-Path $stor) {
  $ult = @{}
  foreach ($l in (Get-Content $stor -Encoding UTF8 | Select-Object -Skip 1)) { $p = $l.Split(';'); if ($p.Count -lt 7) { continue }; $d = 0.0; if (-not [double]::TryParse($p[3], [Globalization.NumberStyles]::Float, $inv, [ref]$d) -or $d -le 0) { continue }; $k = $p[2]; if (-not $ult[$k]) { $ult[$k] = @{ nome = $p[1]; date = @{} } }; $ult[$k].date[$p[5]] = $d }
  $ammessi = $null; if (Test-Path $Watch) { try { $ammessi = @{}; foreach ($s in @((Get-Content $Watch -Raw -Encoding UTF8 | ConvertFrom-Json).strumenti)) { $ammessi[([string]$s.id).ToLower()] = 1 } } catch { $ammessi = $null } }          # solo gli strumenti della watchlist pubblica (non le azioni a caso dell'elenco delle grandi aziende)
  foreach ($k in @($ult.psbase.Keys)) { if ($ammessi -and -not $ammessi.ContainsKey($k.ToLower())) { continue }; $x = $ult[$k]; $ds = @($x.date.psbase.Keys | Sort-Object); if ($ds.Count -lt 2) { continue }
    $fine = $ds[-1]; $lim = ([datetime]::ParseExact($fine, 'yyyy-MM-dd', $inv)).AddDays(-30).ToString('yyyy-MM-dd'); $inizio = @($ds | Where-Object { $_ -le $lim }) | Select-Object -Last 1
    if (-not $inizio) { $inizio = $ds[0]; $corto = $true }; if ($inizio -eq $fine) { continue }
    $ch = ($x.date[$fine] / $x.date[$inizio] - 1) * 100; if ([Math]::Abs($ch) -ge 80) { continue }
    $var += [pscustomobject]@{ nome = $x.nome; ch = $ch } }
  $var = @($var | Sort-Object ch -Descending)
}

# 2) i mercati
$righe = New-Object Collections.Generic.List[string]
$mf = Join-Path $Sito 'mercati.json'
if (Test-Path $mf) { try { $I = (Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json).indicatori
  if ($I.tassi_usa) { $righe.Add('Tassi USA: 10 anni ' + (Fmt $I.tassi_usa.y10 2) + '%, 2 anni ' + (Fmt $I.tassi_usa.y2 2) + '%.') }
  if ($I.crypto) { $c = 'Crypto: ' + (Sg $I.crypto.var_24h_pct) + ' nell''ultima giornata'; if ($I.paura_avidita_crypto) { $c += ', paura/avidita ' + $I.paura_avidita_crypto.valore + ' (' + $I.paura_avidita_crypto.classe + ')' }; $righe.Add($c + '.') }
  $oggi = $roma.ToString('yyyy-MM-dd'); $cal = @(@($I.calendario) | Where-Object { $_.data -ge $oggi } | Select-Object -First 2); if ($cal.Count) { $righe.Add('Prossimi appuntamenti: ' + (($cal | ForEach-Object { ([datetime]::ParseExact($_.data, 'yyyy-MM-dd', $inv)).ToString('d MMM', $itc) + ' ' + $_.titolo }) -join '; ') + '.') }
} catch { } }

# 3) l'analisi del giorno e gli articoli (scritti dall'AI sulle notizie pubbliche)
$arts = @(); $brev = ''
$af = Join-Path $Sito 'analisi.json'
if (Test-Path $af) { try { $A = Get-Content $af -Raw -Encoding UTF8 | ConvertFrom-Json; if ($A.titolo) { $brev = [string]$A.titolo }; $arts = @(@($A.fonti) | Where-Object { $_.url -match '^https://' } | Select-Object -First 3) } catch { } }

$txt = @()
if ($var.Count -ge 2) {
  $top = @($var | Select-Object -First 3); $bot = @($var | Select-Object -Last 3 | Sort-Object ch)
  $txt += 'Strumenti seguiti, ultimi 30 giorni' + $(if ($corto) { ' (storico ancora corto)' } else { '' }) + ':'
  $txt += 'Meglio: ' + (($top | ForEach-Object { $_.nome + ' ' + (Sg $_.ch) }) -join ', ') + '.'
  $txt += 'Peggio: ' + (($bot | ForEach-Object { $_.nome + ' ' + (Sg $_.ch) }) -join ', ') + '.'
  $txt += ''
}
if ($righe.Count) { $txt += $righe; $txt += '' }
if ($brev) { $txt += 'Ultima analisi: ' + $brev + '.'; $txt += '' }
if ($arts.Count) { $txt += 'Da leggere:'; foreach ($a in $arts) { $txt += '- ' + $a.titolo + ' (' + $a.testata + ')' } ; $txt += '' }
$txt += 'Il tuo andamento personale e'' nell''app (Altro > Laboratorio > Settimana): da qui non lo vedo. Spunti da dati pubblici, non consigli.'
$msg = [ordered]@{ topic = $(if ($Argomento) { $Argomento } else { 'prova' }); title = "Il mese di $nomeMese sui mercati"; message = ($txt -join "`n"); tags = @('bar_chart') }
if ($env:GITHUB_REPOSITORY) { $msg['click'] = 'https://' + ($env:GITHUB_REPOSITORY -split '/')[0] + '.github.io/' + ($env:GITHUB_REPOSITORY -split '/')[1] + '/' }
$az = @(); foreach ($a in ($arts | Select-Object -First 2)) { $az += [ordered]@{ action = 'view'; label = [string]$a.testata; url = [string]$a.url } }; if ($az.Count) { $msg['actions'] = $az }
$json = ToJson $msg
if ($SoloProva) { $json; return }
$null = Invoke-RestMethod -Uri 'https://ntfy.sh/' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
"Rapporto del mese di $nomeMese mandato ($($var.Count) strumenti, $($arts.Count) articoli)."
