-- GOLEO AI BOTLAR v2
-- Form arşivi + maç sayfası oranları (İY/MS, kombine) + Sürpriz Bot + Claude web analizi
-- Supabase > SQL Editor'da bir kez çalıştırın (botlar.sql'den SONRA).

-- ===== 1) Fikstür satırlarına takım kimlikleri ve iddaa kodu =====
create or replace function public.fikstur_cek(d date, maxage interval)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  dk text := to_char(d, 'DD/MM/YYYY');
  c fixture_cache%rowtype;
  res http_response; j jsonb; out jsonb;
begin
  select * into c from fixture_cache where day = dk;
  if found and c.fetched_at > now() - maxage then
    return jsonb_build_object('ok', true, 'at', c.fetched_at, 'm', c.data);
  end if;
  if not pg_try_advisory_xact_lock(hashtext('fikstur:' || dk)) then
    return jsonb_build_object('ok', c.day is not null, 'at', c.fetched_at, 'm', coalesce(c.data, '[]'::jsonb));
  end if;
  begin
    perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');
    res := http(('GET',
      'https://vd.mackolik.com/livedata?date=' || urlencode(dk) || '&_=' || extract(epoch from now())::bigint,
      array[http_header('User-Agent', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148'),
            http_header('Referer', 'https://arsiv.mackolik.com/')],
      null, null)::http_request);
    j := res.content::jsonb;
    if jsonb_typeof(j->'m') is distinct from 'array' then raise exception 'beklenmeyen format'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', r->>0, 'eid', r->>1, 'ev', r->>2, 'did', r->>3, 'dep', r->>4, 'st', r->>5, 'dk', r->>6,
             's1', r->>12, 's2', r->>13, 'iy', nullif(r->>7, ''), 'kod', r->>14, 'saat', r->>16,
             'o1', r->>18, 'ox', r->>19, 'o2', r->>20, 'oa', r->>21, 'ou', r->>22,
             'lig', case when jsonb_typeof(r->36) = 'array'
                         then trim(coalesce(r->36->>1, '') || ' ' || coalesce(r->36->>3, '')) end)
           order by r->>16, r->>2), '[]'::jsonb)
      into out
      from (select distinct on (e->>0) e r from jsonb_array_elements(j->'m') e
            where jsonb_typeof(e) = 'array' order by e->>0) q
     where coalesce(case when jsonb_typeof(r->36) = 'array' then r->36->>11 end, '1') = '1';
  exception when others then
    return jsonb_build_object('ok', c.day is not null, 'eski', true, 'at', c.fetched_at,
                              'm', coalesce(c.data, '[]'::jsonb), 'msg', 'Maç verisi alınamadı');
  end;
  insert into fixture_cache(day, data, fetched_at) values (dk, out, now())
    on conflict (day) do update set data = excluded.data, fetched_at = excluded.fetched_at;
  return jsonb_build_object('ok', true, 'at', now(), 'm', out);
end $$;

-- ===== 2) Sonuç arşivi + takım formu =====
create table if not exists public.mac_arsiv(
  mac_id text primary key,
  gun date not null,
  lig text, eid text, ev text, did text, dep text,
  s1 int not null, s2 int not null, iy text
);
create index if not exists mac_arsiv_eid on public.mac_arsiv(eid, gun desc);
create index if not exists mac_arsiv_did on public.mac_arsiv(did, gun desc);
alter table public.mac_arsiv enable row level security;

create table if not exists public.arsiv_gun(gun date primary key, tamam boolean not null default false);
alter table public.arsiv_gun enable row level security;

create or replace function public.arsiv_doldur(d date, maxage interval)
returns int language plpgsql security definer set search_path to 'public' as $$
declare ms jsonb; n int;
begin
  ms := fikstur_cek(d, maxage)->'m';
  if ms is null then return 0; end if;
  insert into mac_arsiv(mac_id, gun, lig, eid, ev, did, dep, s1, s2, iy)
  select x->>'id', d, x->>'lig', x->>'eid', x->>'ev', x->>'did', x->>'dep',
         (x->>'s1')::int, (x->>'s2')::int, x->>'iy'
  from jsonb_array_elements(ms) x
  where x->>'dk' ~* '^(MS|Bitti|UZ|PEN)' and x->>'s1' ~ '^\d+$' and x->>'s2' ~ '^\d+$'
    and coalesce(x->>'eid', '') <> ''
  on conflict (mac_id) do update set s1 = excluded.s1, s2 = excluded.s2, iy = excluded.iy;
  get diagnostics n = row_count;
  if jsonb_array_length(ms) > 0 then
    insert into arsiv_gun(gun, tamam) values (d, d < (now() at time zone 'Europe/Istanbul')::date - 1)
      on conflict (gun) do update set tamam = excluded.tamam;
  end if;
  return n;
