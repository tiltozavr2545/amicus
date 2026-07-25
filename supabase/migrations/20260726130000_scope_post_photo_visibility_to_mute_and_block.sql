-- Post photos were the fourth copy of the visibility rule, and the one nobody
-- noticed: the storage policy from 20260708172235 says its job is to mirror the
-- posts table's RLS, but when 0.9.0 added mute/block it was left at "author or
-- Connection".
--
-- The post row itself became invisible to a blocked user, so the client can no
-- longer discover the photo's path — but the path is not a secret to anyone who
-- saw the post before the block. Holding `posts/<author_id>/<uuid>.jpg`, a
-- blocked user could keep calling createSignedUrl() on it indefinitely and get
-- a fresh working URL every time, because the storage policy only ever asked
-- whether a connections row existed, which a block deliberately does not touch.
--
-- Now it asks is_author_visible() — the same single source of truth the posts
-- policy, reaction_summary() and both comments policies use since
-- 20260726120000. The uuid cast keeps the shape of the original policy (the
-- INSERT policy below pins segment 2 to auth.uid(), so an object under posts/
-- always has a uuid there).
--
-- Note this does not retract signed URLs that were already issued: those carry
-- their own signature and stay valid until they expire (24h, feed_repository
-- .dart:248). What it closes is the ability to mint new ones forever.

drop policy "Post photos are viewable by author and their connections" on storage.objects;

create policy "Post photos are viewable by author and their connections"
on storage.objects for select
to authenticated
using (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'posts'
  and public.is_author_visible(((storage.foldername(name))[2])::uuid)
);

-- Avatars (20260712120000) are deliberately left alone. A block does not break
-- the Connection, so a blocked person still appears in the other's Connections
-- list — and on the "Blocked users" screen, which is the only way to undo the
-- block. Both render the avatar, so scoping avatars the same way would blank
-- out the very rows a user needs in order to unblock someone.
