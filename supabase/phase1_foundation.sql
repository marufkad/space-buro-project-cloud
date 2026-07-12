-- Space Buro Project Cloud — Phase 1 foundation
-- Safe, additive migration for the existing Supabase project.
-- Existing project columns and records are preserved for backward compatibility.

create extension if not exists "pgcrypto";

-- 1. One-time backup outside the exposed public schema.
create schema if not exists app_backup;
create table if not exists app_backup.projects_pre_phase1 as table public.projects;
create table if not exists app_backup.project_stages_pre_phase1 as table public.project_stages;
create table if not exists app_backup.project_history_pre_phase1 as table public.project_history;

-- 2. Company and people foundation.
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  base_currency text not null default 'AED',
  default_language text not null default 'ru',
  timezone text not null default 'Asia/Dubai',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.organizations (id, name, slug)
values ('00000000-0000-0000-0000-000000000001', 'Space Buro', 'space-buro')
on conflict (id) do nothing;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  full_name text,
  phone text,
  job_title text,
  role text not null default 'employee' check (role in (
    'owner','admin','project_manager','foreman','designer','procurement',
    'storekeeper','accountant','marketing','employee'
  )),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.profiles (id, organization_id, full_name, role)
select
  u.id,
  '00000000-0000-0000-0000-000000000001',
  coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1)),
  case when row_number() over (order by u.created_at) = 1 then 'owner' else 'employee' end
from auth.users u
on conflict (id) do update set
  organization_id = coalesce(public.profiles.organization_id, excluded.organization_id),
  full_name = coalesce(public.profiles.full_name, excluded.full_name);

create or replace function public.current_user_organization_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select organization_id from public.profiles where id = auth.uid()
$$;

create or replace function public.current_user_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.can_view_finance()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() in ('owner','admin','accountant','project_manager'), false)
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, organization_id, full_name, role)
  values (
    new.id,
    '00000000-0000-0000-0000-000000000001',
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    'employee'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- 3. Editable dictionaries. Labels are JSON for future RU/EN support.
create table if not exists public.dictionary_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  code text not null,
  name jsonb not null default '{}'::jsonb,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  unique (organization_id, code)
);

create table if not exists public.dictionary_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  group_id uuid not null references public.dictionary_groups(id) on delete cascade,
  code text not null,
  name jsonb not null default '{}'::jsonb,
  color text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (group_id, code)
);

insert into public.dictionary_groups (id, organization_id, code, name, is_system)
values
  ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','project_type','{"ru":"Типы проектов","en":"Project types"}',true),
  ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','project_status','{"ru":"Статусы проектов","en":"Project statuses"}',true),
  ('10000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','expense_category','{"ru":"Категории расходов","en":"Expense categories"}',true),
  ('10000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','task_status','{"ru":"Статусы задач","en":"Task statuses"}',true)
on conflict (id) do nothing;

insert into public.dictionary_items (organization_id, group_id, code, name, color, sort_order)
values
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','furniture','{"ru":"Мебельные проекты","en":"Furniture projects"}','#7656c4',10),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','fitout','{"ru":"Ремонт и fit-out","en":"Renovation and fit-out"}','#2e73d2',20),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','construction','{"ru":"Строительные проекты","en":"Construction projects"}','#c98918',30),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','service','{"ru":"Сервисные и технические работы","en":"Service and technical works"}','#1d9363',40),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','new','{"ru":"Новый","en":"New"}','#6f7c8d',10),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','approval','{"ru":"Согласование","en":"Approval"}','#c98918',20),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','in_progress','{"ru":"В работе","en":"In progress"}','#2e73d2',30),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','installation','{"ru":"Монтаж","en":"Installation"}','#7656c4',40),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','completed','{"ru":"Завершён","en":"Completed"}','#1d9363',50),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004','new','{"ru":"Новая","en":"New"}','#6f7c8d',10),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004','assigned','{"ru":"Назначена","en":"Assigned"}','#2e73d2',20),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004','in_progress','{"ru":"В работе","en":"In progress"}','#7656c4',30),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004','waiting_materials','{"ru":"Ожидает материалы","en":"Waiting for materials"}','#c98918',40),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004','completed','{"ru":"Выполнена","en":"Completed"}','#1d9363',50)
on conflict (group_id, code) do nothing;

