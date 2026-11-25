-- TELEGRAM KANALI OTOMATİK PAYLAŞIM
-- Supabase > SQL Editor'da bir kez çalıştırın. Tekrar çalıştırılabilir.
-- Sabah paylaşılan tercihler ve gece paylaşılan sonuçlar burada işaretlenir (aynı şey iki kez paylaşılmasın).
alter table public.bot_picks add column if not exists kanal_paylasildi boolean not null default false;
alter table public.bot_picks add column if not exists kanal_sonuc_paylasildi boolean not null default false;
