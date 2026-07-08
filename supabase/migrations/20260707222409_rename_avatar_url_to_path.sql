-- `media` bucket is private (RLS-controlled), so we store the storage
-- object path here, not a public URL. The app builds an authenticated
-- request URL from this path when it needs to display the image.
alter table public.users rename column avatar_url to avatar_path;
