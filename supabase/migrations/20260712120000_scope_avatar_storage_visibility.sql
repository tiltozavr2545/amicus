-- Tighten avatar reads to match the profile-row visibility rule introduced in
-- 20260712100000: you may read an avatar only if it is your own or belongs to
-- one of your connections. The previous policy let any authenticated user
-- download any `avatars/{user_id}/...` object by path, which sidestepped the
-- users-table RLS for the one piece of profile data (the photo) that lives in
-- Storage. Upload/update/delete policies (own folder only) are unchanged.

drop policy "Avatars are viewable by authenticated users" on storage.objects;

create policy "Avatars are viewable by the user and their connections"
on storage.objects for select
to authenticated
using (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'avatars'
  and (
    (storage.foldername(name))[2] = auth.uid()::text
    or exists (
      select 1 from public.connections c
      where (c.user_a_id = auth.uid() and c.user_b_id::text = (storage.foldername(name))[2])
         or (c.user_b_id = auth.uid() and c.user_a_id::text = (storage.foldername(name))[2])
    )
  )
);
