-- ============================================================
-- Time Tracker — Supabase schema
-- Применить: Supabase Dashboard → SQL Editor → New query → вставить → Run
-- ============================================================

-- ---------- categories ----------
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  color       text not null,
  position    int  not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists categories_user_idx on public.categories(user_id, position);

-- ---------- entries ----------
create table if not exists public.entries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete cascade,
  start_at    timestamptz not null,
  end_at      timestamptz,             -- null = активный (идёт сейчас)
  created_at  timestamptz not null default now()
);
create index if not exists entries_user_start_idx on public.entries(user_id, start_at desc);
create index if not exists entries_user_active_idx on public.entries(user_id) where end_at is null;

-- Гарантия: у юзера максимум один активный entry
create unique index if not exists entries_one_active_per_user
  on public.entries(user_id) where end_at is null;

-- ---------- settings ----------
create table if not exists public.settings (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  warn_minutes  int not null default 25,
  updated_at    timestamptz not null default now()
);

-- ============================================================
-- Data API access (явные GRANT — обязательно для проектов > Oct 30 2026)
-- ============================================================
grant select, insert, update, delete on public.categories to authenticated;
grant select, insert, update, delete on public.entries    to authenticated;
grant select, insert, update, delete on public.settings   to authenticated;

-- ============================================================
-- Row Level Security — пользователь видит только свои данные
-- ============================================================
alter table public.categories enable row level security;
alter table public.entries    enable row level security;
alter table public.settings   enable row level security;

-- categories
drop policy if exists "categories_select_own" on public.categories;
drop policy if exists "categories_insert_own" on public.categories;
drop policy if exists "categories_update_own" on public.categories;
drop policy if exists "categories_delete_own" on public.categories;

create policy "categories_select_own" on public.categories
  for select using (auth.uid() = user_id);
create policy "categories_insert_own" on public.categories
  for insert with check (auth.uid() = user_id);
create policy "categories_update_own" on public.categories
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "categories_delete_own" on public.categories
  for delete using (auth.uid() = user_id);

-- entries
drop policy if exists "entries_select_own" on public.entries;
drop policy if exists "entries_insert_own" on public.entries;
drop policy if exists "entries_update_own" on public.entries;
drop policy if exists "entries_delete_own" on public.entries;

create policy "entries_select_own" on public.entries
  for select using (auth.uid() = user_id);
create policy "entries_insert_own" on public.entries
  for insert with check (auth.uid() = user_id);
create policy "entries_update_own" on public.entries
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "entries_delete_own" on public.entries
  for delete using (auth.uid() = user_id);

-- settings
drop policy if exists "settings_select_own" on public.settings;
drop policy if exists "settings_upsert_own" on public.settings;
drop policy if exists "settings_update_own" on public.settings;

create policy "settings_select_own" on public.settings
  for select using (auth.uid() = user_id);
create policy "settings_upsert_own" on public.settings
  for insert with check (auth.uid() = user_id);
create policy "settings_update_own" on public.settings
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- Сид дефолтных категорий при первой авторизации
-- ============================================================
create or replace function public.seed_defaults_for_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Создаём дефолтные категории, только если у юзера их ещё нет
  if not exists (select 1 from public.categories where user_id = new.id) then
    insert into public.categories (user_id, name, color, position) values
      (new.id, 'Работа',                '#5e6ad2', 0),
      (new.id, 'Отдых',                 '#10b981', 1),
      (new.id, 'Развлечения и отдых',   '#f59e0b', 2),
      (new.id, 'Быт',                   '#06b6d4', 3),
      (new.id, 'Музыка',                '#ec4899', 4),
      (new.id, 'Спорт',                 '#84cc16', 5),
      (new.id, 'Проекты',               '#a855f7', 6);
  end if;

  insert into public.settings (user_id) values (new.id)
    on conflict (user_id) do nothing;

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.seed_defaults_for_user();

-- ============================================================
-- Realtime: включить публикацию изменений
-- ============================================================
alter publication supabase_realtime add table public.categories;
alter publication supabase_realtime add table public.entries;
alter publication supabase_realtime add table public.settings;
