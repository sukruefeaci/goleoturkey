-- GOLEO AI BOTLAR
-- Supabase > SQL Editor'da bir kez çalıştırın (fikstur.sql'in yerini de alır).

create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

-- ===== 1) Mackolik verisi (oranlar dahil), önbellekli iç fonksiyon =====
create table if not exists public.fixture_cache(
  day text primary key,
  data jsonb not null,
  fetched_at timestamptz not null default now()
);
alter table public.fixture_cache enable row level security;

create or replace function public.goleo_num(t text)
returns numeric language sql immutable as $$
  select case when t ~ '^\d+(\.\d+)?$' then t::numeric end
$$;

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
    perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
    res := http(('GET',
      'https://vd.mackolik.com/livedata?date=' || urlencode(dk) || '&_=' || extract(epoch from now())::bigint,
      array[http_header('User-Agent', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148'),
            http_header('Referer', 'https://arsiv.mackolik.com/')],
      null, null)::http_request);
    j := res.content::jsonb;
    if jsonb_typeof(j->'m') is distinct from 'array' then raise exception 'beklenmeyen format'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', r->>0, 'ev', r->>2, 'dep', r->>4, 'st', r->>5, 'dk', r->>6,
             's1', r->>12, 's2', r->>13, 'iy', nullif(r->>7, ''), 'saat', r->>16,
             'o1', r->>18, 'ox', r->>19, 'o2', r->>20, 'oa', r->>21, 'ou', r->>22,
             'lig', case when jsonb_typeof(r->36) = 'array'
                         then trim(coalesce(r->36->>1, '') || ' ' || coalesce(r->36->>3, '')) end)
           order by r->>16, r->>2), '[]'::jsonb)
      into out
      from jsonb_array_elements(j->'m') r
     where jsonb_typeof(r) = 'array'
       and coalesce(case when jsonb_typeof(r->36) = 'array' then r->36->>11 end, '1') = '1';
  exception when others then
    return jsonb_build_object('ok', c.day is not null, 'eski', true, 'at', c.fetched_at,
                              'm', coalesce(c.data, '[]'::jsonb), 'msg', 'Maç verisi alınamadı');
  end;
  insert into fixture_cache(day, data, fetched_at) values (dk, out, now())
    on conflict (day) do update set data = excluded.data, fetched_at = excluded.fetched_at;
  return jsonb_build_object('ok', true, 'at', now(), 'm', out);
end $$;

-- Uygulamanın kullandığı fikstür fonksiyonu (giriş yapmış kullanıcılar)
create or replace function public.fikstur(d date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare bg date := (now() at time zone 'Europe/Istanbul')::date;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'msg', 'Giriş gerekli'); end if;
  return fikstur_cek(d, case when d = bg then interval '30 seconds'
                             when d < bg then interval '6 hours'
                             else interval '15 minutes' end);
end $$;

-- ===== 2) Tablolar =====
create table if not exists public.bots(
  id serial primary key,
  ad text not null,
  avatar text not null default '🤖',
  renk text not null default '#9B5CFF',
  aciklama text,
  strateji text not null check (strateji in ('ev', 'dep', 'ust', 'alt', 'banko')),
  min_oran numeric not null default 1.30,
  max_oran numeric not null default 1.65,
  gunluk_max int not null default 5,
  vip boolean not null default false,
  aktif boolean not null default true,
  sira int not null default 0
);
alter table public.bots enable row level security;
drop policy if exists "botlar herkese" on public.bots;
create policy "botlar herkese" on public.bots for select using (true);

create table if not exists public.bot_picks(
  id bigserial primary key,
  bot_id int not null references public.bots(id) on delete cascade,
  gun date not null,
  mac_id text not null,
  lig text, ev text, dep text, saat text,
  tahmin text not null,           -- 'MS 1' | 'MS 2' | '2.5 Üst' | '2.5 Alt'
  oran numeric not null,
  guven int not null,
  durum text,                      -- null = bekliyor | tuttu | yatti | iptal
  s1 int, s2 int,
  created_at timestamptz not null default now(),
  unique (bot_id, mac_id)
);
create index if not exists bot_picks_gun on public.bot_picks(gun);
alter table public.bot_picks enable row level security;   -- okuma sadece fonksiyonlarla

