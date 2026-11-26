-- =====================================================================================
-- RLS for the tenant core tables (dealers, dealer_members, contacts, vehicles, leads).
-- Consistent with the original model: a user always keeps full access to the leads they own
-- ("Users can manage own leads", auth.uid() = user_id, from the baseline). Dealer roles add:
--   owner/admin/manager : every lead/contact in the dealer
--   sales/bdc           : leads assigned to them (and those leads' contacts)
--   viewer              : read-only on what they can see
-- service_role bypasses RLS (Edge Functions). Idempotent.
-- =====================================================================================

alter table public.dealers        enable row level security;
alter table public.dealer_members enable row level security;
alter table public.contacts       enable row level security;
alter table public.vehicles       enable row level security;
alter table public.leads          enable row level security;

revoke all on public.dealers, public.dealer_members, public.contacts, public.vehicles from anon;

-- dealers
drop policy if exists dealers_member_select on public.dealers;
create policy dealers_member_select on public.dealers for select to authenticated
  using (public.is_dealer_member(id));
drop policy if exists dealers_admin_update on public.dealers;
create policy dealers_admin_update on public.dealers for update to authenticated
  using (public.is_dealer_member(id, array['owner','admin'])) with check (public.is_dealer_member(id, array['owner','admin']));

-- dealer_members: see yourself and (for managers+) your team; only owners change membership
drop policy if exists dealer_members_select on public.dealer_members;
create policy dealer_members_select on public.dealer_members for select to authenticated
  using (user_id = auth.uid() or public.is_dealer_member(dealer_id, array['owner','admin','manager']));
drop policy if exists dealer_members_owner_write on public.dealer_members;
create policy dealer_members_owner_write on public.dealer_members for all to authenticated
  using (public.is_dealer_member(dealer_id, array['owner'])) with check (public.is_dealer_member(dealer_id, array['owner']));

-- vehicles (inventory): members read, managers+ write
drop policy if exists vehicles_member_select on public.vehicles;
create policy vehicles_member_select on public.vehicles for select to authenticated
  using (public.is_dealer_member(dealer_id));
drop policy if exists vehicles_manager_write on public.vehicles;
create policy vehicles_manager_write on public.vehicles for all to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager']))
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager']));

-- leads (in addition to the baseline owner policy)
drop policy if exists leads_dealer_select on public.leads;
create policy leads_dealer_select on public.leads for select to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager'])
         or (assigned_to = auth.uid() and public.is_dealer_member(dealer_id)));
drop policy if exists leads_dealer_insert on public.leads;
create policy leads_dealer_insert on public.leads for insert to authenticated
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc']));
drop policy if exists leads_dealer_update on public.leads;
create policy leads_dealer_update on public.leads for update to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager'])
         or (assigned_to = auth.uid() and public.is_dealer_member(dealer_id, array['sales','bdc'])))
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc']));

-- contacts: visible/editable when you can see one of their leads, or you are manager+
drop policy if exists contacts_dealer_select on public.contacts;
create policy contacts_dealer_select on public.contacts for select to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager'])
         or exists (select 1 from public.leads l where l.contact_id = contacts.id
                     and (l.user_id = auth.uid() or l.assigned_to = auth.uid())));
drop policy if exists contacts_dealer_insert on public.contacts;
create policy contacts_dealer_insert on public.contacts for insert to authenticated
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc']));
drop policy if exists contacts_dealer_update on public.contacts;
create policy contacts_dealer_update on public.contacts for update to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager'])
         or exists (select 1 from public.leads l where l.contact_id = contacts.id
                     and (l.user_id = auth.uid() or l.assigned_to = auth.uid())))
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc']));
