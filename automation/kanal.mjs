// Goleo Telegram kanalı otomatik paylaşım
//   node kanal.mjs sabah  -> her aktif botun günün en iyi tercihini görsel albüm olarak paylaşır
//   node kanal.mjs gece   -> sabah paylaşılan tercihlerin sonuçlarını tek görselle paylaşır
// Ortam değişkenleri: SUPABASE_SERVICE_KEY, TELEGRAM_BOT_TOKEN, (opsiyonel) KANAL, SUPABASE_URL
// Deneme: DRY=1 FIXTURE=ornek.json node kanal.mjs sabah  -> paylaşmaz, PNG'leri ./cikti klasörüne yazar
import { chromium } from 'playwright';
import fs from 'node:fs';

const MOD = process.argv[2] || 'sabah';
const DRY = process.env.DRY === '1';
const KANAL = process.env.KANAL || '@goleoresmi';
const SB_URL = process.env.SUPABASE_URL || 'https://iaomtetwapkqaudmdzit.supabase.co';
const SB_KEY = process.env.SUPABASE_SERVICE_KEY;
const TG = process.env.TELEGRAM_BOT_TOKEN;
const BUYUK = /(süper lig|premier|laliga|la liga|serie a|bundesliga|ligue 1|şampiyonlar|avrupa|konferans|eredivisie|portekiz)/i;

const trTarih = (off = 0) => {
  const d = new Date(Date.now() + 3 * 3600e3 + off * 864e5); // Europe/Istanbul = UTC+3
  return d.toISOString().slice(0, 10);
};
const trSaat = () => new Date(Date.now() + 3 * 3600e3).toISOString().slice(11, 16);
const gunAdi = g => new Date(g + 'T12:00:00Z').toLocaleDateString('tr-TR', { day: 'numeric', month: 'long', weekday: 'long', timeZone: 'UTC' });
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => '&#' + c.charCodeAt(0) + ';');

// ---------- Supabase ----------
async function sb(path, opt = {}) {
  if (DRY) return null;
  const r = await fetch(SB_URL + '/rest/v1/' + path, {
    ...opt,
    headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'Content-Type': 'application/json', Prefer: 'return=minimal', ...(opt.headers || {}) }
  });
  if (!r.ok) throw new Error('Supabase ' + r.status + ' ' + (await r.text()).slice(0, 300));
  return r.status === 204 ? null : r.json();
}
async function veri(gun, sorgu) {
  if (DRY) {
    const f = JSON.parse(fs.readFileSync(process.env.FIXTURE, 'utf8'));
    return { bots: f.bots, picks: f.picks.map(p => ({ ...p, gun })) };
  }
  const bots = await sb('bots?select=*&aktif=eq.true&order=sira,id');
  const picks = await sb('bot_picks?select=*&gun=eq.' + gun + '&analiz_durum=eq.onay' + sorgu + '&order=saat,id');
  return { bots, picks };
}
const isaretle = (ids, alan) => DRY || !ids.length ? null :
  sb('bot_picks?id=in.(' + ids.join(',') + ')', { method: 'PATCH', body: JSON.stringify({ [alan]: true }) });

// ---------- Telegram ----------
async function tg(metod, form) {
  if (DRY) return;
  const r = await fetch('https://api.telegram.org/bot' + TG + '/' + metod, { method: 'POST', body: form });
  const j = await r.json();
  if (!j.ok) throw new Error('Telegram ' + metod + ': ' + JSON.stringify(j).slice(0, 300));
}
async function albumGonder(pngler, aciklama) {
  if (pngler.length === 1) {
    const f = new FormData();
    f.append('chat_id', KANAL); f.append('caption', aciklama); f.append('parse_mode', 'HTML');
    f.append('photo', new Blob([pngler[0]], { type: 'image/png' }), 'goleo.png');
    return tg('sendPhoto', f);
  }
  const f = new FormData(); f.append('chat_id', KANAL);
  f.append('media', JSON.stringify(pngler.map((_, i) => ({ type: 'photo', media: 'attach://p' + i, ...(i === 0 ? { caption: aciklama, parse_mode: 'HTML' } : {}) }))));
  pngler.forEach((b, i) => f.append('p' + i, new Blob([b], { type: 'image/png' }), 'p' + i + '.png'));
  return tg('sendMediaGroup', f);
}

