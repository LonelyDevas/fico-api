-- Profile picture URL. Null = never chosen (the app falls back to the Google
-- photo when signed in with Google); empty string = the user removed it on
-- purpose and wants initials. Uploaded files live in the public `avatars`
-- bucket (see 0024) under "<user_id>/avatar.jpg".
alter table public.profiles add column if not exists avatar_url text;
