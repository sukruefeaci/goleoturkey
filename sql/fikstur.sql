-- Fikstür / canlı maçlar (Mackolik verisi)
-- Supabase > SQL Editor'da bir kez çalıştırın.

create extension if not exists http with schema extensions;

create table if not exists public.fixture_cache(
  day text primary key,          -- 'dd/mm/yyyy'
  data jsonb not null,
  fetched_at timestamptz not null default now()
);
alter table public.fixture_cache enable row level security;  -- sadece fonksiyon üzerinden okunur

create or replace function public.fikstur(d date)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  dk text := to_char(d, 'DD/MM/YYYY');
  c fixture_cache%rowtype;
  ttl interval;
  res http_response; j jsonb; out jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'msg', 'Giriş gerekli'); end if;
  ttl := case when d = (now() at time zone 'Europe/Istanbul')::date then interval '30 seconds'
              when d < (now() at time zone 'Europe/Istanbul')::date then interval '6 hours'
              else interval '15 minutes' end;
  select * into c from fixture_cache where day = dk;
  if found and c.fetched_at > now() - ttl then
    return jsonb_build_object('ok', true, 'at', c.fetched_at, 'm', c.data);
  end if;
  -- aynı anda tek istek Mackolik'e gitsin, diğerleri önbelleği alsın
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
             'id',  r->>0,
             'ev',  r->>2,
             'dep', r->>4,
             'st',  r->>5,
             'dk',  r->>6,
             's1',  nullif(trim(split_part(r->>7, '-', 1)), ''),
             's2',  nullif(trim(split_part(r->>7, '-', 2)), ''),
             'saat', r->>16,
             'lig', case when jsonb_typeof(r->36) = 'array'
                         then trim(coalesce(r->36->>1, '') || ' ' || coalesce(r->36->>3, '')) end)
           order by r->>16, r->>2), '[]'::jsonb)
      into out
      from jsonb_array_elements(j->'m') r
     where jsonb_typeof(r) = 'array'
       and coalesce(case when jsonb_typeof(r->36) = 'array' then r->36->>11 end, '1') = '1';  -- sadece futbol
  exception when others then
    return jsonb_build_object('ok', c.day is not null, 'eski', true, 'at', c.fetched_at,
                              'm', coalesce(c.data, '[]'::jsonb), 'msg', 'Maç verisi alınamadı');
  end;
  insert into fixture_cache(day, data, fetched_at) values (dk, out, now())
    on conflict (day) do update set data = excluded.data, fetched_at = excluded.fetched_at;
  return jsonb_build_object('ok', true, 'at', now(), 'm', out);
end $$;

revoke execute on function public.fikstur(date) from anon;
