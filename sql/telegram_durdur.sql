-- Admin panelinden "Kullanıcı bildirimleri" kapatılınca Telegram'a bildirim gönderilmesin.
-- Supabase > SQL Editor'da bir kez çalıştırın.
insert into public.config(key, value) values ('kanal_aktif', '1') on conflict (key) do nothing;
insert into public.config(key, value) values ('bildirim_aktif', '1') on conflict (key) do nothing;

create or replace function public.bildirim_gonder()
returns int language plpgsql security definer set search_path to 'public' as $$
declare r record; n int := 0; tur int;
begin
  -- Admin bildirimleri durdurduysa kuyruktaki mesajları göndermeden geç (sonradan toplu gitmesin)
  if coalesce((select value from config where key = 'bildirim_aktif'), '1') = '0' then
    update bildirim_kuyruk set sent_at = now() where sent_at is null;
    return 0;
  end if;
  for tur in 1 .. 4 loop
    for r in select k.id, k.user_id, k.msg, c.tg_id
             from bildirim_kuyruk k left join tg_chats c on c.user_id = k.user_id
             where k.sent_at is null order by k.id limit 25 for update of k skip locked loop
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
revoke execute on function public.bildirim_gonder() from public, anon, authenticated;