end $$;

-- Geçmiş 45 günü parça parça doldurur (her çağrıda en fazla 'adet' gün)
create or replace function public.arsiv_gecmis(adet int)
returns int language plpgsql security definer set search_path to 'public' as $$
declare g date; n int := 0; bg date := (now() at time zone 'Europe/Istanbul')::date;
begin
  for g in select d::date from generate_series(bg - 45, bg - 2, interval '1 day') d
           where not exists (select 1 from arsiv_gun a where a.gun = d::date and a.tamam)
           order by d desc limit adet loop
    -- önbellek ancak gün bittikten sonra alındıysa kullanılır
    n := n + arsiv_doldur(g, now() - ((g + 1)::timestamp + interval '6 hours') at time zone 'Europe/Istanbul');
  end loop;
  return n;
end $$;

create or replace function public.takim_form(tid text, ref date, yer text)
returns jsonb language sql stable set search_path to 'public' as $$
  with m as (
    select gun,
           case when eid = tid then s1 else s2 end gf,
           case when eid = tid then s2 else s1 end ga,
           (eid = tid) evde
    from mac_arsiv
    where (eid = tid or did = tid) and gun < ref
    order by gun desc limit 6),
  y as (
    select case when eid = tid then s1 else s2 end gf,
           case when eid = tid then s2 else s1 end ga
    from mac_arsiv
    where ((yer = 'ev' and eid = tid) or (yer = 'dep' and did = tid)) and gun < ref
    order by gun desc limit 5),
  f5 as (select * from m order by gun desc limit 5)
  select jsonb_build_object(
    'n', (select count(*) from m),
    'form', (select string_agg(case when gf > ga then 'G' when gf = ga then 'B' else 'M' end, '' order by gun desc) from f5),
    'g5', (select count(*) filter (where gf > ga) from f5),
    'm5', (select count(*) filter (where gf < ga) from f5),
    'gf', (select round(avg(gf)::numeric, 1) from m),
    'ga', (select round(avg(ga)::numeric, 1) from m),
    'ust', (select round(100.0 * avg((gf + ga > 2)::int)) from m),
    'kg',  (select round(100.0 * avg((gf > 0 and ga > 0)::int)) from m),
    'yn', (select count(*) from y),
    'yg', (select count(*) filter (where gf > ga) from y),
    'ygf', (select round(avg(gf)::numeric, 1) from y))
$$;

-- ===== 3) Maç sayfası oranları (tüm iddaa marketleri) =====
create table if not exists public.mac_oran(
  mac_id text primary key,
  gun date not null,
  data jsonb not null,
  fetched_at timestamptz not null default now()
);
alter table public.mac_oran enable row level security;

create or replace function public.oran_cek(mid text, d date)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare res http_response; h text; r text[]; lab text[]; odd text[]; mk jsonb := '{}'::jsonb; o jsonb; i int;
begin
  begin
    perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '12000');
    res := http(('GET', 'https://arsiv.mackolik.com/Mac/' || mid || '/',
      array[http_header('User-Agent', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148')],
      null, null)::http_request);
    h := res.content;
  exception when others then
    h := null;
  end;
  if h is not null then
    for r in select regexp_matches(h, $re$OddsDialog\('\d+', '([^']+)', \[([^\]]*)\], \[([^\]]*)\]$re$, 'g') loop
      select array_agg(m[1]) into lab from regexp_matches(r[2], $re$'([^']*)'$re$, 'g') m;
      select array_agg(m[1]) into odd from regexp_matches(r[3], $re$'([^']*)'$re$, 'g') m;
      o := '{}'::jsonb;
      for i in 1 .. least(coalesce(array_length(lab, 1), 0), coalesce(array_length(odd, 1), 0)) loop
        if odd[i] ~ '^\d+(\.\d+)?$' then o := o || jsonb_build_object(lab[i], odd[i]::numeric); end if;
      end loop;
      if o <> '{}'::jsonb then mk := mk || jsonb_build_object(r[1], o); end if;
    end loop;
  end if;
  insert into mac_oran(mac_id, gun, data, fetched_at) values (mid, d, mk, now())
    on conflict (mac_id) do update set data = excluded.data, fetched_at = excluded.fetched_at;
  return mk;
end $$;

-- marketteki bir seçeneğin oranı ve kâr payı çıkarılmış olasılığı
create or replace function public.market_sec(mk jsonb, market text, secim text)
returns table(oran numeric, guven int) language sql immutable as $$
  select (mk->market->>secim)::numeric,
         round(100 * (1 / (mk->market->>secim)::numeric)
               / nullif((select sum(1 / v::numeric) from jsonb_each_text(mk->market) e(k, v) where v::numeric > 0), 0))::int
  where (mk->market->>secim) is not null and (mk->market->>secim)::numeric > 1
