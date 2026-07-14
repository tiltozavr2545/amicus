-- Harden the display-name fallback in handle_new_user(). The original used
-- `coalesce(new.raw_user_meta_data ->> 'name', 'Без имени')`, which only fell
-- back when the `name` key was absent. The sign-up client always sends a `name`
-- key, so an empty (or whitespace-only) name arrived as '' — not NULL — and was
-- stored verbatim, leaving the profile with a blank display name everywhere.
--
-- The app now rejects empty names client-side; this is defence in depth so a
-- direct API sign-up can't create a blank-named profile either. `nullif(trim(...),
-- '')` turns an empty/whitespace name into NULL so the fallback actually fires.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, name)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), 'Без имени')
  );
  return new;
end;
$$;
