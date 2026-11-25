-- TELEGRAM STARS İLE VIP SATIŞI + BOT MESAJLARI
-- Supabase > SQL Editor'da bir kez çalıştırın. Tekrar çalıştırılabilir.

-- ===== 1) Paket fiyatları =====
alter table public.vip_plans add column if not exists stars integer;
alter table public.vip_plans alter column price drop not null;   -- puan fiyatı boş = sadece Stars ile alınır

update public.vip_plans set stars = 49  where days = 1;
update public.vip_plans set stars = 119 where days = 7;
update public.vip_plans set stars = 599 where days = 30;
insert into public.vip_plans(title, days, price, stars, sort, active)
select '1 Günlük VIP', 1, null, 49, 0, true
where not exists (select 1 from public.vip_plans where days = 1);

-- Puanla alma: puan fiyatı olmayan paket puanla alınamaz
create or replace function public.vip_sub_buy(pid bigint)
returns json language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := auth.uid(); pl vip_plans%rowtype; p profiles%rowtype; cur timestamptz; st timestamptz;
begin
  if uid is null then return json_build_object('ok', false, 'msg', 'Giriş gerekli'); end if;
  select * into pl from vip_plans where id = pid and active;
  if not found then return json_build_object('ok', false, 'msg', 'Paket bulunamadı.'); end if;
  if pl.price is null then return json_build_object('ok', false, 'msg', 'Bu paket sadece Telegram Stars ile alınabilir.'); end if;
  select * into p from profiles where id = uid for update;
  if p.points < pl.price then return json_build_object('ok', false, 'msg', 'Puanın yetmiyor.'); end if;
  select max(ends_at) into cur from vip_subs where user_id = uid and ends_at > now();
  st := coalesce(cur, now());
  insert into vip_subs(user_id, plan_id, price, starts_at, ends_at)
    values (uid, pid, pl.price, st, st + make_interval(days => pl.days));
  insert into points_log(user_id, points, reason) values (uid, -pl.price, 'vip abonelik');
  return json_build_object('ok', true, 'msg', 'VIP üyelik aktif! 👑');
end $$;

-- ===== 2) Stars siparişleri =====
create table if not exists public.stars_orders(
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_id bigint not null,
  stars integer not null,
  durum text not null default 'bekliyor',       -- bekliyor | odendi
  charge_id text unique,
  tg_user bigint,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
alter table public.stars_orders enable row level security;
revoke all on public.stars_orders from anon, authenticated;
drop policy if exists "kendi siparisleri" on public.stars_orders;
create policy "kendi siparisleri" on public.stars_orders for select using (user_id = auth.uid());
grant select on public.stars_orders to authenticated;

-- Webhook gizli anahtarı (Telegram her istekte başlıkta gönderir)
insert into public.app_secrets(key, value)
select 'tg_webhook_secret', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
where not exists (select 1 from public.app_secrets where key = 'tg_webhook_secret');

-- ===== 3) Telegram API yardımcı =====
create or replace function public.tg_api(metod text, govde jsonb)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare tok text; res http_response;
begin
  select value into tok from app_secrets where key = 'bot_token';
  perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
  res := http(('POST', 'https://api.telegram.org/bot' || tok || '/' || metod, array[]::http_header[],
               'application/json', govde::text)::http_request);
  return res.content::jsonb;
exception when others then
  return jsonb_build_object('ok', false, 'description', sqlerrm);
end $$;

-- ===== 4) Uygulamadan ödeme linki oluştur =====
create or replace function public.vip_stars_link(pid bigint)
returns json language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := auth.uid(); pl vip_plans%rowtype; oid bigint; r jsonb;
begin
  if uid is null then return json_build_object('ok', false, 'msg', 'Giriş gerekli'); end if;
  select * into pl from vip_plans where id = pid and active and stars > 0;
  if not found then return json_build_object('ok', false, 'msg', 'Bu paket Stars ile satılmıyor.'); end if;
  insert into stars_orders(user_id, plan_id, stars) values (uid, pl.id, pl.stars) returning id into oid;
  r := tg_api('createInvoiceLink', jsonb_build_object(
    'title', 'Goleo ' || pl.title,
    'description', pl.days || ' gün boyunca tüm VIP tahminler ve VIP botların tercihleri açık. Tahminler kazanç garantisi vermez.',
    'payload', 'vip:' || oid,
    'currency', 'XTR',
    'prices', jsonb_build_array(jsonb_build_object('label', pl.title, 'amount', pl.stars))));
  if not coalesce((r->>'ok')::boolean, false) then
    delete from stars_orders where id = oid;
    return json_build_object('ok', false, 'msg', 'Ödeme başlatılamadı, biraz sonra tekrar dene.');
  end if;
  return json_build_object('ok', true, 'link', r->>'result', 'order', oid);
end $$;

