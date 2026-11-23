-- GÜVENLİK SIKILAŞTIRMA + TELEGRAM BİLDİRİMLERİ
-- Supabase > SQL Editor'da bir kez çalıştırın. Tekrar çalıştırılabilir.

-- ============ 1) GÜVENLİK ============

-- 1a) Giriş yapmamış ziyaretçiler (anon) hiçbir tabloya ve fonksiyona erişemesin
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges in schema public grant execute on functions to authenticated, service_role;

-- 1b) API'nin hiç kullanmadığı tehlikeli tablo yetkileri
revoke truncate, trigger, references on all tables in schema public from authenticated;

-- 1c) Sadece sunucunun çağırması gereken fonksiyonlar (kullanıcı çağıramaz)
revoke execute on function public.tg_notify(uuid, text) from authenticated;
do $$
declare f text;
begin
  foreach f in array array['fikstur_cek(date,interval)', 'arsiv_doldur(date,interval)', 'arsiv_gecmis(integer)',
                           'oran_cek(text,date)', 'bot_uret(date)', 'bot_sonuc()', 'analiz_isle(integer)',
                           'bot_calistir()', 'takim_form(text,date,text)', 'handle_new_user()'] loop
    begin
      execute 'revoke execute on function public.' || f || ' from authenticated';
    exception when undefined_function then null;
    end;
  end loop;
end $$;

-- 1c-2) Uygulamanın kullanmadığı, sunucu tarafı fonksiyonlar (zamanlayıcı yine çalıştırabilir)
do $$
declare f oid;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('vip_remind', 'match_stats') loop
    execute 'revoke execute on function ' || f::regprocedure || ' from authenticated';
  end loop;
end $$;

-- 1d) profiles: kullanıcı sadece Telegram adını ve bildirim ayarını değiştirebilir
--     (puan, admin yetkisi, kullanıcı adı ve referans asla)
revoke insert, update, delete on public.profiles from authenticated;
grant update (tg_username) on public.profiles to authenticated;

-- ============ 2) TELEGRAM BİLDİRİMLERİ ============

-- 2a) Kullanıcı bildirimleri kapatabilsin
alter table public.profiles add column if not exists bildirim boolean not null default true;
grant update (bildirim) on public.profiles to authenticated;

-- 2b) Gönderim kuyruğu (Telegram sınırına takılmamak için parça parça gönderilir)
create table if not exists public.bildirim_kuyruk(
  id bigserial primary key,
  user_id uuid not null,
  msg text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index if not exists bildirim_kuyruk_bekleyen on public.bildirim_kuyruk(id) where sent_at is null;
alter table public.bildirim_kuyruk enable row level security;
revoke all on public.bildirim_kuyruk from anon, authenticated;

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

-- 2c) Sabah bildirimi: bugünün bot tahminleri
create or replace function public.sabah_bildirim()
returns int language plpgsql security definer set search_path to 'public' as $$
declare bg date := (now() at time zone 'Europe/Istanbul')::date; adet int; botn int; ornek text; msg text; n int;
begin
  select count(*), count(distinct bot_id) into adet, botn
    from bot_picks where gun = bg and analiz_durum = 'onay';
  if adet = 0 then return 0; end if;
  select string_agg(s, E'\n') into ornek from (
    select b.avatar || ' ' || b.ad || ': ' || p.ev || ' – ' || p.dep || ' · ' || p.tahmin || ' (' || p.oran || ')' s
    from bot_picks p join bots b on b.id = p.bot_id
    where p.gun = bg and p.analiz_durum = 'onay' and not b.vip and b.strateji <> 'surpriz'
    order by (coalesce(p.lig, '') ~* '(süper lig|premier|laliga|la liga|serie a|bundesliga|ligue 1|şampiyonlar|avrupa)') desc,
             p.oran desc
    limit 3) z;
  msg := '☀️ Günaydın! Goleo AI botları bugün ' || adet || ' tahmin paylaştı.' ||
         coalesce(E'\n\n' || ornek, '') ||
         E'\n\n🤖 Tümü: Kupon › AI Botlar' || E'\nhttps://t.me/goleoaibot?startapp' ||
         E'\n\nBildirimleri Profil sayfasından kapatabilirsin.';
  insert into bildirim_kuyruk(user_id, msg)
  select c.user_id, msg from tg_chats c join profiles p on p.id = c.user_id where p.bildirim;
  get diagnostics n = row_count;
  return n;
end $$;

-- 2d) VIP tahmin tutunca: satın alanlara ve aktif VIP üyelere
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
    where exists (select 1 from tg_chats c where c.user_id = x.u);
  end if;
  return new;
end $$;
drop trigger if exists t_vip_tuttu on public.vip_tips;
create trigger t_vip_tuttu after update of durum on public.vip_tips
  for each row execute function public.vip_tuttu_bildirim();

-- 2e) Sürpriz Bot tutunca herkese duyuru
create or replace function public.surpriz_tuttu_bildirim()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare msg text;
begin
  if new.durum = 'tuttu' and old.durum is null
     and exists (select 1 from bots b where b.id = new.bot_id and b.strateji = 'surpriz') then
    msg := '💣 SÜRPRİZ BOT TUTTU!' || E'\n' || new.ev || ' – ' || new.dep ||
           coalesce(' (' || new.s1 || '-' || new.s2 || ')', '') ||
           E'\n' || new.tahmin || ' · Oran ' || new.oran ||
           E'\n\n🤖 Botların bugünkü tahminleri: Kupon › AI Botlar' || E'\nhttps://t.me/goleoaibot?startapp';
    insert into bildirim_kuyruk(user_id, msg)
    select c.user_id, msg from tg_chats c join profiles p on p.id = c.user_id where p.bildirim;
  end if;
  return new;
end $$;
drop trigger if exists t_surpriz_tuttu on public.bot_picks;
create trigger t_surpriz_tuttu after update of durum on public.bot_picks
  for each row execute function public.surpriz_tuttu_bildirim();

revoke execute on function public.bildirim_gonder() from public, anon, authenticated;
revoke execute on function public.sabah_bildirim() from public, anon, authenticated;
revoke execute on function public.vip_tuttu_bildirim() from public, anon, authenticated;
revoke execute on function public.surpriz_tuttu_bildirim() from public, anon, authenticated;

-- 2f) Zamanlayıcılar: kuyruk her dakika, sabah bildirimi 09:35 (TR) = 06:35 UTC
select cron.unschedule(jobid) from cron.job where jobname in ('goleo-bildirim', 'goleo-sabah');
select cron.schedule('goleo-bildirim', '* * * * *', 'select public.bildirim_gonder()');
select cron.schedule('goleo-sabah', '35 6 * * *', 'select public.sabah_bildirim()');

-- ============ 3) KONTROL ============
-- Giriş yapmış kullanıcıların çağırabildiği, içinde yetki kontrolü görünmeyen fonksiyonlar (incelemek için)
select p.proname as kontrol_edilecek_fonksiyon
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosecdef
  and has_function_privilege('authenticated', p.oid, 'execute')
  and pg_get_functiondef(p.oid) !~* '(is_admin\(\)|auth\.uid\(\))'
  and p.prorettype <> 'trigger'::regtype
order by 1;