$$;

-- ===== 4) Bot tabloları güncelleme =====
alter table public.bots drop constraint if exists bots_strateji_check;
alter table public.bots add constraint bots_strateji_check
  check (strateji in ('ev', 'dep', 'ust', 'alt', 'banko', 'surpriz'));

alter table public.bot_picks add column if not exists form jsonb;
alter table public.bot_picks add column if not exists analiz text;
alter table public.bot_picks add column if not exists kaynaklar jsonb;
alter table public.bot_picks add column if not exists analiz_durum text not null default 'onay';  -- bekliyor | onay | red
alter table public.bot_picks add column if not exists analiz_deneme int not null default 0;
alter table public.bot_picks add column if not exists analiz_hata text;
create index if not exists bot_picks_analiz on public.bot_picks(analiz_durum) where analiz_durum = 'bekliyor';

-- Oran aralıklarını yükselt (ortalama ~1.55)
update public.bots set min_oran = 1.45, max_oran = 1.80 where strateji in ('ev', 'dep');
update public.bots set min_oran = 1.50, max_oran = 1.80 where strateji in ('ust', 'alt');
update public.bots set min_oran = 1.25, max_oran = 1.45 where strateji = 'banko';
update public.bots set aciklama = 'Formda ev sahibi favorileri. Oran düşükse MS 1 + 1.5 Üst oynar.' where strateji = 'ev';
update public.bots set aciklama = 'Formda deplasman favorileri. Oran düşükse MS 2 + 1.5 Üst oynar.' where strateji = 'dep';
update public.bots set aciklama = 'Gollü takımların maçlarında 2.5 Üst oynar.' where strateji = 'ust';
update public.bots set aciklama = 'Az gol atan/yiyen takımların maçlarında 2.5 Alt oynar.' where strateji = 'alt';

insert into public.bots(ad, avatar, renk, aciklama, strateji, min_oran, max_oran, gunluk_max, vip, sira)
select 'Sürpriz Bot', '💣', '#EC4899',
       'Her gün 2 yüksek oranlı sürpriz: İlk yarı ev sahibi önde, maç sonu deplasman kazanır (İY 1 / MS 2). Nadiren tutar, tuttuğunda büyük oynar.',
       'surpriz', 24, 32, 2, false, 6
where not exists (select 1 from public.bots where strateji = 'surpriz');

-- çelişen tahminler (aynı maça Üst + Alt ya da MS 1 + MS 2 verilmez)
create or replace function public.catisir(a text, b text)
returns boolean language sql immutable as $$
  select (a = '2.5 Üst' and b = '2.5 Alt') or (a = '2.5 Alt' and b = '2.5 Üst')
      or (a like 'MS 1%' and b like 'MS 2%') or (a like 'MS 2%' and b like 'MS 1%')
$$;

-- gençler / kadınlar / rezerv maçları hariç
create or replace function public.ana_mac(y jsonb)
returns boolean language sql immutable as $$
  select not (coalesce(y->>'lig', '') ~* '(U ?\d{2}\M|kadın|gençler|rezerv|akademi|amatör)'
              or coalesce(y->>'ev', '') ~ '(U\d{2}\M|\(K\))'
              or coalesce(y->>'dep', '') ~ '(U\d{2}\M|\(K\))')
$$;

-- API'siz analiz: arşivdeki form verisinden otomatik yazı
create or replace function public.analiz_sablon(t text, ev text, dep text, fe jsonb, fd jsonb, o numeric, g int)
returns text language plpgsql immutable as $$
declare s text := '';
  ne int := case when coalesce((fe->>'n')::int, 0) >= 3 then (fe->>'n')::int else 0 end;
  nd int := case when coalesce((fd->>'n')::int, 0) >= 3 then (fd->>'n')::int else 0 end;
  ort numeric; ust numeric;
