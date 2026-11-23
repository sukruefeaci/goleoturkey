-- HIZ: Fikstür verisi her dakika arka planda yenilenir, kullanıcı Mackolik'i beklemez.
-- Kullanıcıya oranlar gönderilmez (daha küçük veri). Supabase > SQL Editor'da bir kez çalıştırın.

create or replace function public.fikstur(d date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare bg date := (now() at time zone 'Europe/Istanbul')::date; r jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'msg', 'Giriş gerekli'); end if;
  r := fikstur_cek(d, case when d = bg then interval '3 minutes'
                           when d < bg then interval '6 hours'
                           else interval '15 minutes' end);
  return (r - 'm') || jsonb_build_object('m', coalesce(
    (select jsonb_agg(e - array['o1', 'ox', 'o2', 'oa', 'ou', 'eid', 'did', 'kod'])
       from jsonb_array_elements(r->'m') e), '[]'::jsonb));
end $$;
revoke execute on function public.fikstur(date) from anon;

select cron.unschedule(jobid) from cron.job where jobname = 'goleo-fikstur';
select cron.schedule('goleo-fikstur', '* * * * *',
  $$select public.fikstur_cek((now() at time zone 'Europe/Istanbul')::date, interval '50 seconds')$$);
