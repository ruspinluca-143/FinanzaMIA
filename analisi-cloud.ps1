# Analisi giornaliera dei mercati, scritta nel cloud da Google Gemini (gratis) senza bisogno che il PC sia acceso.
# Legge i titoli di una decina di giornali economici (RSS pubblici) e i dati di mercato di mercati.json, e chiede a Gemini di scrivere
# l'analisi nello stesso formato di quella che scrive Claude sul PC (site/analisi.json). Se la chiave GEMINI_KEY non c'e', non fa niente.
# Il file e' pubblico: contiene solo notizie, giudizi per classe e idee generiche. Nessun dato personale.
# Uso:  pwsh ./analisi-cloud.ps1 -Uscita ./site [-Mercati ./site/mercati.json] [-Watch ./watchlist-pubblica.json] [-Forza] [-SoloRaccolta] [-RispostaProva file.json]
param([string]$Uscita = './site', [string]$Mercati = '', [string]$Watch = './watchlist-pubblica.json', [switch]$Forza, [switch]$SoloRaccolta, [string]$RispostaProva = '')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ua = 'FinanzeApp/1.0 (ruspiniluca143@gmail.com)'
$key = $env:GEMINI_KEY
if (-not $key -and -not $SoloRaccolta -and -not $RispostaProva) { 'Nessuna GEMINI_KEY: niente analisi nel cloud (resta quella di prima).'; return }
if (-not $Mercati) { $Mercati = Join-Path $Uscita 'mercati.json' }
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsLinux -or $IsMacOS) { 'Europe/Rome' } else { 'W. Europe Standard Time' }))
$adesso = [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz); $oggi = $adesso.ToString('yyyy-MM-dd')
$out = Join-Path $Uscita 'analisi.json'
$old = $null; if (Test-Path $out) { try { $old = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $old = $null } }
if (-not $Forza -and $old -and $old.data -eq $oggi) { "L'analisi di oggi ($oggi) c'e' gia': la tengo."; return }

# ---- 1. i titoli dei giornali (RSS) ----
$FEEDS = @(
  @('ANSA', 'https://www.ansa.it/sito/notizie/economia/economia_rss.xml'), @('Il Sole 24 Ore', 'https://www.ilsole24ore.com/rss/finanza.xml'), @('la Repubblica', 'https://www.repubblica.it/rss/economia/rss2.0.xml'),
  @('Corriere della Sera', 'https://www.corriere.it/rss/economia.xml'), @('Money.it', 'https://www.money.it/spip.php?page=backend'), @('Investing.com Italia', 'https://it.investing.com/rss/news.rss'),
  @('Wall Street Italia', 'https://www.wallstreetitalia.com/feed/'), @('Financial Times', 'https://www.ft.com/markets?format=rss'), @('BBC Business', 'https://feeds.bbci.co.uk/news/business/rss.xml'), @('CNBC', 'https://www.cnbc.com/id/10000664/device/rss/rss.html'), @('Investing.com', 'https://www.investing.com/rss/news_25.rss'))
