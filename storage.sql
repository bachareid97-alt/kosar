-- Kosár invoice photos. Run this AFTER schema.sql, as a separate query in the Supabase SQL Editor.
-- Photos are private: each company's files live in a folder named after its id, and only the owner,
-- partners and warehouse staff of that company can open them.
insert into storage.buckets (id, name, public) values ('invoices', 'invoices', false) on conflict (id) do nothing;

create policy invoices_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'invoices' and (storage.foldername(name))[1] = public.my_org()::text and public.my_role() in ('owner','warehouse'));

create policy invoices_read on storage.objects for select to authenticated
  using (bucket_id = 'invoices' and (storage.foldername(name))[1] = public.my_org()::text and public.my_role() in ('owner','partner','warehouse'));
