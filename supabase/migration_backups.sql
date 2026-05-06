-- ============================================================
-- Time Tracker — Backup & soft-delete migration
-- Применить: SQL Editor → New query → вставить → Run
-- ============================================================

-- ---------- 1. Soft delete: добавляем deleted_at ----------
alter table public.categories add column if not exists deleted_at timestamptz;
alter table public.entries    add column if not exists deleted_at timestamptz;

create index if not exists categories_user_alive_idx
  on public.categories(user_id, position) where deleted_at is null;
create index if not exists entries_user_start_alive_idx
  on public.entries(user_id, start_at desc) where deleted_at is null;

-- ---------- 2. Убираем CASCADE — пусть категория удаляется отдельно от записей ----------
alter table public.entries drop constraint if exists entries_category_id_fkey;
alter table public.entries
  add constraint entries_category_id_fkey
  foreign key (category_id) references public.categories(id) on delete set null;

-- ---------- 3. Уникальный индекс «один активный на юзера» — учёт soft delete ----------
drop index if exists entries_one_active_per_user;
create unique index if not exists entries_one_active_per_user
  on public.entries(user_id) where end_at is null and deleted_at is null;

-- ---------- 4. Backups: таблица для daily snapshot ----------
create table if not exists public.backups (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  payload     jsonb not null
);
create index if not exists backups_user_created_idx
  on public.backups(user_id, created_at desc);

alter table public.backups enable row level security;

drop policy if exists "backups_select_own" on public.backups;
create policy "backups_select_own" on public.backups
  for select using (auth.uid() = user_id);

-- INSERT/DELETE делаем через SECURITY DEFINER функции — пользователь сам не пишет

-- ---------- 5. Функция: создать снапшот для одного юзера ----------
create or replace function public.create_user_snapshot(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_payload jsonb;
begin
  select jsonb_build_object(
    'version', 1,
    'snapshotted_at', now(),
    'categories', coalesce((
      select jsonb_agg(to_jsonb(c) order by position)
      from public.categories c where c.user_id = p_user_id
    ), '[]'::jsonb),
    'entries', coalesce((
      select jsonb_agg(to_jsonb(e) order by start_at desc)
      from public.entries e where e.user_id = p_user_id
    ), '[]'::jsonb),
    'settings', (
      select to_jsonb(s) from public.settings s where s.user_id = p_user_id
    )
  ) into v_payload;

  insert into public.backups (user_id, payload)
  values (p_user_id, v_payload)
  returning id into v_id;

  return v_id;
end $$;

-- ---------- 6. Функция: снапшоты для всех + чистка старше 30 дней ----------
create or replace function public.snapshot_all_users()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  u record;
  cnt int := 0;
begin
  for u in select id from auth.users loop
    perform public.create_user_snapshot(u.id);
    cnt := cnt + 1;
  end loop;

  -- Чистим бэкапы старше 30 дней
  delete from public.backups where created_at < now() - interval '30 days';

  return cnt;
end $$;

-- ---------- 7. pg_cron: ежедневный запуск в 03:00 UTC (06:00 MSK) ----------
create extension if not exists pg_cron;

-- Удаляем прошлый job если был (на случай повторного применения миграции)
do $$ begin
  perform cron.unschedule('time-tracker-daily-snapshot');
exception when others then null;
end $$;

select cron.schedule(
  'time-tracker-daily-snapshot',
  '0 3 * * *',
  $$select public.snapshot_all_users()$$
);

-- ---------- 8. Сразу делаем первый снапшот, чтобы не ждать сутки ----------
select public.create_user_snapshot(id) from auth.users;

-- ---------- Готово ----------
-- Проверка:
-- select count(*) from public.backups;          -- > 0
-- select created_at, jsonb_array_length(payload->'entries') as entries_count
-- from public.backups order by created_at desc limit 5;
