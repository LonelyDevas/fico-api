-- OAuth sign-ups (Google) have no chosen username, so handle_new_user() derives one
-- from the email. profiles.username is unique, so two people with the same email
-- prefix (john@gmail.com and john@yahoo.com) would make the second sign-up fail.
-- Give derived usernames a short random suffix when they are already taken.
-- A username the user typed themselves (email sign-up) is left alone, so a clash
-- there still fails and can be reported as "username taken".
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  chosen text := nullif(new.raw_user_meta_data ->> 'username', '');
  candidate text;
  attempts integer := 0;
begin
  if chosen is not null then
    insert into public.profiles (id, username) values (new.id, chosen);
    return new;
  end if;

  candidate := coalesce(nullif(split_part(new.email, '@', 1), ''), 'user');
  while exists (select 1 from public.profiles where username = candidate) and attempts < 20 loop
    attempts := attempts + 1;
    candidate := coalesce(nullif(split_part(new.email, '@', 1), ''), 'user')
                 || substr(md5(random()::text || new.id::text), 1, 4);
  end loop;

  insert into public.profiles (id, username) values (new.id, candidate);
  return new;
end;
$$;