begin
  if ne > 0 then
    s := ev || ' son ' || length(fe->>'form') || ' maçta ' || (fe->>'g5') || ' galibiyet, '
         || (length(fe->>'form') - (fe->>'g5')::int - (fe->>'m5')::int) || ' beraberlik, ' || (fe->>'m5') || ' mağlubiyet aldı; '
         || 'maç başı ' || (fe->>'gf') || ' gol atıp ' || (fe->>'ga') || ' gol yiyor'
         || case when coalesce((fe->>'yn')::int, 0) > 0 then ' (iç sahada son ' || (fe->>'yn') || ' maçta ' || (fe->>'yg') || ' galibiyet)' else '' end || '. ';
  end if;
  if nd > 0 then
    s := s || dep || ' son ' || length(fd->>'form') || ' maçta ' || (fd->>'g5') || ' galibiyet, '
         || (length(fd->>'form') - (fd->>'g5')::int - (fd->>'m5')::int) || ' beraberlik, ' || (fd->>'m5') || ' mağlubiyet aldı; '
         || 'maç başı ' || (fd->>'gf') || ' gol atıp ' || (fd->>'ga') || ' gol yiyor'
         || case when coalesce((fd->>'yn')::int, 0) > 0 then ' (deplasmanda son ' || (fd->>'yn') || ' maçta ' || (fd->>'yg') || ' galibiyet)' else '' end || '. ';
  end if;
  if ne > 0 and nd > 0 and t in ('2.5 Üst', '2.5 Alt') then
    ort := round(((fe->>'gf')::numeric + (fe->>'ga')::numeric + (fd->>'gf')::numeric + (fd->>'ga')::numeric) / 2, 1);
    ust := round(((fe->>'ust')::numeric + (fd->>'ust')::numeric) / 2);
    s := s || 'İki takımın maçlarında ortalama ' || ort || ' gol çıkıyor; 2.5 '
         || case when t = '2.5 Üst' then 'Üst' else 'Alt' end || ' biten maç oranı: %'
         || case when t = '2.5 Üst' then ust else 100 - ust end || '. ';
  end if;
  if ne = 0 and nd = 0 then
    s := 'Takımlar için arşivde henüz yeterli maç yok; tahmin iddaa oranlarına dayanıyor. ';
  end if;
  if t = 'İY 1 / MS 2' then
    s := s || 'İlk yarıyı ev sahibinin önde kapatıp maçı deplasmanın kazanması nadir görülen bir sonuç (oran ' || o || '). Yüksek riskli bir sürpriz tahminidir.';
  else
    s := s || 'Tahmin: ' || t || ', oran ' || o || ' (ima ettiği olasılık yaklaşık %' || g || ').';
  end if;
  return s;
end $$;

-- ===== 5) Tahmin üretme (form filtresi + oran yükseltme + sürpriz) =====
create or replace function public.bot_uret(d date)
returns int language plpgsql security definer set search_path to 'public' as $$
declare
  b bots%rowtype; ms jsonb; n int := 0; mevcut int; x jsonb; mk jsonb;
  simdi timestamp := (now() at time zone 'Europe/Istanbul');
  analiz_var boolean := exists (select 1 from app_secrets where key = 'anthropic_key' and coalesce(value, '') <> '');
  fe jsonb; fd jsonb; t text; o numeric; g int; ok boolean; cekilen int := 0;