function Txt($v) { if ($null -eq $v) { return '' }; if ($v -is [string]) { return $v }; if ($v.PSObject.Properties['#text']) { return [string]$v.'#text' }; if ($v.InnerText) { return [string]$v.InnerText }; return [string]$v }
$items = New-Object System.Collections.ArrayList; $seen = @{}
foreach ($f in $FEEDS) {
  try {
    $r = Invoke-WebRequest $f[1] -UserAgent $ua -UseBasicParsing -TimeoutSec 30; $t = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    $x = [xml]($t.TrimStart([char]0xFEFF)); $lst = @(); if ($x.rss) { $lst = @($x.rss.channel.item) } elseif ($x.feed) { $lst = @($x.feed.entry) }
    $n = 0
    foreach ($i in $lst) { if ($n -ge 8) { break }
      $ti = (Txt $i.title).Trim(); $li = if ($i.link -is [string]) { $i.link } elseif ($i.link.href) { [string]$i.link.href } else { Txt $i.link }; $li = $li.Trim()
      if (-not $ti -or $li -notmatch '^https://[^\s<>"'']+$' -or $seen.ContainsKey($ti)) { continue }
      $de = (Txt $i.description); if (-not $de) { $de = Txt $i.summary }; $de = ([regex]::Replace($de, '<[^>]+>', ' ') -replace '\s+', ' ').Trim(); if ($de.Length -gt 220) { $de = $de.Substring(0, 220) }
      $da = ''; $pd = Txt $i.pubDate; if (-not $pd) { $pd = Txt $i.updated }; if ($pd) { try { $da = ([datetime]::Parse($pd, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)).ToString('yyyy-MM-dd') } catch { $da = '' } }
      $seen[$ti] = 1; [void]$items.Add([pscustomobject]@{ testata = $f[0]; titolo = $ti; url = $li; data = $da; testo = $de }); $n++ }
    "  $($f[0]): $n titoli"
  } catch { "  $($f[0]): non letto ($($_.Exception.Message))" }
}
if ($items.Count -lt 15) { throw "Troppi pochi titoli letti ($($items.Count)): non scrivo l'analisi." }
$ind = $null; if (Test-Path $Mercati) { try { $ind = (Get-Content $Mercati -Raw -Encoding UTF8 | ConvertFrom-Json).indicatori } catch { $ind = $null } }
$cand = @(); if (Test-Path $Watch) { $cand = @((Get-Content $Watch -Raw -Encoding UTF8 | ConvertFrom-Json).strumenti | Where-Object { $_.tipo -eq 'etf' -and $_.id -match '^[A-Z]{2}[A-Z0-9]{9}[0-9]$' } | ForEach-Object { [pscustomobject]@{ isin = $_.id; nome = $_.nome; classe = $_.classe } }) | Select-Object -First 30 }
$righe = for ($k = 0; $k -lt $items.Count; $k++) { '[' + ($k + 1) + '] ' + $items[$k].testata + ' (' + $items[$k].data + '): ' + $items[$k].titolo + $(if ($items[$k].testo) { ' - ' + $items[$k].testo } else { '' }) }
$prev = if ($old) { 'Analisi di ieri: umore ' + $old.umore.valore + ' (' + $old.umore.etichetta + '); giudizi: ' + ((@($old.classi) | ForEach-Object { $_.classe + ' ' + $_.giudizio }) -join ', ') + '. Titolo: ' + $old.titolo } else { 'Nessuna analisi di ieri.' }
if ($SoloRaccolta) { "Raccolti " + $items.Count + " titoli; candidati ETF: " + $cand.Count; ($righe | Select-Object -First 5); return }

# ---- 2. Gemini scrive l'analisi ----
$sys = 'Sei un analista di mercati prudente che scrive ogni mattina, in italiano semplice, per un piccolo investitore italiano che investe soprattutto con piani di accumulo in ETF. Hai davanti i titoli numerati di alcuni giornali economici e alcuni indicatori. Usa SOLO quelle informazioni: non inventare numeri, date o fatti. Se qualcosa non e'' nei dati, non scriverlo. Non dare consigli personalizzati di acquisto o vendita: dai giudizi generali per classe e idee generiche. Ogni giudizio e'' un numero intero da -2 (molto prudente) a +2 (molto favorevole). Rispondi SOLO con JSON: {"titolo":"","sintesi":"4-6 frasi","umore":{"valore":-2..2,"etichetta":""},"classi":[{"classe":"Azioni|Obbligazioni|Liquidita|Crypto|Materie prime","giudizio":-2..2,"etichetta":"","perche":"2-4 frasi con i numeri dei dati","mossa":"una frase pratica e prudente","fonti":[numeri dei titoli]}],"temi":[{"titolo":"","giudizio":-2..2,"perche":"","fonti":[numeri]}],"attenzione":[{"titolo":"","perche":""}],"idee":[{"classe":"","isin":"uno dei candidati","perche":""}],"indicatori":[{"nome":"","valore":"","nota":""}],"limiti":"una frase onesta su cosa non hai potuto leggere"}. Fai 5 classi, 3-5 temi, 2-4 attenzioni, 0-4 idee (solo ISIN dell''elenco dei candidati), 4-6 indicatori presi dai dati. In "fonti" metti solo i numeri dei titoli che hai davvero usato.'
$ctx = 'Oggi e'' ' + $oggi + '. ' + $prev + "`n`nINDICATORI DI MERCATO (JSON):`n" + (($ind | ConvertTo-Json -Depth 5 -Compress)) + "`n`nCANDIDATI PER LE IDEE (ETF generici):`n" + (($cand | ConvertTo-Json -Compress)) + "`n`nTITOLI DEI GIORNALI:`n" + ($righe -join "`n")
if ($RispostaProva) { $g = Get-Content $RispostaProva -Raw -Encoding UTF8 | ConvertFrom-Json }
else {
  $body = @{ systemInstruction = @{ parts = @(@{ text = $sys }) }; contents = @(@{ role = 'user'; parts = @(@{ text = $ctx }) }); generationConfig = @{ temperature = 0.3; responseMimeType = 'application/json' } } | ConvertTo-Json -Depth 8 -Compress
  # 503 = Gemini sovraccarico (capita): 6 tentativi con pause crescenti; dal 4o si prova il modello piu' leggero
  $mods = @('gemini-flash-latest', 'gemini-flash-latest', 'gemini-flash-latest', 'gemini-flash-lite-latest', 'gemini-flash-lite-latest', 'gemini-flash-latest')
  $res = $null; for ($k = 1; $k -le $mods.Count; $k++) { try { $res = Invoke-RestMethod ('https://generativelanguage.googleapis.com/v1beta/models/' + $mods[$k - 1] + ':generateContent') -Method Post -Headers @{ 'x-goog-api-key' = $key } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120; break } catch { if ($k -eq $mods.Count) { throw ('Gemini non risponde: ' + ($_.Exception.Message -replace [regex]::Escape($key), '***')) }; Write-Host ('Tentativo ' + $k + ' fallito (' + ($_.Exception.Message -replace [regex]::Escape($key), '***') + '): riprovo.'); Start-Sleep -Seconds (15 * $k) } }
  $txt = $res.candidates[0].content.parts[0].text; if (-not $txt) { throw 'Gemini non ha dato una risposta.' }; $g = $txt | ConvertFrom-Json
}

