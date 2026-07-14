-- Space Buro Project Cloud — Phase 1.11.1 service library and BOQ task engine
-- Build marker: SB-SEED-CTE-HOTFIX-20260715
--
-- Prerequisite: Phase 1.10 security hotfix.
-- Additive migration: existing clients, projects, estimates and tasks remain.

begin;

-- ---------------------------------------------------------------------------
-- 1. Unlimited bilingual hierarchy: the Space Buro service library.
-- ---------------------------------------------------------------------------

create table if not exists public.service_library_nodes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  parent_id uuid references public.service_library_nodes(id) on delete cascade,
  domain_code text not null,
  node_kind text not null default 'service',
  code text not null,
  name_ru text not null,
  name_en text not null,
  description_ru text,
  description_en text,
  default_unit text not null default 'item',
  default_cost numeric(16,2) not null default 0 check(default_cost >= 0),
  default_sale numeric(16,2) not null default 0 check(default_sale >= 0),
  default_duration_days numeric(10,2) not null default 0 check(default_duration_days >= 0),
  is_estimate_selectable boolean not null default true,
  include_children_default boolean not null default false,
  is_active boolean not null default true,
  version_no integer not null default 1 check(version_no > 0),
  sort_order integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id, code)
);

create table if not exists public.service_library_components (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  parent_node_id uuid not null references public.service_library_nodes(id) on delete cascade,
  component_node_id uuid references public.service_library_nodes(id) on delete cascade,
  material_id uuid references public.materials(id) on delete restrict,
  quantity_factor numeric(16,4) not null default 1 check(quantity_factor > 0),
  unit text not null default 'item',
  waste_percent numeric(8,3) not null default 0 check(waste_percent >= 0),
  default_cost numeric(16,2) not null default 0 check(default_cost >= 0),
  default_sale numeric(16,2) not null default 0 check(default_sale >= 0),
  is_optional boolean not null default false,
  sort_order integer not null default 0,
  comment_ru text,
  comment_en text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(num_nonnulls(component_node_id, material_id) = 1),
  check(component_node_id is null or component_node_id <> parent_node_id)
);

-- A node may create more than one task. Rules can be inherited by descendants.
create table if not exists public.service_task_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  catalog_node_id uuid references public.service_library_nodes(id) on delete cascade,
  domain_code text,
  rule_code text not null,
  task_type text not null,
  applies_to_descendants boolean not null default true,
  title_suffix_ru text,
  title_suffix_en text,
  default_duration_days numeric(10,2) not null default 0 check(default_duration_days >= 0),
  requires_verification boolean not null default true,
  priority integer not null default 100,
  is_active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(num_nonnulls(catalog_node_id, domain_code) = 1),
  unique(organization_id, rule_code)
);

create table if not exists public.estimate_task_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  estimate_record_id uuid not null references public.module_records(id) on delete cascade,
  estimate_line_id uuid references public.module_record_lines(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  rule_id uuid references public.service_task_rules(id) on delete set null,
  task_role text not null default 'execution',
  created_at timestamptz not null default now(),
  unique(task_id),
  unique(estimate_line_id, task_id)
);

create table if not exists public.task_status_transitions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  from_status text not null,
  to_status text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(organization_id, from_status, to_status)
);

alter table public.module_record_lines
  add column if not exists service_library_node_id uuid
    references public.service_library_nodes(id) on delete set null;
alter table public.module_record_lines
  add column if not exists catalog_snapshot jsonb not null default '{}'::jsonb;

alter table public.tasks add column if not exists source_estimate_record_id uuid
  references public.module_records(id) on delete set null;
alter table public.tasks add column if not exists source_estimate_line_id uuid
  references public.module_record_lines(id) on delete set null;
alter table public.tasks add column if not exists service_library_node_id uuid
  references public.service_library_nodes(id) on delete set null;
alter table public.tasks add column if not exists workflow_managed boolean not null default false;
alter table public.tasks add column if not exists workflow_version text;
alter table public.tasks add column if not exists generation_key text;

alter table public.task_dependencies add column if not exists source_estimate_record_id uuid
  references public.module_records(id) on delete set null;
alter table public.task_dependencies add column if not exists is_system_generated boolean not null default false;

create unique index if not exists uq_tasks_generation_key
  on public.tasks(organization_id, generation_key) where generation_key is not null;
create index if not exists idx_service_nodes_tree
  on public.service_library_nodes(organization_id, parent_id, sort_order);
create index if not exists idx_service_nodes_domain
  on public.service_library_nodes(organization_id, domain_code, is_active);
create index if not exists idx_service_components_parent
  on public.service_library_components(parent_node_id, sort_order);
create unique index if not exists uq_service_component_node
  on public.service_library_components(parent_node_id,component_node_id)
  where component_node_id is not null;
create unique index if not exists uq_service_component_material
  on public.service_library_components(parent_node_id,material_id)
  where material_id is not null;
create index if not exists idx_service_rules_node
  on public.service_task_rules(organization_id, catalog_node_id, is_active, priority);
create index if not exists idx_estimate_task_links_estimate
  on public.estimate_task_links(estimate_record_id, estimate_line_id);
create index if not exists idx_tasks_estimate_source
  on public.tasks(source_estimate_record_id, source_estimate_line_id, task_type);
create index if not exists idx_task_dependencies_predecessor_v111
  on public.task_dependencies(predecessor_task_id, successor_task_id);

-- ---------------------------------------------------------------------------
-- 2. RLS and controlled catalog administration.
-- ---------------------------------------------------------------------------

alter table public.service_library_nodes enable row level security;
alter table public.service_library_components enable row level security;
alter table public.service_task_rules enable row level security;
alter table public.estimate_task_links enable row level security;
alter table public.task_status_transitions enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'service_library_nodes','service_library_components','service_task_rules',
    'estimate_task_links','task_status_transitions'
  ] loop
    execute format('drop policy if exists %I_org_select_v111 on public.%I', t, t);
    execute format(
      'create policy %I_org_select_v111 on public.%I for select to authenticated using (organization_id = public.current_user_organization_id())',
      t, t
    );
  end loop;

  foreach t in array array[
    'service_library_nodes','service_library_components','service_task_rules'
  ] loop
    execute format('drop policy if exists %I_org_insert_v111 on public.%I', t, t);
    execute format('drop policy if exists %I_org_update_v111 on public.%I', t, t);
    execute format('drop policy if exists %I_org_delete_v111 on public.%I', t, t);
    execute format(
      'create policy %I_org_insert_v111 on public.%I for insert to authenticated with check (organization_id = public.current_user_organization_id() and public.current_user_role() = any(array[''owner'',''admin'',''accountant'',''project_manager'',''designer'']))',
      t, t
    );
    execute format(
      'create policy %I_org_update_v111 on public.%I for update to authenticated using (organization_id = public.current_user_organization_id() and public.current_user_role() = any(array[''owner'',''admin'',''accountant'',''project_manager'',''designer''])) with check (organization_id = public.current_user_organization_id())',
      t, t
    );
    execute format(
      'create policy %I_org_delete_v111 on public.%I for delete to authenticated using (organization_id = public.current_user_organization_id() and public.current_user_role() = any(array[''owner'',''admin'',''project_manager'']))',
      t, t
    );
  end loop;
end
$$;

drop policy if exists task_status_transitions_org_insert_v111 on public.task_status_transitions;
drop policy if exists task_status_transitions_org_update_v111 on public.task_status_transitions;
drop policy if exists task_status_transitions_org_delete_v111 on public.task_status_transitions;
create policy task_status_transitions_org_insert_v111 on public.task_status_transitions
for insert to authenticated with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role()=any(array['owner','admin'])
);
create policy task_status_transitions_org_update_v111 on public.task_status_transitions
for update to authenticated using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role()=any(array['owner','admin'])
) with check (organization_id=public.current_user_organization_id());
create policy task_status_transitions_org_delete_v111 on public.task_status_transitions
for delete to authenticated using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role()=any(array['owner','admin'])
);

grant select, insert, update, delete on public.service_library_nodes,
  public.service_library_components, public.service_task_rules,
  public.task_status_transitions to authenticated;
grant select on public.estimate_task_links to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Hierarchy and task state-machine safeguards.
-- ---------------------------------------------------------------------------

create or replace function public.prevent_service_library_cycle_v111()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.parent_id is null then return new; end if;
  if new.parent_id = new.id then raise exception 'A catalog node cannot be its own parent'; end if;
  if exists (
    with recursive descendants(id) as (
      select n.id from public.service_library_nodes n where n.parent_id = new.id
      union all
      select n.id from public.service_library_nodes n join descendants d on n.parent_id = d.id
    )
    select 1 from descendants where id = new.parent_id
  ) then
    raise exception 'Catalog hierarchy cycle detected';
  end if;
  return new;
