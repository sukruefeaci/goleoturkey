-- BİLDİRİM 2: bildirim ayarları, bot takibi, kupon bildirimi, gün sonu özeti
-- guvenlik_bildirim.sql'den SONRA, Supabase > SQL Editor'da bir kez çalıştırın. Tekrar çalıştırılabilir.

-- ===== 1) Bildirim türü ayarları =====
-- Anahtarlar: sabah, takip, kupon, surpriz, gunsonu, vip  (yazılmayan tür = açık)
alter table public.profiles add column if not exists bildirim_ayar jsonb not null default '{}'::jsonb;
grant update (bildirim_ayar) on public.profiles to authenticated;

create or replace function public.bildirim_acik(uid uuid, tur text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select p.bildirim and coalesce((p.bildirim_ayar->>tur)::boolean, true)
                   from profiles p where p.id = uid), false)
     and exists (select 1 from tg_chats c where c.user_id = uid)
$$;

-- Mevcut bildirimler de ayara uysun
create or replace function public.sabah_bildirim()
returns int language plpgsql security definer set search_path to 'public' as $$
declare bg date := (now() at time zone 'Europe/Istanbul')::date; adet int; ornek text; msg text; n int;
begin
  select count(*) into adet from bot_picks where gun = bg and analiz_durum = 'onay';
  if adet = 0 then return 0; end if;
  select string_agg(s, E'\n') into ornek from (
    select b.avatar || ' ' || b.ad || ': ' || p.ev || ' – ' || p.dep || ' · ' || p.tahmin || ' (' || p.oran || ')' s
    from bot_picks p join bots b on b.id = p.bot_id
    where p.gun = bg and p.analiz_durum = 'onay' and not b.vip and b.strateji <> 'surpriz'
    order by (coalesce(p.lig, '') ~* '(süper lig|premier|laliga|la liga|serie a|bundesliga|ligue 1|şampiyonlar|avrupa)') desc, p.oran desc
    limit 3) z;
  msg := '☀️ Günaydın! Goleo AI botları bugün ' || adet || ' tahmin paylaştı.' ||
         coalesce(E'\n\n' || ornek, '') ||
         E'\n\n🤖 Tümü: AI Botlar sekmesi' || E'\nhttps://t.me/goleoaibot?startapp';
  insert into bildirim_kuyruk(user_id, msg)
  select c.user_id, msg from tg_chats c where bildirim_acik(c.user_id, 'sabah');
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.vip_tuttu_bildirim()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.durum = 'tuttu' and old.durum is distinct from 'tuttu' then
    insert into bildirim_kuyruk(user_id, msg)
    select u, '✅ VIP tahmin tuttu! ' || new.ev || ' – ' || new.dep || coalesce(' · ' || new.tahmin, '') ||
              E'\n👑 Goleo VIP ile kazanmaya devam!'
    from (select user_id u from vip_purchases where tip_id = new.id
          union
          select user_id from vip_subs where ends_at > now()) x
    where bildirim_acik(x.u, 'vip');
  end if;
  return new;
end $$;

create or replace function public.surpriz_tuttu_bildirim()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare msg text;
begin
  if new.durum = 'tuttu' and old.durum is null
     and exists (select 1 from bots b where b.id = new.bot_id and b.strateji = 'surpriz') then
    msg := '💣 SÜRPRİZ BOT TUTTU!' || E'\n' || new.ev || ' – ' || new.dep ||
           coalesce(' (' || new.s1 || '-' || new.s2 || ')', '') ||
           E'\n' || new.tahmin || ' · Oran ' || new.oran ||
           E'\n\n🤖 Botların bugünkü tahminleri: AI Botlar sekmesi' || E'\nhttps://t.me/goleoaibot?startapp';
    insert into bildirim_kuyruk(user_id, msg)
    select c.user_id, msg from tg_chats c where bildirim_acik(c.user_id, 'surpriz');
  end if;
  return new;
end $$;

-- ===== 2) Bot takibi (yıldız) =====
create table if not exists public.bot_takip(
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  bot_id int not null references public.bots(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, bot_id)
);
alter table public.bot_takip enable row level security;
drop policy if exists "kendi takibi okur" on public.bot_takip;
drop policy if exists "kendi takibi ekler" on public.bot_takip;
drop policy if exists "kendi takibi siler" on public.bot_takip;
create policy "kendi takibi okur" on public.bot_takip for select using (user_id = auth.uid());
create policy "kendi takibi ekler" on public.bot_takip for insert with check (user_id = auth.uid());
create policy "kendi takibi siler" on public.bot_takip for delete using (user_id = auth.uid());
revoke all on public.bot_takip from anon, authenticated;
grant select, insert, delete on public.bot_takip to authenticated;