begin
  ms := fikstur_cek(d, interval '10 minutes')->'m';
  if ms is null or jsonb_array_length(ms) = 0 then return 0; end if;

  -- a) Maç sayfası oranlarını çek (her çalışmada en fazla 12 maç)
  for x in
    select y from jsonb_array_elements(ms) y
    where coalesce(y->>'dk', '') = '' and coalesce(y->>'kod', '0') <> '0' and ana_mac(y)
      and y->>'saat' ~ '^\d{2}:\d{2}$' and (d + (y->>'saat')::time) > simdi + interval '20 minutes'
      and goleo_num(y->>'o1') > 1 and goleo_num(y->>'o2') > 1
      and (least(goleo_num(y->>'o1'), goleo_num(y->>'o2')) < 1.45            -- yükseltme adayı
           or (goleo_num(y->>'o1') between 1.6 and 4.5 and goleo_num(y->>'o2') between 1.6 and 4.5))  -- sürpriz adayı
      and not exists (select 1 from mac_oran o2 where o2.mac_id = y->>'id' and o2.fetched_at > now() - interval '6 hours')
    order by (coalesce(y->>'lig', '') ~* '(süper lig|premier|laliga|la liga|serie a|bundesliga|ligue 1|şampiyonlar|avrupa|konferans)') desc,
             y->>'saat'
    limit 12
  loop
    perform oran_cek(x->>'id', d); cekilen := cekilen + 1;
  end loop;

  -- b) Tahminleri sabah 09:00'dan sonra üret (gece oranlar toplansın)
  if d = simdi::date and simdi::time < time '09:00' then return 0; end if;

  for b in select * from bots where aktif order by sira, id loop
    select count(*) into mevcut from bot_picks where bot_id = b.id and gun = d and analiz_durum <> 'red';
    continue when mevcut >= b.gunluk_max;

    for x in
      select y from jsonb_array_elements(ms) y
      where coalesce(y->>'dk', '') = '' and y->>'saat' ~ '^\d{2}:\d{2}$' and ana_mac(y)
        and coalesce(y->>'kod', '0') <> '0'
        and (d + (y->>'saat')::time) > simdi + interval '45 minutes'
        and not exists (select 1 from bot_picks p where p.bot_id = b.id and p.mac_id = y->>'id')
      order by (coalesce(y->>'lig', '') ~* '(süper lig|premier|laliga|la liga|serie a|bundesliga|ligue 1|şampiyonlar|avrupa|konferans|eredivisie|portekiz)') desc,
               y->>'saat'
    loop
      exit when mevcut >= b.gunluk_max;
      t := null; o := null; g := null;
      select data into mk from mac_oran where mac_id = x->>'id';
      fe := null; fd := null;

      -- 1) markete göre seçim ve oran
      if b.strateji = 'ev' then
        if goleo_num(x->>'o1') between b.min_oran and b.max_oran then
          t := 'MS 1'; o := goleo_num(x->>'o1');
        elsif goleo_num(x->>'o1') between 1.10 and b.min_oran and mk is not null then
          select s.oran into o from market_sec(mk, 'Maç Sonucu ve (1,5) Alt/Üst', '1 ve Üst') s;
          if o between b.min_oran and b.max_oran then t := 'MS 1 + 1.5 Üst'; end if;
        end if;
      elsif b.strateji = 'dep' then
        if goleo_num(x->>'o2') between b.min_oran and b.max_oran then
          t := 'MS 2'; o := goleo_num(x->>'o2');
        elsif goleo_num(x->>'o2') between 1.10 and b.min_oran and mk is not null then
          select s.oran into o from market_sec(mk, 'Maç Sonucu ve (1,5) Alt/Üst', '2 ve Üst') s;
          if o between b.min_oran and b.max_oran then t := 'MS 2 + 1.5 Üst'; end if;
        end if;
      elsif b.strateji = 'ust' then
        if goleo_num(x->>'ou') between b.min_oran and b.max_oran then t := '2.5 Üst'; o := goleo_num(x->>'ou'); end if;
      elsif b.strateji = 'alt' then
        if goleo_num(x->>'oa') between b.min_oran and b.max_oran then t := '2.5 Alt'; o := goleo_num(x->>'oa'); end if;
      elsif b.strateji = 'banko' then
        select v.t, v.o into t, o from (values
          ('MS 1', goleo_num(x->>'o1')), ('MS 2', goleo_num(x->>'o2')),
          ('2.5 Üst', goleo_num(x->>'ou')), ('2.5 Alt', goleo_num(x->>'oa'))) v(t, o)
        where v.o between b.min_oran and b.max_oran order by v.o limit 1;
      elsif b.strateji = 'surpriz' then
        if mk is not null then
          select s.oran into o from market_sec(mk, 'İlk Yarı/Maç Sonucu', '1/2') s;
          if o between b.min_oran and b.max_oran then t := 'İY 1 / MS 2'; end if;
        end if;
      end if;
      continue when t is null;
      continue when exists (select 1 from bot_picks p2 where p2.mac_id = x->>'id' and p2.gun = d
                            and p2.analiz_durum <> 'red' and catisir(p2.tahmin, t));

      -- 2) form filtresi (iki takımın da arşivde en az 4 maçı varsa uygulanır)
      fe := takim_form(x->>'eid', d, 'ev');
      fd := takim_form(x->>'did', d, 'dep');
      ok := (fe->>'n')::int < 4 or (fd->>'n')::int < 4 or case b.strateji
        when 'ev'  then (fe->>'g5')::int >= 3 and (fd->>'g5')::int <= 2
        when 'dep' then (fd->>'g5')::int >= 3 and (fe->>'g5')::int <= 2
        when 'ust' then ((fe->>'gf')::numeric + (fe->>'ga')::numeric + (fd->>'gf')::numeric + (fd->>'ga')::numeric) / 2 >= 2.6
                        and ((fe->>'ust')::numeric + (fd->>'ust')::numeric) / 2 >= 50
        when 'alt' then ((fe->>'gf')::numeric + (fe->>'ga')::numeric + (fd->>'gf')::numeric + (fd->>'ga')::numeric) / 2 <= 2.4
                        and ((fe->>'ust')::numeric + (fd->>'ust')::numeric) / 2 <= 45
        when 'surpriz' then (fe->>'gf')::numeric >= 1.0 and (fd->>'g5')::int >= 2
        else true end;
      continue when not coalesce(ok, true);

      -- güven: oranın kâr payı çıkarılmış olasılığı
      -- güven: oranın ima ettiği olasılık (1/oran). Favorilerde gerçekleşen oranla uyumlu.
      g := least(95, round(100 / o));
      continue when g is null;

      insert into bot_picks(bot_id, gun, mac_id, lig, ev, dep, saat, tahmin, oran, guven, form, analiz_durum, analiz, kaynaklar)
      values (b.id, d, x->>'id', x->>'lig', x->>'ev', x->>'dep', x->>'saat', t, o, g,
              jsonb_build_object('ev', fe, 'dep', fd),
              case when analiz_var then 'bekliyor' else 'onay' end,
              case when analiz_var then null else analiz_sablon(t, x->>'ev', x->>'dep', fe, fd, o, g) end,
              case when analiz_var then null else jsonb_build_array(jsonb_build_object(
                'url', 'https://arsiv.mackolik.com/Mac/' || (x->>'id') || '/', 'baslik', 'Mackolik maç sayfası')) end)
      on conflict do nothing;
      if found then mevcut := mevcut + 1; n := n + 1; end if;
    end loop;
  end loop;
  return n;
