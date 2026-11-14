# Project brief: Amicus (formerly "Круг", "Circle")

> A feed-style social network where you only see posts from people you've genuinely met — in person or through an invite from a friend.

The final name is **Amicus** (Latin for "friend"). The project was originally developed under the working name "Круг" ("Circle") — both names appear in the rest of the brief; it's the same project.

**This document is historical.** It describes the MVP (0.1) as it was conceived before development started, and is kept as is — to show where the project grew from and where reality diverged from the plan. What actually came out: the current schema is in [data-model.md](data-model.md), the version history is in [../CHANGELOG.md](../CHANGELOG.md), what's still open is in [future-development.md](future-development.md), how the MVP itself went is in [implementation-plan.md](implementation-plan.md).

---

## 1. Why this is needed at all (positioning)

Most social networks are built around publicity and an algorithmic feed of strangers. Amicus is the opposite: only people you've actually met or trust get access to your feed. It's closer to the concept of Path (a closed feed for close friends) and BeReal (anti-staged content), but with a unique mechanic — **connection verification** (in the MVP; **rooms** as private sub-spaces inside the shared circle are a feature of future versions *(shipped in 0.17.0 — see "Rooms" in [data-model.md](data-model.md))*).

For a portfolio this is a good story: there's a clear idea, there's a non-trivial data model (not just feed CRUD), there's something to show at an interview — "why I chose exactly this access architecture".

---

## 2. Product mechanics (refined description)

**Connection.** Two people become "connections" in one of these ways:
- The inviter generates a one-time invite link and sends it by any means (Telegram, WhatsApp, etc.);
- Scanning a QR code when meeting in person (a stronger guarantee that the meeting was real) — **not in the MVP, see future-development.md**.

**Main feed.** Posts seen by everyone you have a Connection with. Each user has their own feed — it's the intersection of their own connections, not a shared public page. In the MVP this is the only feed — posts are published only here.

**Rooms** — private sub-spaces inside the circle with their own isolated feed — **not in the MVP** *(shipped later, in 0.17.0, together with room chat — see "Rooms" in [data-model.md](data-model.md))*.

**Post reactions.**
- A like with a counter (the only reaction in the MVP);
- Additional emotions (a set of emoji) — **not in the MVP, see future-development.md**;
- Comments — attached to a post (grouped by `post_id`, each post has its own list), **flat, no threads** in the MVP (replying to a specific comment — see future-development.md).

---

## 3. Data model (simplified)

You've already done ER modeling and normalization in the database labs — this model maps directly onto what you did:

| Entity | Key fields | Comment |
|---|---|---|
| **User** | id, name, avatar, created_at | User profile |
| **Connection** | user_a_id, user_b_id, method, created_at | The "connected" link; method = invite_link / qr_code |
| **InviteLink** | id, owner_id, code, used_by_id, is_used, created_at | One-time invite link |
| **Post** | id, author_id, text, image_url, created_at | The post itself |
| **Reaction** | id, post_id, user_id, type, created_at | Like/emotion |
| **Comment** | id, post_id, author_id, parent_comment_id (nullable), text, created_at | Comment; `post_id` — grouping by post (an index for quickly fetching the comment list of a given post), parent — for threads (contrary to this row, this field didn't make it into the actual MVP schema: it was added only in 0.10.0, see CHANGELOG.md) |

This is a draft, not the final DDL — the tables and relations were refined along the way. **The current schema is in [data-model.md](data-model.md)**, and it's noticeably broader: the single `image_url` became the `post_media` table (up to 20 photos/videos), the avatar became the `profile_photos` gallery, mute/block/favorites, notifications and settings were added. Read the table above as the original intent, not as a reference.

---

## 4. What to do in the MVP (0.1)

You're new to mobile development, so it's important not to drown — it makes sense to cut down the first version.

- Sign-up/sign-in
- Profile (name, avatar)
- Invite link: create one and activate someone else's → a Connection appears
- Main feed: viewing + creating a post (text + one photo), the post is visible to all Connections
- A like with a counter
- Comments — a list on the post screen, grouped by that post (`post_id`), no nesting (a flat list, to keep things simple)

Everything else — 1.0 and 2.0+ — is in [future-development.md](future-development.md).

---

## 5. Recommended stack

You say you're new to mobile development, but you already know SQL/PostgreSQL and C#/.NET from the database labs — that's a great foundation, and I'll build on it.

**Frontend (the app itself): Flutter**
- Flutter is a framework from Google, written in the Dart language. One codebase runs on both Android and iOS — no need to write the app twice.
- Dart is syntactically close to C# (classes, typing, OOP) — it'll be easier for you to adapt than with plain JavaScript (the language of the alternative framework, React Native).
- A huge number of official tutorials and clear documentation — good for a first mobile project.

**Backend (server + database): Supabase**
- Supabase is a service that gives you a ready-made PostgreSQL database in the cloud + user authentication + file storage (for photos) + realtime updates (the feed refreshes on its own, without reloading) — all without having to run a server yourself.
- Since you've already written SQL and worked with PostgreSQL directly — here you apply exactly the same knowledge: you write the schema, set up relations, and Supabase takes care of all the "infrastructure" routine (server, deployment, connection security).
- Row Level Security (row-level rules in the database itself — who can read/write what) maps perfectly onto the "who sees which post" logic that you have to think through anyway.

An alternative for the future (moving from Supabase to your own backend) — see [future-development.md](future-development.md).

---

## 6. Stage-by-stage roadmap

**Stage 0 — Setup.** Install Flutter, go through the official getting-started tutorial (a simple counter app — the standard first step for every beginner), create a Supabase project, set up a GitHub repository.

**Stage 1 — Skeleton.** Sign-up/sign-in screen, Supabase Auth integration, profile screen, saving the user in the database.

**Stage 2 — Connections.** Generating an invite link, activating someone else's link (to start with, simply by entering the code manually, without deep links — those are harder), the Connection table.

**Stage 3 — Main feed.** Post model, post list, post creation screen, uploading photos to Supabase Storage.

**Stage 4 — Reactions and comments.** Like + counter, flat comments.

**Stage 5 — Portfolio polish.** Tidy up the UI, handle empty states and errors, write a README, record a short demo video, optionally — make a test build (TestFlight / Play Internal Testing) so friends can actually try it.