-- 4. CRM: clients and their sites/objects.
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  client_number text,
  name text not null,
  company text,
  phone text,
  whatsapp text,
  email text,
  address text,
  area text,
  client_type text,
  source text,
  manager_id uuid references public.profiles(id) on delete set null,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.client_contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  name text not null,
  position text,
  phone text,
  whatsapp text,
  email text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.project_sites (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  client_id uuid references public.clients(id) on delete set null,
  name text not null,
  object_type text,
  address text,
  area text,
  unit_number text,
  access_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 5. Extend existing projects without removing legacy text fields.
alter table public.projects add column if not exists organization_id uuid references public.organizations(id) on delete cascade;
alter table public.projects add column if not exists client_id uuid references public.clients(id) on delete set null;
alter table public.projects add column if not exists site_id uuid references public.project_sites(id) on delete set null;
alter table public.projects add column if not exists project_type_id uuid references public.dictionary_items(id) on delete set null;
alter table public.projects add column if not exists manager_id uuid references public.profiles(id) on delete set null;
alter table public.projects add column if not exists foreman_id uuid references public.profiles(id) on delete set null;
alter table public.projects add column if not exists designer_id uuid references public.profiles(id) on delete set null;
alter table public.projects add column if not exists actual_end_date date;
alter table public.projects add column if not exists contract_amount numeric(14,2) not null default 0;
alter table public.projects add column if not exists planned_expenses numeric(14,2) not null default 0;
alter table public.projects add column if not exists actual_expenses numeric(14,2) not null default 0;
alter table public.projects add column if not exists planned_profit numeric(14,2) not null default 0;
alter table public.projects add column if not exists actual_profit numeric(14,2) not null default 0;
alter table public.projects add column if not exists currency text not null default 'AED';
alter table public.projects add column if not exists archived_at timestamptz;

update public.projects
set organization_id = '00000000-0000-0000-0000-000000000001'
where organization_id is null;

alter table public.projects alter column organization_id set default public.current_user_organization_id();

-- 6. Planning: extend stages and add tasks.
alter table public.project_stages add column if not exists organization_id uuid references public.organizations(id) on delete cascade;
alter table public.project_stages add column if not exists parent_id uuid references public.project_stages(id) on delete cascade;
alter table public.project_stages add column if not exists start_date date;
alter table public.project_stages add column if not exists end_date date;
alter table public.project_stages add column if not exists actual_start_date date;
alter table public.project_stages add column if not exists actual_end_date date;
alter table public.project_stages add column if not exists planned_duration integer;
alter table public.project_stages add column if not exists responsible_user_id uuid references public.profiles(id) on delete set null;
alter table public.project_stages add column if not exists dependency_stage_id uuid references public.project_stages(id) on delete set null;
alter table public.project_stages add column if not exists budget numeric(14,2) not null default 0;
alter table public.project_stages add column if not exists actual_cost numeric(14,2) not null default 0;
alter table public.project_stages add column if not exists is_critical boolean not null default false;
alter table public.project_stages add column if not exists notes text;

update public.project_stages s
set organization_id = p.organization_id
from public.projects p
where s.project_id = p.id and s.organization_id is null;

alter table public.project_stages alter column organization_id set default public.current_user_organization_id();

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id) on delete cascade,
  stage_id uuid references public.project_stages(id) on delete set null,
  parent_id uuid references public.tasks(id) on delete cascade,
  title text not null,
  description text,
  assignee_id uuid references public.profiles(id) on delete set null,
  start_date date,
  due_date date,
  actual_completed_at timestamptz,
  priority text not null default 'normal' check (priority in ('low','normal','high','critical')),
  status text not null default 'new',
  progress integer not null default 0 check (progress between 0 and 100),
  dependency_task_id uuid references public.tasks(id) on delete set null,
  planned_hours numeric(10,2) not null default 0,
  actual_hours numeric(10,2) not null default 0,
  cost numeric(14,2) not null default 0,
  requires_verification boolean not null default false,
  verified_by uuid references public.profiles(id) on delete set null,
  verified_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.project_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  project_role text,
  can_view_finance boolean not null default false,
  created_at timestamptz not null default now(),
  unique (project_id, profile_id)
);

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  profile_id uuid unique references public.profiles(id) on delete set null,
  employee_number text,
  full_name text not null,
  photo_url text,
  job_title text,
  department text,
  phone text,
  start_date date,
  payment_type text not null default 'monthly',
  monthly_salary numeric(14,2) not null default 0,
  daily_rate numeric(14,2) not null default 0,
  hourly_rate numeric(14,2) not null default 0,
  overtime_rate numeric(14,2) not null default 0,
  project_rate numeric(14,2) not null default 0,
  documents jsonb not null default '[]'::jsonb,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, employee_number)
);

