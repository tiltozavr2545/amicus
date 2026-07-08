-- Post photos: posts/{author_id}/<filename>. Mirrors the posts table's own
-- RLS — visible to the author and their connections, uploadable only by
-- the owning user.
create policy "Post photos are viewable by author and their connections"
on storage.objects for select
to authenticated
using (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'posts'
  and (
    (storage.foldername(name))[2] = auth.uid()::text
    or exists (
      select 1 from connections c
      where (c.user_a_id = auth.uid() and c.user_b_id = ((storage.foldername(name))[2])::uuid)
         or (c.user_b_id = auth.uid() and c.user_a_id = ((storage.foldername(name))[2])::uuid)
    )
  )
);

create policy "Users can upload their own post photos"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'posts'
  and (storage.foldername(name))[2] = auth.uid()::text
);