// ---------- Görsel ----------
const LOGO = sfx => `<svg viewBox="0 0 240 240" style="width:100%;height:100%"><defs><linearGradient id="lr${sfx}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#C9A8FF"/><stop offset=".55" stop-color="#9B5CFF"/><stop offset="1" stop-color="#E25CFF"/></linearGradient><linearGradient id="lg${sfx}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#DCC8FF"/></linearGradient><radialGradient id="lb${sfx}" cx=".5" cy=".38" r=".7"><stop offset="0" stop-color="#3A2170"/><stop offset="1" stop-color="#120D1F"/></radialGradient></defs><circle cx="120" cy="120" r="104" fill="url(#lb${sfx})"/><circle cx="120" cy="120" r="104" fill="none" stroke="url(#lr${sfx})" stroke-width="11"/><path d="M168 86 A58 58 0 1 0 176 132 L176 124 L128 124" fill="none" stroke="url(#lg${sfx})" stroke-width="26" stroke-linecap="round" stroke-linejoin="round"/><polygon points="120,105 136,117 130,136 110,136 104,117" fill="#9B5CFF" stroke="#fff" stroke-width="4" stroke-linejoin="round"/></svg>`;

const CSS = `*{margin:0;padding:0;box-sizing:border-box}
body{width:1080px;height:1350px;overflow:hidden;background:#09070F;font-family:"Inter Display","Inter",sans-serif;color:#fff}
#c{position:relative;width:1080px;height:1350px;background:radial-gradient(90% 45% at 50% 0%,#3b1f73,#130e20 60%,#09070F)}
.hd{position:absolute;top:56px;left:70px;right:70px;display:flex;align-items:center;gap:22px}
.lg{width:96px;height:96px}
.hd h1{font-weight:900;font-size:52px;letter-spacing:12px;background:linear-gradient(90deg,#fff,#D4BCFF);-webkit-background-clip:text;background-clip:text;color:transparent}
.hd p{font-weight:500;font-size:24px;letter-spacing:4px;color:#9A94AD;margin-top:4px}
.tarih{margin-left:auto;font-weight:700;font-size:28px;color:#C9A8FF;padding:12px 22px;border-radius:999px;background:rgba(155,92,255,.15);border:2px solid rgba(155,92,255,.45)}
.f{display:flex;gap:8px}.f i{font-style:normal;width:44px;height:44px;border-radius:11px;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:24px}
.w{background:#16A34A}.l{background:#DC2626}.d{background:#64748B}
.ft{position:absolute;left:0;right:0;bottom:42px;text-align:center}
.ft b{font-weight:900;font-size:32px;color:#E3D4FF}
.ft p{margin-top:10px;font-weight:500;font-size:21px;color:rgba(255,255,255,.42)}`;

const formHtml = f => f && f.form ? `<span class="f">${[...f.form].map(c => `<i class="${c === 'G' ? 'w' : c === 'M' ? 'l' : 'd'}">${c}</i>`).join('')}</span>` : '';

