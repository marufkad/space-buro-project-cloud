-- Space Buro Project Cloud — Phase 1.10 emergency security hotfix
--
-- Apply after Phase 1.9 and before installing any later migration.
-- This migration is additive and idempotent. It does not change business data.

begin;

-- Fail closed for anonymous callers and authenticated users without a profile.
-- Legacy functions use `current_user_role() not in (...)`; returning a sentinel
-- instead of NULL makes every such check reject an unknown caller.
create or replace function public.current_user_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.role from public.profiles p where p.id = auth.uid()),
    '__unauthorized__'
  )
$$;

create or replace function public.current_user_organization_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.organization_id from public.profiles p where p.id = auth.uid()
$$;

create or replace function public.can_view_finance()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    public.current_user_role() = any(array['owner','admin','accountant','project_manager']),
    false
  )
$$;

-- Pin the trigger helper search path. Trigger behavior remains unchanged.
alter function public.touch_updated_at() set search_path = public;

-- Postgres grants EXECUTE on new functions to PUBLIC by default. Remove that
-- implicit path from every SECURITY DEFINER function in the application
-- schema, including trigger helpers that were never intended to be RPCs.
-- Then restore only the small authenticated-callable allow-list.
do $$
declare
  r record;
  v_authenticated_rpc text[] := array[
    'activate_estimate_workflow',
    'add_service_nodes_to_estimate_v111',
    'apply_approved_change_order',
    'approve_schedule_baseline',
    'can_access_module_record',
    'can_access_project_v19',
    'can_view_finance',
    'calculate_contractor_operation_v18',
    'calculate_payroll',
    'create_design_program',
    'create_management_snapshot',
    'create_schedule_baseline',
    'current_user_organization_id',
    'current_user_role',
    'generate_estimate_tasks_v111',
    'next_document_number',
    'payroll_range_preview',
    'post_warehouse_document',
    'recalculate_design_compensation',
    'recalculate_design_program',
    'refresh_operational_notifications',
    'refresh_project_cost_control',
    'reopen_daily_log_correction_v19',
    'reverse_warehouse_document_v19',
    'stock_movement_effective_v19',
    'sync_estimate_execution',
    'sync_project_control_from_estimate'
  ];
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  loop
    execute format(
      'revoke execute on function %I.%I(%s) from public, anon',
      r.nspname, r.proname, r.args
    );

    if r.proname = any(v_authenticated_rpc) then
      execute format(
        'grant execute on function %I.%I(%s) to authenticated',
        r.nspname, r.proname, r.args
      );
    end if;
  end loop;
end
$$;

-- Helper functions are useful inside RLS but do not need anonymous RPC access.
revoke execute on function public.current_user_role() from public, anon;
revoke execute on function public.current_user_organization_id() from public, anon;
revoke execute on function public.can_view_finance() from public, anon;
grant execute on function public.current_user_role() to authenticated;
grant execute on function public.current_user_organization_id() to authenticated;
grant execute on function public.can_view_finance() to authenticated;

-- Cache auth.uid() once per statement instead of recalculating it for every
-- row. Definitions preserve the current access model while clearing the seven
-- known auth-RLS performance advisor findings.
drop policy if exists project_members_read on public.project_members;
create policy project_members_read on public.project_members
for select to authenticated using (
  organization_id = public.current_user_organization_id()
  and (profile_id = (select auth.uid())
    or public.current_user_role() in ('owner','admin','project_manager','foreman'))
);

drop policy if exists projects_read on public.projects;
create policy projects_read on public.projects
for select to authenticated using (
  organization_id = public.current_user_organization_id()
  and (
    public.current_user_role() in ('owner','admin','accountant','project_manager','foreman','procurement','storekeeper')
    or created_by = (select auth.uid())
    or exists (
      select 1 from public.project_members pm
      where pm.project_id = projects.id and pm.profile_id = (select auth.uid())
    )
  )
);

drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects
for update to authenticated using (
  organization_id = public.current_user_organization_id()
  and (
    public.current_user_role() in ('owner','admin','project_manager','foreman')
    or exists (
      select 1 from public.project_members pm
      where pm.project_id = projects.id
        and pm.profile_id = (select auth.uid())
        and pm.project_role in ('manager','foreman')
    )
  )
) with check (organization_id = public.current_user_organization_id());

drop policy if exists tasks_read on public.tasks;
create policy tasks_read on public.tasks
for select to authenticated using (
  organization_id = public.current_user_organization_id()
  and (
    public.current_user_role() in ('owner','admin','project_manager','foreman')
    or assignee_id = (select auth.uid())
    or (select auth.uid()) = any(collaborators)
    or exists (
      select 1 from public.project_members pm
      where pm.project_id = tasks.project_id and pm.profile_id = (select auth.uid())
    )
  )
);

drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks
for update to authenticated using (
  organization_id = public.current_user_organization_id()
  and (
    public.current_user_role() in ('owner','admin','project_manager','foreman')
    or assignee_id = (select auth.uid())
  )
) with check (organization_id = public.current_user_organization_id());

drop policy if exists notifications_recipient_access on public.notifications;
create policy notifications_recipient_access on public.notifications
for select to authenticated using (
  organization_id = public.current_user_organization_id()
  and (
    recipient_id is null or recipient_id = (select auth.uid())
    or public.current_user_role() in ('owner','admin')
  )
);

drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
for update to authenticated using (
  organization_id = public.current_user_organization_id()
  and (
    recipient_id is null or recipient_id = (select auth.uid())
    or public.current_user_role() in ('owner','admin')
  )
) with check (organization_id = public.current_user_organization_id());

-- New functions created by the migration owner are private until explicitly
-- granted. Later migrations must grant only the intended callable RPCs.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;

-- Assertions: abort instead of reporting a successful but ineffective hotfix.
do $$
declare
  r record;
begin
  if public.current_user_role() is null then
    raise exception 'Security hotfix failed: current_user_role() still returns NULL';
  end if;

  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  loop
    if has_function_privilege('anon', r.oid, 'EXECUTE') then
      raise exception 'Security hotfix failed: anon can execute %', r.proname;
    end if;
  end loop;
end
$$;

commit;

notify pgrst, 'reload schema';