end $$;

-- ===== 6) Sonuçlandırma (yeni tahmin türleri) =====
create or replace function public.bot_sonuc()
returns int language plpgsql security definer set search_path to 'public' as $$
declare g date; ms jsonb; n int := 0; k int;
begin
  -- maçı başlayıp hâlâ analiz bekleyen tahminleri analizsiz yayınla (kaybolmasın)
  update bot_picks set analiz_durum = 'onay'
   where analiz_durum = 'bekliyor'
     and (gun + saat::time) < (now() at time zone 'Europe/Istanbul') + interval '15 minutes';

  for g in select distinct gun from bot_picks
           where durum is null and gun >= (now() at time zone 'Europe/Istanbul')::date - 3 loop
    ms := fikstur_cek(g, interval '3 minutes')->'m';
    if ms is null then continue; end if;
    update bot_picks p set
      s1 = case when x->>'s1' ~ '^\d+$' then (x->>'s1')::int end,
      s2 = case when x->>'s2' ~ '^\d+$' then (x->>'s2')::int end,
      durum = case
        when x->>'dk' ~* '^(ert|ipt|İpt|yar|ter)' then 'iptal'
        when p.tahmin = 'İY 1 / MS 2' and coalesce(x->>'iy', '') !~ '^\d+-\d+$' then 'iptal'
        when (case p.tahmin
                when 'MS 1'           then (x->>'s1')::int >  (x->>'s2')::int
                when 'MS 2'           then (x->>'s2')::int >  (x->>'s1')::int
                when '2.5 Üst'        then (x->>'s1')::int + (x->>'s2')::int > 2
                when '2.5 Alt'        then (x->>'s1')::int + (x->>'s2')::int < 3
                when 'MS 1 + 1.5 Üst' then (x->>'s1')::int > (x->>'s2')::int and (x->>'s1')::int + (x->>'s2')::int > 1
                when 'MS 2 + 1.5 Üst' then (x->>'s2')::int > (x->>'s1')::int and (x->>'s1')::int + (x->>'s2')::int > 1
                when 'İY 1 / MS 2'    then split_part(x->>'iy', '-', 1)::int > split_part(x->>'iy', '-', 2)::int
                                           and (x->>'s2')::int > (x->>'s1')::int
              end) then 'tuttu'
        else 'yatti' end
    from jsonb_array_elements(ms) x
    where p.gun = g and p.durum is null and p.analiz_durum = 'onay' and p.mac_id = x->>'id'
      and ((x->>'dk' ~* '^(MS|Bitti|UZ|PEN)' and x->>'s1' ~ '^\d+$' and x->>'s2' ~ '^\d+$')
           or x->>'dk' ~* '^(ert|ipt|İpt|yar|ter)');
    get diagnostics k = row_count; n := n + k;
  end loop;
  return n;
end $$;

-- ===== 7) Claude ile web araştırması ve analiz =====
create or replace function public.form_yazi(f jsonb)
returns text language sql immutable as $$
  select case when coalesce((f->>'n')::int, 0) = 0 then 'arşivde maç yok'
    else 'son ' || (f->>'n') || ' maç form ' || coalesce(f->>'form', '-') ||
         ', maç başı ' || (f->>'gf') || ' attı / ' || (f->>'ga') || ' yedi, maçlarının %' || (f->>'ust') ||
         '''i 2.5 Üst, %' || (f->>'kg') || '''i KG Var' ||
         case when coalesce((f->>'yn')::int, 0) > 0 then ', bu sahada son ' || (f->>'yn') || ' maçta ' || (f->>'yg') || ' galibiyet' else '' end
  end
$$;

create or replace function public.analiz_isle(adet int)
returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  akey text; p record; body jsonb; msgs jsonb; res http_response; r jsonb; i int; n int := 0;
  txt text; js jsonb; src jsonb; prompt text; sys text;