function sayi(f) { const s = (f && f.form) || ''; return { n: s.length, g: [...s].filter(c => c === 'G').length, b: [...s].filter(c => c === 'B').length, m: [...s].filter(c => c === 'M').length }; }
function nedenHtml(p) {
  const e = sayi(p.form && p.form.ev), d = sayi(p.form && p.form.dep);
  if (!e.n && !d.n) return '';
  const bar = (x, t) => x.n ? `<div class="nr"><span class="nt">${esc(t)}</span><span class="nb"><i style="flex:${x.g || 0.001}" class="w"></i><i style="flex:${x.b || 0.001}" class="d"></i><i style="flex:${x.m || 0.001}" class="l"></i></span><span class="nv"><b>${x.g}G</b> ${x.b}B ${x.m}M</span></div>` : '';
  return `<div class="neden"><div class="nh">📊 Son ${Math.max(e.n, d.n)} maç formu</div>${bar(e, p.ev)}${bar(d, p.dep)}</div>`;
}
function tercihHtml(bot, p, gun) {
  const kilit = bot.vip;
  return `<!doctype html><html><head><meta charset="utf-8"><style>${CSS}
.bot{position:absolute;top:220px;left:70px;right:70px;display:flex;align-items:center;gap:26px}
.bav{width:120px;height:120px;border-radius:32px;display:flex;align-items:center;justify-content:center;font-size:66px;background:radial-gradient(circle at 30% 25%,${bot.renk}bb,${bot.renk}33 70%,#14111D);border:3px solid ${bot.renk}aa;box-shadow:0 0 40px ${bot.renk}66;position:relative}
.bav .v{position:absolute;bottom:-14px;left:50%;transform:translateX(-50%);font-size:20px;font-weight:900;color:#2A1E00;background:linear-gradient(90deg,#FFD866,#F5C542);border-radius:8px;padding:3px 10px}
.bot b{display:block;font-weight:900;font-size:60px;line-height:1.05}.bot span{font-weight:500;font-size:26px;color:#9A94AD}
.card{position:absolute;top:410px;left:70px;right:70px;padding:44px 44px 48px;border-radius:38px;background:linear-gradient(180deg,#1E1A2C,#15111F);border:2px solid rgba(255,255,255,.08);border-left:10px solid ${bot.renk};box-shadow:0 18px 50px rgba(0,0,0,.45)}
.lig{display:flex;justify-content:space-between;font-weight:500;font-size:30px;color:#9A94AD}.lig b{font-weight:700;color:#E3D4FF}
.tm{margin-top:30px;display:flex;flex-direction:column;gap:22px}
.tr{display:flex;align-items:center;justify-content:space-between;gap:20px}.tr .n{font-weight:900;font-size:52px;line-height:1.05}
.pk{margin-top:44px;padding-top:36px;border-top:2px solid rgba(255,255,255,.08);display:flex;align-items:center;gap:22px}
.pk .t{font-weight:900;font-size:64px}
.pk .o{font-weight:900;font-size:40px;padding:12px 28px;border-radius:999px;background:linear-gradient(90deg,#9B5CFF,#C04BFF)}
.pk .g{margin-left:auto;font-weight:700;font-size:30px;color:#9A94AD;text-align:right}.pk .g b{display:block;font-weight:900;font-size:52px;color:#34D399}
.lock{margin-top:44px;padding:34px;border-radius:28px;text-align:center;background:linear-gradient(90deg,rgba(245,197,66,.18),rgba(245,197,66,.06));border:2px solid rgba(245,197,66,.55)}
.neden{position:absolute;left:70px;right:70px;top:1000px;padding:30px 40px;border-radius:30px;background:rgba(255,255,255,.035);border:2px solid rgba(255,255,255,.07)}
.nh{font-weight:700;font-size:28px;color:#C9A8FF;margin-bottom:18px}
.nr{display:flex;align-items:center;gap:20px;margin-top:14px}
.nt{width:330px;font-weight:700;font-size:28px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.nb{flex:1;display:flex;height:22px;border-radius:11px;overflow:hidden;gap:3px}.nb i{display:block}
.nv{width:170px;text-align:right;font-weight:500;font-size:26px;color:#9A94AD}.nv b{color:#34D399;font-weight:900}
.lock b{display:block;font-weight:900;font-size:56px;color:#FFD866}.lock span{font-weight:700;font-size:28px;color:#F5E2A8}
</style></head><body><div id="c">
<div class="hd"><div class="lg">${LOGO('a')}</div><div><h1>GOLEO</h1><p>AI TAHMİN BOTLARI</p></div><div class="tarih">${esc(gunAdi(gun))}</div></div>
<div class="bot"><div class="bav">${esc(bot.avatar)}${bot.vip ? '<span class="v">VIP</span>' : ''}</div><div><b>${esc(bot.ad)}</b><span>${esc(bot.aciklama || '')}</span></div></div>
<div class="card">
 <div class="lig"><span>${esc(p.lig || '')}</span><b>⏰ ${esc(p.saat)}</b></div>
 <div class="tm"><div class="tr"><span class="n">${esc(p.ev)}</span>${formHtml(p.form && p.form.ev)}</div>
 <div class="tr"><span class="n">${esc(p.dep)}</span>${formHtml(p.form && p.form.dep)}</div></div>
 ${kilit ? `<div class="lock"><b>🔒 VIP TAHMİN</b><span>Tahmin ve oran VIP üyelere özel · @goleoaibot</span></div>`
         : `<div class="pk"><span class="t">${esc(p.tahmin)}</span><span class="o">${Number(p.oran).toFixed(2)}</span><span class="g">Güven<b>%${p.guven}</b></span></div>`}
</div>
${nedenHtml(p)}
<div class="ft"><b>Tüm tahminler: @goleoaibot</b><p>Form: son 5 maç (G galibiyet · B beraberlik · M mağlubiyet) · Kazanç garantisi yoktur · 18+</p></div>
</div></body></html>`;
}