end
$$;

drop trigger if exists service_library_cycle_v111 on public.service_library_nodes;
create trigger service_library_cycle_v111
before insert or update of parent_id on public.service_library_nodes
for each row execute function public.prevent_service_library_cycle_v111();

create or replace function public.task_has_open_dependencies_v111(p_task_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1
    from public.task_dependencies d
    join public.tasks predecessor on predecessor.id = d.predecessor_task_id
    join public.tasks successor on successor.id = d.successor_task_id
    where d.successor_task_id = p_task_id
      and predecessor.organization_id = successor.organization_id
      and predecessor.status not in ('done','accepted','completed')
  )
$$;

create or replace function public.validate_task_state_v111()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not coalesce(new.workflow_managed, false) then return new; end if;

  if new.status not in ('created','blocked','in_progress','review','done','accepted') then
    raise exception 'Invalid managed task status: %', new.status;
  end if;

  if tg_op = 'INSERT' then return new; end if;
  if new.status is not distinct from old.status then return new; end if;

  if new.status in ('in_progress','review','done','accepted')
    and public.task_has_open_dependencies_v111(new.id) then
    if old.status = 'created' and new.status = 'in_progress' then
      new.status := 'blocked';
    else
      raise exception 'Task cannot advance while dependencies are open';
    end if;
  end if;

  if new.status = 'created' and public.task_has_open_dependencies_v111(new.id) then
    raise exception 'Task still has open dependencies';
  end if;

  if not exists(
    select 1 from public.task_status_transitions t
    where t.organization_id = new.organization_id
      and t.from_status = old.status and t.to_status = new.status and t.is_active
  ) then
    raise exception 'Task transition % -> % is not allowed', old.status, new.status;
  end if;

  if new.status in ('done','accepted') then new.progress := 100; end if;
  if new.status = 'accepted' then
    new.verified_by := coalesce(new.verified_by, auth.uid());
    new.verified_at := coalesce(new.verified_at, now());
    new.actual_completed_at := coalesce(new.actual_completed_at, now());
  end if;
  return new;
end
$$;

drop trigger if exists tasks_state_machine_v111 on public.tasks;
create trigger tasks_state_machine_v111
before insert or update of status on public.tasks
for each row execute function public.validate_task_state_v111();

