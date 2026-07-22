alter table public.posts
  add constraint posts_text_length check (text is null or char_length(text) <= 5000);

alter table public.comments
  add constraint comments_text_length check (char_length(text) <= 5000);