begin
  select value into akey from app_secrets where key = 'anthropic_key';
  if coalesce(akey, '') = '' then return 0; end if;

  sys := 'Sen Goleo uygulamasının futbol analiz asistanısın. Bir istatistik botu iddaa oranları ve takım formuna göre bir tahmin seçti. '
      || 'Görevin: maçı internette araştırmak (sakat ve cezalı oyuncular, muhtemel kadrolar, kilit oyuncuların durumu, rotasyon, motivasyon, son haberler) '
      || 've tahmini ONAYLAMAK ya da REDDETMEK. '
      || 'Yalnızca tahmine karşı somut ve güçlü bir bilgi bulursan reddet (örneğin favori takımın birden fazla kilit oyuncusu yok, ağır rotasyon bekleniyor). Belirsizlik ya da his reddetme sebebi değildir. '
      || 'Bulamadığın bilgiyi uydurma; emin olmadığın oyuncu adı, sakatlık veya istatistik yazma. '
      || 'Analizi Türkçe, 3-5 cümle, sade ve kullanıcıya yönelik yaz; kazanç garantisi verme. '
      || 'Cevabının EN SONUNA yalnızca şu JSON nesnesini yaz: {"karar":"onay" veya "red","analiz":"..."}';

  for p in
    select bp.*, b.ad bot_ad from bot_picks bp join bots b on b.id = bp.bot_id
    where bp.analiz_durum = 'bekliyor' and bp.durum is null
    order by bp.gun, bp.saat, bp.id
    limit adet
    for update of bp skip locked
  loop
    prompt := 'Maç: ' || p.ev || ' - ' || p.dep || E'\nLig: ' || coalesce(p.lig, '-') ||
              E'\nTarih/saat (TR): ' || to_char(p.gun, 'DD.MM.YYYY') || ' ' || p.saat ||
              E'\nBotun tahmini: ' || p.tahmin || ' (oran ' || p.oran || ', piyasa olasılığı yaklaşık %' || p.guven || ')' ||
              E'\nBot: ' || p.bot_ad ||
              E'\nForm (Mackolik sonuç arşivi):\n- ' || p.ev || ': ' || form_yazi(p.form->'ev') ||
              E'\n- ' || p.dep || ': ' || form_yazi(p.form->'dep') ||
              E'\n\nMaçı web''de araştır ve kararını ver.';
    msgs := jsonb_build_array(jsonb_build_object('role', 'user', 'content', prompt));
    r := null;
    begin
      perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '170000');
      for i in 1 .. 3 loop
        body := jsonb_build_object(
          'model', 'claude-opus-5-5',
          'max_tokens', 8000,
          'system', sys,
          'messages', msgs,
          'tools', jsonb_build_array(jsonb_build_object('type', 'web_search_20260209', 'name', 'web_search', 'max_uses', 5)),
          'output_config', jsonb_build_object('effort', 'medium'),
          'fallbacks', 'default');
        res := http(('POST', 'https://api.anthropic.com/v1/messages',
          array[http_header('x-api-key', akey),
                http_header('anthropic-version', '2026-10-21'),
                http_header('anthropic-beta', 'server-side-fallback-2026-07-01')],
          'application/json', body::text)::http_request);
        r := res.content::jsonb;
        exit when res.status <> 200 or r->>'stop_reason' is distinct from 'pause_turn';
        msgs := msgs || jsonb_build_array(jsonb_build_object('role', 'assistant', 'content', r->'content'));
      end loop;
      if res.status <> 200 then raise exception 'api %: %', res.status, left(res.content, 300); end if;
      if r->>'stop_reason' = 'refusal' then raise exception 'refusal'; end if;

      select string_agg(c->>'text', '') into txt from jsonb_array_elements(r->'content') c where c->>'type' = 'text';
      js := substring(txt from '\{[^{}]*"karar"[^{}]*\}')::jsonb;
      select coalesce(jsonb_agg(distinct jsonb_build_object('url', ci->>'url', 'baslik', ci->>'title')), '[]'::jsonb)
        into src
        from jsonb_array_elements(r->'content') c, jsonb_array_elements(case when jsonb_typeof(c->'citations') = 'array' then c->'citations' else '[]'::jsonb end) ci
        where c->>'type' = 'text' and ci->>'url' is not null;

      update bot_picks set
        analiz = left(js->>'analiz', 1200),
        kaynaklar = (select coalesce(jsonb_agg(e), '[]'::jsonb) from (select e from jsonb_array_elements(src) e limit 4) z),
        analiz_durum = case when js->>'karar' = 'red' then 'red' else 'onay' end
      where id = p.id;
      n := n + 1;
    exception when others then
      update bot_picks set analiz_deneme = analiz_deneme + 1, analiz_hata = left(sqlerrm, 500),
             analiz_durum = case when analiz_deneme + 1 >= 2 then 'onay' else 'bekliyor' end
      where id = p.id;
    end;
  end loop;
  return n;
end $$;

-- ===== 8) Ana çalıştırıcı =====
create or replace function public.bot_calistir()
returns json language plpgsql security definer set search_path to 'public' as $$
declare bg date := (now() at time zone 'Europe/Istanbul')::date; a int; b int; c int;
begin
  c := arsiv_gecmis(5);
  perform arsiv_doldur(bg - 1, interval '30 minutes');
  a := bot_uret(bg);
  b := bot_sonuc();
  perform arsiv_doldur(bg, interval '10 minutes');
  return json_build_object('yeni', a, 'sonuclanan', b, 'arsiv', c);
