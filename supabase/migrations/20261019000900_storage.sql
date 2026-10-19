-- =============================================================================
-- Supabase Storage: private buckets with tenant-scoped paths.
--   tenant-assets/{tenant_id}/...     logos, property photos (members read, owner/manager write)
--   tenant-documents/{tenant_id}/...  resident documents, agreements, expense receipts
--                                     (owner/manager/accountant only)
-- Nothing is public; clients use short-lived signed URLs.
-- Guarded so the migration is a no-op where the storage schema does not exist
-- (e.g. the PGlite test harness).
-- =============================================================================
do $outer$
begin
  if not exists (select 1 from pg_namespace where nspname = 'storage') then
    raise notice 'storage schema not present; skipping storage setup';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values
    ('tenant-assets', 'tenant-assets', false, 5242880,
      array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml']),
    ('tenant-documents', 'tenant-documents', false, 10485760,
      array['image/png', 'image/jpeg', 'image/webp', 'application/pdf'])
  on conflict (id) do update
    set public = excluded.public,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

  execute $p$
    create policy tenant_assets_read on storage.objects for select to authenticated
    using (bucket_id = 'tenant-assets'
           and (storage.foldername(name))[1] in (select t::text from private.member_tenant_ids() t))
  $p$;
  execute $p$
    create policy tenant_assets_write on storage.objects for insert to authenticated
    with check (bucket_id = 'tenant-assets'
           and (storage.foldername(name))[1] in (
             select t::text from private.tenant_ids_with_role(array['owner','manager']::public.tenant_role[]) t))
  $p$;
  execute $p$
    create policy tenant_assets_update on storage.objects for update to authenticated
    using (bucket_id = 'tenant-assets'
           and (storage.foldername(name))[1] in (
             select t::text from private.tenant_ids_with_role(array['owner','manager']::public.tenant_role[]) t))
  $p$;
  execute $p$
    create policy tenant_assets_delete on storage.objects for delete to authenticated
    using (bucket_id = 'tenant-assets'
           and (storage.foldername(name))[1] in (
             select t::text from private.tenant_ids_with_role(array['owner','manager']::public.tenant_role[]) t))
  $p$;
  execute $p$
    create policy tenant_documents_read on storage.objects for select to authenticated
    using (bucket_id = 'tenant-documents'
           and (storage.foldername(name))[1] in (select t::text from private.finance_tenant_ids() t))
  $p$;
  execute $p$
    create policy tenant_documents_write on storage.objects for insert to authenticated
    with check (bucket_id = 'tenant-documents'
           and (storage.foldername(name))[1] in (select t::text from private.finance_tenant_ids() t))
  $p$;
  execute $p$
    create policy tenant_documents_delete on storage.objects for delete to authenticated
    using (bucket_id = 'tenant-documents'
           and (storage.foldername(name))[1] in (
             select t::text from private.tenant_ids_with_role(array['owner','manager']::public.tenant_role[]) t))
  $p$;
end;
$outer$;
