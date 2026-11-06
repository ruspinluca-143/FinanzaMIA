// Storico del mercato per l'app Finanze (scheda Consigli > Storia e confronti).
// Fonti PUBBLICHE e gratuite, nessuna credenziale, nessun dato dell'utente:
//  - VIX, chiusure giornaliere dal 1990: FRED (Federal Reserve di St. Louis), serie VIXCLS
//  - S&P 500, chiusure giornaliere degli ultimi 10 anni: FRED, serie SP500
//  - S&P 500, MEDIE MENSILI dal 1871 (Robert Shiller, copia dei dati su github.com/datasets/s-and-p-500)
// Uso: node storico.js [cartella-di-uscita]   (scrive storico-mercato.json; se una fonte manca NON scrive nulla: resta l'ultimo file buono)
const fs = require('fs'), path = require('path');
const out = process.argv[2] || '.';
const UA = 'FinanzeApp/1.0 (uso privato; ruspiniluca143@gmail.com)';
async function get(u) { const r = await fetch(u, { headers: { 'User-Agent': UA } }); if (!r.ok) throw new Error(u + ' -> HTTP ' + r.status); return r.text(); }
function fred(csv) { const d = [], v = []; for (const ln of csv.split(/\r?\n/)) { const p = ln.trim().split(','); if (p.length >= 2 && /^\d{4}-\d{2}-\d{2}$/.test(p[0])) { const x = parseFloat(p[1]); if (isFinite(x)) { d.push(p[0]); v.push(Math.round(x * 100) / 100); } } } return { d, v }; }
(async () => {
  const [vixT, spdT, spmT] = await Promise.all([
    get('https://fred.stlouisfed.org/graph/fredgraph.csv?id=VIXCLS'),
    get('https://fred.stlouisfed.org/graph/fredgraph.csv?id=SP500'),
    get('https://raw.githubusercontent.com/datasets/s-and-p-500/main/data/data.csv')]);
  const vix = fred(vixT), spd = fred(spdT), m = [], mv = [];
  for (const ln of spmT.split(/\r?\n/).slice(1)) { const p = ln.split(','); if (/^\d{4}-\d{2}-\d{2}$/.test(p[0])) { const x = parseFloat(p[1]); if (isFinite(x) && p[0] >= '1928-01-01') { m.push(p[0].slice(0, 7)); mv.push(Math.round(x * 100) / 100); } } }
  if (vix.d.length < 8000 || spd.d.length < 2000 || m.length < 1000) throw new Error('dati insufficienti: VIX ' + vix.d.length + ', S&P giornaliero ' + spd.d.length + ', S&P mensile ' + m.length);
  const doc = { app: 'finanze-storico', versione: 1, generato: new Date().toISOString(), fonti: ['FRED VIXCLS', 'FRED SP500', 'Shiller (S&P 500, medie mensili)'], vix, spd, spm: { m, v: mv } };
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'storico-mercato.json'), JSON.stringify(doc));
  console.log('Scritto storico-mercato.json: VIX ' + vix.d.length + ' giorni (' + vix.d[0] + ' - ' + vix.d[vix.d.length - 1] + '), S&P giornaliero ' + spd.d.length + ' (fino al ' + spd.d[spd.d.length - 1] + '), S&P mensile ' + m.length + ' (fino a ' + m[m.length - 1] + ')');
})().catch(e => { console.error('ERRORE: ' + e.message); process.exit(1); });
