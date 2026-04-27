-- Account deletion function.
-- Called from the client via supabase.rpc('delete_my_account').
-- SECURITY DEFINER so it runs as the DB owner and can delete from auth.users.
-- Pets, vaccinations, reminders, vet_favorites, purchases, and profiles all
-- cascade-delete when the auth.users row is removed.

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  -- Cascade chains: auth.users → profiles → pets → vaccinations/reminders
  --                                       → vet_favorites, purchases
  delete from auth.users where id = uid;
end;
$$;

-- Revoke from public, grant only to authenticated users
revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;
