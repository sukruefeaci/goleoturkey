-- BİLDİRİM 3: Takip edilen botların tahmini TUTUNCA bildirim
-- bildirim2.sql'den SONRA, Supabase > SQL Editor'da bir kez çalıştırın. Tekrar çalıştırılabilir.

alter table public.bot_picks add column if not exists sonuc_bildirildi boolean not null default false;
-- eski sonuçlar için geriye dönük bildirim gitmesin
update public.bot_picks set sonuc_bildirildi = true
 where not sonuc_bildirildi and (durum is not null and gun < (now() at time zone 'Europe/Istanbul')::date - 1);

create or replace function public.takip_bildirim()
returns int language plpgsql security definer set search_path to 'public' as $$
declare b record; liste text; adet int; n int := 0; k int;
  simdi timestamp := (now() at time zone 'Europe/Istanbul');
begin
  -- 1) YENİ TAHMİN: başlamış maçlar için bildirim gönderme, sadece işaretle
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

  -- 2) TUTAN TAHMİN: kullanıcı başına tek mesajda topla
  insert into bildirim_kuyruk(user_id, msg)
  select t.user_id,
         '✅ Takip ettiğin ' || case when count(*) = 1 then 'botun tahmini tuttu!' else 'botlardan ' || count(*) || ' tahmin tuttu!' end ||
         E'\n\n' || string_agg(bo.avatar || ' ' || bo.ad || ': ' || p.ev || ' – ' || p.dep ||
                               coalesce(' (' || p.s1 || '-' || p.s2 || ')', '') || ' · ' || p.tahmin || ' · oran ' || p.oran,
                               E'\n' order by p.gun, p.saat) ||
         E'\n\n🤖 AI Botlar sekmesi' || E'\nhttps://t.me/goleoaibot?startapp'
  from bot_picks p
  join bots bo on bo.id = p.bot_id
  join bot_takip t on t.bot_id = p.bot_id
  where p.durum = 'tuttu' and not p.sonuc_bildirildi and p.analiz_durum = 'onay'
    and bildirim_acik(t.user_id, 'takip')
    -- Sürpriz Bot tutunca herkese zaten duyuru gidiyor; o açıksa tekrar gönderme
    and not (bo.strateji = 'surpriz' and bildirim_acik(t.user_id, 'surpriz'))
  group by t.user_id;
  get diagnostics k = row_count; n := n + k;

  update bot_picks set sonuc_bildirildi = true where durum is not null and not sonuc_bildirildi;
  return n;
end $$;
revoke execute on function public.takip_bildirim() from public, anon, authenticated;
