-- Sponsor Telegram kanalına katılım puanı
-- Supabase > SQL Editor'da bir kez çalıştırın.

-- 1) Telegram'a anlık soru sorabilmek için http eklentisi
create extension if not exists http with schema extensions;

-- 2) Sponsor tablosuna puan ve (isteğe bağlı) kanal kimliği
alter table public.sponsors add column if not exists reward integer not null default 0;
alter table public.sponsors add column if not exists chat text; -- @kanaladi veya -100... (gizli kanallar için)

-- 3) Kim hangi kanaldan puan aldı (her kanal için kişi başı 1 kez)
create table if not exists public.sponsor_claims(
  user_id uuid not null references auth.users(id) on delete cascade,
  chat_key text not null,
  sponsor_id bigint,
  points integer not null,
  created_at timestamptz not null default now(),
  primary key (user_id, chat_key)
);
alter table public.sponsor_claims enable row level security;
drop policy if exists "kendi kayitlari" on public.sponsor_claims;
create policy "kendi kayitlari" on public.sponsor_claims for select using (user_id = auth.uid());

-- 4) Sponsorun Telegram kanal kimliği (chat alanı yoksa linkten çıkarılır)
create or replace function public.sponsor_chat(s public.sponsors)
returns text language sql immutable set search_path to 'public' as $$
  select case
    when nullif(trim(s.chat), '') is not null then trim(s.chat)
    when s.url ~* 't\.me/(joinchat/|\+)' then null
    else '@' || substring(s.url from '(?i)t\.me/(?:s/)?([A-Za-z0-9_]{4,})')
  end
$$;

-- 5) Kullanıcının puan aldığı sponsorlar
create or replace function public.sponsor_status()
returns setof bigint language sql stable security definer set search_path to 'public' as $$
  select s.id from sponsors s
  join sponsor_claims c on c.user_id = auth.uid() and c.chat_key = lower(sponsor_chat(s))
$$;

-- 6) Üyeliği Telegram'dan kontrol et, üyeyse puanı bir kez ver
create or replace function public.sponsor_claim(sid bigint)
returns json language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  uid uuid := auth.uid(); s sponsors%rowtype; ch text; ck text; tgid bigint; tok text;
  res extensions.http_response; j jsonb; st text; n int;
begin
  if uid is null then return json_build_object('ok', false, 'msg', 'Giriş gerekli'); end if;
  select * into s from sponsors where id = sid and active and kind = 'kanal';
  if not found or s.reward <= 0 then return json_build_object('ok', false, 'msg', 'Bu kanal için puan yok.'); end if;
  ch := sponsor_chat(s);
  if ch is null then return json_build_object('ok', false, 'msg', 'Kanal ayarı eksik, yöneticiye bildir.'); end if;
  ck := lower(ch);
  if exists (select 1 from sponsor_claims where user_id = uid and chat_key = ck) then
    return json_build_object('ok', false, 'done', true, 'msg', 'Bu kanaldan zaten puan aldın.');
  end if;
  select tg_id into tgid from tg_chats where user_id = uid;
  if tgid is null then
    return json_build_object('ok', false, 'msg', 'Telegram bağlantın yok. Uygulamayı Telegram''dan aç.');
  end if;
  select value into tok from app_secrets where key = 'bot_token';
  begin
    perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
    res := http_get('https://api.telegram.org/bot' || tok || '/getChatMember?chat_id='
                    || urlencode(ch) || '&user_id=' || tgid);
    j := res.content::jsonb;
  exception when others then
    return json_build_object('ok', false, 'msg', 'Kontrol edilemedi, biraz sonra tekrar dene.');
  end;
  if not coalesce((j->>'ok')::boolean, false) then
    return json_build_object('ok', false, 'msg', 'Kontrol edilemedi (bot kanalda yönetici olmalı).');
  end if;
  st := j->'result'->>'status';
  if not (st in ('creator', 'administrator', 'member')
          or (st = 'restricted' and coalesce((j->'result'->>'is_member')::boolean, false))) then
    return json_build_object('ok', false, 'msg', 'Henüz kanala katılmamışsın.');
  end if;
  insert into sponsor_claims(user_id, chat_key, sponsor_id, points)
    values (uid, ck, s.id, s.reward) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return json_build_object('ok', false, 'done', true, 'msg', 'Bu kanaldan zaten puan aldın.'); end if;
  insert into points_log(user_id, points, reason) values (uid, s.reward, 'kanal katılımı');
  return json_build_object('ok', true, 'points', s.reward, 'msg', '🎉 +' || s.reward || ' puan kazandın!');
end $$;

revoke execute on function public.sponsor_claim(bigint) from anon;
revoke execute on function public.sponsor_status() from anon;