insert into public.bots(ad, avatar, renk, aciklama, strateji, min_oran, max_oran, gunluk_max, vip, sira)
select * from (values
  ('Favori Avcısı',    '🎯', '#22C55E', 'Ev sahibi favorilerini seçer (MS 1).',            'ev',    1.30, 1.60, 5, false, 1),
  ('Deplasman Ustası', '✈️', '#38BDF8', 'Güçlü deplasman favorilerini seçer (MS 2).',      'dep',   1.30, 1.65, 4, false, 2),
  ('Gol Radarı',       '⚽', '#F59E0B', 'Gol beklenen maçlarda 2.5 Üst oynar.',            'ust',   1.35, 1.60, 5, false, 3),
  ('Kilit Savunma',    '🛡️', '#A78BFA', 'Az gol beklenen maçlarda 2.5 Alt oynar.',         'alt',   1.35, 1.60, 4, false, 4),
  ('Banko Bot',        '🔒', '#F43F5E', 'Günün en düşük oranlı, en güçlü tahminleri.',     'banko', 1.15, 1.40, 3, true,  5)
) v(ad, avatar, renk, aciklama, strateji, min_oran, max_oran, gunluk_max, vip, sira)
where not exists (select 1 from public.bots);

-- ===== 3) Tahmin üretme =====
create or replace function public.bot_uret(d date)
returns int language plpgsql security definer set search_path to 'public' as $$
declare
  b bots%rowtype; ms jsonb; n int := 0; k int; mevcut int;
  simdi timestamp := (now() at time zone 'Europe/Istanbul');
begin
  ms := fikstur_cek(d, interval '10 minutes')->'m';
  if ms is null or jsonb_array_length(ms) = 0 then return 0; end if;
  for b in select * from bots where aktif order by sira, id loop
    select count(*) into mevcut from bot_picks where bot_id = b.id and gun = d;
    if mevcut >= b.gunluk_max then continue; end if;
    insert into bot_picks(bot_id, gun, mac_id, lig, ev, dep, saat, tahmin, oran, guven)
    select b.id, d, c.id, c.lig, c.ev, c.dep, c.saat, c.tahmin, c.oran, c.guven
    from (
      select distinct on (x->>'id')
             x->>'id' id, x->>'lig' lig, x->>'ev' ev, x->>'dep' dep, x->>'saat' saat,
             s.tahmin, s.oran, round(100 * (1 / s.oran) / s.top)::int guven,
             (coalesce(x->>'lig', '') ~* '(süper lig|premier|la liga|serie a|bundesliga|ligue 1|şampiyonlar|avrupa|konferans|eredivisie|portekiz)') buyuk
      from jsonb_array_elements(ms) x
      cross join lateral (select goleo_num(x->>'o1') o1, goleo_num(x->>'ox') ox, goleo_num(x->>'o2') o2,
                                 goleo_num(x->>'oa') oa, goleo_num(x->>'ou') ou) o
      cross join lateral (values
        ('ev',  'MS 1',    o.o1, 1/nullif(o.o1,0) + 1/nullif(o.ox,0) + 1/nullif(o.o2,0)),
        ('dep', 'MS 2',    o.o2, 1/nullif(o.o1,0) + 1/nullif(o.ox,0) + 1/nullif(o.o2,0)),
        ('ust', '2.5 Üst', o.ou, 1/nullif(o.oa,0) + 1/nullif(o.ou,0)),
        ('alt', '2.5 Alt', o.oa, 1/nullif(o.oa,0) + 1/nullif(o.ou,0))
      ) s(tur, tahmin, oran, top)
      where (b.strateji = 'banko' or s.tur = b.strateji)
        and s.oran between b.min_oran and b.max_oran
        and s.top between 1.0 and 1.35
        and coalesce(x->>'dk', '') = ''
        and x->>'saat' ~ '^\d{2}:\d{2}$'
        and (d + (x->>'saat')::time) > simdi + interval '15 minutes'
        and not exists (select 1 from bot_picks p where p.bot_id = b.id and p.mac_id = x->>'id')
      order by x->>'id', s.oran
    ) c
    order by c.buyuk desc, c.oran, c.saat
    limit b.gunluk_max - mevcut
    on conflict do nothing;
    get diagnostics k = row_count; n := n + k;
  end loop;
  return n;
end $$;