# ---- 3. controlli e scrittura nello stesso formato di quella di Claude ----
function Giu($v) { $n = 0; if ([int]::TryParse([string]$v, [ref]$n)) { return [math]::Max(-2, [math]::Min(2, $n)) }; return 0 }
$usate = New-Object System.Collections.ArrayList; $map = @{}
function Fon($lst) { $o = @(); foreach ($x in @($lst)) { $n = 0; if ([int]::TryParse([string]$x, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { if (-not $map.ContainsKey($n)) { [void]$usate.Add($n); $map[$n] = $usate.Count }; $o += $map[$n] } }; return @($o | Select-Object -Unique) }
$classi = @(foreach ($c in @($g.classi)) { if ($c.classe -and $c.perche) { [ordered]@{ classe = [string]$c.classe; giudizio = (Giu $c.giudizio); etichetta = [string]$c.etichetta; perche = [string]$c.perche; mossa = [string]$c.mossa; fonti = (Fon $c.fonti) } } })
if ($classi.Count -lt 3) { throw 'Gemini ha scritto meno di 3 classi: non pubblico.' }
$temi = @(foreach ($c in @($g.temi)) { if ($c.titolo -and $c.perche) { [ordered]@{ titolo = [string]$c.titolo; giudizio = (Giu $c.giudizio); perche = [string]$c.perche; fonti = (Fon $c.fonti) } } })
$att = @(foreach ($c in @($g.attenzione)) { if ($c.titolo) { [ordered]@{ titolo = [string]$c.titolo; perche = [string]$c.perche } } })
$ok = @{}; foreach ($c in $cand) { $ok[$c.isin] = 1 }
$idee = @(foreach ($c in @($g.idee)) { if ($c.isin -and $ok.ContainsKey([string]$c.isin)) { [ordered]@{ classe = [string]$c.classe; isin = [string]$c.isin; perche = [string]$c.perche } } })
$indi = @(foreach ($c in @($g.indicatori)) { if ($c.nome -and $c.valore) { [ordered]@{ nome = [string]$c.nome; valore = [string]$c.valore; nota = [string]$c.nota } } })
$fonti = @(foreach ($n in $usate) { $it = $items[$n - 1]; [ordered]@{ testata = $it.testata; titolo = $it.titolo; url = $it.url; data = $it.data } })
if ($fonti.Count -lt 3) { throw 'Troppe poche fonti citate: non pubblico.' }
$um = [ordered]@{ valore = (Giu $g.umore.valore); etichetta = [string]$g.umore.etichetta }
$res = [ordered]@{ app = 'finanze-analisi'; versione = 1; generato = $adesso.ToString("yyyy-MM-dd'T'HH:mm:ssK"); data = $oggi; titolo = [string]$g.titolo; sintesi = [string]$g.sintesi; umore = $um; classi = $classi; temi = $temi; attenzione = $att; idee = $idee; indicatori = $indi; fonti = $fonti; limiti = ([string]$g.limiti + ' Scritta dall''AI Gemini leggendo i titoli e i riassunti dei giornali, non gli articoli interi.'); autore = 'Gemini (cloud)' }
$json = $res | ConvertTo-Json -Depth 8 -Compress
if ($json -match '(?i)(password|passphrase|iban|api[_-]?key|\bsecret\b)') { throw 'Il testo contiene parole sospette: non pubblico.' }
if ($json.Length -gt 250000) { throw 'File troppo grande.' }
if (-not (Test-Path $Uscita)) { New-Item -ItemType Directory $Uscita -Force | Out-Null }
[IO.File]::WriteAllText($out, $json, (New-Object Text.UTF8Encoding($false)))
"Scritta l'analisi del $oggi (" + [math]::Round($json.Length / 1KB) + ' KB, ' + $classi.Count + ' classi, ' + $fonti.Count + ' fonti)'