function sonucHtml(satirlar, gun) {
  const w = satirlar.filter(s => s.p.durum === 'tuttu').length, t = satirlar.filter(s => s.p.durum !== 'iptal').length;
  const n = satirlar.length, h = n <= 4 ? 176 : n <= 5 ? 150 : 128;
  return `<!doctype html><html><head><meta charset="utf-8"><style>${CSS}
.ttl{position:absolute;top:200px;left:70px;right:70px;display:flex;justify-content:space-between;align-items:center}
.ttl b{font-weight:900;font-size:62px}.ttl b em{font-style:normal;background:linear-gradient(90deg,#C9A8FF,#FF8BD8);-webkit-background-clip:text;background-clip:text;color:transparent}
.skor{font-weight:900;font-size:56px;padding:10px 30px;border-radius:24px;background:${w * 2 >= t ? 'rgba(52,211,153,.15)' : 'rgba(255,255,255,.06)'};border:2px solid ${w * 2 >= t ? 'rgba(52,211,153,.55)' : 'rgba(255,255,255,.15)'};color:${w * 2 >= t ? '#34D399' : '#fff'}}
.list{position:absolute;top:330px;left:70px;right:70px;display:flex;flex-direction:column;gap:18px}
.row{height:${h}px;display:flex;align-items:center;gap:24px;padding:0 30px;border-radius:28px;background:linear-gradient(180deg,#1E1A2C,#15111F);border:2px solid rgba(255,255,255,.07)}
.av{width:78px;height:78px;flex:none;border-radius:22px;display:flex;align-items:center;justify-content:center;font-size:42px}
.mid{flex:1;min-width:0}.mid .bn{font-weight:700;font-size:24px;color:#9A94AD}
.mid .m{font-weight:900;font-size:34px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mid .t{font-weight:700;font-size:26px;color:#C9A8FF;margin-top:4px}
.sc{font-weight:900;font-size:40px;min-width:96px;text-align:center}
.rs{width:76px;height:76px;flex:none;border-radius:50%;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:40px}
.ok{background:#16A34A;box-shadow:0 0 24px rgba(52,211,153,.5)}.no{background:#DC2626}.ip{background:#475569;font-size:22px}
</style></head><body><div id="c">
<div class="hd"><div class="lg">${LOGO('b')}</div><div><h1>GOLEO</h1><p>AI TAHMİN BOTLARI</p></div><div class="tarih">${esc(gunAdi(gun))}</div></div>
<div class="ttl"><b>Günün <em>sonuçları</em></b><span class="skor">${w}/${t}</span></div>
<div class="list">${satirlar.map(({ bot, p }) => `<div class="row">
 <div class="av" style="background:radial-gradient(circle at 30% 25%,${bot.renk}bb,${bot.renk}33 70%,#14111D);border:2px solid ${bot.renk}aa">${esc(bot.avatar)}</div>
 <div class="mid"><div class="bn">${esc(bot.ad)}</div><div class="m">${esc(p.ev)} – ${esc(p.dep)}</div><div class="t">${esc(p.tahmin)} · ${Number(p.oran).toFixed(2)}</div></div>
 <div class="sc">${p.s1 ?? '-'}-${p.s2 ?? '-'}</div>
 <div class="rs ${p.durum === 'tuttu' ? 'ok' : p.durum === 'yatti' ? 'no' : 'ip'}">${p.durum === 'tuttu' ? '✓' : p.durum === 'yatti' ? '✗' : 'ERT'}</div></div>`).join('')}</div>
<div class="ft"><b>Tüm sonuçlar ve yeni tahminler: @goleoaibot</b><p>Tutan da yatan da paylaşılır · Kazanç garantisi yoktur · 18+</p></div>
</div></body></html>`;
}

async function render(htmls) {
  const b = await chromium.launch();
  const out = [];
  for (const h of htmls) {
    const p = await b.newPage({ viewport: { width: 1080, height: 1350 }, deviceScaleFactor: 2 });
    await p.setContent(h, { waitUntil: 'load' });
    await p.waitForTimeout(400);
    out.push(await p.screenshot({ type: 'png' }));
    await p.close();
  }
  await b.close();
  return out;
}
function kaydet(pngler, ad) {
  fs.mkdirSync('cikti', { recursive: true });
  pngler.forEach((b, i) => fs.writeFileSync(`cikti/${ad}_${i + 1}.png`, b));
}