-- ===== 4) Sonuçlandırma =====
create or replace function public.bot_sonuc()
returns int language plpgsql security definer set search_path to 'public' as $$
declare g date; ms jsonb; n int := 0; k int;
begin
  for g in select distinct gun from bot_picks
           where durum is null and gun >= (now() at time zone 'Europe/Istanbul')::date - 3 loop
    ms := fikstur_cek(g, interval '3 minutes')->'m';
    if ms is null then continue; end if;
    update bot_picks p set
      s1 = case when x->>'s1' ~ '^\d+$' then (x->>'s1')::int end,
      s2 = case when x->>'s2' ~ '^\d+$' then (x->>'s2')::int end,
      durum = case
        when x->>'dk' ~* '^(ert|ipt|İpt|yar|ter)' then 'iptal'
        when (case p.tahmin
                when 'MS 1'    then (x->>'s1')::int >  (x->>'s2')::int
                when 'MS 2'    then (x->>'s2')::int >  (x->>'s1')::int
                when '2.5 Üst' then (x->>'s1')::int + (x->>'s2')::int > 2
                else                (x->>'s1')::int + (x->>'s2')::int < 3 end) then 'tuttu'
        else 'yatti' end
    from jsonb_array_elements(ms) x
    where p.gun = g and p.durum is null and p.mac_id = x->>'id'
      and ((x->>'dk' ~* '^(MS|Bitti|UZ|PEN)' and x->>'s1' ~ '^\d+$' and x->>'s2' ~ '^\d+$')
           or x->>'dk' ~* '^(ert|ipt|İpt|yar|ter)');
    get diagnostics k = row_count; n := n + k;
  end loop;
  return n;
end $$;

create or replace function public.bot_calistir()
returns json language plpgsql security definer set search_path to 'public' as $$
declare a int; b int;
begin
  a := bot_uret((now() at time zone 'Europe/Istanbul')::date);
  b := bot_sonuc();
  return json_build_object('yeni', a, 'sonuclanan', b);
end $$;

-- ===== 5) Uygulama için okuma fonksiyonları =====
create or replace function public.bot_istatistik(per text)
returns table(id int, ad text, avatar text, renk text, aciklama text, vip boolean,
              toplam int, kazanan int, yuzde int, son5 text[], bekleyen int)
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
  select b.id, b.ad, b.avatar, b.renk, b.aciklama, b.vip,
         (count(p.id) filter (where p.durum in ('tuttu', 'yatti')))::int,
         (count(p.id) filter (where p.durum = 'tuttu'))::int,
         coalesce(round(100.0 * count(p.id) filter (where p.durum = 'tuttu')
                  / nullif(count(p.id) filter (where p.durum in ('tuttu', 'yatti')), 0)), 0)::int,
         (select array_agg(z.durum) from (select q.durum from bot_picks q
            where q.bot_id = b.id and q.durum in ('tuttu', 'yatti')
            order by q.gun desc, q.id desc limit 5) z),
         (count(p.id) filter (where p.durum is null))::int
  from bots b cross join r
  left join bot_picks p on p.bot_id = b.id and p.gun between r.d1 and r.d2
  where b.aktif
  group by b.id
  order by 9 desc, 7 desc, b.sira
$$;

create or replace function public.bot_tahminler(bid int, d date)
returns setof json language sql stable security definer set search_path to 'public' as $$
  select json_build_object(
    'id', p.id, 'lig', p.lig, 'ev', p.ev, 'dep', p.dep, 'saat', p.saat,
    'oran', p.oran, 'guven', p.guven, 'durum', p.durum, 's1', p.s1, 's2', p.s2,
    'kilit', k.kilit,
    'tahmin', case when k.kilit then null else p.tahmin end)
  from bot_picks p
  join bots b on b.id = p.bot_id
  cross join lateral (select b.vip and p.durum is null and not (
      is_admin() or exists (select 1 from vip_subs s where s.user_id = auth.uid() and s.ends_at > now())) kilit) k
  where p.bot_id = bid and p.gun = d
  order by p.saat, p.id
$$;

-- ===== 6) Yetkiler =====
revoke execute on function public.fikstur_cek(date, interval) from public, anon, authenticated;
revoke execute on function public.bot_uret(date) from public, anon, authenticated;
revoke execute on function public.bot_sonuc() from public, anon, authenticated;
revoke execute on function public.bot_calistir() from public, anon, authenticated;
revoke execute on function public.fikstur(date) from anon;
revoke execute on function public.bot_istatistik(text) from anon;
revoke execute on function public.bot_tahminler(int, date) from anon;

-- ===== 7) Zamanlayıcı: 15 dakikada bir tahmin üret + sonuçlandır =====
select cron.unschedule(jobid) from cron.job where jobname = 'goleo-botlar';
select cron.schedule('goleo-botlar', '*/15 * * * *', 'select public.bot_calistir()');

-- Önbelleği yenile ve hemen bir kez çalıştır
delete from public.fixture_cache;
select public.bot_calistir();