-- 7. Basic finance.
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id) on delete cascade,
  stage_id uuid references public.project_stages(id) on delete set null,
  category text not null,
  subcategory text,
  description text not null,
  supplier_name text,
  planned_amount numeric(14,2) not null default 0,
  actual_amount numeric(14,2) not null default 0,
  vat_amount numeric(14,2) not null default 0,
  expense_date date not null default current_date,
  status text not null default 'planned',
  payment_status text not null default 'unpaid',
  document_url text,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id) on delete cascade,
  client_id uuid references public.clients(id) on delete set null,
  payment_type text not null default 'client_payment',
  direction text not null default 'income' check (direction in ('income','outcome')),
  amount numeric(14,2) not null,
  currency text not null default 'AED',
  due_date date,
  paid_date date,
  status text not null default 'expected',
  method text,
  reference text,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 8. Materials and basic warehouse.
create table if not exists public.material_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  parent_id uuid references public.material_categories(id) on delete cascade,
  code text,
  name jsonb not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  unique (organization_id, code)
);

create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  code text,
  name text not null,
  category_id uuid references public.material_categories(id) on delete set null,
  brand text,
  color text,
  dimensions text,
  thickness numeric(10,2),
  unit text not null default 'pcs',
  purchase_price numeric(14,2) not null default 0,
  average_price numeric(14,2) not null default 0,
  minimum_stock numeric(14,3) not null default 0,
  photo_url text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, code)
);

