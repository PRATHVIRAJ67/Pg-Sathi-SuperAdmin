-- =============================================================================
-- Residents can see the room and bed they stay in (needed by the resident app).
--
-- Before this, rooms/beds were readable by business members only, so a
-- resident's own stay came back without its room/bed names. The helpers are
-- SECURITY DEFINER to avoid RLS recursion between stays, beds and rooms; they
-- only ever return rows linked to the caller's own resident record(s).
-- =============================================================================

create or replace function private.my_bed_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select s.bed_id
    from public.stays s
   where s.resident_id in (select private.my_resident_ids());
$$;

create or replace function private.my_room_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select b.room_id
    from public.stays s
    join public.beds b on b.id = s.bed_id
   where s.resident_id in (select private.my_resident_ids());
$$;

revoke all on function private.my_bed_ids(), private.my_room_ids() from public, anon;
grant execute on function private.my_bed_ids(), private.my_room_ids() to authenticated;

drop policy if exists beds_select on public.beds;
create policy beds_select on public.beds for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()) or id in (select private.my_bed_ids()));

drop policy if exists rooms_select on public.rooms;
create policy rooms_select on public.rooms for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()) or id in (select private.my_room_ids()));