-- ===== 5) Botun aldığı tüm güncellemeler (Edge Function buraya iletir) =====
create or replace function public.tg_isle(u jsonb, sec text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare
  q jsonb; m jsonb; sp jsonb; o stars_orders%rowtype; pl vip_plans%rowtype; oid bigint;
  st timestamptz; cur timestamptz; metin text; prm text; url text; destek text;
  app text := 'https://sukruefeaci.github.io/goleoturkey/';
begin
  if sec is distinct from (select value from app_secrets where key = 'tg_webhook_secret') then
    return json_build_object('ok', false, 'hata', 'yetkisiz');
  end if;

  -- a) Ödeme öncesi kontrol (10 sn içinde cevaplanmalı)
  q := u->'pre_checkout_query';
  if q is not null then
    oid := nullif(substring(q->>'invoice_payload' from '^vip:(\d+)$'), '')::bigint;
    select * into o from stars_orders where id = oid;
    if not found or o.durum <> 'bekliyor' or (q->>'currency') <> 'XTR' or (q->>'total_amount')::int <> o.stars then
      perform tg_api('answerPreCheckoutQuery', jsonb_build_object('pre_checkout_query_id', q->>'id', 'ok', false,
        'error_message', 'Bu ödeme isteği geçersiz ya da süresi dolmuş. Lütfen uygulamadan tekrar dene.'));
    else
      perform tg_api('answerPreCheckoutQuery', jsonb_build_object('pre_checkout_query_id', q->>'id', 'ok', true));
    end if;
    return json_build_object('ok', true);
  end if;

  m := u->'message';
  if m is null then return json_build_object('ok', true); end if;

  -- b) Ödeme tamamlandı → VIP aç
  sp := m->'successful_payment';
  if sp is not null then
    oid := nullif(substring(sp->>'invoice_payload' from '^vip:(\d+)$'), '')::bigint;
    select * into o from stars_orders where id = oid for update;
    if found and o.durum = 'bekliyor' then
      select * into pl from vip_plans where id = o.plan_id;
      update stars_orders set durum = 'odendi', charge_id = sp->>'telegram_payment_charge_id',
             tg_user = (m->'from'->>'id')::bigint, paid_at = now() where id = o.id;
      select max(ends_at) into cur from vip_subs where user_id = o.user_id and ends_at > now();
      st := coalesce(cur, now());
      insert into vip_subs(user_id, plan_id, price, starts_at, ends_at)
        values (o.user_id, o.plan_id, 0, st, st + make_interval(days => pl.days));
      perform tg_api('sendMessage', jsonb_build_object('chat_id', m->'chat'->'id',
        'text', '⭐ Ödemen alındı, teşekkürler! 👑 ' || pl.title || ' aktif.' || E'\nBitiş: ' ||
                to_char((st + make_interval(days => pl.days)) at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI'),
        'reply_markup', jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('text', '⚽ Goleo''yu aç', 'web_app', jsonb_build_object('url', app)))))));
    end if;
    return json_build_object('ok', true);
  end if;

  -- c) Komutlar (sadece özel sohbet)
  if m->'chat'->>'type' <> 'private' then return json_build_object('ok', true); end if;
  metin := coalesce(m->>'text', '');

  if metin ~* '^/paysupport' then
    select value into destek from config where key = 'admin_tg';
    perform tg_api('sendMessage', jsonb_build_object('chat_id', m->'chat'->'id',
      'text', '💬 Ödeme desteği' || E'\n\n' || 'Stars ödemenle ilgili bir sorun yaşadıysan bize yaz, en kısa sürede dönüş yapacağız.' ||
              coalesce(E'\n👉 ' || nullif(destek, ''), '') || E'\n\nYazarken ödeme tarihini ve paketi belirtmen yeterli.'));
    return json_build_object('ok', true);
  end if;

  prm := nullif(substring(metin from '^/start\s+([A-Za-z0-9_-]{1,64})'), '');
  url := app || case when prm is not null then '?ref=' || prm else '' end;
  perform tg_api('sendMessage', jsonb_build_object('chat_id', m->'chat'->'id',
    'text', case when metin ~* '^/start'
      then '👋 Hoş geldin ' || coalesce(m->'from'->>'first_name', '') || '!' || E'\n\n' ||
           '⚽ Goleo''da yapay zekâ botları her gün maçları analiz edip tahmin paylaşıyor.' || E'\n' ||
           '📅 Canlı skorlar · 🎫 Günlük kuponlar · 🔔 Anlık bildirimler' || E'\n\n' ||
           'Başlamak için aşağıdaki butona dokun 👇'
      else '⚽ Goleo''yu açmak için aşağıdaki butona dokun 👇' end,
    'reply_markup', jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
      jsonb_build_object('text', '⚽ Goleo''yu Aç', 'web_app', jsonb_build_object('url', url)))))));
  return json_build_object('ok', true);
end $$;

revoke execute on function public.tg_api(text, jsonb) from public, anon, authenticated;
revoke execute on function public.tg_isle(jsonb, text) from public, anon, authenticated;
grant execute on function public.tg_isle(jsonb, text) to service_role;
revoke execute on function public.vip_stars_link(bigint) from public, anon;
grant execute on function public.vip_stars_link(bigint) to authenticated;
