-- Storage layout in the `media` bucket: avatars/{user_id}/<filename>
-- Post photos (Этап 3) will use a separate posts/{user_id}/... prefix with
-- their own policies, added later.

create policy "Avatars are viewable by authenticated users"
on storage.objects for select
to authenticated
using (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'avatars'
);

create policy "Users can upload their own avatar"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'avatars'
  and (storage.foldername(name))[2] = auth.uid()::text
);

create policy "Users can update their own avatar"
on storage.objects for update
to authenticated
using (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'avatars'
  and (storage.foldername(name))[2] = auth.uid()::text
)
with check (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'avatars'
  and (storage.foldername(name))[2] = auth.uid()::text
);

create policy "Users can delete their own avatar"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'avatars'
  and (storage.foldername(name))[2] = auth.uid()::text
);
