-- =====================================================================
-- Phase 2: member profile, documents, admin approval.
-- Run ONCE in Supabase Dashboard > SQL Editor (paste whole file > Run),
-- after schema.sql. Safe to run again.
-- This file only ADDS rules; it does not loosen any Row Level Security.
-- =====================================================================

-- 1) Admin's note to a member ("information incomplete: please upload ...").
alter table public.profiles add column if not exists review_note text;

do $$ begin
  alter table public.profiles
    add constraint profiles_review_note_len check (review_note is null or char_length(review_note) <= 1000);
exception when duplicate_object then null; end $$;

-- 2) A stored file path must sit inside the owner's own folder: <user-id>/<file>.
do $$ begin
  alter table public.profiles
    add constraint profiles_photo_path_owner check (photo_path is null or photo_path like id::text || '/%');
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.member_documents
    add constraint member_documents_path_owner check (storage_path like member_id::text || '/%');
exception when duplicate_object then null; end $$;

create index if not exists member_documents_member_idx
  on public.member_documents (member_id, kind, uploaded_at desc);

-- 3) Stricter profile protection.
--    - members cannot change role, status, joined_on or the admin's note
--    - only super admin changes roles
--    - only super admin changes the status of another admin / super admin
--    - nobody changes their OWN role or status from the website (no self-lockout)
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then          -- SQL Editor / service use: allowed (used to create the first super admin)
    return new;
  end if;
  new.member_no := old.member_no;
  new.id := old.id;

  if not public.is_admin() then
    new.role        := old.role;
    new.status      := old.status;
    new.joined_on   := old.joined_on;
    new.review_note := old.review_note;
    return new;
  end if;

  if not public.is_super_admin() then
    new.role := old.role;
    if old.role in ('admin', 'super_admin') then
      new.status    := old.status;
      new.joined_on := old.joined_on;
    end if;
  end if;

  if old.id = auth.uid() then
    new.role      := old.role;
    new.status    := old.status;
    new.joined_on := old.joined_on;
  end if;
  return new;
end $$;

-- 4) File type and size limits enforced by Storage itself (max 5 MB).
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'avatars';

update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
 where id = 'documents';