create table if not exists public.warehouse_locations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  name text not null,
  address text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete restrict,
  warehouse_id uuid references public.warehouse_locations(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  movement_type text not null check (movement_type in (
    'receipt','issue','reserve','unreserve','return','transfer','writeoff','defect','inventory'
  )),
  quantity numeric(14,3) not null,
  unit_cost numeric(14,2) not null default 0,
  movement_date timestamptz not null default now(),
  performed_by uuid references public.profiles(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

create or replace view public.warehouse_stock
with (security_invoker = true)
as
select
  sm.organization_id,
  sm.warehouse_id,
  sm.material_id,
  sum(case
    when sm.movement_type in ('receipt','return','inventory') then sm.quantity
    when sm.movement_type in ('issue','writeoff','defect') then -sm.quantity
    else 0
  end) as quantity_on_hand,
  sum(case when sm.movement_type = 'reserve' then sm.quantity when sm.movement_type = 'unreserve' then -sm.quantity else 0 end) as reserved
from public.stock_movements sm
group by sm.organization_id, sm.warehouse_id, sm.material_id;

-- 9. Audit and notifications.
alter table public.project_history add column if not exists organization_id uuid references public.organizations(id) on delete cascade;
update public.project_history h
set organization_id = p.organization_id
from public.projects p
where h.project_id = p.id and h.organization_id is null;
alter table public.project_history alter column organization_id set default public.current_user_organization_id();

create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  entity_type text not null,
  entity_id uuid,
  action text not null,
  old_data jsonb,
  new_data jsonb,
  actor_id uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  recipient_id uuid references public.profiles(id) on delete cascade,
  notification_type text not null,
  title text not null,
  message text,
  entity_type text,
  entity_id uuid,
  due_at timestamptz,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.log_project_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.activity_log (organization_id, entity_type, entity_id, action, old_data, new_data, actor_id)
  values (
    coalesce(new.organization_id, old.organization_id),
    'project',
    coalesce(new.id, old.id),
    lower(tg_op),
    case when tg_op = 'INSERT' then null else to_jsonb(old) end,
    case when tg_op = 'DELETE' then null else to_jsonb(new) end,
    auth.uid()
  );
  return new;
end;
$$;

drop trigger if exists projects_activity_log on public.projects;
create trigger projects_activity_log
after insert or update on public.projects
for each row execute function public.log_project_change();

-- 10. Common updated_at trigger.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['organizations','profiles','clients','project_sites','tasks','employees','expenses','payments','materials']
  loop
    execute format('drop trigger if exists %I_touch_updated_at on public.%I', t, t);
    execute format('create trigger %I_touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()', t, t);
  end loop;
end $$;

-- 11. Indexes.
create index if not exists idx_projects_org on public.projects(organization_id);
create index if not exists idx_projects_client on public.projects(client_id);
create index if not exists idx_clients_org on public.clients(organization_id);
create index if not exists idx_tasks_project on public.tasks(project_id);
create index if not exists idx_tasks_assignee_due on public.tasks(assignee_id, due_date);
create index if not exists idx_employees_org_active on public.employees(organization_id, is_active);
create index if not exists idx_stages_project_dates on public.project_stages(project_id, start_date, end_date);
create index if not exists idx_expenses_project on public.expenses(project_id, expense_date);
create index if not exists idx_payments_project on public.payments(project_id, due_date);
create index if not exists idx_stock_material on public.stock_movements(material_id, warehouse_id);
create index if not exists idx_activity_entity on public.activity_log(entity_type, entity_id, created_at desc);

-- 12. RLS. The old broad project policies are replaced with organization-aware rules.
alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.dictionary_groups enable row level security;
alter table public.dictionary_items enable row level security;
alter table public.clients enable row level security;
alter table public.client_contacts enable row level security;
alter table public.project_sites enable row level security;
alter table public.projects enable row level security;
alter table public.project_stages enable row level security;
alter table public.project_history enable row level security;
alter table public.tasks enable row level security;
alter table public.project_members enable row level security;
alter table public.employees enable row level security;
alter table public.expenses enable row level security;
alter table public.payments enable row level security;
alter table public.material_categories enable row level security;
alter table public.materials enable row level security;
alter table public.warehouse_locations enable row level security;
alter table public.stock_movements enable row level security;
alter table public.activity_log enable row level security;
alter table public.notifications enable row level security;

drop policy if exists "authenticated users manage projects" on public.projects;
drop policy if exists "authenticated users manage stages" on public.project_stages;
drop policy if exists "authenticated users manage history" on public.project_history;

do $$
declare
  t text;
  policy_name text;
begin
  foreach t in array array[
    'dictionary_groups','dictionary_items','clients','client_contacts','project_sites',
    'projects','project_stages','project_history','tasks','project_members','employees',
    'material_categories','materials','warehouse_locations','stock_movements',
    'activity_log','notifications'
  ] loop
    policy_name := t || '_organization_access';
    execute format('drop policy if exists %I on public.%I', policy_name, t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (organization_id = public.current_user_organization_id()) with check (organization_id = public.current_user_organization_id())',
      policy_name, t
    );
  end loop;
end $$;

drop policy if exists organizations_members_read on public.organizations;
create policy organizations_members_read on public.organizations
for select to authenticated
using (id = public.current_user_organization_id());

drop policy if exists profiles_members_read on public.profiles;
create policy profiles_members_read on public.profiles
for select to authenticated
using (organization_id = public.current_user_organization_id());

drop policy if exists profiles_admin_manage on public.profiles;
create policy profiles_admin_manage on public.profiles
for all to authenticated
using (
  organization_id = public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin')
)
with check (
  organization_id = public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin')
);

drop policy if exists expenses_finance_access on public.expenses;
create policy expenses_finance_access on public.expenses
for all to authenticated
using (organization_id = public.current_user_organization_id() and public.can_view_finance())
with check (organization_id = public.current_user_organization_id() and public.can_view_finance());

drop policy if exists payments_finance_access on public.payments;
create policy payments_finance_access on public.payments
for all to authenticated
using (organization_id = public.current_user_organization_id() and public.can_view_finance())
with check (organization_id = public.current_user_organization_id() and public.can_view_finance());

-- 13. Grants for the authenticated role.
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.current_user_organization_id() to authenticated;
grant execute on function public.current_user_role() to authenticated;
grant execute on function public.can_view_finance() to authenticated;

-- Phase 1 foundation complete. Existing project data remains in public.projects.