// ---------- Modlar ----------
async function sabah() {
  const gun = trTarih(0), simdi = trSaat();
  const { bots, picks } = await veri(gun, '&kanal_paylasildi=eq.false&durum=is.null');
  const secim = [];
  for (const bot of bots) {
    const aday = picks.filter(p => p.bot_id === bot.id && (DRY || p.saat > simdi))
      .sort((a, b) => (BUYUK.test(b.lig || '') - BUYUK.test(a.lig || '')) || (b.guven - a.guven) || a.saat.localeCompare(b.saat));
    if (aday[0]) secim.push({ bot, p: aday[0] });
  }
  if (!secim.length) { console.log('Paylaşılacak tercih yok.'); return; }
  const png = await render(secim.map(s => tercihHtml(s.bot, s.p, gun)));
  if (DRY) kaydet(png, 'sabah');
  const satir = secim.map(({ bot, p }) => bot.vip
    ? `${bot.avatar} <b>${esc(bot.ad)}</b>: ${esc(p.saat)} ${esc(p.ev)} – ${esc(p.dep)} · 🔒 VIP`
    : `${bot.avatar} <b>${esc(bot.ad)}</b>: ${esc(p.saat)} ${esc(p.ev)} – ${esc(p.dep)} · ${esc(p.tahmin)} (${Number(p.oran).toFixed(2)})`).join('\n');
  const aciklama = `☀️ <b>Goleo AI botlarının bugünkü tercihleri</b>\n\n${satir}\n\n🤖 Tüm tahminler ve analizler: @goleoaibot\n<i>Kazanç garantisi yoktur. 18+</i>`;
  await albumGonder(png, aciklama.slice(0, 1024));
  await isaretle(secim.map(s => s.p.id), 'kanal_paylasildi');
  console.log('Sabah paylaşıldı:', secim.length, 'tercih');
}

async function gece() {
  const gun = trTarih(new Date(Date.now() + 3 * 3600e3).getUTCHours() < 12 ? -1 : 0);
  const { bots, picks } = await veri(gun, '&kanal_paylasildi=eq.true&kanal_sonuc_paylasildi=eq.false&durum=not.is.null');
  const B = Object.fromEntries(bots.map(b => [b.id, b]));
  const satirlar = picks.filter(p => B[p.bot_id]).map(p => ({ bot: B[p.bot_id], p }))
    .sort((a, b) => (a.bot.sira - b.bot.sira) || a.p.saat.localeCompare(b.p.saat)).slice(0, 6);
  if (!satirlar.length) { console.log('Paylaşılacak sonuç yok.'); return; }
  const png = await render([sonucHtml(satirlar, gun)]);
  if (DRY) kaydet(png, 'gece');
  const w = satirlar.filter(s => s.p.durum === 'tuttu').length, t = satirlar.filter(s => s.p.durum !== 'iptal').length;
  const satir = satirlar.map(({ bot, p }) => `${p.durum === 'tuttu' ? '✅' : p.durum === 'yatti' ? '❌' : '⏸'} ${bot.avatar} ${esc(p.ev)} – ${esc(p.dep)} (${p.s1 ?? '-'}-${p.s2 ?? '-'}) · ${esc(p.tahmin)}`).join('\n');
  const aciklama = `🌙 <b>Günün sonuçları: ${w}/${t} tuttu</b>\n\n${satir}\n\nTutan da yatan da burada. Yarın yeni tercihlerle görüşmek üzere! ⚽\n🤖 @goleoaibot\n<i>Kazanç garantisi yoktur. 18+</i>`;
  await albumGonder(png, aciklama.slice(0, 1024));
  await isaretle(satirlar.map(s => s.p.id), 'kanal_sonuc_paylasildi');
  console.log('Gece paylaşıldı:', satirlar.length, 'sonuç');
}

if (!DRY && (!SB_KEY || !TG)) { console.error('SUPABASE_SERVICE_KEY ve TELEGRAM_BOT_TOKEN gerekli'); process.exit(1); }
(MOD === 'gece' ? gece() : sabah()).catch(e => { console.error(e); process.exit(1); });