alter table public.bot_picks add column if not exists bildirildi boolean not null default false;
update public.bot_picks set bildirildi = true where not bildirildi and gun < (now() at time zone 'Europe/Istanbul')::date;

-- Yayınlanan yeni bot tahminlerini takipçilere bot başına tek mesajla bildirir
create or replace function public.takip_bildirim()
returns int language plpgsql security definer set search_path to 'public' as $$
declare b record; liste text; adet int; n int := 0; k int;
  simdi timestamp := (now() at time zone 'Europe/Istanbul');
begin
  -- başlamış maçlar için bildirim gönderme, sadece işaretle
  update bot_picks set bildirildi = true
   where not bildirildi and analiz_durum = 'onay' and (gun + saat::time) <= simdi;

  for b in
    select bt.id, bt.ad, bt.avatar, bt.vip from bots bt
    where exists (select 1 from bot_picks p where p.bot_id = bt.id and not p.bildirildi and p.analiz_durum = 'onay')
  loop
    select count(*), string_agg('• ' || p.saat || ' ' || p.ev || ' – ' || p.dep || ' · ' || p.tahmin || ' (' || p.oran || ')', E'\n' order by p.saat)
      into adet, liste
      from (select * from bot_picks where bot_id = b.id and not bildirildi and analiz_durum = 'onay' order by saat limit 6) p;

    insert into bildirim_kuyruk(user_id, msg)
    select t.user_id,
           '⭐ ' || b.avatar || ' ' || b.ad || ' ' || adet || ' yeni tahmin paylaştı' ||
           case when not b.vip
                  or exists (select 1 from vip_subs s where s.user_id = t.user_id and s.ends_at > now())
                  or exists (select 1 from profiles pr where pr.id = t.user_id and pr.is_admin)
                then E':\n\n' || liste
                else E'.\n\n🔒 Bu bir VIP bot; tahminleri görmek için VIP ol.' end ||
           E'\n\n🤖 AI Botlar sekmesi' || E'\nhttps://t.me/goleoaibot?startapp'
    from bot_takip t
    where t.bot_id = b.id and bildirim_acik(t.user_id, 'takip');
    get diagnostics k = row_count; n := n + k;

    update bot_picks set bildirildi = true where bot_id = b.id and not bildirildi and analiz_durum = 'onay';
  end loop;
  return n;
end $$;

-- ===== 3) Admin kupon ekleyince =====
create or replace function public.kupon_bildirim()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare msg text; liste text; ad text;
begin
  if new.gun < (now() at time zone 'Europe/Istanbul')::date then return new; end if;
  ad := case new.tur when 'tekli' then 'Tekli' when 'ikili' then '2''li' when 'uclu' then '3''lü' else coalesce(new.tur, '') end;
  select string_agg('• ' || coalesce(i->>'saat', '') || ' ' || coalesce(i->>'ev', '') || ' – ' || coalesce(i->>'dep', ''), E'\n')
    into liste from jsonb_array_elements(case when jsonb_typeof(new.items) = 'array' then new.items else '[]'::jsonb end) i;
  msg := '🎫 Yeni kupon yayında! (' || ad || ' · ' || to_char(new.gun, 'DD.MM') || ')' ||
         coalesce(E'\n\n' || liste, '') ||
         E'\n\n📲 Tahminler Kupon sekmesinde' || E'\nhttps://t.me/goleoaibot?startapp';
  insert into bildirim_kuyruk(user_id, msg)
  select c.user_id, msg from tg_chats c where bildirim_acik(c.user_id, 'kupon');
  return new;
end $$;
drop trigger if exists t_kupon_bildirim on public.coupons;
create trigger t_kupon_bildirim after insert on public.coupons
  for each row execute function public.kupon_bildirim();

-- ===== 4) Gün sonu özeti (00:00) =====
create or replace function public.gunsonu_bildirim()
returns int language plpgsql security definer set search_path to 'public' as $$
declare d date := (now() at time zone 'Europe/Istanbul')::date - 1;
  kt int; kw int; kl int; bw int; bl int; bb text; yo text; vw int; vl int; msg text; n int;