create or replace function public.refresh_task_dependency_state_v111(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare t public.tasks%rowtype; v_open boolean;
begin
  select * into t from public.tasks where id = p_task_id for update;
  if t.id is null or not t.workflow_managed or t.status not in ('created','blocked') then return; end if;
  v_open := public.task_has_open_dependencies_v111(t.id);
  if v_open and t.status = 'created' then
    update public.tasks set status = 'blocked', updated_at = now() where id = t.id;
  elsif not v_open and t.status = 'blocked' then
    update public.tasks set status = 'created', updated_at = now() where id = t.id;
  end if;
end
$$;

create or replace function public.prevent_task_dependency_cycle_v111()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.predecessor_task_id = new.successor_task_id then
    raise exception 'A task cannot depend on itself';
  end if;
  if not exists(
    select 1 from public.tasks predecessor
    join public.tasks successor on successor.id=new.successor_task_id
    where predecessor.id=new.predecessor_task_id
      and predecessor.organization_id=new.organization_id
      and successor.organization_id=new.organization_id
  ) then
    raise exception 'Both dependency tasks must belong to the same organization';
  end if;
  if exists(
    with recursive path(task_id) as (
      select new.successor_task_id
      union
      select d.successor_task_id
      from public.task_dependencies d join path p on d.predecessor_task_id = p.task_id
      where tg_op = 'INSERT' or d.id <> new.id
    )
    select 1 from path where task_id = new.predecessor_task_id
  ) then
    raise exception 'Task dependency cycle detected';
  end if;
  return new;
end
$$;

drop trigger if exists task_dependencies_cycle_v111 on public.task_dependencies;
create trigger task_dependencies_cycle_v111
before insert or update of predecessor_task_id, successor_task_id on public.task_dependencies
for each row execute function public.prevent_task_dependency_cycle_v111();

create or replace function public.refresh_dependency_after_change_v111()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.refresh_task_dependency_state_v111(
    case when tg_op = 'DELETE' then old.successor_task_id else new.successor_task_id end
  );
  return case when tg_op = 'DELETE' then old else new end;
end
$$;

drop trigger if exists task_dependencies_refresh_v111 on public.task_dependencies;
create trigger task_dependencies_refresh_v111
after insert or update or delete on public.task_dependencies
for each row execute function public.refresh_dependency_after_change_v111();

create or replace function public.refresh_successors_after_task_v111()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare r record;
begin
  if new.status is not distinct from old.status then return new; end if;
  for r in select successor_task_id from public.task_dependencies where predecessor_task_id = new.id loop
    perform public.refresh_task_dependency_state_v111(r.successor_task_id);
  end loop;
  return new;
end
$$;

drop trigger if exists tasks_refresh_successors_v111 on public.tasks;
create trigger tasks_refresh_successors_v111
after update of status on public.tasks
for each row execute function public.refresh_successors_after_task_v111();

-- ---------------------------------------------------------------------------
-- 4. Idempotent estimate -> task engine.
-- ---------------------------------------------------------------------------

create or replace function public.upsert_estimate_task_v111(
  p_estimate_id uuid,
  p_line_id uuid,
  p_rule_id uuid,
  p_task_type text,
  p_suffix_ru text default null,
  p_duration_days numeric default 0,
  p_requires_verification boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.module_records%rowtype;
  l public.module_record_lines%rowtype;
  v_task uuid;
  v_key text;
  v_title text;
  v_due date;
begin
  select * into e from public.module_records where id = p_estimate_id and module_code = 'estimates';
  select * into l from public.module_record_lines where id = p_line_id and record_id = p_estimate_id;
  if e.id is null or l.id is null then raise exception 'Estimate line not found'; end if;

  v_key := 'estimate:' || e.id || ':line:' || l.id || ':rule:' || coalesce(p_rule_id::text, p_task_type);
  v_title := l.name || case when coalesce(p_suffix_ru,'') = '' then '' else ' · ' || p_suffix_ru end;
  v_due := coalesce(l.planned_finish,
    case when l.planned_start is not null and coalesce(p_duration_days,0) > 0
      then l.planned_start + ceil(p_duration_days)::integer else null end);

  insert into public.tasks(
    organization_id, project_id, title, description, assignee_id, start_date, due_date,
    priority, status, progress, cost, requires_verification, created_by, creator_id,
    task_type, entity_type, entity_id, source_estimate_record_id, source_estimate_line_id,
    service_library_node_id, workflow_managed, workflow_version, generation_key
  ) values(
    e.organization_id, e.project_id, v_title, l.description, l.responsible_id,
    l.planned_start, v_due,
    case when e.priority in ('low','normal','high','critical') then e.priority else 'normal' end,
    'created', 0, round(coalesce(l.quantity,0) * coalesce(l.unit_cost,0),2),
    p_requires_verification, auth.uid(), auth.uid(), p_task_type,
    'estimate_line', l.id, e.id, l.id, l.service_library_node_id,
    true, '1.11', v_key
  )
  on conflict(organization_id, generation_key) where generation_key is not null do update set
    project_id = excluded.project_id,
    title = excluded.title,
    description = excluded.description,
    assignee_id = excluded.assignee_id,
    start_date = excluded.start_date,
    due_date = excluded.due_date,
    cost = excluded.cost,
    requires_verification = excluded.requires_verification,
    service_library_node_id = excluded.service_library_node_id,
    workflow_version = excluded.workflow_version,
    updated_at = now()
  returning id into v_task;

  insert into public.estimate_task_links(
    organization_id, estimate_record_id, estimate_line_id, task_id, rule_id, task_role
  ) values(e.organization_id, e.id, l.id, v_task, p_rule_id, p_task_type)
  on conflict(task_id) do update set rule_id = excluded.rule_id, task_role = excluded.task_role;

  update public.module_record_lines
  set linked_task_id = coalesce(linked_task_id, v_task), updated_at = now()
  where id = l.id;

  return v_task;
end
$$;

create or replace function public.generate_estimate_tasks_v111(p_estimate_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_role text := public.current_user_role();
  e public.module_records%rowtype;
  l public.module_record_lines%rowtype;
  r record;
  v_task uuid;
  v_first_task uuid;
  v_handover uuid;
  v_domain text;
  v_fallback_type text;
  v_rules integer;
  v_created integer := 0;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not coalesce(v_role = any(array['owner','admin','accountant','project_manager','procurement']), false) then
    raise exception 'Not allowed to generate estimate tasks';
  end if;

  select * into e from public.module_records
  where id = p_estimate_id and organization_id = v_org and module_code = 'estimates'
    and deleted_at is null for update;
  if e.id is null then raise exception 'Estimate not found'; end if;
  if e.project_id is null then raise exception 'Estimate must be linked to a project'; end if;
  if not public.can_access_project_v19(e.project_id) then raise exception 'Project access denied'; end if;
  if e.status not in ('agreed','approved','confirmed') then
    raise exception 'Estimate must be confirmed before task generation';
  end if;

  for l in
    select * from public.module_record_lines
    where record_id = e.id
      and line_type not in ('section','subsection','heading','note')
      and lower(coalesce(data->>'exclude_from_tasks','false')) not in ('true','1','yes')
    order by sort_order, created_at, id
  loop
    v_first_task := null;
    v_rules := 0;
    select coalesce(n.domain_code, l.data->>'service_domain') into v_domain
    from public.service_library_nodes n where n.id = l.service_library_node_id;

    for r in
      with recursive lineage(id,parent_id,depth) as (
        select n.id,n.parent_id,0 from public.service_library_nodes n
        where n.id = l.service_library_node_id and n.organization_id = v_org
        union all
        select p.id,p.parent_id,x.depth+1
        from public.service_library_nodes p join lineage x on x.parent_id = p.id
      ), candidates as (
        select rule.*, coalesce(lineage.depth,100000) as depth
        from public.service_task_rules rule
        left join lineage on lineage.id = rule.catalog_node_id
        where rule.organization_id = v_org and rule.is_active
          and (
            (lineage.id is not null and (lineage.depth = 0 or rule.applies_to_descendants))
            or (rule.domain_code is not null and rule.domain_code = v_domain)
          )
      )
      select distinct on (task_type) * from candidates
      order by task_type, depth, priority desc, created_at, id
    loop
      v_task := public.upsert_estimate_task_v111(
        e.id,l.id,r.id,r.task_type,r.title_suffix_ru,
        coalesce(nullif(r.default_duration_days,0),
          (select default_duration_days from public.service_library_nodes where id=l.service_library_node_id),0),
        r.requires_verification
      );
      v_first_task := coalesce(v_first_task,v_task);
      v_rules := v_rules + 1;
      v_created := v_created + 1;
    end loop;

    if v_rules = 0 then
      v_fallback_type := case
        when l.line_type = 'material' then 'procurement'
        when v_domain = 'documentation' then 'documentation'
        when v_domain = 'design' then 'design'
        when v_domain = 'furniture' then 'production'
        when v_domain = 'materials' then 'procurement'
        else 'construction'
      end;
      v_task := public.upsert_estimate_task_v111(e.id,l.id,null,v_fallback_type,null,0,true);
      v_first_task := v_task;
      v_created := v_created + 1;
    end if;

    update public.module_record_lines set linked_task_id = v_first_task where id = l.id;
  end loop;

  -- Design for one BOQ line blocks construction/production for the same line.
  insert into public.task_dependencies(
    organization_id, predecessor_task_id, successor_task_id, dependency_type,
    comment, source_estimate_record_id, is_system_generated
  )
  select e.organization_id, design_task.id, execution_task.id, 'finish_to_start',
    'Design approval blocks construction/production for the same BOQ item', e.id, true
  from public.tasks design_task
  join public.tasks execution_task
    on execution_task.source_estimate_line_id = design_task.source_estimate_line_id
   and execution_task.organization_id = design_task.organization_id
  where design_task.source_estimate_record_id = e.id and design_task.task_type = 'design'
    and execution_task.task_type in ('construction','production')
  on conflict(predecessor_task_id,successor_task_id) do nothing;

  -- A material child line blocks the execution task of its parent BOQ line.
  insert into public.task_dependencies(
    organization_id, predecessor_task_id, successor_task_id, dependency_type,
    comment, source_estimate_record_id, is_system_generated
  )
  select e.organization_id, procurement_task.id, execution_task.id, 'finish_to_start',
    'Material procurement blocks the related execution task', e.id, true
  from public.tasks procurement_task
  join public.module_record_lines material_line
    on material_line.id=procurement_task.source_estimate_line_id
  join public.tasks execution_task
    on execution_task.source_estimate_line_id=material_line.parent_line_id
   and execution_task.organization_id=procurement_task.organization_id
  where procurement_task.source_estimate_record_id=e.id
    and procurement_task.task_type='procurement'
    and execution_task.task_type in ('construction','production')
  on conflict(predecessor_task_id,successor_task_id) do nothing;

  -- One project handover task; every present and future project task blocks it.
  insert into public.tasks(
    organization_id,project_id,title,description,priority,status,progress,
    requires_verification,created_by,creator_id,task_type,entity_type,entity_id,
    source_estimate_record_id,workflow_managed,workflow_version,generation_key
  ) values(
    e.organization_id,e.project_id,'Сдача проекта / Project handover',
    'Финальная сдача доступна после завершения всех задач проекта.',
    'high','created',0,true,auth.uid(),auth.uid(),'handover','project',e.project_id,
    e.id,true,'1.11','project:'||e.project_id||':handover'
  )
  on conflict(organization_id,generation_key) where generation_key is not null do update set
    source_estimate_record_id = excluded.source_estimate_record_id,
    workflow_version = excluded.workflow_version,
    updated_at = now()
  returning id into v_handover;

  insert into public.estimate_task_links(
    organization_id,estimate_record_id,estimate_line_id,task_id,rule_id,task_role
  ) values(e.organization_id,e.id,null,v_handover,null,'handover')
  on conflict(task_id) do update set estimate_record_id=excluded.estimate_record_id;

  insert into public.task_dependencies(
    organization_id,predecessor_task_id,successor_task_id,dependency_type,
    comment,source_estimate_record_id,is_system_generated
  )
  select e.organization_id,t.id,v_handover,'finish_to_start',
    'Project handover waits for every project task',e.id,true
  from public.tasks t
  where t.project_id=e.project_id and t.id<>v_handover and t.task_type<>'handover'
  on conflict(predecessor_task_id,successor_task_id) do nothing;

  for r in select id from public.tasks where project_id=e.project_id and workflow_managed loop
    perform public.refresh_task_dependency_state_v111(r.id);
  end loop;

  return jsonb_build_object(
    'estimate_id',e.id,'project_id',e.project_id,'tasks_processed',v_created,
    'handover_task_id',v_handover,'workflow_version','1.11'
  );
end
$$;

-- Add checked library nodes to a draft BOQ. Catalog names and prices are copied
-- as a snapshot, so later catalog edits never rewrite an existing estimate.
create or replace function public.add_service_nodes_to_estimate_v111(
  p_estimate_id uuid,
  p_node_ids uuid[],
  p_include_children boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid:=public.current_user_organization_id();
  v_role text:=public.current_user_role();
  e public.module_records%rowtype;
  r record;
  c record;
  v_parent_line uuid;
  v_line uuid;
  v_line_map jsonb:='{}'::jsonb;
  v_count integer:=0;
  v_material_count integer:=0;
begin
  if auth.uid() is null then raise exception 'Not authenticated';end if;
  if not coalesce(v_role=any(array['owner','admin','accountant','project_manager','designer','procurement']),false) then
    raise exception 'Not allowed to edit estimates';
  end if;
  if coalesce(array_length(p_node_ids,1),0)=0 then raise exception 'Select at least one library item';end if;

  select * into e from public.module_records
  where id=p_estimate_id and organization_id=v_org and module_code='estimates'
    and deleted_at is null for update;
  if e.id is null then raise exception 'Estimate not found';end if;
  if e.status in ('agreed','approved','confirmed','archived','superseded') then
    raise exception 'Approved estimate is immutable; create a new version';
  end if;
  if e.project_id is not null and not public.can_access_project_v19(e.project_id) then
    raise exception 'Project access denied';
  end if;

  for r in
    with recursive tree(id,parent_in_selection,depth) as (
      select n.id,null::uuid,0
      from public.service_library_nodes n
      where n.organization_id=v_org and n.id=any(p_node_ids) and n.is_active
      union
      select child.id,parent.id,parent.depth+1
      from public.service_library_nodes child
      join tree parent on child.parent_id=parent.id
      where p_include_children and child.organization_id=v_org and child.is_active
    ), selected as (
      -- Preserve the deepest path if both a parent and child were selected.
      select distinct on(id) id as source_node_id,parent_in_selection as source_parent_id,depth
      from tree order by id,depth desc
    )
    select selected.source_node_id,selected.source_parent_id,selected.depth,n.*
    from selected join public.service_library_nodes n on n.id=selected.source_node_id
    order by selected.depth,n.sort_order,n.code
  loop
    v_parent_line:=nullif(v_line_map->>r.source_parent_id::text,'')::uuid;
    insert into public.module_record_lines(
      organization_id,record_id,parent_line_id,line_type,code,name,description,
      quantity,unit,unit_cost,unit_sale,planned_amount,status,sort_order,data,
      service_library_node_id,catalog_snapshot
    ) values(
      v_org,e.id,v_parent_line,
      case when r.node_kind in ('domain','section','subsection','software') then 'section'
        when r.domain_code='materials' then 'material' else 'work' end,
      r.code,r.name_ru,r.description_ru,1,r.default_unit,r.default_cost,r.default_sale,
      r.default_sale,'draft',coalesce((select max(sort_order)+1 from public.module_record_lines where record_id=e.id),1),
      jsonb_build_object('service_domain',r.domain_code,'name_en',r.name_en,'catalog_version',r.version_no,'builder','1.11'),
      r.id,
      jsonb_build_object('code',r.code,'name_ru',r.name_ru,'name_en',r.name_en,
        'unit',r.default_unit,'cost',r.default_cost,'sale',r.default_sale,'version',r.version_no)
    ) returning id into v_line;
    v_line_map:=v_line_map||jsonb_build_object(r.id::text,v_line);
    v_count:=v_count+1;

    -- Reusable child nodes: document workflow steps and furniture operations.
    for c in
      select component.id as component_id,
        component.quantity_factor as component_quantity,
        component.unit as component_unit,
        component.default_cost as component_cost,
        component.default_sale as component_sale,
        n.id as node_id,n.code,n.name_ru,n.name_en,n.description_ru,
        n.domain_code,n.version_no,n.default_unit,n.default_cost,n.default_sale
      from public.service_library_components component
      join public.service_library_nodes n on n.id=component.component_node_id
      where component.parent_node_id=r.id and component.component_node_id is not null and n.is_active
      order by component.sort_order,n.sort_order
    loop
      insert into public.module_record_lines(
        organization_id,record_id,parent_line_id,line_type,code,name,description,
        quantity,unit,unit_cost,unit_sale,planned_amount,status,sort_order,data,
        service_library_node_id,catalog_snapshot
      ) values(
        v_org,e.id,v_line,'work',c.code,c.name_ru,c.description_ru,
        c.component_quantity,coalesce(nullif(c.component_unit,''),c.default_unit),
        coalesce(nullif(c.component_cost,0),c.default_cost,0),
        coalesce(nullif(c.component_sale,0),c.default_sale,0),
        c.component_quantity*coalesce(nullif(c.component_sale,0),c.default_sale,0),
        'draft',coalesce((select max(sort_order)+1 from public.module_record_lines where record_id=e.id),1),
        jsonb_build_object('service_domain',c.domain_code,'name_en',c.name_en,'catalog_version',c.version_no,'component_of',r.id,'source_component_id',c.component_id,'builder','1.11'),
        c.node_id,
        jsonb_build_object('code',c.code,'name_ru',c.name_ru,'name_en',c.name_en,
          'unit',coalesce(nullif(c.component_unit,''),c.default_unit),
          'cost',coalesce(nullif(c.component_cost,0),c.default_cost,0),
          'sale',coalesce(nullif(c.component_sale,0),c.default_sale,0),'version',c.version_no)
      );
      v_count:=v_count+1;
    end loop;

    -- Material components reference the existing unified material catalog.
    for c in
      select component.*,m.code as material_code,m.name as material_name,
        m.unit as material_unit,m.purchase_price,m.sale_price
      from public.service_library_components component
      join public.materials m on m.id=component.material_id
      where component.parent_node_id=r.id and component.material_id is not null
      order by component.sort_order,m.name
    loop
      insert into public.module_record_lines(
        organization_id,record_id,parent_line_id,line_type,code,name,description,material_id,
        quantity,unit,unit_cost,unit_sale,planned_amount,status,sort_order,data,catalog_snapshot
      ) values(
        v_org,e.id,v_line,'material',c.material_code,c.material_name,c.comment_ru,c.material_id,
        c.quantity_factor*(1+c.waste_percent/100),coalesce(nullif(c.unit,''),c.material_unit,'pcs'),
        coalesce(nullif(c.default_cost,0),c.purchase_price,0),
        coalesce(nullif(c.default_sale,0),c.sale_price,c.purchase_price,0),
        c.quantity_factor*coalesce(nullif(c.default_sale,0),c.sale_price,c.purchase_price,0),
        'draft',coalesce((select max(sort_order)+1 from public.module_record_lines where record_id=e.id),1),
        jsonb_build_object('source_component_id',c.id,'waste_percent',c.waste_percent,'service_domain','materials','builder','1.11'),
        jsonb_build_object('material_id',c.material_id,'name',c.material_name,'unit',c.material_unit,
          'cost',coalesce(nullif(c.default_cost,0),c.purchase_price,0),
          'sale',coalesce(nullif(c.default_sale,0),c.sale_price,c.purchase_price,0))
      );
      v_material_count:=v_material_count+1;
    end loop;
  end loop;

  update public.module_records set
    cost_amount=coalesce((select sum(quantity*unit_cost) from public.module_record_lines where record_id=e.id and line_type not in ('section','subsection')),0),
    sale_amount=coalesce((select sum(quantity*unit_sale) from public.module_record_lines where record_id=e.id and line_type not in ('section','subsection')),0),
    planned_amount=coalesce((select sum(quantity*unit_sale) from public.module_record_lines where record_id=e.id and line_type not in ('section','subsection')),0),
    updated_at=now()
  where id=e.id;

  return jsonb_build_object('estimate_id',e.id,'catalog_lines',v_count,'material_lines',v_material_count);
end
$$;

create or replace function public.generate_tasks_on_estimate_confirmation_v111()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.module_code = 'estimates' and new.status in ('agreed','approved','confirmed') then
    if tg_op = 'INSERT' then
      perform public.generate_estimate_tasks_v111(new.id);
    elsif old.status not in ('agreed','approved','confirmed') then
      perform public.generate_estimate_tasks_v111(new.id);
    end if;
  end if;
  return new;
end
$$;

drop trigger if exists estimates_generate_tasks_v111 on public.module_records;
create trigger estimates_generate_tasks_v111
after insert or update of status on public.module_records
for each row execute function public.generate_tasks_on_estimate_confirmation_v111();

-- Any later manual project task must also block the project handover.
create or replace function public.attach_new_task_to_handover_v111()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_handover uuid;
begin
  if new.project_id is null or new.task_type = 'handover' then return new; end if;
  select id into v_handover from public.tasks
  where project_id=new.project_id and task_type='handover' and workflow_managed
  order by created_at limit 1;
  if v_handover is not null then
    insert into public.task_dependencies(
      organization_id,predecessor_task_id,successor_task_id,dependency_type,
      comment,source_estimate_record_id,is_system_generated
    ) values(
      new.organization_id,new.id,v_handover,'finish_to_start',
      'New project task automatically blocks handover',new.source_estimate_record_id,true
    ) on conflict(predecessor_task_id,successor_task_id) do nothing;
  end if;
  return new;
end
$$;

drop trigger if exists tasks_attach_handover_v111 on public.tasks;
create trigger tasks_attach_handover_v111
after insert on public.tasks
for each row execute function public.attach_new_task_to_handover_v111();

-- Internal helpers cannot be called through PostgREST.
revoke execute on function public.upsert_estimate_task_v111(uuid,uuid,uuid,text,text,numeric,boolean)
  from public,anon,authenticated;
revoke execute on function public.task_has_open_dependencies_v111(uuid)
  from public,anon,authenticated;
revoke execute on function public.prevent_service_library_cycle_v111()
  from public,anon,authenticated;
revoke execute on function public.prevent_task_dependency_cycle_v111()
  from public,anon,authenticated;
revoke execute on function public.refresh_task_dependency_state_v111(uuid)
  from public,anon,authenticated;
revoke execute on function public.validate_task_state_v111()
  from public,anon,authenticated;
revoke execute on function public.refresh_dependency_after_change_v111()
  from public,anon,authenticated;
revoke execute on function public.refresh_successors_after_task_v111()
  from public,anon,authenticated;
revoke execute on function public.attach_new_task_to_handover_v111()
  from public,anon,authenticated;
revoke execute on function public.generate_tasks_on_estimate_confirmation_v111()
  from public,anon,authenticated;
revoke execute on function public.generate_estimate_tasks_v111(uuid) from public,anon;
grant execute on function public.generate_estimate_tasks_v111(uuid) to authenticated;
revoke execute on function public.add_service_nodes_to_estimate_v111(uuid,uuid[],boolean) from public,anon;
grant execute on function public.add_service_nodes_to_estimate_v111(uuid,uuid[],boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Initial bilingual service bible. Everything remains editable in settings.
-- ---------------------------------------------------------------------------

with sb_service_seed_v111(
  code,parent_code,domain_code,node_kind,
  name_ru,name_en,unit,duration,selectable,sort_order
) as (values
('DOC',null,'documentation','domain','Документация и разрешения','Documentation and permits','item',0,false,10),
('DOC.WORKFLOW','DOC','documentation','section','Этапы получения документа','Document approval stages','item',0,false,10),
('DOC.WORKFLOW.REQUIREMENTS','DOC.WORKFLOW','documentation','stage','Сбор требований','Requirements collection','item',1,true,10),
('DOC.WORKFLOW.PREPARE','DOC.WORKFLOW','documentation','stage','Подготовка документов','Document preparation','item',2,true,20),
('DOC.WORKFLOW.DRAWINGS','DOC.WORKFLOW','documentation','stage','Чертежи для согласования','Approval drawings','item',3,true,30),
('DOC.WORKFLOW.SUBMIT','DOC.WORKFLOW','documentation','stage','Подача','Submission','item',1,true,40),
('DOC.WORKFLOW.REVIEW','DOC.WORKFLOW','documentation','stage','Рассмотрение','Authority review','item',5,true,50),
('DOC.WORKFLOW.CORRECT','DOC.WORKFLOW','documentation','stage','Исправление замечаний','Comment resolution','item',2,true,60),
('DOC.WORKFLOW.APPROVE','DOC.WORKFLOW','documentation','stage','Получение согласования','Approval receipt','item',1,true,70),
('DOC.PERMITS','DOC','documentation','section','Разрешения и согласования','Permits and approvals','item',0,false,20),
('DOC.PERMITS.FITOUT','DOC.PERMITS','documentation','document','Fit-out permit','Fit-out permit','item',10,true,10),
('DOC.PERMITS.NOC_BUILDING','DOC.PERMITS','documentation','document','NOC управляющей компании','Building management NOC','item',7,true,20),
('DOC.PERMITS.NOC_DEVELOPER','DOC.PERMITS','documentation','document','NOC девелопера','Developer NOC','item',7,true,30),
('DOC.PERMITS.DDA','DOC.PERMITS','documentation','document','Согласование DDA','DDA approval','item',14,true,40),
('DOC.PERMITS.DCD','DOC.PERMITS','documentation','document','Согласование DCD','DCD approval','item',14,true,50),
('DOC.PERMITS.DM','DOC.PERMITS','documentation','document','Согласование Dubai Municipality','Dubai Municipality approval','item',14,true,55),
('DOC.PERMITS.TRAKHEES','DOC.PERMITS','documentation','document','Согласование Trakhees','Trakhees approval','item',14,true,57),
('DOC.PERMITS.DEWA','DOC.PERMITS','documentation','document','Согласование DEWA','DEWA approval','item',14,true,58),
('DOC.PERMITS.DEMOLITION','DOC.PERMITS','documentation','document','Разрешение на демонтаж','Demolition permit','item',5,true,60),
('DOC.PERMITS.NOISE','DOC.PERMITS','documentation','document','Разрешение на шумные работы','Noise work permit','item',3,true,70),
('DOC.PERMITS.HOTWORK','DOC.PERMITS','documentation','document','Разрешение на огневые работы','Hot work permit','item',3,true,75),
('DOC.PERMITS.DELIVERY','DOC.PERMITS','documentation','document','Разрешение на доставку','Delivery permit','item',2,true,80),
('DOC.PERMITS.WASTE','DOC.PERMITS','documentation','document','Разрешение на вывоз мусора','Waste removal permit','item',3,true,90),
('DOC.PERMITS.PASSES','DOC.PERMITS','documentation','document','Пропуска сотрудников','Staff access passes','item',3,true,100),
('DOC.PERMITS.WORK','DOC.PERMITS','documentation','document','Разрешение на выполнение работ','Work permit','item',3,true,110),
('DOC.PERMITS.COMPLETION','DOC.PERMITS','documentation','document','Сертификат завершения','Completion certificate','item',7,true,120),
('DOC.COMPANY','DOC','documentation','section','Документы компании','Company documents','item',0,false,30),
('DOC.COMPANY.LICENSE','DOC.COMPANY','documentation','document','Trade license','Trade license','item',1,true,10),
('DOC.COMPANY.INSURANCE','DOC.COMPANY','documentation','document','Страхование','Insurance','item',3,true,20),
('DOC.COMPANY.DEPOSIT','DOC.COMPANY','documentation','document','Security deposit / cheque','Security deposit / cheque','item',1,true,30),
('DOC.COMPANY.METHOD','DOC.COMPANY','documentation','document','Методика производства работ','Method statement','item',3,true,40),
('DOC.COMPANY.RISK','DOC.COMPANY','documentation','document','Оценка рисков','Risk assessment','item',3,true,50),
('DOC.COMPANY.MATERIAL','DOC.COMPANY','documentation','document','Согласование материалов','Material submittal','item',5,true,60),

('DES',null,'design','domain','Проектирование и дизайн','Design and engineering','item',0,false,20),
('DES.SURVEY','DES','design','section','Замеры и обследование','Survey and site assessment','item',1,true,10),
('DES.CONCEPT','DES','design','section','Концепция и планировка','Concept and space planning','item',3,true,20),
('DES.CONCEPT.MOOD','DES.CONCEPT','design','stage','Moodboard и стиль','Moodboard and style','item',2,true,10),
('DES.CONCEPT.ZONING','DES.CONCEPT','design','stage','Зонирование','Space zoning','item',2,true,20),
('DES.CONCEPT.MATERIAL','DES.CONCEPT','design','stage','Концепция материалов','Material concept','item',2,true,30),
('DES.AUTOCAD','DES','design','software','AutoCAD и 2D-чертежи','AutoCAD and 2D drawings','item',0,false,25),
('DES.AUTOCAD.EXISTING','DES.AUTOCAD','design','stage','Обмерный план','Existing conditions plan','sheet',2,true,10),
('DES.AUTOCAD.DEMOLITION','DES.AUTOCAD','design','stage','План демонтажа','Demolition plan','sheet',2,true,20),
('DES.AUTOCAD.CONSTRUCTION','DES.AUTOCAD','design','stage','План возводимых конструкций','Construction layout','sheet',2,true,30),
('DES.AUTOCAD.FINISHES','DES.AUTOCAD','design','stage','План отделки','Finishes plan','sheet',2,true,40),
('DES.AUTOCAD.DETAILS','DES.AUTOCAD','design','stage','Развертки, узлы и детали','Elevations and details','sheet',4,true,50),
('DES.SKETCHUP','DES','design','software','SketchUp','SketchUp','item',0,false,30),
('DES.SKETCHUP.MODEL','DES.SKETCHUP','design','stage','3D-модель','3D model','item',3,true,10),
('DES.SKETCHUP.CLIENT','DES.SKETCHUP','design','stage','Чертежи для клиента','Client drawings','sheet',3,true,20),
('DES.SKETCHUP.REVISION','DES.SKETCHUP','design','stage','Правки','Revisions','item',2,true,30),
('DES.REVIT','DES','design','software','Revit','Revit','item',0,false,40),
('DES.REVIT.EXISTING','DES.REVIT','design','stage','Обмерный план','Existing conditions plan','sheet',2,true,10),
('DES.REVIT.LAYOUT','DES.REVIT','design','stage','Планировка','Layout plan','sheet',2,true,20),
('DES.REVIT.RCP','DES.REVIT','design','stage','План потолков','Reflected ceiling plan','sheet',2,true,30),
('DES.REVIT.ELECTRICAL','DES.REVIT','design','stage','План электрики','Electrical plan','sheet',3,true,40),
('DES.REVIT.PLUMBING','DES.REVIT','design','stage','План сантехники','Plumbing plan','sheet',3,true,50),
('DES.REVIT.DETAILS','DES.REVIT','design','stage','Узлы и детали','Details and sections','sheet',4,true,60),
('DES.3DSMAX','DES','design','software','3ds Max и визуализация','3ds Max and visualization','item',0,false,50),
('DES.3DSMAX.MODEL','DES.3DSMAX','design','stage','Моделирование','Modelling','item',3,true,10),
('DES.3DSMAX.MATERIALS','DES.3DSMAX','design','stage','Материалы и освещение','Materials and lighting','item',2,true,20),
('DES.3DSMAX.RENDER','DES.3DSMAX','design','stage','Рендер и постобработка','Render and post-production','image',3,true,30),
('DES.BASIS','DES','design','software','Базис-Мебельщик','Basis-Mebelshchik','item',0,false,60),
('DES.BASIS.MODEL','DES.BASIS','design','stage','Модель мебели','Furniture model','item',3,true,10),
('DES.BASIS.SHOP','DES.BASIS','design','stage','Производственные чертежи','Production drawings','sheet',4,true,20),
('DES.BASIS.CUTLIST','DES.BASIS','design','stage','Карта раскроя и присадка','Cut list and drilling','item',3,true,30),
('DES.BASIS.BOM','DES.BASIS','design','stage','Спецификация и BOM','Specification and BOM','item',2,true,40),
('DES.APPROVAL','DES','design','section','Согласование и версии','Approval and revisions','item',0,false,70),
('DES.APPROVAL.CLIENT','DES.APPROVAL','design','stage','Согласование клиента','Client approval','item',3,true,10),
('DES.APPROVAL.AUTHORITY','DES.APPROVAL','design','stage','Комплект для органов согласования','Authority submission package','item',4,true,15),
('DES.APPROVAL.PRODUCTION','DES.APPROVAL','design','stage','Выпуск в производство','Release for production','item',1,true,20),
('DES.SPEC','DES','design','section','Спецификации и ведомости','Schedules and specifications','item',0,false,80),
('DES.SPEC.FINISHES','DES.SPEC','design','stage','Ведомость отделки','Finishes schedule','item',2,true,10),
('DES.SPEC.LIGHTING','DES.SPEC','design','stage','Спецификация освещения','Lighting schedule','item',2,true,20),
('DES.SPEC.SANITARY','DES.SPEC','design','stage','Спецификация сантехники','Sanitary schedule','item',2,true,30),
('DES.SPEC.DOORS','DES.SPEC','design','stage','Ведомость дверей','Door schedule','item',2,true,40),

('CON',null,'construction','domain','Строительство и ремонт','Construction and fit-out','item',0,false,30),
('CON.PRELIM','CON','construction','section','Подготовительные работы','Preliminaries','job',2,true,10),
('CON.PRELIM.SURVEY','CON.PRELIM','construction','service','Обследование и разметка','Survey and setting out','job',1,true,10),
('CON.PRELIM.MOB','CON.PRELIM','construction','service','Мобилизация','Mobilization','job',1,true,20),
('CON.PRELIM.PROTECT','CON.PRELIM','construction','service','Защита существующей отделки','Protection of existing finishes','m2',1,true,30),
('CON.PRELIM.TEMP','CON.PRELIM','construction','service','Временное электроснабжение и вода','Temporary power and water','job',1,true,40),
('CON.PRELIM.HSE','CON.PRELIM','construction','service','HSE и организация площадки','HSE and site setup','job',1,true,50),
('CON.DEM','CON','construction','section','Демонтаж','Demolition','m2',3,true,20),
('CON.DEM.PARTITION','CON.DEM','construction','service','Демонтаж перегородок','Partition demolition','m2',2,true,10),
('CON.DEM.CEILING','CON.DEM','construction','service','Демонтаж потолков','Ceiling demolition','m2',2,true,20),
('CON.DEM.FLOOR','CON.DEM','construction','service','Демонтаж напольных покрытий','Floor finish removal','m2',2,true,30),
('CON.DEM.MEP','CON.DEM','construction','service','Демонтаж инженерных систем','MEP demolition','point',2,true,40),
('CON.DEM.WASTE','CON.DEM','construction','service','Погрузка и вывоз строительного мусора','Debris loading and disposal','trip',1,true,50),
('CON.CIVIL','CON','construction','section','Общестроительные работы','Civil works','m2',0,false,30),
('CON.CIVIL.BLOCK','CON.CIVIL','construction','service','Кладка блоков','Blockwork','m2',3,true,10),
('CON.CIVIL.PLASTER','CON.CIVIL','construction','service','Штукатурка','Plastering','m2',3,true,20),
('CON.CIVIL.SCREED','CON.CIVIL','construction','service','Стяжка пола','Floor screed','m2',3,true,30),
('CON.CIVIL.CONCRETE','CON.CIVIL','construction','service','Бетонные работы и ремонт','Concrete works and repair','m3',4,true,40),
('CON.CIVIL.OPENING','CON.CIVIL','construction','service','Проёмы и усиление','Openings and strengthening','item',4,true,50),
('CON.DRYWALL','CON','construction','section','Гипсокартон и потолки','Drywall and ceilings','m2',0,false,40),
('CON.DRYWALL.PARTITION','CON.DRYWALL','construction','service','Гипсокартонные перегородки','Gypsum partitions','m2',4,true,10),
('CON.DRYWALL.MR','CON.DRYWALL','construction','service','Влагостойкие перегородки','Moisture-resistant partitions','m2',4,true,15),
('CON.DRYWALL.CEILING','CON.DRYWALL','construction','service','Гипсокартонный потолок','Gypsum ceiling','m2',4,true,20),
('CON.DRYWALL.GRID','CON.DRYWALL','construction','service','Модульный потолок','Suspended grid ceiling','m2',3,true,30),
('CON.DRYWALL.ACCESS','CON.DRYWALL','construction','service','Ревизионные люки','Access panels','pcs',2,true,40),
('CON.WATERPROOF','CON','construction','section','Гидроизоляция','Waterproofing','m2',3,true,50),
('CON.WATERPROOF.WET','CON.WATERPROOF','construction','service','Гидроизоляция мокрых зон','Wet-area waterproofing','m2',3,true,10),
('CON.WATERPROOF.ROOF','CON.WATERPROOF','construction','service','Гидроизоляция кровли и террас','Roof and terrace waterproofing','m2',4,true,20),
('CON.WATERPROOF.TEST','CON.WATERPROOF','construction','stage','Испытание проливом','Flood test','item',2,true,30),
('CON.TILE','CON','construction','section','Плитка и камень','Tiling and stone','m2',0,false,60),
('CON.TILE.PORCELAIN','CON.TILE','construction','service','Укладка керамогранита','Porcelain tile installation','m2',4,true,10),
('CON.TILE.CERAMIC','CON.TILE','construction','service','Укладка керамической плитки','Ceramic tile installation','m2',4,true,15),
('CON.TILE.MARBLE','CON.TILE','construction','service','Укладка мрамора и камня','Marble and stone installation','m2',5,true,20),
('CON.TILE.MOSAIC','CON.TILE','construction','service','Укладка мозаики','Mosaic installation','m2',5,true,30),
('CON.TILE.GROUT','CON.TILE','construction','service','Затирка швов','Tile grouting','m2',2,true,40),
('CON.FLOOR','CON','construction','section','Напольные покрытия','Flooring','m2',0,false,70),
('CON.FLOOR.SPC','CON.FLOOR','construction','service','Укладка SPC','SPC flooring installation','m2',3,true,10),
('CON.FLOOR.PARQUET','CON.FLOOR','construction','service','Укладка паркета','Parquet installation','m2',4,true,20),
('CON.FLOOR.CARPET','CON.FLOOR','construction','service','Укладка ковролина','Carpet installation','m2',3,true,30),
('CON.FLOOR.SKIRTING','CON.FLOOR','construction','service','Монтаж плинтуса','Skirting installation','lm',2,true,40),
('CON.PAINT','CON','construction','section','Малярные работы','Painting works','m2',0,false,80),
('CON.PAINT.PREP','CON.PAINT','construction','subsection','Подготовка поверхности','Surface preparation','m2',2,true,10),
('CON.PAINT.REPAIR','CON.PAINT','construction','service','Ремонт трещин','Crack repair','lm',2,true,20),
('CON.PAINT.LEVEL_BASIC','CON.PAINT','construction','service','Базовое выравнивание','Basic wall levelling','m2',3,true,30),
('CON.PAINT.LEVEL_FULL','CON.PAINT','construction','service','Полное выравнивание','Full wall levelling','m2',5,true,40),
('CON.PAINT.MESH','CON.PAINT','construction','service','Армирующая сетка','Reinforcement mesh','m2',2,true,50),
('CON.PAINT.PUTTY','CON.PAINT','construction','service','Шпаклёвка','Skim coat / putty','m2',3,true,60),
('CON.PAINT.PRIMER','CON.PAINT','construction','service','Грунтовка','Primer','m2',1,true,70),
('CON.PAINT.EMULSION','CON.PAINT','construction','service','Emulsion paint','Emulsion paint','m2',3,true,80),
('CON.PAINT.PU','CON.PAINT','construction','service','PU-покраска','PU painting','m2',5,true,90),
('CON.PAINT.EPOXY','CON.PAINT','construction','service','Эпоксидная покраска','Epoxy painting','m2',4,true,100),
('CON.MEP','CON','construction','section','Инженерные системы','MEP systems','item',0,false,90),
('CON.MEP.ELECTRICAL','CON.MEP','construction','service','Электрика и освещение','Electrical and lighting','point',4,true,10),
('CON.MEP.ELECTRICAL.CONTAIN','CON.MEP.ELECTRICAL','construction','service','Кабельные трассы и закладные','Containment and conduits','lm',3,true,10),
('CON.MEP.ELECTRICAL.CABLE','CON.MEP.ELECTRICAL','construction','service','Прокладка кабелей','Cable installation','lm',3,true,20),
('CON.MEP.ELECTRICAL.DB','CON.MEP.ELECTRICAL','construction','service','Щиты и автоматические выключатели','Distribution boards and breakers','item',3,true,30),
('CON.MEP.ELECTRICAL.POINT','CON.MEP.ELECTRICAL','construction','service','Розетки и выключатели','Sockets and switches','point',2,true,40),
('CON.MEP.ELECTRICAL.LIGHT','CON.MEP.ELECTRICAL','construction','service','Светильники и управление','Lighting fixtures and controls','point',3,true,50),
('CON.MEP.ELECTRICAL.TEST','CON.MEP.ELECTRICAL','construction','stage','Испытания и ввод в эксплуатацию','Testing and commissioning','item',2,true,60),
('CON.MEP.PLUMBING','CON.MEP','construction','service','Сантехника','Plumbing','point',4,true,20),
('CON.MEP.PLUMBING.WATER','CON.MEP.PLUMBING','construction','service','Водоснабжение','Water supply pipework','point',3,true,10),
('CON.MEP.PLUMBING.DRAIN','CON.MEP.PLUMBING','construction','service','Канализация и дренаж','Drainage pipework','point',3,true,20),
('CON.MEP.PLUMBING.FIXTURE','CON.MEP.PLUMBING','construction','service','Сантехнические приборы','Sanitary fixtures','pcs',3,true,30),
('CON.MEP.PLUMBING.TEST','CON.MEP.PLUMBING','construction','stage','Опрессовка и испытания','Pressure testing','item',2,true,40),
('CON.MEP.HVAC','CON.MEP','construction','service','Кондиционирование','Air conditioning','item',5,true,30),
('CON.MEP.HVAC.DUCT','CON.MEP.HVAC','construction','service','Воздуховоды и изоляция','Ductwork and insulation','m2',4,true,10),
('CON.MEP.HVAC.PIPE','CON.MEP.HVAC','construction','service','Трубопроводы хладагента и дренаж','Refrigerant piping and drainage','lm',4,true,20),
('CON.MEP.HVAC.UNIT','CON.MEP.HVAC','construction','service','Монтаж оборудования HVAC','HVAC equipment installation','item',4,true,30),
('CON.MEP.HVAC.GRILLE','CON.MEP.HVAC','construction','service','Диффузоры и решётки','Diffusers and grilles','pcs',2,true,40),
('CON.MEP.HVAC.TAB','CON.MEP.HVAC','construction','stage','Балансировка и пусконаладка','Testing, adjusting and balancing','item',3,true,50),
('CON.MEP.VENT','CON.MEP','construction','service','Вентиляция','Ventilation','item',5,true,40),
('CON.MEP.FIRE','CON.MEP','construction','service','Противопожарные системы','Fire protection systems','item',5,true,50),
('CON.MEP.FIRE.ALARM','CON.MEP.FIRE','construction','service','Пожарная сигнализация','Fire alarm','point',4,true,10),
('CON.MEP.FIRE.SPRINKLER','CON.MEP.FIRE','construction','service','Спринклерная система','Fire sprinkler system','point',4,true,20),
('CON.MEP.LOWCURRENT','CON.MEP','construction','service','Слаботочные системы','Low-current systems','point',4,true,60),
('CON.MEP.LOWCURRENT.DATA','CON.MEP.LOWCURRENT','construction','service','Структурированная кабельная сеть','Structured cabling','point',3,true,10),
('CON.MEP.LOWCURRENT.CCTV','CON.MEP.LOWCURRENT','construction','service','CCTV','CCTV','point',3,true,20),
('CON.MEP.LOWCURRENT.ACCESS','CON.MEP.LOWCURRENT','construction','service','Контроль доступа','Access control','point',3,true,30),
('CON.SPECIAL','CON','construction','section','Специальные работы','Specialist works','item',0,false,100),
('CON.SPECIAL.GLASS','CON.SPECIAL','construction','service','Стеклянные работы','Glass works','m2',4,true,10),
('CON.SPECIAL.METAL','CON.SPECIAL','construction','service','Металлические работы','Metal works','kg',5,true,20),
('CON.SPECIAL.DOORS','CON.SPECIAL','construction','service','Двери','Doors','pcs',3,true,30),
('CON.EXTERNAL','CON','construction','section','Фасад и наружные работы','Facade and external works','m2',0,false,110),
('CON.EXTERNAL.FACADE','CON.EXTERNAL','construction','service','Фасадные покрытия','Facade finishes','m2',5,true,10),
('CON.EXTERNAL.PAVING','CON.EXTERNAL','construction','service','Мощение','External paving','m2',4,true,20),
('CON.EXTERNAL.LANDSCAPE','CON.EXTERNAL','construction','service','Благоустройство и озеленение','Landscaping','m2',5,true,30),
('CON.QC','CON','construction','section','Контроль качества и сдача','Quality control and handover','item',0,false,120),
('CON.QC.INSPECTION','CON.QC','construction','stage','Проверка качества','Quality inspection','item',2,true,10),
('CON.QC.SNAG','CON.QC','construction','stage','Исправление замечаний','Snag rectification','item',3,true,20),
('CON.QC.CLEAN','CON.QC','construction','stage','Финальная уборка','Final cleaning','item',2,true,30),
('CON.QC.ASBUILT','CON.QC','construction','stage','Исполнительная документация','As-built documentation','item',3,true,40),

('FUR',null,'furniture','domain','Мебельное производство','Furniture production','item',0,false,40),
('FUR.PRODUCTS','FUR','furniture','section','Типы мебели','Furniture types','item',0,false,10),
('FUR.PRODUCTS.KITCHEN','FUR.PRODUCTS','furniture','service','Кухни','Kitchens','item',0,true,10),
('FUR.PRODUCTS.WARDROBE','FUR.PRODUCTS','furniture','service','Гардеробные и шкафы','Wardrobes and closets','item',0,true,20),
('FUR.PRODUCTS.TV','FUR.PRODUCTS','furniture','service','ТВ-зоны','TV units','item',0,true,30),
('FUR.PRODUCTS.VANITY','FUR.PRODUCTS','furniture','service','Тумбы и vanity','Vanities and cabinets','item',0,true,40),
('FUR.PRODUCTS.PANELS','FUR.PRODUCTS','furniture','service','Стеновые панели','Wall panels','m2',0,true,50),
('FUR.PRODUCTS.DOORS','FUR.PRODUCTS','furniture','service','Мебельные двери','Furniture doors','pcs',0,true,60),
('FUR.PRODUCTS.CABINET','FUR.PRODUCTS','furniture','service','Встроенные тумбы и шкафы','Built-in cabinets','item',0,true,70),
('FUR.PRODUCTS.FREESTANDING','FUR.PRODUCTS','furniture','service','Отдельно стоящая мебель','Freestanding furniture','item',0,true,80),
('FUR.PRODUCTS.OFFICE','FUR.PRODUCTS','furniture','service','Офисная мебель','Office furniture','item',0,true,90),
('FUR.PRODUCTS.RESTAURANT','FUR.PRODUCTS','furniture','service','Мебель для ресторанов','Restaurant furniture','item',0,true,100),
('FUR.PRODUCTS.RETAIL','FUR.PRODUCTS','furniture','service','Мебель для магазинов','Retail furniture','item',0,true,110),
('FUR.PRODUCTS.UPHOLSTERY','FUR.PRODUCTS','furniture','service','Мягкая мебель','Upholstered furniture','item',0,true,120),
('FUR.PROCESS','FUR','furniture','section','Этапы производства','Production stages','item',0,false,20),
('FUR.PROCESS.SURVEY','FUR.PROCESS','furniture','stage','Замер','Survey','item',1,true,10),
('FUR.PROCESS.APPROVAL','FUR.PROCESS','furniture','stage','Согласование материалов','Material approval','item',2,true,20),
('FUR.PROCESS.SHOPDRAWING','FUR.PROCESS','furniture','stage','Shop drawings','Shop drawings','sheet',4,true,30),
('FUR.PROCESS.BOM','FUR.PROCESS','furniture','stage','BOM и карта раскроя','BOM and cutting list','item',3,true,40),
('FUR.PROCESS.MATERIALS','FUR.PROCESS','furniture','stage','Заказ и приём материалов','Material ordering and receipt','item',5,true,45),
('FUR.PROCESS.CUTTING','FUR.PROCESS','furniture','stage','Раскрой','Cutting','item',2,true,50),
('FUR.PROCESS.EDGE','FUR.PROCESS','furniture','stage','Кромление','Edge banding','item',2,true,60),
('FUR.PROCESS.CNC','FUR.PROCESS','furniture','stage','CNC и присадка','CNC and drilling','item',2,true,70),
('FUR.PROCESS.ASSEMBLY','FUR.PROCESS','furniture','stage','Сборка','Assembly','item',3,true,80),
('FUR.PROCESS.VENEER','FUR.PROCESS','furniture','stage','Прессование шпона и ламината','Veneer and laminate pressing','item',3,true,85),
('FUR.PROCESS.SANDING','FUR.PROCESS','furniture','stage','Шлифовка и подготовка','Sanding and preparation','item',3,true,87),
('FUR.PROCESS.FINISH','FUR.PROCESS','furniture','stage','Шпон и покраска','Veneer and painting','item',5,true,90),
('FUR.PROCESS.HARDWARE','FUR.PROCESS','furniture','stage','Установка фурнитуры','Hardware installation','item',2,true,100),
('FUR.PROCESS.ELECTRICAL','FUR.PROCESS','furniture','stage','LED и электрика мебели','Furniture LED and electrical','item',2,true,105),
('FUR.PROCESS.QC','FUR.PROCESS','furniture','stage','Контроль качества','Quality control','item',1,true,110),
('FUR.PROCESS.PACK','FUR.PROCESS','furniture','stage','Упаковка','Packing','item',1,true,120),
('FUR.PROCESS.DELIVERY','FUR.PROCESS','furniture','stage','Доставка','Delivery','item',1,true,130),
('FUR.PROCESS.INSTALL','FUR.PROCESS','furniture','stage','Монтаж','Installation','item',3,true,140),
('FUR.PROCESS.SNAG','FUR.PROCESS','furniture','stage','Исправление замечаний','Snag rectification','item',2,true,150),

('MAT',null,'materials','domain','Материалы и комплектующие','Materials and components','item',0,false,50),
('MAT.BUILDING','MAT','materials','section','Строительные материалы','Building materials','item',0,true,10),
('MAT.FURNITURE','MAT','materials','section','Мебельные материалы','Furniture materials','item',0,true,20),
('MAT.HARDWARE','MAT','materials','section','Фурнитура','Hardware','item',0,true,30),
('MAT.ELECTRICAL','MAT','materials','section','Электрические материалы','Electrical materials','item',0,true,35),
('MAT.PLUMBING','MAT','materials','section','Сантехнические материалы','Plumbing materials','item',0,true,37),
('MAT.FINISHES','MAT','materials','section','Отделочные материалы','Finishing materials','item',0,true,38),
('MAT.GLASS','MAT','materials','section','Стекло и зеркало','Glass and mirror','item',0,true,39),
('MAT.METAL','MAT','materials','section','Металл и профили','Metal and profiles','item',0,true,40),
('MAT.STONE','MAT','materials','section','Камень и кварц','Stone and quartz','item',0,true,41),
('MAT.LIGHTING','MAT','materials','section','Освещение','Lighting','item',0,true,42),
('MAT.CONSUMABLES','MAT','materials','section','Расходные и упаковочные материалы','Consumables and packaging','item',0,true,43),
('MAT.EQUIPMENT','MAT','materials','section','Инструменты и оборудование','Tools and equipment','item',0,true,50)
)

insert into public.service_library_nodes(
  organization_id,parent_id,domain_code,node_kind,code,name_ru,name_en,
  default_unit,default_duration_days,is_estimate_selectable,include_children_default,
  sort_order,metadata
)
select o.id,null,s.domain_code,s.node_kind,s.code,s.name_ru,s.name_en,s.unit,s.duration,
  s.selectable,s.node_kind in ('domain','section','software'),s.sort_order,
  jsonb_build_object('seed_parent_code',s.parent_code,'seed_version','1.11')
from public.organizations o cross join sb_service_seed_v111 s
on conflict(organization_id,code) do nothing;

update public.service_library_nodes child
set parent_id=parent.id,
  metadata=child.metadata||jsonb_build_object('seed_parent_applied',true),
  updated_at=now()
from public.service_library_nodes parent
where child.organization_id=parent.organization_id
  and child.metadata->>'seed_parent_code'=parent.code
  and coalesce(child.metadata->>'seed_parent_applied','false')<>'true'
  and child.parent_id is distinct from parent.id;

insert into public.service_task_rules(
  organization_id,catalog_node_id,rule_code,task_type,applies_to_descendants,
  requires_verification,priority,metadata
)
select n.organization_id,n.id,'RULE-'||n.code,
  case n.domain_code when 'documentation' then 'documentation' when 'design' then 'design'
    when 'construction' then 'construction' when 'furniture' then 'production'
    when 'materials' then 'procurement' end,
  true,true,100,jsonb_build_object('seed_version','1.11')
from public.service_library_nodes n
where n.code in ('DOC','DES','CON','FUR','MAT')
on conflict(organization_id,rule_code) do nothing;

-- Furniture products create both a design task and a production task. The
-- design -> production dependency is derived by the engine from the same line.
insert into public.service_task_rules(
  organization_id,catalog_node_id,rule_code,task_type,applies_to_descendants,
  title_suffix_ru,title_suffix_en,requires_verification,priority,metadata
)
select n.organization_id,n.id,'RULE-FUR-PRODUCT-DESIGN','design',true,
  'проектирование','design',true,200,jsonb_build_object('seed_version','1.11')
from public.service_library_nodes n where n.code='FUR.PRODUCTS'
on conflict(organization_id,rule_code) do nothing;

-- Reusable document approval steps and furniture production stages.
insert into public.service_library_components(
  organization_id,parent_node_id,component_node_id,quantity_factor,unit,sort_order,metadata
)
select parent.organization_id,parent.id,step.id,1,step.default_unit,step.sort_order,
  jsonb_build_object('seed_version','1.11','component_template','document_workflow')
from public.service_library_nodes parent
join public.service_library_nodes step on step.organization_id=parent.organization_id
where (parent.code like 'DOC.PERMITS.%' or parent.code like 'DOC.COMPANY.%')
  and step.code like 'DOC.WORKFLOW.%' and step.node_kind='stage'
on conflict(parent_node_id,component_node_id) where component_node_id is not null do nothing;

insert into public.service_library_components(
  organization_id,parent_node_id,component_node_id,quantity_factor,unit,sort_order,metadata
)
select product.organization_id,product.id,step.id,1,step.default_unit,step.sort_order,
  jsonb_build_object('seed_version','1.11','component_template','furniture_production')
from public.service_library_nodes product
join public.service_library_nodes step on step.organization_id=product.organization_id
where product.code like 'FUR.PRODUCTS.%'
  and step.code like 'FUR.PROCESS.%' and step.node_kind='stage'
on conflict(parent_node_id,component_node_id) where component_node_id is not null do nothing;

insert into public.task_status_transitions(organization_id,from_status,to_status)
select o.id,v.from_status,v.to_status
from public.organizations o cross join (values
  ('created','blocked'),('blocked','created'),('created','in_progress'),
  ('in_progress','review'),('review','done'),('done','accepted')
) v(from_status,to_status)
on conflict(organization_id,from_status,to_status) do nothing;

-- Reuse the common timestamp trigger.
do $$
declare t text;
begin
  foreach t in array array[
    'service_library_nodes','service_library_components','service_task_rules'
  ] loop
    execute format('drop trigger if exists %I_touch_updated_at on public.%I',t,t);
    execute format('create trigger %I_touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()',t,t);
  end loop;
end
$$;

-- Assertions prevent a partial "Success" result.
do $$
declare r record;
begin
  if not exists(select 1 from public.service_library_nodes where code='DOC')
    or not exists(select 1 from public.service_library_nodes where code='DES')
    or not exists(select 1 from public.service_library_nodes where code='CON')
    or not exists(select 1 from public.service_library_nodes where code='FUR') then
    raise exception 'Phase 1.11 seed failed';
  end if;
  if has_function_privilege('anon','public.generate_estimate_tasks_v111(uuid)','EXECUTE') then
    raise exception 'Phase 1.11 security failed: anon can generate tasks';
  end if;
  if not exists(
    select 1 from public.service_library_components c
    join public.service_library_nodes p on p.id=c.parent_node_id
    join public.service_library_nodes n on n.id=c.component_node_id
    where p.code='DOC.PERMITS.FITOUT' and n.code='DOC.WORKFLOW.SUBMIT'
  ) then raise exception 'Phase 1.11 document workflow seed failed'; end if;
  if not exists(
    select 1 from public.task_status_transitions
    where from_status='review' and to_status='done' and is_active
  ) then raise exception 'Phase 1.11 task state machine seed failed'; end if;

  for r in
    select p.oid,p.proname
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and (p.proname like '%\_v111' escape '\'
        or p.proname in ('generate_tasks_on_estimate_confirmation_v111'))
  loop
    if has_function_privilege('anon',r.oid,'EXECUTE') then
      raise exception 'Phase 1.11 security failed: anon can execute %',r.proname;
    end if;
  end loop;
end
$$;

commit;

notify pgrst, 'reload schema';