end $$;

-- ===== 9) Uygulama okuma fonksiyonları =====
drop function if exists public.bot_istatistik(text);
create function public.bot_istatistik(per text)
returns table(id int, ad text, avatar text, renk text, aciklama text, vip boolean, strateji text,
              toplam int, kazanan int, yuzde int, son5 text[], bekleyen int,
              ort_oran numeric, son_tutan date, son_tutan_oran numeric)
language sql stable security definer set search_path to 'public' as $$
  with t as (select (now() at time zone 'Europe/Istanbul')::date bg),
  r as (
    select case per when 'bugun' then bg when 'dun' then bg - 1
                    when 'ay' then date_trunc('month', bg)::date
                    when 'gecen' then (date_trunc('month', bg) - interval '1 month')::date
                    else date '2000-01-01' end d1,
           case per when 'dun' then bg - 1
                    when 'gecen' then (date_trunc('month', bg) - interval '1 day')::date
                    else bg end d2
    from t)
  select b.id, b.ad, b.avatar, b.renk, b.aciklama, b.vip, b.strateji,
         (count(p.id) filter (where p.durum in ('tuttu', 'yatti')))::int,
         (count(p.id) filter (where p.durum = 'tuttu'))::int,
         coalesce(round(100.0 * count(p.id) filter (where p.durum = 'tuttu')
                  / nullif(count(p.id) filter (where p.durum in ('tuttu', 'yatti')), 0)), 0)::int,
         (select array_agg(z.durum) from (select q.durum from bot_picks q
            where q.bot_id = b.id and q.durum in ('tuttu', 'yatti') and q.analiz_durum = 'onay'
            order by q.gun desc, q.id desc limit 5) z),
         (count(p.id) filter (where p.durum is null))::int,
         round(avg(p.oran), 2),
         (select max(q.gun) from bot_picks q where q.bot_id = b.id and q.durum = 'tuttu'),
         (select q.oran from bot_picks q where q.bot_id = b.id and q.durum = 'tuttu' order by q.gun desc, q.id desc limit 1)
  from bots b cross join r
  left join bot_picks p on p.bot_id = b.id and p.gun between r.d1 and r.d2 and p.analiz_durum = 'onay'
  where b.aktif
  group by b.id
  order by (b.strateji = 'surpriz'), 10 desc, 8 desc, b.sira
$$;

create or replace function public.bot_tahminler(bid int, d date)
returns setof json language sql stable security definer set search_path to 'public' as $$
  select json_build_object(
    'id', p.id, 'lig', p.lig, 'ev', p.ev, 'dep', p.dep, 'saat', p.saat,
    'oran', p.oran, 'guven', p.guven, 'durum', p.durum, 's1', p.s1, 's2', p.s2,
    'kilit', k.kilit,
    'tahmin', case when k.kilit then null else p.tahmin end,
    'analiz', case when k.kilit then null else p.analiz end,
    'kaynaklar', case when k.kilit then null else p.kaynaklar end,
    'form', p.form)
  from bot_picks p
  join bots b on b.id = p.bot_id
  cross join lateral (select b.vip and p.durum is null and not (
      is_admin() or exists (select 1 from vip_subs s where s.user_id = auth.uid() and s.ends_at > now())) kilit) k
  where p.bot_id = bid and p.gun = d and p.analiz_durum = 'onay'
  order by p.saat, p.id
$$;

-- ===== 10) Yetkiler =====
revoke execute on function public.fikstur_cek(date, interval) from public, anon, authenticated;
revoke execute on function public.arsiv_doldur(date, interval) from public, anon, authenticated;
revoke execute on function public.arsiv_gecmis(int) from public, anon, authenticated;
revoke execute on function public.oran_cek(text, date) from public, anon, authenticated;
revoke execute on function public.bot_uret(date) from public, anon, authenticated;
revoke execute on function public.bot_sonuc() from public, anon, authenticated;
revoke execute on function public.analiz_isle(int) from public, anon, authenticated;
revoke execute on function public.bot_calistir() from public, anon, authenticated;
revoke execute on function public.bot_istatistik(text) from anon;
revoke execute on function public.bot_tahminler(int, date) from anon;

-- ===== 11) Zamanlayıcılar =====
select cron.unschedule(jobid) from cron.job where jobname in ('goleo-botlar', 'goleo-analiz');
select cron.schedule('goleo-botlar', '*/15 * * * *', 'select public.bot_calistir()');
select cron.schedule('goleo-analiz', '*/5 * * * *', 'select public.analiz_isle(2)');

-- İlk çalıştırma: arşivin ilk 5 günü + bugünün oranları
select public.bot_calistir();
