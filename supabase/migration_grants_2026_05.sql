-- ============================================================
-- Migration: tighten Data API grants
-- Дата: 2026-05-27
-- Применить: Supabase Dashboard → SQL Editor → New query → вставить → Run
--
-- Зачем:
--   1. С 2026-10-30 Supabase отзовёт дефолтный grant на public-таблицы
--      для anon/authenticated на существующих проектах. Фиксируем
--      explicit grants сейчас, чтобы не зависеть от дефолтов.
--   2. Security Advisor (lints 0028/0029): SECURITY DEFINER функции
--      сейчас исполнимы через REST anon/authenticated. На клиенте
--      .rpc() не используется — функции нужны только server-side:
--        • seed_defaults_for_user — trigger на auth.users
--          (роль supabase_auth_admin при signup)
--        • create_user_snapshot — вложенный вызов из snapshot_all_users
--        • snapshot_all_users — pg_cron job time-tracker-daily-snapshot
--          (роль postgres, автоматически имеет EXECUTE как owner)
--   3. Таблица backups — клиент через REST не пишет (только функции).
--      SELECT оставляем (для возможного UI истории), всё остальное
--      убираем у anon/authenticated.
--
-- Откат:
--   GRANT ALL ON public.<table> TO anon, authenticated;
--   GRANT EXECUTE ON FUNCTION public.<fn>(...) TO PUBLIC;
-- ============================================================

-- ============================================================
-- 1. SECURITY DEFINER functions
-- ============================================================

-- seed_defaults_for_user: trigger на auth.users — нужен supabase_auth_admin
REVOKE EXECUTE ON FUNCTION public.seed_defaults_for_user() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.seed_defaults_for_user() TO supabase_auth_admin;

-- snapshot_all_users: pg_cron от postgres (owner — права автоматом)
REVOKE EXECUTE ON FUNCTION public.snapshot_all_users() FROM PUBLIC, anon, authenticated;

-- create_user_snapshot: вызывается только из snapshot_all_users (тоже postgres)
REVOKE EXECUTE ON FUNCTION public.create_user_snapshot(uuid) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 2. backups: только SELECT для authenticated (RLS отфильтрует свои)
-- ============================================================
REVOKE ALL  ON public.backups FROM anon, authenticated;
GRANT SELECT ON public.backups TO authenticated;

-- ============================================================
-- 3. Client-facing tables: explicit DML, anon без прав
-- ============================================================
REVOKE ALL ON public.categories, public.entries, public.settings FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
   ON public.categories, public.entries, public.settings
   TO authenticated;

-- ============================================================
-- 4. Sequences — задел на будущие SERIAL/IDENTITY столбцы
-- ============================================================
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- ============================================================
-- Sanity checks (выполнить после применения миграции)
-- ============================================================
-- Таблицы — должны показать только нужные права:
-- SELECT grantee, table_name, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privs
-- FROM information_schema.role_table_grants
-- WHERE table_schema='public' AND grantee IN ('anon','authenticated')
-- GROUP BY grantee, table_name ORDER BY table_name, grantee;
--
-- Ожидаемо:
--   authenticated | backups    | SELECT
--   authenticated | categories | DELETE, INSERT, SELECT, UPDATE
--   authenticated | entries    | DELETE, INSERT, SELECT, UPDATE
--   authenticated | settings   | DELETE, INSERT, SELECT, UPDATE
--   (anon — пусто)
--
-- Функции — anon/authenticated не должны фигурировать в proacl:
-- SELECT proname, proacl FROM pg_proc
-- WHERE pronamespace='public'::regnamespace
--   AND proname IN ('create_user_snapshot','seed_defaults_for_user','snapshot_all_users');
--
-- Дым-тест signup: создать тестового юзера через Auth → убедиться, что
-- trigger seed_defaults_for_user отработал (появилась дефолтная категория
-- в public.categories для нового user_id).