begin
  -- kuponlar: tüm maçları tuttuysa kazandı, biri yattıysa kaybetti
  select count(*),
         count(*) filter (where not exists (select 1 from jsonb_array_elements(c.items) i where coalesce(i->>'durum', '') <> 'tuttu')),
         count(*) filter (where exists (select 1 from jsonb_array_elements(c.items) i where i->>'durum' = 'yatti'))
    into kt, kw, kl
    from coupons c where c.gun = d and jsonb_typeof(c.items) = 'array' and jsonb_array_length(c.items) > 0;

  select count(*) filter (where durum = 'tuttu'), count(*) filter (where durum = 'yatti')
    into bw, bl from bot_picks where gun = d and analiz_durum = 'onay';

  select b.avatar || ' ' || b.ad || ' ' || count(*) filter (where p.durum = 'tuttu') || '/' || count(*)
    into bb
    from bot_picks p join bots b on b.id = p.bot_id
    where p.gun = d and p.analiz_durum = 'onay' and p.durum in ('tuttu', 'yatti') and b.strateji <> 'surpriz'
    group by b.id, b.avatar, b.ad
    having count(*) >= 2
    order by count(*) filter (where p.durum = 'tuttu')::numeric / count(*) desc, count(*) desc
    limit 1;

  select p.ev || ' – ' || p.dep || ' · ' || p.tahmin || ' (oran ' || p.oran || ')'
    into yo from bot_picks p
    where p.gun = d and p.analiz_durum = 'onay' and p.durum = 'tuttu'
    order by p.oran desc limit 1;

  select count(*) filter (where durum = 'tuttu'), count(*) filter (where durum = 'yatti')
    into vw, vl from vip_tips where gun = d and active;

  if coalesce(kw + kl, 0) + coalesce(bw + bl, 0) + coalesce(vw + vl, 0) = 0 then return 0; end if;

  msg := '🌙 Günün özeti · ' || to_char(d, 'DD.MM.YYYY') || E'\n' ||
    case when kw + kl > 0 then E'\n🎫 Kuponlar: ' || kw || '/' || (kw + kl) || ' tuttu' else '' end ||
    case when bw + bl > 0 then E'\n🤖 AI Botlar: ' || bw || '/' || (bw + bl) || ' tuttu (%' || round(100.0 * bw / (bw + bl)) || ')' else '' end ||
    case when vw + vl > 0 then E'\n👑 VIP: ' || vw || '/' || (vw + vl) || ' tuttu' else '' end ||
    coalesce(E'\n🏆 Günün botu: ' || bb, '') ||
    coalesce(E'\n💥 En yüksek oranlı tutan: ' || yo, '') ||
    E'\n\nYarın yeni tahminlerle görüşmek üzere! ⚽' || E'\nhttps://t.me/goleoaibot?startapp';

  insert into bildirim_kuyruk(user_id, msg)
  select c.user_id, msg from tg_chats c where bildirim_acik(c.user_id, 'gunsonu');
  get diagnostics n = row_count;
  return n;
end $$;

-- ===== 4b) Gönderici: aynı Telegram hesabına tekrar eden mesajı atla =====
create or replace function public.bildirim_gonder()
returns int language plpgsql security definer set search_path to 'public' as $$
declare r record; n int := 0; tur int;
begin
  for tur in 1 .. 4 loop                       -- dakikada en fazla 4 x 25 mesaj
    for r in select k.id, k.user_id, k.msg, c.tg_id
             from bildirim_kuyruk k left join tg_chats c on c.user_id = k.user_id
             where k.sent_at is null order by k.id limit 25 for update of k skip locked loop
      -- aynı Telegram hesabına (birden fazla Goleo hesabı bağlıysa) aynı mesaj 30 dk içinde tekrar gitmesin
      if r.tg_id is not null and not exists (
           select 1 from bildirim_kuyruk k2 join tg_chats c2 on c2.user_id = k2.user_id
           where c2.tg_id = r.tg_id and k2.msg = r.msg and k2.sent_at > now() - interval '30 minutes') then
        perform tg_notify(r.user_id, r.msg);
        n := n + 1;
      end if;
      update bildirim_kuyruk set sent_at = now() where id = r.id;
    end loop;
    exit when not exists (select 1 from bildirim_kuyruk where sent_at is null);
    perform pg_sleep(1.5);
  end loop;
  delete from bildirim_kuyruk where sent_at < now() - interval '7 days';
  return n;
end $$;

-- ===== 5) Yetkiler ve zamanlayıcılar =====
revoke execute on function public.bildirim_acik(uuid, text) from public, anon, authenticated;
revoke execute on function public.takip_bildirim() from public, anon, authenticated;
revoke execute on function public.bildirim_gonder() from public, anon, authenticated;
revoke execute on function public.kupon_bildirim() from public, anon, authenticated;
revoke execute on function public.gunsonu_bildirim() from public, anon, authenticated;
revoke execute on function public.sabah_bildirim() from public, anon, authenticated;
revoke execute on function public.vip_tuttu_bildirim() from public, anon, authenticated;
revoke execute on function public.surpriz_tuttu_bildirim() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname in ('goleo-takip', 'goleo-gunsonu');
select cron.schedule('goleo-takip', '*/5 * * * *', 'select public.takip_bildirim()');
select cron.schedule('goleo-gunsonu', '0 21 * * *', 'select public.gunsonu_bildirim()');   -- 00:00 TR
