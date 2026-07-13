-- Space Buro Project Cloud — Phase 1.9 Project Control Core
-- Safe additive migration. Existing records, tasks, estimates, warehouse documents
-- and calculations are preserved. No table or business record is dropped.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- 1. Stable WBS / cost codes and project budget control.
-- ---------------------------------------------------------------------------

create table if not exists public.cost_codes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  parent_id uuid references public.cost_codes(id) on delete restrict,
  code text not null,
  name text not null,
  name_ru text,
  category text not null default 'work',
  cost_type text not null default 'direct',
  unit text,
  color text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,code)
);

create table if not exists public.project_cost_codes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  cost_code_id uuid not null references public.cost_codes(id) on delete restrict,
  estimate_record_id uuid references public.module_records(id) on delete set null,
  estimate_line_id uuid references public.module_record_lines(id) on delete set null,
  stage_id uuid references public.project_stages(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  budget_revenue numeric(16,2) not null default 0,
  budget_cost numeric(16,2) not null default 0,
  committed_cost numeric(16,2) not null default 0,
  actual_cost numeric(16,2) not null default 0,
  forecast_cost numeric(16,2) not null default 0,
  manual_forecast_cost numeric(16,2),
  progress_percent numeric(7,3) not null default 0,
  start_date date,
  end_date date,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (project_id,cost_code_id,estimate_line_id)
);

-- PostgreSQL treats NULLs as distinct in a normal unique constraint. These
-- partial indexes make estimate synchronization idempotent and still allow a
-- manually created project budget row for the same company cost code.
create unique index if not exists uq_project_cost_codes_estimate_line
  on public.project_cost_codes(project_id,estimate_line_id)
  where estimate_line_id is not null;
create unique index if not exists uq_project_cost_codes_manual
  on public.project_cost_codes(project_id,cost_code_id)
  where estimate_line_id is null;

-- Existing operational records receive nullable stable links. Old data remains
-- valid and can be classified later from the interface.
alter table public.module_record_lines add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.module_record_lines add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;
alter table public.tasks add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.tasks add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;
alter table public.project_stages add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.project_stages add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;
alter table public.expenses add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.expenses add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;
alter table public.expenses add column if not exists warehouse_document_id uuid references public.warehouse_documents(id) on delete set null;
alter table public.expenses add column if not exists stock_movement_id uuid references public.stock_movements(id) on delete set null;
alter table public.expenses add column if not exists exclude_from_project_cost boolean not null default false;
alter table public.payments add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.payments add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;
alter table public.payments add column if not exists exchange_rate numeric(16,6) not null default 1;
alter table public.stock_movements add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.stock_movements add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;
alter table public.warehouse_document_items add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.warehouse_document_items add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;
alter table public.payroll_adjustments add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.payroll_adjustments add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;
alter table public.contractor_operations add column if not exists cost_code_id uuid references public.cost_codes(id) on delete set null;
alter table public.contractor_operations add column if not exists project_cost_code_id uuid references public.project_cost_codes(id) on delete set null;

-- Standard Space Buro WBS roots. They are editable; project-specific children
-- may be added without changing application code.
with roots(code,name,name_ru,category,cost_type,color,sort_order) as (values
  ('DES','Design','Дизайн','design','direct','#8b5cf6',10),
  ('DOC','Documentation & permits','Документация и разрешения','documentation','direct','#64748b',20),
  ('PRE','Preliminaries','Подготовительные работы','work','direct','#0ea5e9',30),
  ('DEM','Demolition','Демонтаж','work','direct','#ef4444',40),
  ('CIV','Civil works','Общестроительные работы','work','direct','#f59e0b',50),
  ('GYP','Gypsum & ceilings','Гипсокартон и потолки','work','direct','#eab308',60),
  ('ELE','Electrical','Электрика','engineering','direct','#f97316',70),
  ('PLU','Plumbing','Сантехника','engineering','direct','#06b6d4',80),
  ('HVAC','HVAC & ventilation','Кондиционирование и вентиляция','engineering','direct','#0284c7',90),
  ('TIL','Tiling & stone','Плитка и камень','finishing','direct','#a16207',100),
  ('PNT','Painting','Малярные работы','finishing','direct','#ec4899',110),
  ('FLR','Flooring','Напольные покрытия','finishing','direct','#84cc16',120),
  ('GLZ','Glass & mirrors','Стекло и зеркала','work','direct','#38bdf8',130),
  ('MET','Metal works','Металлические работы','work','direct','#475569',140),
  ('FUR','Custom furniture','Корпусная мебель','furniture','direct','#7c3aed',150),
  ('SOF','Upholstery','Мягкая мебель','furniture','direct','#db2777',160),
  ('STN','Stone & countertops','Камень и столешницы','furniture','direct','#78716c',170),
  ('LOG','Delivery & logistics','Доставка и логистика','logistics','direct','#14b8a6',180),
  ('LAB','Direct labour','Прямые трудозатраты','labour','direct','#22c55e',190),
  ('SUB','Subcontractors','Подрядчики','subcontract','direct','#6366f1',200),
  ('OVH','Project overhead','Накладные расходы проекта','overhead','indirect','#94a3b8',210),
  ('UNASSIGNED','Unassigned cost','Нераспределённые расходы','unclassified','direct','#dc2626',999)
)
insert into public.cost_codes(organization_id,code,name,name_ru,category,cost_type,color,sort_order)
select o.id,r.code,r.name,r.name_ru,r.category,r.cost_type,r.color,r.sort_order
from public.organizations o cross join roots r
on conflict(organization_id,code) do nothing;

-- Preserve every legacy project cost even before users classify it. A single
-- editable UNASSIGNED row per project prevents old expenses from disappearing
-- from forecasts and avoids multiplying them across repeated WBS codes.
insert into public.project_cost_codes(organization_id,project_id,cost_code_id,metadata)
select p.organization_id,p.id,c.id,jsonb_build_object('system_fallback','unassigned')
from public.projects p join public.cost_codes c on c.organization_id=p.organization_id and c.code='UNASSIGNED'
where exists(select 1 from public.expenses e where e.project_id=p.id and e.cost_code_id is null)
   or exists(select 1 from public.stock_movements s where s.project_id=p.id and s.cost_code_id is null)
   or exists(select 1 from public.payroll_adjustments a where a.project_id=p.id and a.cost_code_id is null)
   or exists(select 1 from public.contractor_operations o where o.project_id=p.id and o.cost_code_id is null)
on conflict(project_id,cost_code_id) where estimate_line_id is null do nothing;

update public.expenses e set cost_code_id=c.id,project_cost_code_id=pc.id
from public.cost_codes c join public.project_cost_codes pc on pc.cost_code_id=c.id and pc.estimate_line_id is null
where e.project_id=pc.project_id and e.organization_id=c.organization_id and c.code='UNASSIGNED'
  and e.cost_code_id is null and e.project_cost_code_id is null;
update public.stock_movements s set cost_code_id=c.id,project_cost_code_id=pc.id
from public.cost_codes c join public.project_cost_codes pc on pc.cost_code_id=c.id and pc.estimate_line_id is null
where s.project_id=pc.project_id and s.organization_id=c.organization_id and c.code='UNASSIGNED'
  and s.cost_code_id is null and s.project_cost_code_id is null;
update public.payroll_adjustments a set cost_code_id=c.id,project_cost_code_id=pc.id
from public.cost_codes c join public.project_cost_codes pc on pc.cost_code_id=c.id and pc.estimate_line_id is null
where a.project_id=pc.project_id and a.organization_id=c.organization_id and c.code='UNASSIGNED'
  and a.cost_code_id is null and a.project_cost_code_id is null;
update public.contractor_operations o set cost_code_id=c.id,project_cost_code_id=pc.id
from public.cost_codes c join public.project_cost_codes pc on pc.cost_code_id=c.id and pc.estimate_line_id is null
where o.project_id=pc.project_id and o.organization_id=c.organization_id and c.code='UNASSIGNED'
  and o.cost_code_id is null and o.project_cost_code_id is null;

-- ---------------------------------------------------------------------------
-- 2. Baseline / current / actual schedule and dependency graph.
-- ---------------------------------------------------------------------------

create table if not exists public.schedule_activities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  parent_id uuid references public.schedule_activities(id) on delete cascade,
  stage_id uuid references public.project_stages(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  source_estimate_line_id uuid references public.module_record_lines(id) on delete set null,
  wbs_code text,
  name text not null,
  activity_type text not null default 'task',
  status text not null default 'not_started',
  baseline_start date,
  baseline_end date,
  current_start date,
  current_end date,
  actual_start date,
  actual_end date,
  duration_days integer not null default 0,
  progress_percent numeric(7,3) not null default 0,
  planned_quantity numeric(14,3) not null default 0,
  actual_quantity numeric(14,3) not null default 0,
  unit text,
  responsible_id uuid references public.profiles(id) on delete set null,
  is_critical boolean not null default false,
  delay_reason text,
  constraint_notes text,
  sort_order integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (progress_percent between 0 and 100),
  check (duration_days >= 0)
);

create unique index if not exists uq_schedule_activity_estimate_line
  on public.schedule_activities(project_id,source_estimate_line_id)
  where source_estimate_line_id is not null;
create unique index if not exists uq_schedule_activity_task
  on public.schedule_activities(project_id,task_id)
  where task_id is not null and source_estimate_line_id is null;

create table if not exists public.activity_dependencies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  predecessor_id uuid not null references public.schedule_activities(id) on delete cascade,
  successor_id uuid not null references public.schedule_activities(id) on delete cascade,
  dependency_type text not null default 'FS' check (dependency_type in ('FS','SS','FF','SF')),
  lag_days integer not null default 0,
  comment text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (predecessor_id <> successor_id),
  unique(predecessor_id,successor_id)
);

create table if not exists public.schedule_baselines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null,
  version integer not null,
  status text not null default 'draft',
  baseline_date date not null default current_date,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  notes text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id,version)
);

create table if not exists public.schedule_baseline_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  baseline_id uuid not null references public.schedule_baselines(id) on delete cascade,
  activity_id uuid references public.schedule_activities(id) on delete set null,
  parent_item_id uuid references public.schedule_baseline_items(id) on delete set null,
  stage_id uuid references public.project_stages(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  wbs_code text,
  name text not null,
  start_date date,
  end_date date,
  duration_days integer not null default 0,
  progress_percent numeric(7,3) not null default 0,
  planned_quantity numeric(14,3) not null default 0,
  unit text,
  is_critical boolean not null default false,
  sort_order integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(baseline_id,activity_id)
);

alter table public.task_dependencies add column if not exists is_critical boolean not null default false;

-- ---------------------------------------------------------------------------
-- 3. Controlled project documents, revisions and transmittals.
-- ---------------------------------------------------------------------------

create table if not exists public.project_documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  document_number text not null,
  title text not null,
  document_type text not null default 'drawing',
  discipline text,
  status text not null default 'draft',
  current_revision text,
  current_revision_id uuid,
  responsible_id uuid references public.profiles(id) on delete set null,
  client_visible boolean not null default false,
  description text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,project_id,document_number)
);

create table if not exists public.document_revisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  document_id uuid not null references public.project_documents(id) on delete cascade,
  revision_no integer not null default 0,
  revision_code text not null,
  title text,
  file_url text,
  storage_path text,
  file_name text,
  mime_type text,
  file_size bigint,
  status text not null default 'draft',
  purpose text,
  change_description text,
  issued_at timestamptz,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  supersedes_revision_id uuid references public.document_revisions(id) on delete set null,
  checksum text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(document_id,revision_code),
  unique(document_id,revision_no)
);

do $$ begin
  if not exists(select 1 from pg_constraint where conname='project_documents_current_revision_fk') then
    alter table public.project_documents add constraint project_documents_current_revision_fk
      foreign key(current_revision_id) references public.document_revisions(id) on delete set null;
  end if;
end $$;

create table if not exists public.transmittals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  transmittal_number text not null,
  subject text,
  recipient_type text not null default 'client',
  recipient_name text,
  recipient_email text,
  purpose text not null default 'for_information',
  status text not null default 'draft',
  sent_at timestamptz,
  acknowledged_at timestamptz,
  due_date date,
  message text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,transmittal_number)
);

create table if not exists public.transmittal_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  transmittal_id uuid not null references public.transmittals(id) on delete cascade,
  document_revision_id uuid not null references public.document_revisions(id) on delete restrict,
  response_status text not null default 'pending',
  response_comment text,
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  unique(transmittal_id,document_revision_id)
);

-- ---------------------------------------------------------------------------
-- 4. Variations / change orders with financial and schedule impact.
-- ---------------------------------------------------------------------------

create table if not exists public.change_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  change_number text not null,
  title text not null,
  reason text,
  description text,
  status text not null default 'draft',
  initiated_by_type text not null default 'internal',
  client_id uuid references public.clients(id) on delete set null,
  source_rfi_id uuid,
  currency text not null default 'AED',
  revenue_amount numeric(16,2) not null default 0,
  cost_amount numeric(16,2) not null default 0,
  margin_amount numeric(16,2) not null default 0,
  vat_percent numeric(7,3) not null default 5,
  vat_amount numeric(16,2) not null default 0,
  total_amount numeric(16,2) not null default 0,
  schedule_impact_days integer not null default 0,
  submitted_at timestamptz,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  rejected_at timestamptz,
  applied_at timestamptz,
  client_signature_url text,
  documents jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,project_id,change_number)
);

create table if not exists public.change_order_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  change_order_id uuid not null references public.change_orders(id) on delete cascade,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  stage_id uuid references public.project_stages(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  schedule_activity_id uuid references public.schedule_activities(id) on delete set null,
  material_id uuid references public.materials(id) on delete set null,
  line_type text not null default 'work',
  description text not null,
  quantity numeric(14,3) not null default 1,
  unit text not null default 'job',
  unit_price numeric(16,2) not null default 0,
  unit_cost numeric(16,2) not null default 0,
  revenue_amount numeric(16,2) not null default 0,
  cost_amount numeric(16,2) not null default 0,
  schedule_impact_days integer not null default 0,
  sort_order integer not null default 0,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 5. RFI, submittals and explicit client decisions.
-- ---------------------------------------------------------------------------

create table if not exists public.rfis (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  rfi_number text not null,
  subject text not null,
  question text not null,
  answer text,
  status text not null default 'draft',
  priority text not null default 'normal',
  raised_by uuid default auth.uid() references public.profiles(id) on delete set null,
  assigned_to uuid references public.profiles(id) on delete set null,
  recipient_name text,
  due_date date,
  submitted_at timestamptz,
  answered_at timestamptz,
  closed_at timestamptz,
  cost_impact numeric(16,2) not null default 0,
  schedule_impact_days integer not null default 0,
  related_change_order_id uuid references public.change_orders(id) on delete set null,
  related_document_id uuid references public.project_documents(id) on delete set null,
  attachments jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,project_id,rfi_number)
);

do $$ begin
  if not exists(select 1 from pg_constraint where conname='change_orders_source_rfi_fk') then
    alter table public.change_orders add constraint change_orders_source_rfi_fk
      foreign key(source_rfi_id) references public.rfis(id) on delete set null;
  end if;
end $$;

create table if not exists public.submittals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  submittal_number text not null,
  submittal_type text not null default 'material',
  title text not null,
  specification text,
  status text not null default 'draft',
  revision text,
  responsible_id uuid references public.profiles(id) on delete set null,
  reviewer_id uuid references public.profiles(id) on delete set null,
  reviewer_name text,
  due_date date,
  submitted_at timestamptz,
  responded_at timestamptz,
  approved_at timestamptz,
  response_code text,
  response_comment text,
  related_material_id uuid references public.materials(id) on delete set null,
  related_document_id uuid references public.project_documents(id) on delete set null,
  related_revision_id uuid references public.document_revisions(id) on delete set null,
  related_rfi_id uuid references public.rfis(id) on delete set null,
  attachments jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,project_id,submittal_number)
);

create table if not exists public.client_decisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  decision_number text not null,
  title text not null,
  question text not null,
  decision text,
  status text not null default 'waiting',
  requested_at timestamptz not null default now(),
  due_date date,
  decided_at timestamptz,
  client_id uuid references public.clients(id) on delete set null,
  requested_by uuid default auth.uid() references public.profiles(id) on delete set null,
  responsible_id uuid references public.profiles(id) on delete set null,
  cost_impact numeric(16,2) not null default 0,
  schedule_impact_days integer not null default 0,
  related_rfi_id uuid references public.rfis(id) on delete set null,
  related_change_order_id uuid references public.change_orders(id) on delete set null,
  attachments jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,project_id,decision_number)
);

-- Every resubmission is a new immutable revision; the submittal header remains
-- the stable register entry used by RFIs, materials and reports.
create table if not exists public.submittal_revisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  submittal_id uuid not null references public.submittals(id) on delete cascade,
  revision_no integer not null default 0,
  revision_code text not null,
  title text,
  status text not null default 'draft',
  document_revision_id uuid references public.document_revisions(id) on delete set null,
  file_url text,
  storage_path text,
  submitted_at timestamptz,
  responded_at timestamptz,
  approved_at timestamptz,
  reviewer_id uuid references public.profiles(id) on delete set null,
  response_code text,
  response_comment text,
  supersedes_revision_id uuid references public.submittal_revisions(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(submittal_id,revision_no),
  unique(submittal_id,revision_code)
);

alter table public.submittals add column if not exists current_submittal_revision_id uuid;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='submittals_current_revision_fk') then
    alter table public.submittals add constraint submittals_current_revision_fk
      foreign key(current_submittal_revision_id) references public.submittal_revisions(id) on delete set null;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Procurement commitments, supplier invoices and three-way matching.
-- ---------------------------------------------------------------------------

create table if not exists public.procurement_commitments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  source_record_id uuid references public.module_records(id) on delete set null,
  commitment_number text not null,
  commitment_type text not null default 'purchase_order',
  title text,
  status text not null default 'draft',
  currency text not null default 'AED',
  exchange_rate numeric(16,6) not null default 1,
  order_date date,
  expected_date date,
  delivery_location text,
  payment_terms text,
  subtotal numeric(16,2) not null default 0,
  discount_amount numeric(16,2) not null default 0,
  vat_amount numeric(16,2) not null default 0,
  delivery_cost numeric(16,2) not null default 0,
  customs_cost numeric(16,2) not null default 0,
  other_landed_cost numeric(16,2) not null default 0,
  total_amount numeric(16,2) not null default 0,
  base_currency_total numeric(16,2) not null default 0,
  submitted_by uuid references public.profiles(id) on delete set null,
  submitted_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  issued_at timestamptz,
  closed_at timestamptz,
  documents jsonb not null default '[]'::jsonb,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,commitment_number)
);

create table if not exists public.procurement_commitment_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  commitment_id uuid not null references public.procurement_commitments(id) on delete cascade,
  source_line_id uuid references public.module_record_lines(id) on delete set null,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  material_id uuid references public.materials(id) on delete set null,
  description text not null,
  specification text,
  quantity numeric(14,3) not null default 0,
  unit text not null default 'pcs',
  unit_price numeric(16,4) not null default 0,
  discount_percent numeric(7,3) not null default 0,
  vat_percent numeric(7,3) not null default 5,
  net_amount numeric(16,2) not null default 0,
  vat_amount numeric(16,2) not null default 0,
  total_amount numeric(16,2) not null default 0,
  delivered_quantity numeric(14,3) not null default 0,
  accepted_quantity numeric(14,3) not null default 0,
  invoiced_quantity numeric(14,3) not null default 0,
  cancelled_quantity numeric(14,3) not null default 0,
  required_date date,
  promised_date date,
  status text not null default 'ordered',
  sort_order integer not null default 0,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.supplier_invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  commitment_id uuid references public.procurement_commitments(id) on delete set null,
  invoice_number text not null,
  invoice_date date not null default current_date,
  due_date date,
  status text not null default 'draft',
  match_status text not null default 'not_checked',
  currency text not null default 'AED',
  exchange_rate numeric(16,6) not null default 1,
  subtotal numeric(16,2) not null default 0,
  vat_amount numeric(16,2) not null default 0,
  additional_cost numeric(16,2) not null default 0,
  total_amount numeric(16,2) not null default 0,
  paid_amount numeric(16,2) not null default 0,
  payment_status text not null default 'unpaid',
  document_url text,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,supplier_id,invoice_number)
);

create table if not exists public.supplier_invoice_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  invoice_id uuid not null references public.supplier_invoices(id) on delete cascade,
  commitment_item_id uuid references public.procurement_commitment_items(id) on delete set null,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  material_id uuid references public.materials(id) on delete set null,
  description text not null,
  quantity numeric(14,3) not null default 0,
  unit text not null default 'pcs',
  unit_price numeric(16,4) not null default 0,
  vat_percent numeric(7,3) not null default 5,
  net_amount numeric(16,2) not null default 0,
  vat_amount numeric(16,2) not null default 0,
  total_amount numeric(16,2) not null default 0,
  sort_order integer not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.supplier_invoices add column if not exists submitted_by uuid references public.profiles(id) on delete set null;
alter table public.supplier_invoices add column if not exists submitted_at timestamptz;
alter table public.supplier_invoices add column if not exists paid_by uuid references public.profiles(id) on delete set null;
alter table public.supplier_invoices add column if not exists paid_at timestamptz;
alter table public.supplier_invoices add column if not exists payment_reference text;
alter table public.change_orders add column if not exists submitted_by uuid references public.profiles(id) on delete set null;
alter table public.change_orders add column if not exists approval_reference text;

alter table public.warehouse_documents add column if not exists commitment_id uuid references public.procurement_commitments(id) on delete set null;
alter table public.warehouse_documents add column if not exists supplier_invoice_id uuid references public.supplier_invoices(id) on delete set null;
alter table public.warehouse_document_items add column if not exists commitment_item_id uuid references public.procurement_commitment_items(id) on delete set null;
alter table public.warehouse_document_items add column if not exists supplier_invoice_item_id uuid references public.supplier_invoice_items(id) on delete set null;

-- ---------------------------------------------------------------------------
-- 7. Furniture production orders, BOM and routing.
-- ---------------------------------------------------------------------------

create table if not exists public.production_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  order_number text not null,
  room text,
  product_code text,
  product_name text not null,
  description text,
  drawing_revision_id uuid references public.document_revisions(id) on delete set null,
  source_estimate_line_id uuid references public.module_record_lines(id) on delete set null,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  quantity numeric(14,3) not null default 1,
  unit text not null default 'item',
  priority text not null default 'normal',
  status text not null default 'draft',
  planned_start_date date,
  planned_end_date date,
  actual_start_date date,
  actual_end_date date,
  progress_percent numeric(7,3) not null default 0,
  responsible_id uuid references public.profiles(id) on delete set null,
  workshop_warehouse_id uuid references public.warehouse_locations(id) on delete set null,
  qc_status text not null default 'not_checked',
  qc_approved_by uuid references public.profiles(id) on delete set null,
  qc_approved_at timestamptz,
  packing_status text not null default 'not_started',
  delivery_status text not null default 'not_started',
  installation_status text not null default 'not_started',
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(progress_percent between 0 and 100),
  unique(organization_id,order_number)
);

create table if not exists public.production_bom_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  production_order_id uuid not null references public.production_orders(id) on delete cascade,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  material_id uuid references public.materials(id) on delete set null,
  material_description text,
  specification text,
  quantity numeric(14,3) not null default 0,
  unit text not null default 'pcs',
  waste_percent numeric(7,3) not null default 0,
  required_quantity numeric(14,3) not null default 0,
  reserved_quantity numeric(14,3) not null default 0,
  issued_quantity numeric(14,3) not null default 0,
  used_quantity numeric(14,3) not null default 0,
  returned_quantity numeric(14,3) not null default 0,
  unit_cost numeric(16,4) not null default 0,
  total_cost numeric(16,2) not null default 0,
  reservation_id uuid references public.stock_reservations(id) on delete set null,
  sort_order integer not null default 0,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.production_routing_steps (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  production_order_id uuid not null references public.production_orders(id) on delete cascade,
  sequence_no integer not null,
  operation_code text,
  operation_name text not null,
  workstation text,
  responsible_id uuid references public.profiles(id) on delete set null,
  dependency_step_id uuid references public.production_routing_steps(id) on delete set null,
  status text not null default 'not_started',
  planned_start_date date,
  planned_end_date date,
  actual_start_date date,
  actual_end_date date,
  planned_hours numeric(12,2) not null default 0,
  actual_hours numeric(12,2) not null default 0,
  progress_percent numeric(7,3) not null default 0,
  qc_required boolean not null default false,
  qc_status text not null default 'not_checked',
  qc_checked_by uuid references public.profiles(id) on delete set null,
  qc_checked_at timestamptz,
  instructions text,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(progress_percent between 0 and 100),
  unique(production_order_id,sequence_no)
);

-- ---------------------------------------------------------------------------
-- 8. Mobile field daily log: labour, progress, materials and media.
-- ---------------------------------------------------------------------------

create table if not exists public.daily_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  log_date date not null default current_date,
  status text not null default 'draft',
  weather text,
  temperature_c numeric(6,2),
  foreman_id uuid references public.profiles(id) on delete set null,
  summary text,
  work_completed text,
  planned_next text,
  delays text,
  issues text,
  client_decisions text,
  safety_notes text,
  visitors text,
  voice_note_url text,
  submitted_at timestamptz,
  submitted_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id,log_date)
);

create table if not exists public.daily_log_labor (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  daily_log_id uuid not null references public.daily_logs(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete set null,
  contractor_id uuid references public.contractors(id) on delete set null,
  crew_name text,
  trade text,
  headcount integer not null default 1,
  regular_hours numeric(10,2) not null default 0,
  overtime_hours numeric(10,2) not null default 0,
  cost_amount numeric(16,2) not null default 0,
  work_description text,
  task_id uuid references public.tasks(id) on delete set null,
  schedule_activity_id uuid references public.schedule_activities(id) on delete set null,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(employee_id is not null or contractor_id is not null or crew_name is not null)
);
alter table public.daily_log_labor add column if not exists cost_amount numeric(16,2) not null default 0;

create table if not exists public.daily_log_progress (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  daily_log_id uuid not null references public.daily_logs(id) on delete cascade,
  stage_id uuid references public.project_stages(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  schedule_activity_id uuid references public.schedule_activities(id) on delete set null,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  description text not null,
  planned_quantity numeric(14,3) not null default 0,
  actual_quantity numeric(14,3) not null default 0,
  quantity_completed numeric(14,3) not null default 0,
  unit text,
  progress_percent numeric(7,3),
  verified boolean not null default false,
  verified_by uuid references public.profiles(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(progress_percent is null or progress_percent between 0 and 100),
  check(planned_quantity>=0 and actual_quantity>=0 and quantity_completed>=0)
);

create table if not exists public.daily_log_materials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  daily_log_id uuid not null references public.daily_logs(id) on delete cascade,
  material_id uuid references public.materials(id) on delete set null,
  material_description text,
  warehouse_document_item_id uuid references public.warehouse_document_items(id) on delete set null,
  received_quantity numeric(14,3) not null default 0,
  used_quantity numeric(14,3) not null default 0,
  damaged_quantity numeric(14,3) not null default 0,
  returned_quantity numeric(14,3) not null default 0,
  unit text not null default 'pcs',
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(material_id is not null or material_description is not null)
);

create table if not exists public.daily_log_media (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  daily_log_id uuid not null references public.daily_logs(id) on delete cascade,
  media_type text not null default 'photo',
  file_url text not null,
  thumbnail_url text,
  caption text,
  location text,
  taken_at timestamptz,
  task_id uuid references public.tasks(id) on delete set null,
  schedule_activity_id uuid references public.schedule_activities(id) on delete set null,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 9. Quality, defects, inspections, handover and warranty.
-- ---------------------------------------------------------------------------

create table if not exists public.quality_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  quality_number text not null,
  record_type text not null default 'inspection',
  title text not null,
  description text,
  status text not null default 'open',
  severity text not null default 'normal',
  stage_id uuid references public.project_stages(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  schedule_activity_id uuid references public.schedule_activities(id) on delete set null,
  cost_code_id uuid references public.cost_codes(id) on delete set null,
  project_cost_code_id uuid references public.project_cost_codes(id) on delete set null,
  location text,
  assigned_to uuid references public.profiles(id) on delete set null,
  contractor_id uuid references public.contractors(id) on delete set null,
  reported_by uuid default auth.uid() references public.profiles(id) on delete set null,
  due_date date,
  inspected_at timestamptz,
  closed_at timestamptz,
  verified_at timestamptz,
  verified_by uuid references public.profiles(id) on delete set null,
  root_cause text,
  corrective_action text,
  before_photos jsonb not null default '[]'::jsonb,
  after_photos jsonb not null default '[]'::jsonb,
  attachments jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,project_id,quality_number)
);

create table if not exists public.quality_checklist_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  quality_record_id uuid not null references public.quality_records(id) on delete cascade,
  item_no integer not null default 1,
  requirement text not null,
  result text not null default 'pending',
  measured_value text,
  comments text,
  evidence_urls jsonb not null default '[]'::jsonb,
  checked_by uuid references public.profiles(id) on delete set null,
  checked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(quality_record_id,item_no)
);

create table if not exists public.handovers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  handover_number text not null,
  handover_type text not null default 'final',
  title text not null,
  status text not null default 'draft',
  client_id uuid references public.clients(id) on delete set null,
  planned_date date,
  actual_date date,
  submitted_at timestamptz,
  accepted_at timestamptz,
  accepted_by_name text,
  signature_url text,
  warranty_start_date date,
  warranty_end_date date,
  retention_amount numeric(16,2) not null default 0,
  retention_due_date date,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,project_id,handover_number)
);

create table if not exists public.handover_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  handover_id uuid not null references public.handovers(id) on delete cascade,
  item_no integer not null default 1,
  category text not null default 'document',
  title text not null,
  status text not null default 'pending',
  document_revision_id uuid references public.document_revisions(id) on delete set null,
  quality_record_id uuid references public.quality_records(id) on delete set null,
  file_url text,
  required boolean not null default true,
  accepted_at timestamptz,
  comments text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(handover_id,item_no)
);

-- ---------------------------------------------------------------------------
-- 10. Numbering, immutable approvals, calculations and graph safety.
-- ---------------------------------------------------------------------------

create or replace function public.assign_control_number_v19()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_field text;
  v_type text;
  v_prefix text;
  v_row jsonb:=to_jsonb(new);
begin
  case tg_table_name
    when 'project_documents' then v_field:='document_number';v_type:='project_document';v_prefix:='DOC';
    when 'transmittals' then v_field:='transmittal_number';v_type:='transmittal';v_prefix:='TRN';
    when 'change_orders' then v_field:='change_number';v_type:='change_order';v_prefix:='VO';
    when 'rfis' then v_field:='rfi_number';v_type:='rfi';v_prefix:='RFI';
    when 'submittals' then v_field:='submittal_number';v_type:='submittal';v_prefix:='SUB';
    when 'client_decisions' then v_field:='decision_number';v_type:='client_decision';v_prefix:='DEC';
    when 'procurement_commitments' then v_field:='commitment_number';v_type:='purchase_order';v_prefix:='PO';
    when 'production_orders' then v_field:='order_number';v_type:='production_order';v_prefix:='PROD';
    when 'quality_records' then v_field:='quality_number';v_type:='quality';v_prefix:='QC';
    when 'handovers' then v_field:='handover_number';v_type:='handover';v_prefix:='HO';
    else return new;
  end case;
  if coalesce(v_row->>v_field,'')='' then
    v_row:=jsonb_set(v_row,array[v_field],to_jsonb(public.next_document_number(v_type,v_prefix)),true);
    new:=jsonb_populate_record(new,v_row);
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'project_documents','transmittals','change_orders','rfis','submittals','client_decisions',
    'procurement_commitments','production_orders','quality_records','handovers'
  ] loop
    execute format('drop trigger if exists %I on public.%I',t||'_assign_number_v19',t);
    execute format('create trigger %I before insert on public.%I for each row execute function public.assign_control_number_v19()',t||'_assign_number_v19',t);
  end loop;
end $$;

create or replace function public.calculate_change_order_item_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  new.quantity:=coalesce(new.quantity,0);
  new.unit_price:=coalesce(new.unit_price,0);
  new.unit_cost:=coalesce(new.unit_cost,0);
  new.revenue_amount:=round(new.quantity*new.unit_price,2);
  new.cost_amount:=round(new.quantity*new.unit_cost,2);
  return new;
end;$$;

create or replace function public.recalculate_change_order_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if tg_op='DELETE' then v_id:=old.change_order_id; else v_id:=new.change_order_id; end if;
  update public.change_orders c set
    revenue_amount=x.revenue_amount,
    cost_amount=x.cost_amount,
    margin_amount=x.revenue_amount-x.cost_amount,
    vat_amount=round(x.revenue_amount*coalesce(c.vat_percent,5)/100,2),
    total_amount=x.revenue_amount+round(x.revenue_amount*coalesce(c.vat_percent,5)/100,2),
    schedule_impact_days=x.schedule_days,
    updated_at=now()
  from (
    select coalesce(sum(revenue_amount),0) revenue_amount,
      coalesce(sum(cost_amount),0) cost_amount,
      coalesce(max(schedule_impact_days),0) schedule_days
    from public.change_order_items where change_order_id=v_id
  ) x where c.id=v_id;
  if tg_op='DELETE' then return old; end if;return new;
end;$$;

drop trigger if exists change_order_items_calculate_v19 on public.change_order_items;
create trigger change_order_items_calculate_v19 before insert or update on public.change_order_items
for each row execute function public.calculate_change_order_item_v19();
drop trigger if exists change_order_items_recalculate_v19 on public.change_order_items;
create trigger change_order_items_recalculate_v19 after insert or update or delete on public.change_order_items
for each row execute function public.recalculate_change_order_v19();

create or replace function public.calculate_commitment_item_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  new.quantity:=coalesce(new.quantity,0);new.unit_price:=coalesce(new.unit_price,0);
  new.discount_percent:=greatest(0,least(100,coalesce(new.discount_percent,0)));
  new.vat_percent:=greatest(0,coalesce(new.vat_percent,0));
  new.net_amount:=round(new.quantity*new.unit_price*(1-new.discount_percent/100),2);
  new.vat_amount:=round(new.net_amount*new.vat_percent/100,2);
  new.total_amount:=new.net_amount+new.vat_amount;
  return new;
end;$$;

create or replace function public.recalculate_commitment_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if tg_op='DELETE' then v_id:=old.commitment_id;else v_id:=new.commitment_id;end if;
  update public.procurement_commitments c set
    subtotal=x.net_amount,
    vat_amount=x.vat_amount,
    total_amount=greatest(0,x.net_amount-coalesce(c.discount_amount,0))+x.vat_amount+
      coalesce(c.delivery_cost,0)+coalesce(c.customs_cost,0)+coalesce(c.other_landed_cost,0),
    base_currency_total=(greatest(0,x.net_amount-coalesce(c.discount_amount,0))+x.vat_amount+
      coalesce(c.delivery_cost,0)+coalesce(c.customs_cost,0)+coalesce(c.other_landed_cost,0))*coalesce(c.exchange_rate,1),
    updated_at=now()
  from (select coalesce(sum(net_amount),0) net_amount,coalesce(sum(vat_amount),0) vat_amount
    from public.procurement_commitment_items where commitment_id=v_id) x where c.id=v_id;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;

drop trigger if exists procurement_items_calculate_v19 on public.procurement_commitment_items;
create trigger procurement_items_calculate_v19 before insert or update on public.procurement_commitment_items
for each row execute function public.calculate_commitment_item_v19();
drop trigger if exists procurement_items_recalculate_v19 on public.procurement_commitment_items;
create trigger procurement_items_recalculate_v19 after insert or update or delete on public.procurement_commitment_items
for each row execute function public.recalculate_commitment_v19();

create or replace function public.calculate_supplier_invoice_item_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  new.quantity:=coalesce(new.quantity,0);new.unit_price:=coalesce(new.unit_price,0);
  new.vat_percent:=greatest(0,coalesce(new.vat_percent,0));
  new.net_amount:=round(new.quantity*new.unit_price,2);
  new.vat_amount:=round(new.net_amount*new.vat_percent/100,2);
  new.total_amount:=new.net_amount+new.vat_amount;
  return new;
end;$$;

create or replace function public.recalculate_supplier_invoice_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if tg_op='DELETE' then v_id:=old.invoice_id;else v_id:=new.invoice_id;end if;
  update public.supplier_invoices i set subtotal=x.net_amount,vat_amount=x.vat_amount,
    total_amount=x.total_amount+coalesce(i.additional_cost,0),updated_at=now()
  from (select coalesce(sum(net_amount),0) net_amount,coalesce(sum(vat_amount),0) vat_amount,
    coalesce(sum(total_amount),0) total_amount from public.supplier_invoice_items where invoice_id=v_id) x
  where i.id=v_id;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;

drop trigger if exists supplier_invoice_items_calculate_v19 on public.supplier_invoice_items;
create trigger supplier_invoice_items_calculate_v19 before insert or update on public.supplier_invoice_items
for each row execute function public.calculate_supplier_invoice_item_v19();
drop trigger if exists supplier_invoice_items_recalculate_v19 on public.supplier_invoice_items;
create trigger supplier_invoice_items_recalculate_v19 after insert or update or delete on public.supplier_invoice_items
for each row execute function public.recalculate_supplier_invoice_v19();

create or replace function public.calculate_production_bom_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  new.required_quantity:=round(coalesce(new.quantity,0)*(1+greatest(0,coalesce(new.waste_percent,0))/100),3);
  new.total_cost:=round(new.required_quantity*coalesce(new.unit_cost,0),2);
  return new;
end;$$;
drop trigger if exists production_bom_calculate_v19 on public.production_bom_items;
create trigger production_bom_calculate_v19 before insert or update on public.production_bom_items
for each row execute function public.calculate_production_bom_v19();

create or replace function public.set_current_document_revision_v19()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  -- The document header is protected once a controlled revision is approved.
  -- This transaction-local token allows only this revision trigger to advance
  -- the current-revision pointer and derived header status.
  perform set_config('app.phase19_document_sync',new.document_id::text,true);
  update public.project_documents set current_revision=new.revision_code,current_revision_id=new.id,
    status=case when new.status in ('approved','issued') then new.status else status end,updated_at=now()
  where id=new.document_id and (current_revision_id is null or
    new.revision_no >= coalesce((select revision_no from public.document_revisions where id=current_revision_id),-1));
  perform set_config('app.phase19_document_sync','',true);
  return new;
end;$$;
drop trigger if exists document_revisions_set_current_v19 on public.document_revisions;
create trigger document_revisions_set_current_v19 after insert or update of revision_no,revision_code,status
on public.document_revisions for each row execute function public.set_current_document_revision_v19();

create or replace function public.set_current_submittal_revision_v19()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.submittals s set current_submittal_revision_id=new.id,revision=new.revision_code,
    status=case when new.status in ('submitted','approved','approved_with_comments','rejected','revise_resubmit') then new.status else s.status end,
    submitted_at=coalesce(new.submitted_at,s.submitted_at),responded_at=coalesce(new.responded_at,s.responded_at),updated_at=now()
  where s.id=new.submittal_id and (s.current_submittal_revision_id is null or new.revision_no>=coalesce((
    select revision_no from public.submittal_revisions where id=s.current_submittal_revision_id),-1));
  return new;
end;$$;
drop trigger if exists submittal_revisions_set_current_v19 on public.submittal_revisions;
create trigger submittal_revisions_set_current_v19 after insert or update of revision_no,revision_code,status,response_code,response_comment
on public.submittal_revisions for each row execute function public.set_current_submittal_revision_v19();

create or replace function public.prevent_activity_dependency_cycle_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_pred_project uuid;v_succ_project uuid;
begin
  select project_id into v_pred_project from public.schedule_activities where id=new.predecessor_id;
  select project_id into v_succ_project from public.schedule_activities where id=new.successor_id;
  if v_pred_project is distinct from new.project_id or v_succ_project is distinct from new.project_id then
    raise exception 'Both activities must belong to dependency project';
  end if;
  if exists(
    with recursive path(id) as (
      select d.successor_id from public.activity_dependencies d
      where d.predecessor_id=new.successor_id and d.id<>coalesce(new.id,'00000000-0000-0000-0000-000000000000'::uuid)
      union
      select d.successor_id from public.activity_dependencies d join path p on d.predecessor_id=p.id
      where d.id<>coalesce(new.id,'00000000-0000-0000-0000-000000000000'::uuid)
    ) select 1 from path where id=new.predecessor_id
  ) then raise exception 'Schedule dependency creates a cycle';end if;
  return new;
end;$$;
drop trigger if exists activity_dependencies_no_cycle_v19 on public.activity_dependencies;
create trigger activity_dependencies_no_cycle_v19 before insert or update on public.activity_dependencies
for each row execute function public.prevent_activity_dependency_cycle_v19();

create or replace function public.protect_approved_baseline_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_old_status text;v_new_status text;v_guard text:=current_setting('app.phase19_baseline_approval',true);
begin
  if tg_table_name='schedule_baselines' then
    if tg_op='INSERT' then
      if new.status in ('approved','superseded') then raise exception 'Create a draft baseline and approve it through approve_schedule_baseline()';end if;
      return new;
    end if;
    if old.status in ('approved','superseded') then
      if tg_op='UPDATE' and old.status='approved' and new.status='superseded'
        and v_guard=old.project_id::text
        and (to_jsonb(new)-array['status','updated_at'])=(to_jsonb(old)-array['status','updated_at']) then return new;end if;
      raise exception 'Approved or superseded baseline is immutable; create a new version';
    end if;
    if tg_op='UPDATE' and new.status='approved' and new.status is distinct from old.status
      and v_guard is distinct from new.project_id::text then
      raise exception 'Approve a schedule baseline through approve_schedule_baseline()';
    end if;
  else
    if tg_op in ('UPDATE','DELETE') then
      select status into v_old_status from public.schedule_baselines where id=old.baseline_id;
    end if;
    if tg_op in ('INSERT','UPDATE') then
      select status into v_new_status from public.schedule_baselines where id=new.baseline_id;
    end if;
    if coalesce(v_old_status,v_new_status) in ('approved','superseded')
      or coalesce(v_new_status,v_old_status) in ('approved','superseded') then
      raise exception 'Approved or superseded baseline items are immutable';
    end if;
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists schedule_baselines_protect_v19 on public.schedule_baselines;
create trigger schedule_baselines_protect_v19 before update or delete on public.schedule_baselines
for each row execute function public.protect_approved_baseline_v19();
drop trigger if exists schedule_baseline_items_protect_v19 on public.schedule_baseline_items;
create trigger schedule_baseline_items_protect_v19 before insert or update or delete on public.schedule_baseline_items
for each row execute function public.protect_approved_baseline_v19();

create or replace function public.protect_approved_revision_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.status in ('approved','issued') then
    raise exception 'Approved or issued document revision is immutable; upload a new revision';
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists document_revisions_protect_v19 on public.document_revisions;
create trigger document_revisions_protect_v19 before update or delete on public.document_revisions
for each row execute function public.protect_approved_revision_v19();

create or replace function public.protect_approved_submittal_revision_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.status in ('approved','approved_with_comments','issued') then
    raise exception 'Approved submittal revision is immutable; create a new revision';
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists submittal_revisions_protect_v19 on public.submittal_revisions;
create trigger submittal_revisions_protect_v19 before update or delete on public.submittal_revisions
for each row execute function public.protect_approved_submittal_revision_v19();

create or replace function public.protect_controlled_document_header_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_guard text:=current_setting('app.phase19_document_sync',true);
begin
  if old.status in ('approved','issued') then
    if tg_op='DELETE' then
      raise exception 'Controlled document cannot be deleted; issue a superseding revision';
    end if;
    if v_guard=old.id::text then
      return new;
    end if;
    if new.project_id is distinct from old.project_id
      or new.document_number is distinct from old.document_number
      or new.title is distinct from old.title
      or new.document_type is distinct from old.document_type
      or new.discipline is distinct from old.discipline
      or new.current_revision is distinct from old.current_revision
      or new.current_revision_id is distinct from old.current_revision_id
      or new.description is distinct from old.description
      or new.metadata is distinct from old.metadata
      or new.created_by is distinct from old.created_by then
      raise exception 'Controlled document content is immutable; create a new revision';
    end if;
    if (old.status='approved' and new.status not in ('approved','issued','superseded','archived'))
      or (old.status='issued' and new.status not in ('issued','superseded','archived')) then
      raise exception 'Controlled document status cannot move backwards';
    end if;
  end if;
  return new;
end;$$;
drop trigger if exists project_documents_protect_controlled_v19 on public.project_documents;
create trigger project_documents_protect_controlled_v19 before update or delete on public.project_documents
for each row execute function public.protect_controlled_document_header_v19();

create or replace function public.protect_sent_transmittal_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;v_role text:=public.current_user_role();
begin
  if tg_table_name='transmittals' then
    if tg_op='DELETE' then
      if old.status in ('sent','acknowledged','closed') then raise exception 'Sent transmittal cannot be deleted';end if;
      return old;
    end if;
    if new.status='sent' and new.status is distinct from old.status then
      if v_role not in ('owner','admin','project_manager','designer') then
        raise exception 'Not allowed to issue a transmittal';
      end if;
      if not exists(select 1 from public.transmittal_items i where i.transmittal_id=new.id) then
        raise exception 'A transmittal must contain at least one document revision';
      end if;
      new.sent_at:=coalesce(new.sent_at,now());
    end if;
    if old.status in ('sent','acknowledged','closed') then
      if (old.status='sent' and new.status not in ('sent','acknowledged','closed'))
        or (old.status='acknowledged' and new.status not in ('acknowledged','closed'))
        or (old.status='closed' and new.status<>'closed') then
        raise exception 'Transmittal status cannot move backwards';
      end if;
      if new.project_id is distinct from old.project_id
        or new.transmittal_number is distinct from old.transmittal_number
        or new.subject is distinct from old.subject
        or new.recipient_type is distinct from old.recipient_type
        or new.recipient_name is distinct from old.recipient_name
        or new.recipient_email is distinct from old.recipient_email
        or new.purpose is distinct from old.purpose
        or new.due_date is distinct from old.due_date
        or new.message is distinct from old.message
        or new.created_by is distinct from old.created_by then
        raise exception 'Sent transmittal content is immutable';
      end if;
      if new.status in ('acknowledged','closed') then new.acknowledged_at:=coalesce(new.acknowledged_at,now());end if;
    end if;
    return new;
  end if;

  if tg_op='INSERT' then select status into v_status from public.transmittals where id=new.transmittal_id;
  else select status into v_status from public.transmittals where id=old.transmittal_id;end if;
  if v_status in ('sent','acknowledged','closed') then
    if tg_op in ('INSERT','DELETE') then
      raise exception 'The document list of a sent transmittal is immutable';
    end if;
    if new.transmittal_id is distinct from old.transmittal_id
      or new.document_revision_id is distinct from old.document_revision_id then
      raise exception 'A sent transmittal document cannot be replaced';
    end if;
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists transmittals_protect_sent_v19 on public.transmittals;
create trigger transmittals_protect_sent_v19 before update or delete on public.transmittals
for each row execute function public.protect_sent_transmittal_v19();
drop trigger if exists transmittal_items_protect_sent_v19 on public.transmittal_items;
create trigger transmittal_items_protect_sent_v19 before insert or update or delete on public.transmittal_items
for each row execute function public.protect_sent_transmittal_v19();

create or replace function public.protect_applied_change_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_applied timestamptz;v_status text;v_change uuid;v_guard text;
begin
  if tg_table_name='change_orders' then v_applied:=old.applied_at;v_status:=old.status;v_change:=old.id;
  elsif tg_op='INSERT' then v_change:=new.change_order_id;select applied_at,status into v_applied,v_status from public.change_orders where id=v_change;
  else v_change:=old.change_order_id;select applied_at,status into v_applied,v_status from public.change_orders where id=v_change;end if;
  v_guard:=current_setting('app.phase19_apply_change_order',true);
  if v_guard=v_change::text then
    if tg_op='DELETE' then return old;end if;return new;
  end if;
  if v_applied is not null or v_status in ('approved','client_approved') then
    raise exception 'Approved change order is immutable; apply it or create a reversing change order';
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists change_orders_protect_applied_v19 on public.change_orders;
create trigger change_orders_protect_applied_v19 before update or delete on public.change_orders
for each row execute function public.protect_applied_change_v19();
drop trigger if exists change_order_items_protect_applied_v19 on public.change_order_items;
create trigger change_order_items_protect_applied_v19 before insert or update or delete on public.change_order_items
for each row execute function public.protect_applied_change_v19();

create or replace function public.protect_approved_estimate_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;v_module text;
begin
  if tg_table_name='module_records' then
    if old.module_code='estimates' and old.status in ('approved','agreed') then
      if tg_op='DELETE' then raise exception 'Approved estimate is immutable; create a new version or variation';end if;
      if new.status not in (old.status,'archived','superseded') then
        raise exception 'Approved estimate status cannot be rolled back; create a new version';
      end if;
      if new.project_id is distinct from old.project_id or new.client_id is distinct from old.client_id
        or new.name is distinct from old.name or new.currency is distinct from old.currency
        or new.planned_amount is distinct from old.planned_amount or new.cost_amount is distinct from old.cost_amount
        or new.sale_amount is distinct from old.sale_amount or new.planned_start is distinct from old.planned_start
        or new.planned_finish is distinct from old.planned_finish or new.data is distinct from old.data then
        raise exception 'Approved estimate business fields are immutable; create a new version or variation';
      end if;
    end if;
    if tg_op='DELETE' then return old;end if;return new;
  end if;

  if tg_op='INSERT' then select status,module_code into v_status,v_module from public.module_records where id=new.record_id;
  else select status,module_code into v_status,v_module from public.module_records where id=old.record_id;end if;
  if v_module='estimates' and v_status in ('approved','agreed') then
    if tg_op in ('INSERT','DELETE') then raise exception 'Approved estimate lines are immutable; create a new version or variation';end if;
    if new.parent_line_id is distinct from old.parent_line_id or new.line_type is distinct from old.line_type
      or new.code is distinct from old.code or new.name is distinct from old.name
      or new.description is distinct from old.description or new.material_id is distinct from old.material_id
      or new.project_stage_id is distinct from old.project_stage_id or new.quantity is distinct from old.quantity
      or new.unit is distinct from old.unit or new.unit_cost is distinct from old.unit_cost
      or new.unit_sale is distinct from old.unit_sale or new.planned_amount is distinct from old.planned_amount
      or new.actual_amount is distinct from old.actual_amount or new.planned_start is distinct from old.planned_start
      or new.planned_finish is distinct from old.planned_finish or new.actual_start is distinct from old.actual_start
      or new.actual_finish is distinct from old.actual_finish or new.progress is distinct from old.progress
      or new.status is distinct from old.status or new.responsible_id is distinct from old.responsible_id
      or new.sort_order is distinct from old.sort_order or new.data is distinct from old.data then
      raise exception 'Approved estimate lines are immutable; create a new version or variation';
    end if;
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;

drop trigger if exists module_records_protect_approved_estimate_v19 on public.module_records;
create trigger module_records_protect_approved_estimate_v19 before update or delete on public.module_records
for each row execute function public.protect_approved_estimate_v19();
drop trigger if exists module_record_lines_protect_approved_estimate_v19 on public.module_record_lines;
create trigger module_record_lines_protect_approved_estimate_v19 before insert or update or delete on public.module_record_lines
for each row execute function public.protect_approved_estimate_v19();

create or replace function public.protect_committed_procurement_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;
begin
  if tg_table_name='procurement_commitments' then
    if old.status in ('approved','issued','partially_received','received','closed') then
      if tg_op='DELETE' then raise exception 'Approved commitment cannot be deleted; cancel or reverse it';end if;
      if (old.status='approved' and new.status not in ('approved','issued','cancelled'))
        or (old.status='issued' and new.status not in ('issued','partially_received','received','cancelled'))
        or (old.status='partially_received' and new.status not in ('partially_received','received','closed','cancelled'))
        or (old.status='received' and new.status not in ('received','closed'))
        or (old.status='closed' and new.status<>'closed') then
        raise exception 'Procurement status cannot move backwards';
      end if;
      if new.project_id is distinct from old.project_id or new.supplier_id is distinct from old.supplier_id
        or new.currency is distinct from old.currency or new.exchange_rate is distinct from old.exchange_rate
        or new.subtotal is distinct from old.subtotal or new.discount_amount is distinct from old.discount_amount
        or new.vat_amount is distinct from old.vat_amount or new.delivery_cost is distinct from old.delivery_cost
        or new.customs_cost is distinct from old.customs_cost or new.other_landed_cost is distinct from old.other_landed_cost
        or new.total_amount is distinct from old.total_amount then
        raise exception 'Approved commitment financial fields are immutable; use a change or cancellation';
      end if;
    end if;
  else
    if tg_op='INSERT' then select status into v_status from public.procurement_commitments where id=new.commitment_id;
    else select status into v_status from public.procurement_commitments where id=old.commitment_id;end if;
    if v_status in ('approved','issued','partially_received','received','closed') then
      if tg_op in ('INSERT','DELETE') then raise exception 'Approved commitment lines are immutable';end if;
      if new.material_id is distinct from old.material_id or new.description is distinct from old.description
        or new.quantity is distinct from old.quantity or new.unit is distinct from old.unit
        or new.unit_price is distinct from old.unit_price or new.discount_percent is distinct from old.discount_percent
        or new.vat_percent is distinct from old.vat_percent or new.cost_code_id is distinct from old.cost_code_id
        or new.project_cost_code_id is distinct from old.project_cost_code_id then
        raise exception 'Approved commitment line pricing is immutable';
      end if;
    end if;
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists procurement_commitments_protect_v19 on public.procurement_commitments;
create trigger procurement_commitments_protect_v19 before update or delete on public.procurement_commitments
for each row execute function public.protect_committed_procurement_v19();
drop trigger if exists procurement_commitment_items_protect_v19 on public.procurement_commitment_items;
create trigger procurement_commitment_items_protect_v19 before insert or update or delete on public.procurement_commitment_items
for each row execute function public.protect_committed_procurement_v19();

create or replace function public.protect_approved_supplier_invoice_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;
begin
  if tg_table_name='supplier_invoices' then v_status:=old.status;
  elsif tg_op='INSERT' then select status into v_status from public.supplier_invoices where id=new.invoice_id;
  else select status into v_status from public.supplier_invoices where id=old.invoice_id;end if;
  if v_status in ('approved','posted','paid') then
    if tg_table_name='supplier_invoices' then
      if tg_op='DELETE' then raise exception 'Approved supplier invoice cannot be deleted';end if;
      if (old.status='approved' and new.status not in ('approved','posted','paid','cancelled'))
        or (old.status='posted' and new.status not in ('posted','paid','cancelled'))
        or (old.status='paid' and new.status<>'paid') then
        raise exception 'Supplier invoice status cannot move backwards';
      end if;
      if new.project_id is distinct from old.project_id or new.supplier_id is distinct from old.supplier_id
        or new.commitment_id is distinct from old.commitment_id or new.invoice_number is distinct from old.invoice_number
        or new.invoice_date is distinct from old.invoice_date or new.currency is distinct from old.currency
        or new.exchange_rate is distinct from old.exchange_rate or new.subtotal is distinct from old.subtotal
        or new.vat_amount is distinct from old.vat_amount or new.additional_cost is distinct from old.additional_cost
        or new.total_amount is distinct from old.total_amount then
        raise exception 'Approved supplier invoice is immutable except payment tracking';
      end if;
    else
      raise exception 'Approved supplier invoice lines are immutable';
    end if;
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists supplier_invoices_protect_v19 on public.supplier_invoices;
create trigger supplier_invoices_protect_v19 before update or delete on public.supplier_invoices
for each row execute function public.protect_approved_supplier_invoice_v19();
drop trigger if exists supplier_invoice_items_protect_v19 on public.supplier_invoice_items;
create trigger supplier_invoice_items_protect_v19 before insert or update or delete on public.supplier_invoice_items
for each row execute function public.protect_approved_supplier_invoice_v19();

-- Create an immutable snapshot of the current schedule. Parent relationships
-- are restored after all rows are copied so sort order cannot break hierarchy.
create or replace function public.create_schedule_baseline(p_project_id uuid,p_name text default null)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid:=public.current_user_organization_id();v_id uuid;v_version integer;
begin
  if public.current_user_role() not in ('owner','admin','project_manager') then
    raise exception 'Not allowed to create schedule baseline';
  end if;
  if not exists(select 1 from public.projects where id=p_project_id and organization_id=v_org) then
    raise exception 'Project not found';
  end if;
  if not public.can_access_project_v19(p_project_id) then raise exception 'Project access denied';end if;
  select coalesce(max(version),0)+1 into v_version from public.schedule_baselines
    where project_id=p_project_id and organization_id=v_org;
  insert into public.schedule_baselines(organization_id,project_id,name,version,status)
  values(v_org,p_project_id,coalesce(nullif(p_name,''),'Baseline '||v_version),v_version,'draft')
  returning id into v_id;

  insert into public.schedule_baseline_items(
    organization_id,baseline_id,activity_id,stage_id,task_id,cost_code_id,wbs_code,name,
    start_date,end_date,duration_days,progress_percent,planned_quantity,unit,is_critical,sort_order,metadata
  )
  select v_org,v_id,a.id,a.stage_id,a.task_id,a.cost_code_id,a.wbs_code,a.name,
    coalesce(a.current_start,a.baseline_start),coalesce(a.current_end,a.baseline_end),a.duration_days,
    a.progress_percent,a.planned_quantity,a.unit,a.is_critical,a.sort_order,
    jsonb_build_object('source_activity_id',a.id,'captured_at',now())
  from public.schedule_activities a where a.project_id=p_project_id and a.organization_id=v_org;

  update public.schedule_baseline_items child set parent_item_id=parent.id
  from public.schedule_activities ca
  join public.schedule_baseline_items parent on parent.baseline_id=v_id and parent.activity_id=ca.parent_id
  where child.baseline_id=v_id and child.activity_id=ca.id;
  return v_id;
end;
$$;

create or replace function public.approve_schedule_baseline(p_baseline_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid:=public.current_user_organization_id();v_project uuid;v_status text;
begin
  if public.current_user_role() not in ('owner','admin','project_manager') then
    raise exception 'Not allowed to approve schedule baseline';
  end if;
  select project_id,status into v_project,v_status from public.schedule_baselines
    where id=p_baseline_id and organization_id=v_org for update;
  if v_project is null then raise exception 'Baseline not found';end if;
  if not public.can_access_project_v19(v_project) then raise exception 'Project access denied';end if;
  if v_status='approved' then return p_baseline_id;end if;
  if v_status='superseded' then raise exception 'Superseded baseline cannot be approved again; create a new baseline';end if;
  if not exists(select 1 from public.schedule_baseline_items where baseline_id=p_baseline_id) then
    raise exception 'Cannot approve an empty schedule baseline';
  end if;
  perform set_config('app.phase19_baseline_approval',v_project::text,true);
  update public.schedule_baselines set status='superseded',updated_at=now()
    where project_id=v_project and organization_id=v_org and id<>p_baseline_id and status='approved';
  update public.schedule_baselines set status='approved',approved_by=auth.uid(),approved_at=now(),updated_at=now()
    where id=p_baseline_id;
  perform set_config('app.phase19_baseline_approval','',true);
  return p_baseline_id;
end;
$$;

create unique index if not exists uq_schedule_one_approved_baseline
  on public.schedule_baselines(project_id) where status='approved';

-- Idempotently map an approved BOQ to WBS budget rows and schedule activities.
-- Existing tasks are linked via module_record_lines.linked_task_id. Missing
-- work/subwork tasks are created once and written back to the estimate line;
-- reruns update the same rows and never duplicate or delete execution history.
create or replace function public.sync_project_control_from_estimate(p_estimate_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid:=public.current_user_organization_id();
  e public.module_records%rowtype;
  l public.module_record_lines%rowtype;
  v_code text;v_cost_code uuid;v_pc uuid;v_activity uuid;v_parent_activity uuid;
  v_task uuid;v_parent_task uuid;v_is_leaf boolean;v_budget_rows integer:=0;v_activity_rows integer:=0;v_task_rows integer:=0;
begin
  if public.current_user_role() not in ('owner','admin','accountant','project_manager') then
    raise exception 'Not allowed to synchronize project control';
  end if;
  select * into e from public.module_records where id=p_estimate_id and organization_id=v_org
    and module_code='estimates' and deleted_at is null for update;
  if e.id is null then raise exception 'Estimate not found';end if;
  if e.project_id is null then raise exception 'Estimate must be linked to a project';end if;
  if not public.can_access_project_v19(e.project_id) then raise exception 'Project access denied';end if;
  if e.status not in ('agreed','approved') then raise exception 'Approve the estimate before synchronization';end if;

  for l in select * from public.module_record_lines where record_id=e.id
    order by sort_order,created_at,id
  loop
    v_code:=upper(coalesce(nullif(trim(l.code),''),'EST-'||substr(replace(l.id::text,'-',''),1,10)));
    if l.line_type in ('work','subwork','task') then
      v_task:=l.linked_task_id;v_parent_task:=null;
      if v_task is not null and not exists(select 1 from public.tasks where id=v_task and organization_id=v_org and project_id=e.project_id) then
        v_task:=null;
      end if;
      if l.parent_line_id is not null then
        select linked_task_id into v_parent_task from public.module_record_lines
          where id=l.parent_line_id and record_id=e.id;
      end if;
      if v_task is null then
        insert into public.tasks(organization_id,project_id,parent_id,title,description,assignee_id,start_date,due_date,
          priority,status,progress,cost,requires_verification,created_by)
        values(v_org,e.project_id,v_parent_task,l.name,l.description,l.responsible_id,l.planned_start,l.planned_finish,
          case when e.priority in ('low','normal','high','critical') then e.priority else 'normal' end,
          case when coalesce(l.progress,0)>=100 then 'completed' when coalesce(l.progress,0)>0 then 'in_progress' else 'new' end,
          greatest(0,least(100,round(coalesce(l.progress,0))::integer)),round(coalesce(l.quantity,0)*coalesce(l.unit_cost,0),2),true,auth.uid())
        returning id into v_task;
      else
        update public.tasks set parent_id=v_parent_task,title=l.name,description=l.description,
          assignee_id=l.responsible_id,start_date=l.planned_start,due_date=l.planned_finish,
          progress=greatest(0,least(100,round(coalesce(l.progress,0))::integer)),
          cost=round(coalesce(l.quantity,0)*coalesce(l.unit_cost,0),2),requires_verification=true,updated_at=now()
        where id=v_task;
      end if;
      update public.module_record_lines set linked_task_id=v_task,updated_at=now() where id=l.id;
      l.linked_task_id:=v_task;v_task_rows:=v_task_rows+1;
    end if;
    insert into public.cost_codes(organization_id,code,name,name_ru,category,cost_type,unit,sort_order,metadata)
    values(v_org,v_code,l.name,l.name,
      case when l.line_type='material' then 'material' when l.line_type in ('section','subsection') then 'summary' else 'work' end,
      'direct',nullif(l.unit,''),l.sort_order,jsonb_build_object('created_from_estimate',e.id))
    on conflict(organization_id,code) do update set
      unit=coalesce(public.cost_codes.unit,excluded.unit),is_active=true,updated_at=now()
    returning id into v_cost_code;

    select not exists(select 1 from public.module_record_lines c where c.parent_line_id=l.id) into v_is_leaf;
    v_pc:=null;
    if v_is_leaf or lower(coalesce(l.data->>'include_in_budget','false')) in ('true','1','yes') then
      insert into public.project_cost_codes(
        organization_id,project_id,cost_code_id,estimate_record_id,estimate_line_id,stage_id,task_id,
        budget_revenue,budget_cost,progress_percent,start_date,end_date,metadata
      ) values(
        v_org,e.project_id,v_cost_code,e.id,l.id,l.project_stage_id,l.linked_task_id,
        round(coalesce(l.quantity,0)*coalesce(l.unit_sale,0),2),
        round(coalesce(l.quantity,0)*coalesce(l.unit_cost,0),2),
        coalesce(l.progress,0),l.planned_start,l.planned_finish,
        jsonb_build_object('source','estimate','line_type',l.line_type)
      )
      on conflict(project_id,estimate_line_id) where estimate_line_id is not null do update set
        cost_code_id=excluded.cost_code_id,estimate_record_id=excluded.estimate_record_id,
        stage_id=excluded.stage_id,task_id=excluded.task_id,budget_revenue=excluded.budget_revenue,
        budget_cost=excluded.budget_cost,progress_percent=excluded.progress_percent,
        start_date=excluded.start_date,end_date=excluded.end_date,updated_at=now()
      returning id into v_pc;
      v_budget_rows:=v_budget_rows+1;
    end if;

    update public.module_record_lines set cost_code_id=v_cost_code,project_cost_code_id=v_pc,updated_at=now()
      where id=l.id;
    if l.linked_task_id is not null then
      update public.tasks set cost_code_id=v_cost_code,project_cost_code_id=v_pc,updated_at=now()
        where id=l.linked_task_id and organization_id=v_org;
    end if;
    if l.project_stage_id is not null then
      update public.project_stages set cost_code_id=v_cost_code,project_cost_code_id=v_pc
        where id=l.project_stage_id and organization_id=v_org;
    end if;

    if l.line_type in ('section','subsection','work','subwork','task','milestone') then
      v_parent_activity:=null;
      if l.parent_line_id is not null then
        select id into v_parent_activity from public.schedule_activities
          where project_id=e.project_id and source_estimate_line_id=l.parent_line_id;
      end if;
      insert into public.schedule_activities(
        organization_id,project_id,parent_id,stage_id,task_id,cost_code_id,project_cost_code_id,
        source_estimate_line_id,wbs_code,name,activity_type,status,baseline_start,baseline_end,
        current_start,current_end,duration_days,progress_percent,planned_quantity,unit,responsible_id,
        is_critical,sort_order,metadata
      ) values(
        v_org,e.project_id,v_parent_activity,l.project_stage_id,l.linked_task_id,v_cost_code,v_pc,l.id,v_code,l.name,
        case when l.line_type in ('section','subsection') then 'summary' when l.line_type='milestone' then 'milestone' else 'task' end,
        case when coalesce(l.progress,0)>=100 then 'completed' when coalesce(l.progress,0)>0 then 'in_progress' else 'not_started' end,
        l.planned_start,l.planned_finish,l.planned_start,l.planned_finish,
        case when l.planned_start is not null and l.planned_finish is not null then greatest(0,l.planned_finish-l.planned_start+1) else 0 end,
        coalesce(l.progress,0),coalesce(l.quantity,0),l.unit,l.responsible_id,
        lower(coalesce(l.data->>'is_critical','false')) in ('true','1','yes'),l.sort_order,jsonb_build_object('source','estimate')
      )
      on conflict(project_id,source_estimate_line_id) where source_estimate_line_id is not null do update set
        parent_id=excluded.parent_id,stage_id=excluded.stage_id,task_id=excluded.task_id,
        cost_code_id=excluded.cost_code_id,project_cost_code_id=excluded.project_cost_code_id,
        wbs_code=excluded.wbs_code,name=excluded.name,activity_type=excluded.activity_type,
        baseline_start=coalesce(public.schedule_activities.baseline_start,excluded.baseline_start),
        baseline_end=coalesce(public.schedule_activities.baseline_end,excluded.baseline_end),
        current_start=case when public.schedule_activities.actual_start is null then excluded.current_start else public.schedule_activities.current_start end,
        current_end=case when public.schedule_activities.actual_end is null then excluded.current_end else public.schedule_activities.current_end end,
        duration_days=excluded.duration_days,planned_quantity=excluded.planned_quantity,unit=excluded.unit,
        responsible_id=excluded.responsible_id,sort_order=excluded.sort_order,updated_at=now()
      returning id into v_activity;
      v_activity_rows:=v_activity_rows+1;
    end if;
  end loop;

  -- Repair parent links after every row exists, regardless of input ordering.
  update public.schedule_activities child set parent_id=parent.id,updated_at=now()
  from public.module_record_lines line
  join public.schedule_activities parent on parent.project_id=e.project_id and parent.source_estimate_line_id=line.parent_line_id
  where child.project_id=e.project_id and child.source_estimate_line_id=line.id and line.record_id=e.id
    and child.parent_id is distinct from parent.id;

  perform public.refresh_project_cost_control(e.project_id);
  return jsonb_build_object('estimate_id',e.id,'project_id',e.project_id,
    'budget_rows',v_budget_rows,'tasks',v_task_rows,'schedule_activities',v_activity_rows);
end;
$$;

-- Apply an approved variation once. Budget, project contract value, tasks and
-- schedule activities change together; repeated calls return without doubling.
create or replace function public.apply_approved_change_order(p_change_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid:=public.current_user_organization_id();c public.change_orders%rowtype;i public.change_order_items%rowtype;
  v_cost uuid;v_pc uuid;v_task uuid;v_activity uuid;v_count integer:=0;
  v_revenue numeric:=0;v_item_cost numeric:=0;v_schedule_impact integer:=0;
begin
  if public.current_user_role() not in ('owner','admin','accountant','project_manager') then
    raise exception 'Not allowed to apply change order';
  end if;
  select * into c from public.change_orders where id=p_change_order_id and organization_id=v_org for update;
  if c.id is null then raise exception 'Change order not found';end if;
  if not public.can_access_project_v19(c.project_id) then raise exception 'Project access denied';end if;
  if c.status not in ('approved','client_approved') then raise exception 'Change order must be approved';end if;
  if c.applied_at is not null then
    return jsonb_build_object('change_order_id',c.id,'already_applied',true);
  end if;
  perform set_config('app.phase19_apply_change_order',c.id::text,true);
  select count(*),coalesce(sum(revenue_amount),0),coalesce(sum(cost_amount),0),
    coalesce(max(schedule_impact_days),0)
  into v_count,v_revenue,v_item_cost,v_schedule_impact
  from public.change_order_items where change_order_id=c.id;
  if v_count=0 then raise exception 'Add at least one change order item before applying';end if;
  c.revenue_amount:=v_revenue;c.cost_amount:=v_item_cost;c.schedule_impact_days:=v_schedule_impact;
  update public.change_orders set revenue_amount=v_revenue,cost_amount=v_item_cost,
    margin_amount=v_revenue-v_item_cost,vat_amount=round(v_revenue*coalesce(vat_percent,5)/100,2),
    total_amount=v_revenue+round(v_revenue*coalesce(vat_percent,5)/100,2),
    schedule_impact_days=v_schedule_impact,updated_at=now() where id=c.id;
  v_count:=0;

  for i in select * from public.change_order_items where change_order_id=c.id order by sort_order,created_at loop
    v_cost:=i.cost_code_id;
    if v_cost is null then
      select id into v_cost from public.cost_codes where organization_id=v_org and code='OVH';
    end if;
    v_pc:=i.project_cost_code_id;
    if v_pc is null then
      insert into public.project_cost_codes(organization_id,project_id,cost_code_id,budget_revenue,budget_cost,metadata)
      values(v_org,c.project_id,v_cost,0,0,jsonb_build_object('source','change_order'))
      on conflict(project_id,cost_code_id) where estimate_line_id is null do update set updated_at=now()
      returning id into v_pc;
    end if;
    update public.project_cost_codes set budget_revenue=budget_revenue+i.revenue_amount,
      budget_cost=budget_cost+i.cost_amount,updated_at=now() where id=v_pc;

    v_task:=i.task_id;
    if v_task is null then
      insert into public.tasks(organization_id,project_id,stage_id,title,description,start_date,due_date,
        priority,status,progress,cost,requires_verification,entity_type,entity_id,cost_code_id,project_cost_code_id,created_by)
      values(v_org,c.project_id,i.stage_id,i.description,'Variation '||c.change_number,current_date,
        current_date+greatest(0,i.schedule_impact_days),'high','new',0,i.cost_amount,true,
        'change_order_item',i.id,v_cost,v_pc,auth.uid()) returning id into v_task;
    end if;
    v_activity:=i.schedule_activity_id;
    if v_activity is null then
      insert into public.schedule_activities(organization_id,project_id,stage_id,task_id,cost_code_id,
        project_cost_code_id,wbs_code,name,activity_type,status,current_start,current_end,duration_days,
        responsible_id,metadata)
      values(v_org,c.project_id,i.stage_id,v_task,v_cost,v_pc,
        coalesce((select code from public.cost_codes where id=v_cost),'VO'),i.description,'variation','not_started',
        current_date,current_date+greatest(0,i.schedule_impact_days),greatest(1,i.schedule_impact_days),null,
        jsonb_build_object('change_order_id',c.id,'change_order_item_id',i.id))
      returning id into v_activity;
    end if;
    update public.change_order_items set cost_code_id=v_cost,project_cost_code_id=v_pc,
      task_id=v_task,schedule_activity_id=v_activity,updated_at=now() where id=i.id;
    v_count:=v_count+1;
  end loop;

  update public.projects set contract_amount=coalesce(contract_amount,0)+c.revenue_amount,
    planned_expenses=coalesce(planned_expenses,0)+c.cost_amount,
    planned_profit=coalesce(planned_profit,0)+(c.revenue_amount-c.cost_amount)
  where id=c.project_id and organization_id=v_org;
  update public.change_orders set applied_at=now(),approved_at=coalesce(approved_at,now()),
    approved_by=coalesce(approved_by,auth.uid()),updated_at=now() where id=c.id;
  perform public.refresh_project_cost_control(c.project_id);
  return jsonb_build_object('change_order_id',c.id,'applied_items',v_count,'already_applied',false);
end;
$$;

-- Recalculate committed, actual and estimate-at-completion values from linked
-- source records. Supplier invoices are intentionally excluded from operational
-- actual cost to avoid double counting stock issues; invoices remain visible in
-- the three-way-match and cash-flow layers. An expense linked to a warehouse
-- document/stock movement, or explicitly excluded, is likewise not counted a
-- second time. Unlinked legacy expenses remain visible and can be classified.
create or replace function public.refresh_project_cost_control(p_project_id uuid default null)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid:=public.current_user_organization_id();v_count integer;
begin
  if auth.uid() is not null and public.current_user_role() not in ('owner','admin','accountant','project_manager') then
    raise exception 'Not allowed to refresh project cost control';
  end if;
  if v_org is null and p_project_id is not null then
    select organization_id into v_org from public.projects where id=p_project_id;
  end if;
  if v_org is null then return 0;end if;
  if auth.uid() is not null and p_project_id is not null and not public.can_access_project_v19(p_project_id) then
    raise exception 'Project access denied';
  end if;
  perform set_config('app.phase19_refresh_project_cost','true',true);
  with values_by_code as (
    select pc.id,
      coalesce((select sum(pci.net_amount*case when p.subtotal>0 then
          greatest(0,p.subtotal-coalesce(p.discount_amount,0)+coalesce(p.delivery_cost,0)+
            coalesce(p.customs_cost,0)+coalesce(p.other_landed_cost,0))/p.subtotal else 1 end
          *coalesce(p.exchange_rate,1))
        from public.procurement_commitment_items pci
        join public.procurement_commitments p on p.id=pci.commitment_id
        where p.organization_id=v_org and p.project_id=pc.project_id
          and p.status in ('approved','issued','partially_received','received','closed')
          and (pci.project_cost_code_id=pc.id or (pci.project_cost_code_id is null and pci.cost_code_id=pc.cost_code_id
            and pc.id=(select pc2.id from public.project_cost_codes pc2 where pc2.project_id=pc.project_id
              and pc2.cost_code_id=pc.cost_code_id order by (pc2.estimate_line_id is null) desc,pc2.created_at,pc2.id limit 1)))),0) committed,
      coalesce((select sum(e.actual_amount)
        from public.expenses e where e.organization_id=v_org and e.project_id=pc.project_id
          and e.status not in ('planned','cancelled','rejected')
          and not coalesce(e.exclude_from_project_cost,false)
          and e.warehouse_document_id is null and e.stock_movement_id is null
          and (e.project_cost_code_id=pc.id or (e.project_cost_code_id is null and e.cost_code_id=pc.cost_code_id
            and pc.id=(select pc2.id from public.project_cost_codes pc2 where pc2.project_id=pc.project_id
              and pc2.cost_code_id=pc.cost_code_id order by (pc2.estimate_line_id is null) desc,pc2.created_at,pc2.id limit 1)))),0)
      +coalesce((select sum(case
                            when pa.adjustment_type in ('salary_payment','advance') then 0
                            when pa.adjustment_type in ('penalty','deduction') then -abs(pa.amount)
                            when pa.adjustment_type in ('project_payment','bonus','overtime','additional_accrual','correction','other')
                              and coalesce(pa.source_type,'')<>'daily_log_labor' then pa.amount
                            else 0 end)
        from public.payroll_adjustments pa where pa.organization_id=v_org and pa.project_id=pc.project_id
          and coalesce(pa.approval_status,'approved') in ('approved','paid')
          and (pa.project_cost_code_id=pc.id or (pa.project_cost_code_id is null and pa.cost_code_id=pc.cost_code_id
            and pc.id=(select pc2.id from public.project_cost_codes pc2 where pc2.project_id=pc.project_id
              and pc2.cost_code_id=pc.cost_code_id order by (pc2.estimate_line_id is null) desc,pc2.created_at,pc2.id limit 1)))),0)
      +coalesce((select sum(coalesce(nullif(co.approved_amount,0),co.amount))
        from public.contractor_operations co where co.organization_id=v_org and co.project_id=pc.project_id
          and co.status in ('approved','completed','paid')
          and (co.project_cost_code_id=pc.id or (co.project_cost_code_id is null and co.cost_code_id=pc.cost_code_id
            and pc.id=(select pc2.id from public.project_cost_codes pc2 where pc2.project_id=pc.project_id
              and pc2.cost_code_id=pc.cost_code_id order by (pc2.estimate_line_id is null) desc,pc2.created_at,pc2.id limit 1)))),0)
      +coalesce((select sum(case when sm.movement_type='return' then -sm.quantity else sm.quantity end
          *coalesce(nullif(sm.landed_unit_cost,0),sm.unit_cost,0))
        from public.stock_movements sm where sm.organization_id=v_org and sm.project_id=pc.project_id
          and public.stock_movement_effective_v19(sm.id,sm.reversed_at)
          and sm.movement_type in ('issue','writeoff','defect','return')
          and (sm.project_cost_code_id=pc.id or (sm.project_cost_code_id is null and sm.cost_code_id=pc.cost_code_id
            and pc.id=(select pc2.id from public.project_cost_codes pc2 where pc2.project_id=pc.project_id
              and pc2.cost_code_id=pc.cost_code_id order by (pc2.estimate_line_id is null) desc,pc2.created_at,pc2.id limit 1)))),0)
      +coalesce((select sum(dl.cost_amount)
        from public.daily_log_labor dl join public.daily_logs d on d.id=dl.daily_log_id
        where d.organization_id=v_org and d.project_id=pc.project_id and d.status in ('submitted','approved')
          and (dl.project_cost_code_id=pc.id or (dl.project_cost_code_id is null and dl.cost_code_id=pc.cost_code_id
            and pc.id=(select pc2.id from public.project_cost_codes pc2 where pc2.project_id=pc.project_id
              and pc2.cost_code_id=pc.cost_code_id order by (pc2.estimate_line_id is null) desc,pc2.created_at,pc2.id limit 1)))),0) actual,
      coalesce((select sum(case when pci.quantity>0 then
          greatest(0,pci.quantity-pci.accepted_quantity-pci.cancelled_quantity)/pci.quantity else 0 end
          *pci.net_amount*case when p.subtotal>0 then
            greatest(0,p.subtotal-coalesce(p.discount_amount,0)+coalesce(p.delivery_cost,0)+
              coalesce(p.customs_cost,0)+coalesce(p.other_landed_cost,0))/p.subtotal else 1 end
          *coalesce(p.exchange_rate,1))
        from public.procurement_commitment_items pci
        join public.procurement_commitments p on p.id=pci.commitment_id
        where p.organization_id=v_org and p.project_id=pc.project_id
          and p.status in ('approved','issued','partially_received','received')
          and (pci.project_cost_code_id=pc.id or (pci.project_cost_code_id is null and pci.cost_code_id=pc.cost_code_id
            and pc.id=(select pc2.id from public.project_cost_codes pc2 where pc2.project_id=pc.project_id
              and pc2.cost_code_id=pc.cost_code_id order by (pc2.estimate_line_id is null) desc,pc2.created_at,pc2.id limit 1)))),0) open_commitment
    from public.project_cost_codes pc
    where pc.organization_id=v_org and (p_project_id is null or pc.project_id=p_project_id)
  )
  update public.project_cost_codes pc set committed_cost=v.committed,actual_cost=v.actual,
    forecast_cost=greatest(pc.budget_cost,v.committed,v.actual+v.open_commitment,
      coalesce(pc.manual_forecast_cost,0)),updated_at=now()
  from values_by_code v where pc.id=v.id;
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;

create or replace function public.protect_project_cost_derived_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='INSERT' then
    if coalesce(current_setting('app.phase19_refresh_project_cost',true),'')<>'true' then
      new.committed_cost:=0;new.actual_cost:=0;new.forecast_cost:=0;
    end if;
    if new.manual_forecast_cost is not null and public.current_user_role() not in ('owner','admin','accountant','project_manager') then
      raise exception 'Not allowed to set manual project forecast';
    end if;
    return new;
  end if;
  if (new.committed_cost is distinct from old.committed_cost or new.actual_cost is distinct from old.actual_cost
      or new.forecast_cost is distinct from old.forecast_cost)
    and coalesce(current_setting('app.phase19_refresh_project_cost',true),'')<>'true' then
    raise exception 'Committed, actual and forecast costs are server-calculated';
  end if;
  if new.manual_forecast_cost is distinct from old.manual_forecast_cost
    and public.current_user_role() not in ('owner','admin','accountant','project_manager') then
    raise exception 'Not allowed to set manual project forecast';
  end if;
  return new;
end;$$;
drop trigger if exists project_cost_codes_protect_derived_v19 on public.project_cost_codes;
create trigger project_cost_codes_protect_derived_v19 before insert or update on public.project_cost_codes
for each row execute function public.protect_project_cost_derived_v19();

create or replace function public.assign_unassigned_project_cost_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_code uuid;v_pc uuid;v_pc_project uuid;
begin
  if new.project_id is null then return new;end if;
  if new.project_cost_code_id is not null then
    select project_id into v_pc_project from public.project_cost_codes where id=new.project_cost_code_id;
    if v_pc_project is distinct from new.project_id then new.project_cost_code_id:=null;end if;
  end if;
  if new.cost_code_id is null then
    select id into v_code from public.cost_codes where organization_id=new.organization_id and code='UNASSIGNED';
    new.cost_code_id:=v_code;
  else v_code:=new.cost_code_id;end if;
  if new.project_cost_code_id is null then
    select id into v_pc from public.project_cost_codes where project_id=new.project_id and cost_code_id=v_code
      order by (estimate_line_id is null) desc,created_at,id limit 1;
    if v_pc is null then
      insert into public.project_cost_codes(organization_id,project_id,cost_code_id,metadata)
      values(new.organization_id,new.project_id,v_code,jsonb_build_object('system_fallback','automatic'))
      on conflict(project_id,cost_code_id) where estimate_line_id is null do update set updated_at=now()
      returning id into v_pc;
    end if;
    new.project_cost_code_id:=v_pc;
  end if;
  return new;
end;$$;

do $$ declare t text;begin
  foreach t in array array['expenses','stock_movements','payroll_adjustments','contractor_operations'] loop
    execute format('drop trigger if exists %I on public.%I','zz_'||t||'_assign_unassigned_v19',t);
    execute format('create trigger %I before insert or update of organization_id,project_id,cost_code_id,project_cost_code_id on public.%I for each row execute function public.assign_unassigned_project_cost_v19()',
      'zz_'||t||'_assign_unassigned_v19',t);
  end loop;
end $$;

create or replace function public.refresh_project_cost_from_row_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_old jsonb;v_new jsonb;v_old_project uuid;v_new_project uuid;
begin
  if tg_op<>'INSERT' then v_old:=to_jsonb(old);v_old_project:=nullif(v_old->>'project_id','')::uuid;end if;
  if tg_op<>'DELETE' then v_new:=to_jsonb(new);v_new_project:=nullif(v_new->>'project_id','')::uuid;end if;
  if v_new_project is not null then perform public.refresh_project_cost_control(v_new_project);end if;
  if v_old_project is not null and v_old_project is distinct from v_new_project then
    perform public.refresh_project_cost_control(v_old_project);
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;

do $$ declare t text;begin
  foreach t in array array['expenses','stock_movements','payroll_adjustments','contractor_operations','procurement_commitments','daily_logs'] loop
    execute format('drop trigger if exists %I on public.%I',t||'_refresh_project_cost_v19',t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.refresh_project_cost_from_row_v19()',t||'_refresh_project_cost_v19',t);
  end loop;
end $$;

create or replace function public.recalculate_schedule_activity_progress_v19(p_activity_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare v_qty numeric;v_cumulative numeric;v_daily numeric;v_explicit numeric;v_first date;v_last date;v_planned numeric;v_progress numeric;
begin
  if p_activity_id is null then return;end if;
  select max(p.actual_quantity) filter(where p.actual_quantity>0),coalesce(sum(p.quantity_completed),0),
    max(p.progress_percent),min(d.log_date),max(d.log_date)
  into v_cumulative,v_daily,v_explicit,v_first,v_last
  from public.daily_log_progress p join public.daily_logs d on d.id=p.daily_log_id
  where p.schedule_activity_id=p_activity_id and d.status in ('submitted','approved');
  v_qty:=coalesce(v_cumulative,v_daily,0);
  select planned_quantity into v_planned from public.schedule_activities where id=p_activity_id;
  if v_planned>0 then v_progress:=least(100,round(v_qty/v_planned*100,3));
  else v_progress:=coalesce(v_explicit,0);end if;
  update public.schedule_activities set actual_quantity=v_qty,progress_percent=v_progress,
    actual_start=case when v_qty>0 or v_progress>0 then coalesce(actual_start,v_first) else actual_start end,
    actual_end=case when v_progress>=100 then coalesce(v_last,current_date) else null end,
    status=case when v_progress>=100 then 'completed' when v_progress>0 then 'in_progress' else status end,
    updated_at=now() where id=p_activity_id;
end;
$$;

create or replace function public.daily_progress_refresh_activity_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_old uuid;v_new uuid;
begin
  if tg_op<>'INSERT' then v_old:=old.schedule_activity_id;end if;
  if tg_op<>'DELETE' then v_new:=new.schedule_activity_id;end if;
  perform public.recalculate_schedule_activity_progress_v19(v_old);
  if v_new is distinct from v_old then perform public.recalculate_schedule_activity_progress_v19(v_new);end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists daily_log_progress_refresh_activity_v19 on public.daily_log_progress;
create trigger daily_log_progress_refresh_activity_v19 after insert or update or delete on public.daily_log_progress
for each row execute function public.daily_progress_refresh_activity_v19();

create or replace function public.daily_log_status_refresh_activities_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare r record;
begin
  if new.status is distinct from old.status then
    for r in select distinct schedule_activity_id from public.daily_log_progress
      where daily_log_id=new.id and schedule_activity_id is not null loop
      perform public.recalculate_schedule_activity_progress_v19(r.schedule_activity_id);
    end loop;
  end if;return new;
end;$$;
drop trigger if exists daily_logs_status_refresh_activities_v19 on public.daily_logs;
create trigger daily_logs_status_refresh_activities_v19 after update of status on public.daily_logs
for each row execute function public.daily_log_status_refresh_activities_v19();

create or replace function public.sync_schedule_activity_links_v19()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.task_id is not null then
    update public.tasks set progress=greatest(0,least(100,round(new.progress_percent)::integer)),
      status=case when new.progress_percent>=100 then 'completed'
        when entity_type='schedule_activity' and entity_id=new.id and status='completed' and new.progress_percent>0 then 'in_progress'
        when entity_type='schedule_activity' and entity_id=new.id and status='completed' and new.progress_percent=0 then 'new'
        when new.progress_percent>0 and status='new' then 'in_progress' else status end,
      actual_completed_at=case when new.progress_percent>=100 then coalesce(actual_completed_at,now())
        when entity_type='schedule_activity' and entity_id=new.id and status='completed' then null else actual_completed_at end,
      entity_type=coalesce(entity_type,'schedule_activity'),entity_id=coalesce(entity_id,new.id),
      cost_code_id=coalesce(cost_code_id,new.cost_code_id),project_cost_code_id=coalesce(project_cost_code_id,new.project_cost_code_id),updated_at=now()
    where id=new.task_id;
  end if;
  if new.project_cost_code_id is not null then
    update public.project_cost_codes set progress_percent=new.progress_percent,updated_at=now() where id=new.project_cost_code_id;
  end if;
  return new;
end;$$;
drop trigger if exists schedule_activities_sync_links_v19 on public.schedule_activities;
create trigger schedule_activities_sync_links_v19 after insert or update of progress_percent,cost_code_id,project_cost_code_id
on public.schedule_activities for each row execute function public.sync_schedule_activity_links_v19();

-- Copy WBS links from the originating GRN/issue line to posted stock movements.
create or replace function public.inherit_stock_cost_code_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.warehouse_document_id is not null and (new.cost_code_id is null or new.project_cost_code_id is null) then
    select coalesce(new.cost_code_id,i.cost_code_id),coalesce(new.project_cost_code_id,i.project_cost_code_id)
    into new.cost_code_id,new.project_cost_code_id
    from public.warehouse_document_items i where i.document_id=new.warehouse_document_id
      and i.material_id=new.material_id order by i.created_at limit 1;
  end if;return new;
end;$$;
drop trigger if exists stock_movements_inherit_cost_code_v19 on public.stock_movements;
create trigger stock_movements_inherit_cost_code_v19 before insert on public.stock_movements
for each row execute function public.inherit_stock_cost_code_v19();

-- A reversed legacy movement without a compensating entry is excluded. For
-- controlled Phase 1.9 reversals both the marked original and its active
-- opposite entry remain effective and net to zero, preserving an auditable
-- double-entry trail without changing the physical balance twice.
create or replace function public.stock_movement_effective_v19(p_id uuid,p_reversed_at timestamptz)
returns boolean language sql stable security definer set search_path=public as $$
  select p_reversed_at is null or exists(
    select 1 from public.stock_movements r where r.reversal_of_id=p_id and r.reversed_at is null
  )
$$;

create or replace function public.refresh_commitment_receipt_v19(p_item_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if p_item_id is null then return;end if;
  update public.procurement_commitment_items p set
    delivered_quantity=x.delivered,accepted_quantity=x.accepted,updated_at=now()
  from (
    select coalesce(sum(i.delivered_quantity),0) delivered,coalesce(sum(i.accepted_quantity),0) accepted
    from public.warehouse_document_items i join public.warehouse_documents d on d.id=i.document_id
    where i.commitment_item_id=p_item_id and d.status in ('posted','received','partially_received')
  ) x where p.id=p_item_id;
end;$$;

create or replace function public.warehouse_item_refresh_commitment_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_old uuid;v_new uuid;
begin
  if tg_op<>'INSERT' then v_old:=old.commitment_item_id;end if;
  if tg_op<>'DELETE' then v_new:=new.commitment_item_id;end if;
  perform public.refresh_commitment_receipt_v19(v_old);
  if v_new is distinct from v_old then perform public.refresh_commitment_receipt_v19(v_new);end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists warehouse_items_refresh_commitment_v19 on public.warehouse_document_items;
create trigger warehouse_items_refresh_commitment_v19 after insert or update or delete on public.warehouse_document_items
for each row execute function public.warehouse_item_refresh_commitment_v19();

create or replace function public.invoice_item_refresh_commitment_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_old uuid;v_new uuid;
begin
  if tg_op<>'INSERT' then v_old:=old.commitment_item_id;end if;
  if tg_op<>'DELETE' then v_new:=new.commitment_item_id;end if;
  if v_old is not null then update public.procurement_commitment_items p set invoiced_quantity=coalesce((
    select sum(ii.quantity) from public.supplier_invoice_items ii join public.supplier_invoices inv on inv.id=ii.invoice_id
    where ii.commitment_item_id=v_old and inv.status in ('approved','posted','paid')),0),updated_at=now() where p.id=v_old;end if;
  if v_new is not null and v_new is distinct from v_old then update public.procurement_commitment_items p set invoiced_quantity=coalesce((
    select sum(ii.quantity) from public.supplier_invoice_items ii join public.supplier_invoices inv on inv.id=ii.invoice_id
    where ii.commitment_item_id=v_new and inv.status in ('approved','posted','paid')),0),updated_at=now() where p.id=v_new;end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists supplier_invoice_items_refresh_commitment_v19 on public.supplier_invoice_items;
create trigger supplier_invoice_items_refresh_commitment_v19 after insert or update or delete on public.supplier_invoice_items
for each row execute function public.invoice_item_refresh_commitment_v19();

create or replace function public.supplier_invoice_status_refresh_commitment_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare r record;
begin
  if new.status is distinct from old.status then
    for r in select distinct commitment_item_id from public.supplier_invoice_items
      where invoice_id=new.id and commitment_item_id is not null loop
      update public.procurement_commitment_items p set invoiced_quantity=coalesce((
        select sum(ii.quantity) from public.supplier_invoice_items ii join public.supplier_invoices inv on inv.id=ii.invoice_id
        where ii.commitment_item_id=r.commitment_item_id and inv.status in ('approved','posted','paid')),0),updated_at=now()
      where p.id=r.commitment_item_id;
    end loop;
  end if;return new;
end;$$;
drop trigger if exists supplier_invoices_status_refresh_commitment_v19 on public.supplier_invoices;
create trigger supplier_invoices_status_refresh_commitment_v19 after update of status on public.supplier_invoices
for each row execute function public.supplier_invoice_status_refresh_commitment_v19();

-- Safe posting replacement: only accepted receipt quantity becomes available.
-- Damaged quantity remains documented on the GRN but does not enter stock.
create or replace function public.post_warehouse_document(p_document_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  d public.warehouse_documents%rowtype;i public.warehouse_document_items%rowtype;
  v_type text;v_warehouse uuid;v_available numeric(14,3);v_cost numeric(14,2);v_quantity numeric(14,3);
  v_reserved numeric(14,3);v_project_reserved numeric(14,3);v_role text:=public.current_user_role();
  v_over_issue boolean;v_over_reserve boolean;
begin
  if v_role not in ('owner','admin','storekeeper') then raise exception 'Not allowed to post warehouse documents';end if;
  select * into d from public.warehouse_documents where id=p_document_id
    and organization_id=public.current_user_organization_id() for update;
  if d.id is null then raise exception 'Warehouse document not found';end if;
  if d.project_id is not null and not public.can_access_project_v19(d.project_id) then raise exception 'Project access denied';end if;
  if d.status in ('posted','received') then
    if exists(select 1 from public.stock_movements where warehouse_document_id=d.id and reversed_at is null) then return d.id;end if;
    raise exception 'Posted warehouse document has no active ledger movements; use a controlled correction';
  end if;
  if d.status in ('cancelled','reversed','in_transit','partially_received')
    or d.status not in ('draft','pending_approval','approved') then
    raise exception 'Warehouse document status % cannot be posted',d.status;
  end if;
  if exists(select 1 from public.stock_movements where warehouse_document_id=d.id and reversed_at is null) then
    raise exception 'Active stock movements already exist for this document; duplicate posting blocked';
  end if;
  if not exists(select 1 from public.warehouse_document_items where document_id=d.id) then
    raise exception 'Add at least one material before posting';
  end if;
  v_over_issue:=lower(coalesce(d.data->>'over_issue_approved','false')) in ('true','1','yes') and v_role in ('owner','admin');
  v_over_reserve:=lower(coalesce(d.data->>'over_reserve_approved','false')) in ('true','1','yes') and v_role in ('owner','admin');
  perform set_config('app.phase19_stock_post',d.id::text,true);

  for i in select * from public.warehouse_document_items where document_id=d.id order by created_at loop
    v_type:=case d.document_type when 'acceptance' then 'receipt' when 'supplier_return' then 'issue'
      when 'adjustment' then 'inventory' else d.document_type end;
    if v_type='receipt' then
      if i.delivered_quantity>0 and i.accepted_quantity+i.damaged_quantity>i.delivered_quantity then
        raise exception 'Accepted plus damaged quantity exceeds delivered quantity for material %',i.material_id;
      end if;
      v_quantity:=case when i.accepted_quantity>0 or i.delivered_quantity>0 then i.accepted_quantity else i.quantity end;
    else v_quantity:=i.quantity;end if;
    if coalesce(v_quantity,0)<0 then raise exception 'Warehouse quantity cannot be negative';end if;
    if coalesce(v_quantity,0)=0 then continue;end if;

    v_warehouse:=case when v_type in ('receipt','return','inventory')
      then coalesce(d.destination_warehouse_id,d.source_warehouse_id)
      else coalesce(d.source_warehouse_id,d.destination_warehouse_id) end;
    select coalesce(available,0),coalesce(average_purchase_price,0) into v_available,v_cost
      from public.warehouse_stock where material_id=i.material_id
        and warehouse_id=coalesce(d.source_warehouse_id,v_warehouse);
    v_available:=coalesce(v_available,0);v_cost:=coalesce(v_cost,0);
    select greatest(0,coalesce(sum(case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end),0))
      into v_project_reserved from public.stock_movements sm
      where sm.organization_id=d.organization_id and sm.material_id=i.material_id
        and sm.project_id is not distinct from d.project_id
        and coalesce(sm.warehouse_id,sm.source_warehouse_id,sm.destination_warehouse_id)=coalesce(d.source_warehouse_id,v_warehouse)
        and public.stock_movement_effective_v19(sm.id,sm.reversed_at);
    v_project_reserved:=coalesce(v_project_reserved,0);
    if v_type='issue' and v_quantity>v_available+v_project_reserved and not v_over_issue then
      raise exception 'Quantity exceeds available stock for material %',i.material_id;
    end if;
    if v_type in ('writeoff','defect','transfer') and v_quantity>v_available and not v_over_issue then
      raise exception 'Quantity exceeds unreserved available stock for material %',i.material_id;
    end if;
    if v_type='reserve' and v_quantity>v_available and not v_over_reserve then
      raise exception 'Reserve exceeds available stock for material %',i.material_id;
    end if;
    if v_type='unreserve' then
      select greatest(0,coalesce(sum(case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end),0))
        into v_reserved from public.stock_movements sm
        where sm.organization_id=d.organization_id and sm.material_id=i.material_id
          and (d.project_id is null or sm.project_id=d.project_id)
          and coalesce(sm.warehouse_id,sm.source_warehouse_id,sm.destination_warehouse_id)=coalesce(d.source_warehouse_id,v_warehouse)
          and public.stock_movement_effective_v19(sm.id,sm.reversed_at);
      if v_quantity>coalesce(v_reserved,0) then raise exception 'Unreserve exceeds active reserve for material %',i.material_id;end if;
    end if;
    if v_type in ('issue','writeoff','defect','transfer') then i.unit_cost:=v_cost;end if;
    if v_type='return' and coalesce(i.unit_cost,0)=0 and coalesce(i.landed_unit_cost,0)=0 then
      i.unit_cost:=v_cost;
    end if;

    insert into public.stock_movements(
      organization_id,material_id,warehouse_id,source_warehouse_id,destination_warehouse_id,
      project_id,task_id,stage_id,movement_type,quantity,unit_cost,landed_unit_cost,movement_date,
      performed_by,notes,reference,unit,supplier_id,warehouse_document_id,batch_id,storage_node_id,
      condition,cost_code_id,project_cost_code_id
    ) values(
      d.organization_id,i.material_id,case when v_type='transfer' then null else v_warehouse end,
      case when v_type='transfer' then d.source_warehouse_id end,
      case when v_type='transfer' then d.destination_warehouse_id end,
      d.project_id,d.task_id,d.stage_id,v_type,v_quantity,i.unit_cost,nullif(i.landed_unit_cost,0),
      d.document_date,auth.uid(),i.notes,d.document_number,i.unit,d.supplier_id,d.id,i.batch_id,
      coalesce(i.destination_storage_node_id,i.source_storage_node_id),i.condition,
      i.cost_code_id,i.project_cost_code_id
    );
  end loop;
  update public.warehouse_documents set status='posted',posted_at=now(),posted_by=auth.uid(),updated_at=now()
    where id=d.id;
  perform set_config('app.phase19_stock_post','',true);
  return d.id;
end;
$$;

create or replace function public.warehouse_status_refresh_commitment_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare r record;
begin
  if new.status is distinct from old.status then
    for r in select distinct commitment_item_id from public.warehouse_document_items
      where document_id=new.id and commitment_item_id is not null loop
      perform public.refresh_commitment_receipt_v19(r.commitment_item_id);
    end loop;
  end if;return new;
end;$$;
drop trigger if exists warehouse_documents_status_refresh_commitment_v19 on public.warehouse_documents;
create trigger warehouse_documents_status_refresh_commitment_v19 after update of status on public.warehouse_documents
for each row execute function public.warehouse_status_refresh_commitment_v19();

-- Include landed cost in the weighted average while keeping the exact existing
-- warehouse_stock column contract for backwards compatibility.
create or replace view public.warehouse_stock
with (security_invoker=true)
as
with movement_lines as (
  select organization_id,coalesce(warehouse_id,source_warehouse_id,destination_warehouse_id) warehouse_id,material_id,
    case when movement_type in ('receipt','return','inventory') then quantity
         when movement_type in ('issue','writeoff','defect') then -quantity else 0 end quantity_delta,
    case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end reserve_delta,
    case when movement_type in ('receipt','return','inventory') then
           quantity*coalesce(nullif(landed_unit_cost,0),unit_cost,0)
         when movement_type in ('issue','writeoff','defect') then
           -quantity*coalesce(nullif(landed_unit_cost,0),unit_cost,0)
         else 0 end value_delta,
    case when movement_type='receipt' then movement_date end receipt_at
  from public.stock_movements sm where movement_type<>'transfer'
    and public.stock_movement_effective_v19(sm.id,sm.reversed_at)
  union all
  select organization_id,source_warehouse_id,material_id,-quantity,0,
    -quantity*coalesce(nullif(landed_unit_cost,0),unit_cost,0),null
  from public.stock_movements sm where movement_type='transfer'
    and public.stock_movement_effective_v19(sm.id,sm.reversed_at) and source_warehouse_id is not null
  union all
  select organization_id,destination_warehouse_id,material_id,quantity,0,
    quantity*coalesce(nullif(landed_unit_cost,0),unit_cost,0),null
  from public.stock_movements sm where movement_type='transfer'
    and public.stock_movement_effective_v19(sm.id,sm.reversed_at) and destination_warehouse_id is not null
), totals as (
  select organization_id,warehouse_id,material_id,coalesce(sum(quantity_delta),0) quantity_on_hand,
    greatest(0,coalesce(sum(reserve_delta),0)) reserved,
    case when sum(quantity_delta)>0 then greatest(0,coalesce(sum(value_delta),0))/sum(quantity_delta) else 0 end average_purchase_price,
    greatest(0,coalesce(sum(value_delta),0)) inventory_value,
    max(receipt_at) last_receipt_at from movement_lines group by organization_id,warehouse_id,material_id
)
select organization_id,warehouse_id,material_id,quantity_on_hand,reserved,average_purchase_price,
  inventory_value,last_receipt_at,
  greatest(0,quantity_on_hand-reserved) available from totals;

create or replace function public.refresh_material_average_cost_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_material uuid;v_average numeric;
begin
  if tg_op='DELETE' then v_material:=old.material_id;else v_material:=new.material_id;end if;
  select case when sum(greatest(quantity_on_hand,0))>0
    then sum(greatest(quantity_on_hand,0)*average_purchase_price)/sum(greatest(quantity_on_hand,0)) else 0 end
  into v_average from public.warehouse_stock where material_id=v_material;
  perform set_config('app.phase19_material_average',v_material::text,true);
  update public.materials set average_price=coalesce(v_average,0),updated_at=now() where id=v_material;
  perform set_config('app.phase19_material_average','',true);
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists stock_movements_refresh_material_cost_v19 on public.stock_movements;
create trigger stock_movements_refresh_material_cost_v19 after insert or update or delete on public.stock_movements
for each row execute function public.refresh_material_average_cost_v19();

-- ---------------------------------------------------------------------------
-- 11. Reporting views: plan/fact, three-way match, forecast and action centre.
-- ---------------------------------------------------------------------------

create or replace view public.project_schedule_variance
with (security_invoker=true)
as
select a.organization_id,a.project_id,a.id activity_id,a.parent_id,a.wbs_code,a.name,a.activity_type,a.status,
  a.baseline_start,a.baseline_end,a.current_start,a.current_end,a.actual_start,a.actual_end,
  a.duration_days,a.progress_percent,a.planned_quantity,a.actual_quantity,a.unit,a.responsible_id,a.is_critical,
  case when a.baseline_start is not null and a.current_start is not null then a.current_start-a.baseline_start else 0 end start_variance_days,
  case when a.baseline_end is not null and a.current_end is not null then a.current_end-a.baseline_end else 0 end finish_variance_days,
  case when a.current_end is not null and a.progress_percent<100 and a.current_end<current_date then current_date-a.current_end else 0 end overdue_days,
  case when a.actual_end is not null and a.baseline_end is not null then a.actual_end-a.baseline_end
       when a.progress_percent<100 and a.baseline_end is not null and current_date>a.baseline_end then current_date-a.baseline_end else 0 end total_delay_days,
  a.delay_reason,a.cost_code_id,a.project_cost_code_id,a.task_id,a.stage_id
from public.schedule_activities a;

create or replace view public.procurement_three_way_match
with (security_invoker=true)
as
select p.organization_id,p.project_id,p.id commitment_id,p.commitment_number,p.status commitment_status,
  p.supplier_id,p.currency,pi.id commitment_item_id,pi.material_id,pi.description,pi.unit,
  pi.quantity ordered_quantity,pi.accepted_quantity received_quantity,pi.invoiced_quantity,
  pi.unit_price ordered_unit_price,pi.net_amount ordered_net_amount,
  coalesce(inv.invoice_line_count,0) invoice_line_count,coalesce(inv.invoice_net_amount,0) invoice_net_amount,
  coalesce(inv.invoice_total_amount,0) invoice_total_amount,
  case when pi.accepted_quantity>=pi.quantity-pi.cancelled_quantity then 'matched'
       when pi.accepted_quantity>0 then 'partial' else 'not_received' end quantity_match_status,
  case when coalesce(inv.invoice_line_count,0)=0 then 'invoice_pending'
       when abs(coalesce(inv.maximum_unit_price,0)-pi.unit_price)<=0.01 then 'matched' else 'price_variance' end price_match_status,
  case when coalesce(inv.invoice_line_count,0)=0 or pi.invoiced_quantity=0 then 'invoice_pending'
       when pi.invoiced_quantity>pi.accepted_quantity+0.001 then 'invoice_exceeds_receipt'
       when pi.accepted_quantity<pi.quantity-pi.cancelled_quantity then 'receipt_pending'
       when pi.invoiced_quantity<pi.accepted_quantity-0.001 then 'partial_invoice'
       when abs(pi.invoiced_quantity-pi.accepted_quantity)>0.001 then 'quantity_variance'
       when abs(coalesce(inv.maximum_unit_price,0)-pi.unit_price)>0.01 then 'price_variance'
       when abs(coalesce(inv.invoice_net_amount,0)-pi.net_amount*case when pi.quantity>0 then pi.invoiced_quantity/pi.quantity else 0 end)>0.05 then 'value_variance'
       when pi.accepted_quantity>=pi.quantity-pi.cancelled_quantity then 'matched'
       else 'review' end match_status,
  pi.cost_code_id,pi.project_cost_code_id,pi.required_date,pi.promised_date
from public.procurement_commitments p
join public.procurement_commitment_items pi on pi.commitment_id=p.id
left join (
  select ii.commitment_item_id,count(*) invoice_line_count,sum(ii.net_amount) invoice_net_amount,sum(ii.total_amount) invoice_total_amount,
    max(ii.unit_price) maximum_unit_price
  from public.supplier_invoice_items ii join public.supplier_invoices si on si.id=ii.invoice_id
  where si.status in ('approved','posted','paid') group by ii.commitment_item_id
) inv on inv.commitment_item_id=pi.id;

create or replace view public.project_cost_forecast
with (security_invoker=true)
as
select pc.organization_id,pc.project_id,pc.id project_cost_code_id,pc.cost_code_id,cc.code cost_code,
  cc.name cost_code_name,cc.name_ru cost_code_name_ru,cc.category,cc.cost_type,
  pc.budget_revenue,pc.budget_cost,pc.committed_cost,pc.actual_cost,pc.forecast_cost,
  greatest(0,pc.forecast_cost-pc.actual_cost) cost_to_complete,
  pc.budget_cost-pc.forecast_cost cost_variance,
  pc.budget_revenue-pc.forecast_cost forecast_profit,
  case when pc.budget_revenue<>0 then round((pc.budget_revenue-pc.forecast_cost)/pc.budget_revenue*100,2) else 0 end forecast_margin_percent,
  case when pc.budget_cost<>0 then round((pc.forecast_cost-pc.budget_cost)/pc.budget_cost*100,2) else 0 end cost_variance_percent,
  pc.progress_percent,pc.start_date,pc.end_date,pc.estimate_record_id,pc.estimate_line_id,
  case when pc.budget_cost<=0 and pc.forecast_cost<=0 then 'within_budget'
       when pc.budget_cost<=0 and pc.forecast_cost>0 then 'over_budget'
       when pc.forecast_cost>pc.budget_cost then 'over_budget'
       when pc.forecast_cost>=pc.budget_cost*0.9 then 'warning' else 'within_budget' end budget_status
from public.project_cost_codes pc join public.cost_codes cc on cc.id=pc.cost_code_id;

create or replace view public.project_financial_summary
with (security_invoker=true)
as
select f.organization_id,f.project_id,sum(f.budget_revenue) budget_revenue,sum(f.budget_cost) budget_cost,
  sum(f.committed_cost) committed_cost,sum(f.actual_cost) actual_cost,sum(f.forecast_cost) forecast_cost,
  sum(f.cost_to_complete) cost_to_complete,sum(f.cost_variance) cost_variance,
  sum(f.forecast_profit) forecast_profit,
  case when sum(f.budget_revenue)<>0 then round(sum(f.forecast_profit)/sum(f.budget_revenue)*100,2) else 0 end forecast_margin_percent,
  coalesce((select sum(p.amount*coalesce(p.exchange_rate,1)) from public.payments p
    where p.project_id=f.project_id and p.direction='income' and p.status='paid'),0) received_income,
  coalesce((select sum(greatest(0,p.amount)*coalesce(p.exchange_rate,1)) from public.payments p
    where p.project_id=f.project_id and p.direction='income'
      and p.status in ('expected','overdue','partially_paid','due')),0) receivable
from public.project_cost_forecast f group by f.organization_id,f.project_id;

create or replace view public.project_action_center
with (security_invoker=true)
as
select organization_id,project_id,'rfi'::text action_type,id entity_id,
  case when due_date<current_date then 'critical' else priority end severity,
  subject title,status,due_date,assigned_to owner_id,cost_impact amount,
  jsonb_build_object('number',rfi_number,'schedule_impact_days',schedule_impact_days) context
from public.rfis where status not in ('answered','closed','cancelled') and due_date is not null
union all
select organization_id,project_id,'submittal',id,
  case when due_date<current_date then 'critical' else 'normal' end,title,status,due_date,reviewer_id,0,
  jsonb_build_object('number',submittal_number,'type',submittal_type)
from public.submittals where status not in ('approved','closed','cancelled') and due_date is not null
union all
select organization_id,project_id,'client_decision',id,
  case when due_date<current_date then 'critical' else 'high' end,title,status,due_date,responsible_id,cost_impact,
  jsonb_build_object('number',decision_number,'schedule_impact_days',schedule_impact_days)
from public.client_decisions where status not in ('decided','closed','cancelled') and due_date is not null
union all
select organization_id,project_id,'schedule_delay',id,
  case when is_critical then 'critical' else 'high' end,name,status,current_end,responsible_id,0,
  jsonb_build_object('wbs_code',wbs_code,'overdue_days',current_date-current_end,'delay_reason',delay_reason)
from public.schedule_activities where progress_percent<100 and current_end<current_date and status<>'cancelled'
union all
select organization_id,project_id,'change_order',id,'high',title,status,
  coalesce(submitted_at::date,created_at::date),approved_by,revenue_amount,
  jsonb_build_object('number',change_number,'cost_amount',cost_amount,'schedule_impact_days',schedule_impact_days)
from public.change_orders where status in ('internal_review','priced','sent_to_client','waiting_approval')
union all
select organization_id,project_id,'procurement_delay',id,'critical',coalesce(title,commitment_number),status,
  expected_date,null,total_amount,jsonb_build_object('number',commitment_number,'supplier_id',supplier_id)
from public.procurement_commitments where expected_date<current_date and status in ('approved','issued','partially_received')
union all
select organization_id,project_id,'quality',id,
  case when severity in ('critical','major') or due_date<current_date then 'critical' else 'normal' end,
  title,status,due_date,assigned_to,0,jsonb_build_object('number',quality_number,'type',record_type)
from public.quality_records where status not in ('closed','verified','cancelled') and due_date is not null;

create or replace function public.calculate_daily_labor_cost_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_hourly numeric:=0;v_overtime numeric:=0;v_org uuid;v_project uuid;v_person_org uuid;
  v_cost_code uuid;v_project_cost uuid;
  v_privileged boolean:=public.current_user_role() in ('owner','admin','accountant','project_manager');
begin
  select organization_id,project_id into v_org,v_project from public.daily_logs where id=new.daily_log_id;
  if v_org is null or v_org is distinct from new.organization_id then raise exception 'Daily log organization mismatch';end if;
  if new.employee_id is not null then
    select organization_id,coalesce(nullif(hourly_rate,0),nullif(daily_rate,0)/nullif(standard_hours_per_day,0),0),
      coalesce(nullif(overtime_rate,0),nullif(hourly_rate,0),nullif(daily_rate,0)/nullif(standard_hours_per_day,0),0)
      into v_person_org,v_hourly,v_overtime from public.employees where id=new.employee_id;
  elsif new.contractor_id is not null then
    select organization_id into v_person_org from public.contractors where id=new.contractor_id;
    -- Contractor attendance is operational only. contractor_operations is the
    -- authoritative accrual for variable/fixed/unit/daily/hourly contracts.
    v_hourly:=0;v_overtime:=0;
  end if;
  if (new.employee_id is not null or new.contractor_id is not null)
    and (v_person_org is null or v_person_org is distinct from new.organization_id) then
    raise exception 'Employee or contractor organization mismatch';
  end if;
  if new.cost_code_id is null then
    select id into v_cost_code from public.cost_codes where organization_id=v_org and code='UNASSIGNED';
    new.cost_code_id:=v_cost_code;
  else v_cost_code:=new.cost_code_id;end if;
  if new.project_cost_code_id is null then
    select id into v_project_cost from public.project_cost_codes where project_id=v_project and cost_code_id=v_cost_code
      order by (estimate_line_id is null) desc,created_at,id limit 1;
    if v_project_cost is null then
      insert into public.project_cost_codes(organization_id,project_id,cost_code_id,metadata)
      values(v_org,v_project,v_cost_code,jsonb_build_object('system_fallback','daily_labor'))
      on conflict(project_id,cost_code_id) where estimate_line_id is null do update set updated_at=now()
      returning id into v_project_cost;
    end if;
    new.project_cost_code_id:=v_project_cost;
  end if;
  if tg_op='UPDATE' and not v_privileged
    and new.employee_id is not distinct from old.employee_id and new.contractor_id is not distinct from old.contractor_id
    and new.regular_hours is not distinct from old.regular_hours and new.overtime_hours is not distinct from old.overtime_hours then
    new.cost_amount:=old.cost_amount;return new;
  end if;
  if v_privileged and coalesce(new.cost_amount,0)<>0 then return new;end if;
  new.cost_amount:=round(coalesce(new.regular_hours,0)*coalesce(v_hourly,0)+
    coalesce(new.overtime_hours,0)*coalesce(v_overtime,0),2);
  return new;
end;$$;
drop trigger if exists daily_log_labor_calculate_cost_v19 on public.daily_log_labor;
create trigger daily_log_labor_calculate_cost_v19 before insert or update
on public.daily_log_labor for each row execute function public.calculate_daily_labor_cost_v19();

create or replace function public.daily_labor_refresh_project_cost_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_old_log uuid;v_new_log uuid;v_old_project uuid;v_new_project uuid;
begin
  if tg_op<>'INSERT' then v_old_log:=old.daily_log_id;select project_id into v_old_project from public.daily_logs where id=v_old_log;end if;
  if tg_op<>'DELETE' then v_new_log:=new.daily_log_id;select project_id into v_new_project from public.daily_logs where id=v_new_log;end if;
  if v_new_project is not null then perform public.refresh_project_cost_control(v_new_project);end if;
  if v_old_project is not null and v_old_project is distinct from v_new_project then perform public.refresh_project_cost_control(v_old_project);end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
drop trigger if exists daily_log_labor_refresh_project_cost_v19 on public.daily_log_labor;
create trigger daily_log_labor_refresh_project_cost_v19 after insert or update or delete on public.daily_log_labor
for each row execute function public.daily_labor_refresh_project_cost_v19();

create or replace function public.recalculate_production_order_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_order uuid;
begin
  if tg_op='DELETE' then v_order:=old.production_order_id;else v_order:=new.production_order_id;end if;
  update public.production_orders p set progress_percent=x.progress,
    status=case when x.progress>=100 and p.status not in ('completed','cancelled') then 'ready_for_qc'
      when x.progress>0 and p.status in ('draft','released','not_started') then 'in_progress' else p.status end,
    actual_start_date=case when x.progress>0 then coalesce(p.actual_start_date,current_date) else p.actual_start_date end,
    actual_end_date=case when x.progress>=100 then coalesce(p.actual_end_date,current_date) else p.actual_end_date end,
    updated_at=now()
  from (select coalesce(avg(progress_percent),0) progress from public.production_routing_steps
    where production_order_id=v_order) x where p.id=v_order;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
create or replace function public.validate_production_step_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status='completed' then
    if new.qc_required and (new.qc_status not in ('passed','approved') or new.qc_checked_by is null) then
      raise exception 'Required routing QC must pass before completing the operation';
    end if;
    new.progress_percent:=100;
    new.actual_end_date:=coalesce(new.actual_end_date,current_date);
  elsif new.status in ('not_started','draft') then new.progress_percent:=0;
  else new.progress_percent:=greatest(0,least(100,coalesce(new.progress_percent,0)));end if;
  if new.progress_percent>0 then new.actual_start_date:=coalesce(new.actual_start_date,current_date);end if;
  return new;
end;$$;
drop trigger if exists production_routing_validate_v19 on public.production_routing_steps;
create trigger production_routing_validate_v19 before insert or update of status,progress_percent,qc_status,qc_checked_by
on public.production_routing_steps for each row execute function public.validate_production_step_v19();

create or replace function public.validate_production_completion_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status='completed' and (tg_op='INSERT' or new.status is distinct from old.status) then
    if not exists(select 1 from public.production_routing_steps where production_order_id=new.id) then
      raise exception 'Production order needs routing steps before completion';
    end if;
    if exists(select 1 from public.production_routing_steps where production_order_id=new.id
      and (status<>'completed' or (qc_required and qc_status not in ('passed','approved')))) then
      raise exception 'Complete all routing operations and required QC first';
    end if;
    if new.qc_status not in ('passed','approved') or new.qc_approved_by is null then
      raise exception 'Final production QC approval is required';
    end if;
    if new.responsible_id is not null and new.qc_approved_by=new.responsible_id
      and public.current_user_role() not in ('owner','admin') then
      raise exception 'Production responsible person cannot self-approve final QC';
    end if;
    new.qc_approved_at:=coalesce(new.qc_approved_at,now());
    new.actual_end_date:=coalesce(new.actual_end_date,current_date);
  end if;
  return new;
end;$$;
drop trigger if exists production_orders_validate_completion_v19 on public.production_orders;
create trigger production_orders_validate_completion_v19 before insert or update of status
on public.production_orders for each row execute function public.validate_production_completion_v19();

create or replace function public.validate_daily_log_transition_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_role text:=public.current_user_role();v_guard text:=current_setting('app.phase19_daily_correction',true);
begin
  if tg_op='INSERT' then new.created_by:=auth.uid();end if;
  if tg_op='DELETE' then
    if old.status='approved' then raise exception 'Approved daily log is immutable';end if;return old;
  end if;
  if tg_op='UPDATE' and old.status='approved' then
    if v_guard=old.id::text and new.status='correction' then return new;end if;
    raise exception 'Approved daily log is immutable; open a controlled correction';
  end if;
  if tg_op='UPDATE' and old.status='submitted' and new.status='draft' then raise exception 'Submitted daily log cannot return to draft';end if;
  if new.status='submitted' and (tg_op='INSERT' or new.status is distinct from old.status) then
    new.submitted_by:=auth.uid();new.submitted_at:=now();
  end if;
  if new.status='approved' and (tg_op='INSERT' or new.status is distinct from old.status) then
    if v_role not in ('owner','admin','project_manager') then raise exception 'Not allowed to approve daily log';end if;
    if new.submitted_by=auth.uid() and v_role not in ('owner','admin') then raise exception 'Daily-log submitter cannot self-approve';end if;
    new.approved_by:=auth.uid();new.approved_at:=now();
  end if;
  return new;
end;$$;
drop trigger if exists daily_logs_transition_gate_v19 on public.daily_logs;
create trigger daily_logs_transition_gate_v19 before insert or update or delete on public.daily_logs
for each row execute function public.validate_daily_log_transition_v19();

create or replace function public.validate_quality_transition_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_role text:=public.current_user_role();v_status text;
begin
  if tg_table_name='quality_checklist_items' then
    if tg_op='INSERT' then select status into v_status from public.quality_records where id=new.quality_record_id;
    else select status into v_status from public.quality_records where id=old.quality_record_id;end if;
    if v_status in ('verified','closed') then raise exception 'Verified quality checklist is immutable';end if;
    if tg_op='DELETE' then return old;end if;return new;
  end if;
  if tg_op='INSERT' then new.reported_by:=auth.uid();
  elsif new.reported_by is distinct from old.reported_by then raise exception 'Quality reporter is immutable';end if;
  if tg_op='INSERT' and new.status in ('verified','closed') then raise exception 'Create and inspect a quality record before verification';end if;
  if tg_op='DELETE' then
    if old.status in ('verified','closed') then raise exception 'Verified quality record is immutable';end if;return old;
  end if;
  if tg_op='UPDATE' and old.status in ('verified','closed') then raise exception 'Verified quality record is immutable';end if;
  if new.status in ('verified','closed') and (tg_op='INSERT' or new.status is distinct from old.status) then
    if v_role not in ('owner','admin','project_manager','foreman') then raise exception 'Not allowed to close quality record';end if;
    if auth.uid() in (old.assigned_to,old.reported_by) and v_role not in ('owner','admin') then
      raise exception 'Assignee or reporter cannot self-verify quality record';
    end if;
    if exists(select 1 from public.quality_checklist_items i where i.quality_record_id=new.id
      and i.result not in ('passed','accepted','not_applicable')) then
      raise exception 'Complete the quality checklist before verification';
    end if;
    new.verified_by:=auth.uid();new.verified_at:=now();
    if new.status='closed' then new.closed_at:=coalesce(new.closed_at,now());end if;
  end if;
  return new;
end;$$;
drop trigger if exists quality_records_transition_gate_v19 on public.quality_records;
create trigger quality_records_transition_gate_v19 before insert or update or delete on public.quality_records
for each row execute function public.validate_quality_transition_v19();
drop trigger if exists quality_checklist_items_freeze_v19 on public.quality_checklist_items;
create trigger quality_checklist_items_freeze_v19 before insert or update or delete on public.quality_checklist_items
for each row execute function public.validate_quality_transition_v19();

create or replace function public.validate_revision_approval_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_role text:=public.current_user_role();
begin
  if tg_op='INSERT' then
    new.created_by:=auth.uid();
    if new.status in ('approved','approved_with_comments','issued') then
      raise exception 'Create a draft revision before approval';
    end if;
  elsif new.created_by is distinct from old.created_by then raise exception 'Revision creator is immutable';end if;
  if new.status in ('approved','approved_with_comments','issued')
    and (tg_op='INSERT' or new.status is distinct from old.status) then
    if v_role not in ('owner','admin','project_manager','designer') then raise exception 'Not allowed to approve project revision';end if;
    if old.created_by=auth.uid() and v_role='designer' then raise exception 'Designer author cannot self-approve revision';end if;
    if tg_table_name='document_revisions' then new.approved_by:=auth.uid();new.approved_at:=now();
    else new.reviewer_id:=auth.uid();new.approved_at:=now();end if;
  end if;
  return new;
end;$$;
drop trigger if exists document_revisions_approval_gate_v19 on public.document_revisions;
create trigger document_revisions_approval_gate_v19 before insert or update on public.document_revisions
for each row execute function public.validate_revision_approval_v19();
drop trigger if exists submittal_revisions_approval_gate_v19 on public.submittal_revisions;
create trigger submittal_revisions_approval_gate_v19 before insert or update on public.submittal_revisions
for each row execute function public.validate_revision_approval_v19();

create or replace function public.validate_commitment_transition_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_role text:=public.current_user_role();
begin
  if new.status='submitted' and (tg_op='INSERT' or new.status is distinct from old.status) then
    new.submitted_by:=coalesce(new.submitted_by,auth.uid());new.submitted_at:=coalesce(new.submitted_at,now());
  end if;
  if new.status in ('approved','issued') and (tg_op='INSERT' or new.status is distinct from old.status) then
    if v_role not in ('owner','admin','project_manager','procurement') then raise exception 'Not allowed to approve or issue commitment';end if;
    if v_role='procurement' and auth.uid() in (new.created_by,new.submitted_by) then
      raise exception 'Procurement author cannot self-approve commitment';
    end if;
    new.approved_by:=coalesce(new.approved_by,auth.uid());new.approved_at:=coalesce(new.approved_at,now());
    if new.status='issued' then new.issued_at:=coalesce(new.issued_at,now());end if;
  end if;
  return new;
end;$$;
drop trigger if exists procurement_commitments_transition_gate_v19 on public.procurement_commitments;
create trigger procurement_commitments_transition_gate_v19 before insert or update of status on public.procurement_commitments
for each row execute function public.validate_commitment_transition_v19();
drop trigger if exists production_routing_refresh_order_v19 on public.production_routing_steps;
create trigger production_routing_refresh_order_v19 after insert or update or delete on public.production_routing_steps
for each row execute function public.recalculate_production_order_v19();

create or replace function public.validate_handover_gate_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;v_role text:=public.current_user_role();
begin
  if tg_table_name='handover_items' then
    if tg_op='INSERT' then select status into v_status from public.handovers where id=new.handover_id;
    else select status into v_status from public.handovers where id=old.handover_id;end if;
    if v_status in ('accepted','handed_over','closed') then raise exception 'Completed handover items are immutable; reopen handover first';end if;
    if tg_op='DELETE' then return old;end if;return new;
  end if;
  if tg_op='DELETE' then
    if old.status in ('accepted','handed_over','closed') then raise exception 'Completed handover cannot be deleted';end if;return old;
  end if;
  if tg_op='UPDATE' and old.status in ('accepted','handed_over','closed') then
    if new.status='reopened' and v_role in ('owner','admin','project_manager') then return new;end if;
    raise exception 'Completed handover is immutable; reopen it explicitly';
  end if;
  if new.status in ('accepted','handed_over','closed')
    and (tg_op='INSERT' or new.status is distinct from old.status) then
    if v_role not in ('owner','admin','project_manager') then raise exception 'Not allowed to complete handover';end if;
    if exists(select 1 from public.quality_records q where q.project_id=new.project_id
      and q.organization_id=new.organization_id and q.severity='critical'
      and q.status not in ('closed','verified','cancelled')) then
      raise exception 'Cannot complete handover while critical quality records are open';
    end if;
    if not exists(select 1 from public.handover_items i where i.handover_id=new.id and i.required) then
      raise exception 'Add at least one required handover item before completion';
    end if;
    if exists(select 1 from public.handover_items i where i.handover_id=new.id and i.required
      and i.status not in ('accepted','completed','not_applicable')) then
      raise exception 'Cannot complete handover while required handover items are pending';
    end if;
    if coalesce(new.accepted_by_name,'')='' or
      (coalesce(new.signature_url,'')='' and coalesce(new.metadata->>'client_acceptance_reference','')='') then
      if v_role not in ('owner','admin') or lower(coalesce(new.metadata->>'acceptance_override','false')) not in ('true','1','yes')
        or coalesce(new.metadata->>'acceptance_override_reason','')='' then
        raise exception 'Client acceptance name and signature/reference are required for handover';
      end if;
      new.metadata:=new.metadata||jsonb_build_object('acceptance_override_by',auth.uid(),'acceptance_override_at',now());
    end if;
    new.accepted_at:=coalesce(new.accepted_at,now());
    new.actual_date:=coalesce(new.actual_date,current_date);
  end if;
  return new;
end;$$;
drop trigger if exists handovers_validate_gate_v19 on public.handovers;
create trigger handovers_validate_gate_v19 before insert or update or delete on public.handovers
for each row execute function public.validate_handover_gate_v19();
drop trigger if exists handover_items_freeze_v19 on public.handover_items;
create trigger handover_items_freeze_v19 before insert or update or delete on public.handover_items
for each row execute function public.validate_handover_gate_v19();

-- ---------------------------------------------------------------------------
-- 11b. Ledger and approval hardening. These guards close direct-API bypasses:
-- derived values are server-owned, approved child rows are frozen and every
-- approval transition is checked independently of the browser interface.
-- ---------------------------------------------------------------------------

create or replace function public.validate_change_order_transition_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_role text:=public.current_user_role();v_count integer;v_revenue numeric;v_cost numeric;v_days integer;
begin
  if tg_op='INSERT' then
    new.created_by:=auth.uid();
    if new.status in ('approved','client_approved') then
      raise exception 'Create the variation header and lines before approval';
    end if;
  else
    if new.created_by is distinct from old.created_by then raise exception 'Variation creator is immutable';end if;
    if old.submitted_by is not null and new.submitted_by is distinct from old.submitted_by then
      raise exception 'Variation submitter is server controlled';
    end if;
    if old.status in ('approved','client_approved') and new.status not in (old.status,'in_progress','completed','invoiced','paid') then
      raise exception 'Approved variation status cannot move backwards';
    end if;
  end if;
  if new.project_id is not null and not public.can_access_project_v19(new.project_id) then raise exception 'Project access denied';end if;
  if new.status in ('internal_review','priced','sent_to_client')
    and (tg_op='INSERT' or new.status is distinct from old.status) then
    new.submitted_by:=auth.uid();new.submitted_at:=coalesce(new.submitted_at,now());
  end if;
  if new.status in ('approved','client_approved')
    and (tg_op='INSERT' or new.status is distinct from old.status) then
    if v_role not in ('owner','admin','accountant','project_manager') then raise exception 'Not allowed to approve variation';end if;
    if old.created_by=auth.uid() and v_role not in ('owner','admin') then raise exception 'Variation creator cannot self-approve';end if;
    select count(*),coalesce(sum(revenue_amount),0),coalesce(sum(cost_amount),0),coalesce(max(schedule_impact_days),0)
      into v_count,v_revenue,v_cost,v_days from public.change_order_items where change_order_id=new.id;
    if v_count=0 then raise exception 'Add at least one variation line before approval';end if;
    if new.status='client_approved' and coalesce(new.client_signature_url,'')=''
      and coalesce(new.approval_reference,new.metadata->>'client_approval_reference','')='' then
      raise exception 'Client-approved variation requires signature or approval reference';
    end if;
    new.revenue_amount:=v_revenue;new.cost_amount:=v_cost;new.margin_amount:=v_revenue-v_cost;
    new.vat_amount:=round(v_revenue*coalesce(new.vat_percent,5)/100,2);
    new.total_amount:=v_revenue+new.vat_amount;new.schedule_impact_days:=v_days;
    new.approved_by:=auth.uid();new.approved_at:=now();
    new.submitted_by:=coalesce(old.submitted_by,auth.uid());new.submitted_at:=coalesce(old.submitted_at,now());
  end if;
  return new;
end;$$;
drop trigger if exists change_orders_transition_gate_v19 on public.change_orders;
create trigger change_orders_transition_gate_v19 before insert or update on public.change_orders
for each row execute function public.validate_change_order_transition_v19();

create or replace function public.validate_estimate_approval_v19()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.module_code='estimates' and new.status in ('approved','agreed')
    and (tg_op='INSERT' or new.status is distinct from old.status) then
    if tg_op='INSERT' or not exists(select 1 from public.module_record_lines l where l.record_id=new.id) then
      raise exception 'An estimate must contain at least one line before approval';
    end if;
    if new.project_id is not null and not public.can_access_project_v19(new.project_id) then raise exception 'Project access denied';end if;
  end if;
  return new;
end;$$;
drop trigger if exists module_records_validate_estimate_approval_v19 on public.module_records;
create trigger module_records_validate_estimate_approval_v19 before insert or update of status,module_code,project_id on public.module_records
for each row execute function public.validate_estimate_approval_v19();

create or replace function public.calculate_commitment_header_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_net numeric(16,2);v_vat numeric(16,2);
begin
  select coalesce(sum(net_amount),0),coalesce(sum(vat_amount),0) into v_net,v_vat
  from public.procurement_commitment_items where commitment_id=new.id;
  new.subtotal:=v_net;new.vat_amount:=v_vat;
  new.total_amount:=greatest(0,v_net-coalesce(new.discount_amount,0))+v_vat+
    coalesce(new.delivery_cost,0)+coalesce(new.customs_cost,0)+coalesce(new.other_landed_cost,0);
  new.base_currency_total:=round(new.total_amount*coalesce(nullif(new.exchange_rate,0),1),2);
  return new;
end;$$;
drop trigger if exists procurement_commitments_derive_totals_v19 on public.procurement_commitments;
create trigger procurement_commitments_derive_totals_v19 before insert or update of
  subtotal,vat_amount,total_amount,base_currency_total,discount_amount,delivery_cost,customs_cost,other_landed_cost,exchange_rate
on public.procurement_commitments for each row execute function public.calculate_commitment_header_v19();

create or replace function public.validate_commitment_transition_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_role text:=public.current_user_role();v_net numeric(16,2);v_vat numeric(16,2);
begin
  if tg_op='INSERT' then
    new.created_by:=auth.uid();
    if new.status in ('approved','issued','partially_received','received','closed') then
      raise exception 'Create and submit a purchase order before approval';
    end if;
  elsif new.created_by is distinct from old.created_by
    or (new.submitted_by is distinct from old.submitted_by and new.status is not distinct from old.status) then
    raise exception 'Purchase-order actor fields are server controlled';
  end if;
  if new.project_id is not null and not public.can_access_project_v19(new.project_id) then raise exception 'Project access denied';end if;
  if tg_op='UPDATE' and new.status is distinct from old.status then
    if (old.status='draft' and new.status not in ('draft','submitted','cancelled'))
      or (old.status='submitted' and new.status not in ('submitted','approved','rejected','cancelled'))
      or (old.status='rejected' and new.status not in ('rejected','draft','cancelled')) then
      raise exception 'Invalid purchase-order status transition % to %',old.status,new.status;
    end if;
  end if;
  if new.status='submitted' and (tg_op='INSERT' or new.status is distinct from old.status) then
    new.submitted_by:=auth.uid();new.submitted_at:=now();
  end if;
  if new.status in ('approved','issued') and (tg_op='INSERT' or new.status is distinct from old.status) then
    if v_role not in ('owner','admin','project_manager','procurement') then raise exception 'Not allowed to approve or issue commitment';end if;
    if not exists(select 1 from public.procurement_commitment_items where commitment_id=new.id) then
      raise exception 'Add at least one line before approving a purchase order';
    end if;
    if v_role='procurement' and old.created_by=auth.uid() then raise exception 'Procurement author cannot self-approve commitment';end if;
    select coalesce(sum(net_amount),0),coalesce(sum(vat_amount),0) into v_net,v_vat
      from public.procurement_commitment_items where commitment_id=new.id;
    new.subtotal:=v_net;new.vat_amount:=v_vat;
    new.total_amount:=greatest(0,v_net-coalesce(new.discount_amount,0))+v_vat+
      coalesce(new.delivery_cost,0)+coalesce(new.customs_cost,0)+coalesce(new.other_landed_cost,0);
    new.base_currency_total:=round(new.total_amount*coalesce(nullif(new.exchange_rate,0),1),2);
    new.approved_by:=auth.uid();new.approved_at:=now();
    if new.status='issued' then new.issued_at:=coalesce(new.issued_at,now());end if;
  end if;
  return new;
end;$$;

create or replace function public.set_commitment_derived_v19(p_item_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if p_item_id is null then return;end if;
  perform set_config('app.phase19_commitment_derived',p_item_id::text,true);
  update public.procurement_commitment_items p set
    delivered_quantity=coalesce((select sum(i.delivered_quantity) from public.warehouse_document_items i
      join public.warehouse_documents d on d.id=i.document_id where i.commitment_item_id=p_item_id
      and d.status in ('posted','received','partially_received')),0),
    accepted_quantity=coalesce((select sum(i.accepted_quantity) from public.warehouse_document_items i
      join public.warehouse_documents d on d.id=i.document_id where i.commitment_item_id=p_item_id
      and d.status in ('posted','received','partially_received')),0),
    invoiced_quantity=coalesce((select sum(ii.quantity) from public.supplier_invoice_items ii
      join public.supplier_invoices inv on inv.id=ii.invoice_id where ii.commitment_item_id=p_item_id
      and inv.status in ('approved','posted','paid')),0),updated_at=now()
  where p.id=p_item_id;
  perform set_config('app.phase19_commitment_derived','',true);
end;$$;

create or replace function public.refresh_commitment_receipt_v19(p_item_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin perform public.set_commitment_derived_v19(p_item_id);end;$$;

create or replace function public.protect_commitment_derived_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_guard text:=current_setting('app.phase19_commitment_derived',true);
begin
  if tg_op='INSERT' then
    new.delivered_quantity:=0;new.accepted_quantity:=0;new.invoiced_quantity:=0;
  elsif (new.delivered_quantity is distinct from old.delivered_quantity
      or new.accepted_quantity is distinct from old.accepted_quantity
      or new.invoiced_quantity is distinct from old.invoiced_quantity)
    and v_guard is distinct from old.id::text then
    raise exception 'Delivered, accepted and invoiced quantities are server derived';
  end if;
  return new;
end;$$;
drop trigger if exists procurement_items_protect_derived_v19 on public.procurement_commitment_items;
create trigger procurement_items_protect_derived_v19 before insert or update on public.procurement_commitment_items
for each row execute function public.protect_commitment_derived_v19();

create or replace function public.invoice_item_refresh_commitment_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_old uuid;v_new uuid;
begin
  if tg_op<>'INSERT' then v_old:=old.commitment_item_id;end if;
  if tg_op<>'DELETE' then v_new:=new.commitment_item_id;end if;
  perform public.set_commitment_derived_v19(v_old);
  if v_new is distinct from v_old then perform public.set_commitment_derived_v19(v_new);end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
create or replace function public.supplier_invoice_status_refresh_commitment_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare r record;
begin
  if new.status is distinct from old.status then
    for r in select distinct commitment_item_id from public.supplier_invoice_items
      where invoice_id=new.id and commitment_item_id is not null loop
      perform public.set_commitment_derived_v19(r.commitment_item_id);
    end loop;
  end if;return new;
end;$$;

create or replace function public.calculate_supplier_invoice_header_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_net numeric(16,2);v_vat numeric(16,2);v_total numeric(16,2);
begin
  select coalesce(sum(net_amount),0),coalesce(sum(vat_amount),0),coalesce(sum(total_amount),0)
    into v_net,v_vat,v_total from public.supplier_invoice_items where invoice_id=new.id;
  new.subtotal:=v_net;new.vat_amount:=v_vat;new.total_amount:=v_total+coalesce(new.additional_cost,0);
  return new;
end;$$;
drop trigger if exists supplier_invoices_derive_totals_v19 on public.supplier_invoices;
create trigger supplier_invoices_derive_totals_v19 before insert or update of subtotal,vat_amount,total_amount,additional_cost
on public.supplier_invoices for each row execute function public.calculate_supplier_invoice_header_v19();

create or replace function public.validate_supplier_invoice_transition_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_role text:=public.current_user_role();
begin
  if tg_op='INSERT' then
    new.created_by:=auth.uid();
    if new.status not in ('draft','received','submitted') then raise exception 'Create and submit an invoice before approval';end if;
    if v_role='procurement' and new.status not in ('draft','received','submitted') then raise exception 'Procurement cannot approve invoices';end if;
  elsif new.created_by is distinct from old.created_by then raise exception 'Invoice creator is immutable';end if;
  if new.project_id is not null and not public.can_access_project_v19(new.project_id) then raise exception 'Project access denied';end if;
  if coalesce(new.paid_amount,0)<0 or coalesce(new.paid_amount,0)>coalesce(new.total_amount,0)+0.01 then
    raise exception 'Paid amount must be between zero and invoice total';
  end if;
  if tg_op='UPDATE' and new.status is distinct from old.status then
    if (old.status in ('draft','received') and new.status not in ('draft','received','submitted','cancelled'))
      or (old.status='submitted' and new.status not in ('submitted','approved','rejected','cancelled'))
      or (old.status='rejected' and new.status not in ('rejected','draft','cancelled'))
      or (old.status='approved' and new.status not in ('approved','posted','paid','cancelled'))
      or (old.status='posted' and new.status not in ('posted','paid','cancelled'))
      or (old.status='paid' and new.status<>'paid') then
      raise exception 'Invalid supplier-invoice status transition % to %',old.status,new.status;
    end if;
  end if;
  if new.status='submitted' and (tg_op='INSERT' or new.status is distinct from old.status) then
    new.submitted_by:=auth.uid();new.submitted_at:=now();
  end if;
  if new.status in ('approved','posted','paid') and (tg_op='INSERT' or new.status is distinct from old.status) then
    if v_role not in ('owner','admin','accountant') then raise exception 'Only finance can approve or post supplier invoices';end if;
    if old.created_by=auth.uid() and v_role not in ('owner') then raise exception 'Invoice creator cannot self-approve';end if;
    if not exists(select 1 from public.supplier_invoice_items where invoice_id=new.id) then raise exception 'Invoice requires at least one line';end if;
    if coalesce(new.document_url,'')='' and lower(coalesce(new.metadata->>'manual_invoice_confirmed','false')) not in ('true','1','yes') then
      raise exception 'Attach the supplier invoice before approval';
    end if;
    new.approved_by:=coalesce(old.approved_by,auth.uid());new.approved_at:=coalesce(old.approved_at,now());
  end if;
  if new.status='paid' and (tg_op='INSERT' or new.status is distinct from old.status) then
    if coalesce(new.paid_amount,0)+0.01<coalesce(new.total_amount,0) or coalesce(new.payment_reference,'')='' then
      raise exception 'Paid invoice requires full paid amount and payment reference';
    end if;
    new.paid_by:=auth.uid();new.paid_at:=now();new.payment_status:='paid';
  end if;
  if tg_op='UPDATE' and (new.paid_amount is distinct from old.paid_amount or new.payment_reference is distinct from old.payment_reference)
    and v_role not in ('owner','admin','accountant') then raise exception 'Only finance can record invoice payment evidence';end if;
  return new;
end;$$;
drop trigger if exists supplier_invoices_transition_gate_v19 on public.supplier_invoices;
create trigger supplier_invoices_transition_gate_v19 before insert or update on public.supplier_invoices
for each row execute function public.validate_supplier_invoice_transition_v19();

create or replace function public.freeze_approved_daily_child_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_log uuid;v_status text;
begin
  if tg_op='INSERT' then v_log:=new.daily_log_id;else v_log:=old.daily_log_id;end if;
  select status into v_status from public.daily_logs where id=v_log;
  if v_status='approved' then raise exception 'Approved daily-log details are immutable; open a controlled correction';end if;
  if tg_op='UPDATE' and new.daily_log_id is distinct from old.daily_log_id then
    select status into v_status from public.daily_logs where id=new.daily_log_id;
    if v_status='approved' then raise exception 'Cannot move a row into an approved daily log';end if;
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;
do $$ declare t text;begin
  foreach t in array array['daily_log_labor','daily_log_progress','daily_log_materials','daily_log_media'] loop
    execute format('drop trigger if exists %I on public.%I',t||'_freeze_approved_v19',t);
    execute format('create trigger %I before insert or update or delete on public.%I for each row execute function public.freeze_approved_daily_child_v19()',t||'_freeze_approved_v19',t);
  end loop;
end $$;

create or replace function public.reopen_daily_log_correction_v19(p_daily_log_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_project uuid;v_org uuid:=public.current_user_organization_id();
begin
  if public.current_user_role() not in ('owner','admin','project_manager') then raise exception 'Not allowed to open a daily-log correction';end if;
  if coalesce(trim(p_reason),'')='' then raise exception 'Correction reason is required';end if;
  select project_id into v_project from public.daily_logs where id=p_daily_log_id and organization_id=v_org and status='approved' for update;
  if v_project is null then raise exception 'Approved daily log not found';end if;
  if not public.can_access_project_v19(v_project) then raise exception 'Project access denied';end if;
  perform set_config('app.phase19_daily_correction',p_daily_log_id::text,true);
  update public.daily_logs set status='correction',approved_by=null,approved_at=null,
    metadata=metadata||jsonb_build_object('correction_opened_by',auth.uid(),'correction_opened_at',now(),'correction_reason',p_reason),updated_at=now()
  where id=p_daily_log_id;
  perform set_config('app.phase19_daily_correction','',true);
  return p_daily_log_id;
end;$$;

create or replace function public.stock_balance_v19(p_org uuid,p_material uuid,p_warehouse uuid,p_project uuid default null)
returns table(quantity_on_hand numeric,reserved_total numeric,reserved_for_project numeric)
language sql stable security definer set search_path=public as $$
  with m as (
    select sm.* from public.stock_movements sm where sm.organization_id=p_org and sm.material_id=p_material
      and public.stock_movement_effective_v19(sm.id,sm.reversed_at)
  ), physical as (
    select coalesce(sum(delta),0) qty from (
      select case when movement_type in ('receipt','return','inventory') and coalesce(warehouse_id,source_warehouse_id,destination_warehouse_id)=p_warehouse then quantity
                  when movement_type in ('issue','writeoff','defect') and coalesce(warehouse_id,source_warehouse_id,destination_warehouse_id)=p_warehouse then -quantity
                  when movement_type='transfer' and source_warehouse_id=p_warehouse then -quantity
                  when movement_type='transfer' and destination_warehouse_id=p_warehouse then quantity else 0 end delta from m
    ) q
  ), reserves as (
    select coalesce(sum(case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end),0) all_reserved,
      coalesce(sum(case when project_id is not distinct from p_project then
        case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end else 0 end),0) project_reserved
    from m where coalesce(warehouse_id,source_warehouse_id,destination_warehouse_id)=p_warehouse
  )
  select physical.qty,greatest(0,reserves.all_reserved),greatest(0,reserves.project_reserved) from physical cross join reserves
$$;

create or replace function public.guard_stock_movement_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_wh uuid;v_qty numeric;v_reserved numeric;v_project_reserved numeric;v_allowed numeric;
  v_post text:=current_setting('app.phase19_stock_post',true);v_reverse text:=current_setting('app.phase19_stock_reversal',true);
  v_over_issue boolean:=false;v_over_reserve boolean:=false;
begin
  if tg_op='DELETE' then
    raise exception 'Stock ledger rows cannot be deleted; use a compensating movement or controlled reversal';
  end if;
  if tg_op='UPDATE' then
    if v_reverse=old.warehouse_document_id::text and new.reversed_at is not null
      and (to_jsonb(new)-array['reversed_at','updated_at'])=(to_jsonb(old)-array['reversed_at','updated_at']) then return new;end if;
    raise exception 'Stock ledger rows are immutable; use a compensating movement or controlled reversal';
  end if;
  if tg_op='INSERT' and new.warehouse_document_id is not null and v_post is distinct from new.warehouse_document_id::text then
    raise exception 'Document-linked stock movements can only be created by the posting service';
  end if;
  if tg_op='INSERT' and coalesce(v_post,'')='' and public.current_user_role() not in ('owner','admin','accountant','project_manager','procurement') then
    new.unit_cost:=0;new.landed_unit_cost:=null;
  end if;
  if tg_op='INSERT' and new.warehouse_document_id is not null and v_post=new.warehouse_document_id::text
    and public.current_user_role() in ('owner','admin') then
    select lower(coalesce(data->>'over_issue_approved','false')) in ('true','1','yes'),
      lower(coalesce(data->>'over_reserve_approved','false')) in ('true','1','yes')
      into v_over_issue,v_over_reserve from public.warehouse_documents where id=new.warehouse_document_id;
  end if;
  if coalesce(new.quantity,0)<=0 then raise exception 'Stock movement quantity must be greater than zero';end if;
  v_wh:=case when new.movement_type in ('issue','writeoff','defect','transfer') then coalesce(new.source_warehouse_id,new.warehouse_id)
             else coalesce(new.warehouse_id,new.destination_warehouse_id,new.source_warehouse_id) end;
  if v_wh is null then raise exception 'Warehouse is required for stock movement';end if;
  select quantity_on_hand,reserved_total,reserved_for_project into v_qty,v_reserved,v_project_reserved
    from public.stock_balance_v19(new.organization_id,new.material_id,v_wh,new.project_id);
  if tg_op='UPDATE' and old.reversed_at is null and public.stock_movement_effective_v19(old.id,old.reversed_at) then
    if old.movement_type in ('receipt','return','inventory') and coalesce(old.warehouse_id,old.destination_warehouse_id,old.source_warehouse_id)=v_wh then v_qty:=v_qty-old.quantity;
    elsif old.movement_type in ('issue','writeoff','defect') and coalesce(old.warehouse_id,old.source_warehouse_id)=v_wh then v_qty:=v_qty+old.quantity;
    elsif old.movement_type='transfer' and old.source_warehouse_id=v_wh then v_qty:=v_qty+old.quantity;
    elsif old.movement_type='transfer' and old.destination_warehouse_id=v_wh then v_qty:=v_qty-old.quantity;end if;
    if old.movement_type='reserve' and coalesce(old.warehouse_id,old.source_warehouse_id)=v_wh then v_reserved:=greatest(0,v_reserved-old.quantity);end if;
    if old.movement_type='unreserve' and coalesce(old.warehouse_id,old.source_warehouse_id)=v_wh then v_reserved:=v_reserved+old.quantity;end if;
  end if;
  v_allowed:=greatest(0,coalesce(v_qty,0)-coalesce(v_reserved,0));
  if new.movement_type='issue' then v_allowed:=v_allowed+coalesce(v_project_reserved,0);end if;
  if new.movement_type in ('issue','writeoff','defect','transfer') and new.quantity>v_allowed+0.0005
    and not coalesce(v_over_issue,false) then
    raise exception 'Stock movement exceeds available quantity';
  end if;
  if new.movement_type='reserve' and new.quantity>v_allowed+0.0005
    and not coalesce(v_over_reserve,false) then
    raise exception 'Reserve exceeds available quantity';
  end if;
  if new.movement_type='unreserve' and new.quantity>
    (case when new.project_id is null then coalesce(v_reserved,0) else coalesce(v_project_reserved,0) end)+0.0005 then
    raise exception 'Unreserve exceeds active reserve';
  end if;
  return new;
end;$$;
drop trigger if exists stock_movements_guard_v19 on public.stock_movements;
create trigger stock_movements_guard_v19 before insert or update or delete on public.stock_movements
for each row execute function public.guard_stock_movement_v19();

create or replace function public.protect_posted_warehouse_document()
returns trigger language plpgsql set search_path=public as $$
declare v_guard text:=current_setting('app.phase19_warehouse_reversal',true);
begin
  if old.status in ('posted','received','reversed','cancelled') then
    if tg_op='UPDATE' and old.status in ('posted','received') and new.status='reversed'
      and v_guard=old.id::text
      and (to_jsonb(new)-array['status','updated_at','cancelled_at','cancelled_by','reversal_document_id'])=
          (to_jsonb(old)-array['status','updated_at','cancelled_at','cancelled_by','reversal_document_id']) then return new;end if;
    raise exception 'Confirmed or cancelled warehouse document is immutable; use controlled reversal';
  end if;
  if tg_op='DELETE' then return old;end if;return new;
end;$$;

create or replace function public.reverse_warehouse_document_v19(p_document_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.warehouse_documents%rowtype;m public.stock_movements%rowtype;v_id uuid;v_type text;v_mtype text;
  v_org uuid:=public.current_user_organization_id();v_number text;
begin
  if public.current_user_role() not in ('owner','admin') then raise exception 'Only owner/admin can reverse posted stock';end if;
  if coalesce(trim(p_reason),'')='' then raise exception 'Reversal reason is required';end if;
  select * into d from public.warehouse_documents where id=p_document_id and organization_id=v_org for update;
  if d.id is null then raise exception 'Warehouse document not found';end if;
  if d.status='reversed' and d.reversal_document_id is not null then return d.reversal_document_id;end if;
  if d.status not in ('posted','received') then raise exception 'Only posted/received documents can be reversed';end if;
  if not exists(select 1 from public.stock_movements where warehouse_document_id=d.id and reversed_at is null) then
    raise exception 'No active stock movements found for reversal';
  end if;
  v_type:=case d.document_type
    when 'receipt' then 'supplier_return' when 'acceptance' then 'supplier_return' when 'return' then 'issue'
    when 'inventory' then 'writeoff' when 'adjustment' then 'writeoff'
    when 'issue' then 'receipt' when 'supplier_return' then 'receipt' when 'writeoff' then 'receipt'
    when 'defect' then 'receipt' when 'reserve' then 'unreserve' when 'unreserve' then 'reserve'
    when 'transfer' then 'transfer' else 'adjustment' end;
  v_number:=public.next_document_number('warehouse_reversal','REV');
  insert into public.warehouse_documents(organization_id,document_number,document_type,document_date,status,
    source_warehouse_id,destination_warehouse_id,project_id,stage_id,task_id,supplier_id,responsible_id,
    reason,reference,currency,notes,reversal_document_id,created_by,data)
  values(v_org,v_number,v_type,now(),'draft',
    case when d.document_type='transfer' then d.destination_warehouse_id
         when v_type in ('issue','supplier_return','writeoff','defect','reserve','unreserve') then coalesce(d.destination_warehouse_id,d.source_warehouse_id) end,
    case when d.document_type='transfer' then d.source_warehouse_id
         when v_type in ('receipt','return','inventory','adjustment') then coalesce(d.source_warehouse_id,d.destination_warehouse_id) end,
    d.project_id,d.stage_id,d.task_id,d.supplier_id,auth.uid(),p_reason,d.document_number,d.currency,
    'Controlled reversal of '||d.document_number,d.id,auth.uid(),jsonb_build_object('reversal_of',d.id,'reason',p_reason))
  returning id into v_id;

  perform set_config('app.phase19_stock_post',v_id::text,true);
  for m in select * from public.stock_movements where warehouse_document_id=d.id and reversed_at is null order by created_at,id loop
    v_mtype:=case m.movement_type when 'receipt' then 'issue' when 'return' then 'issue' when 'inventory' then 'issue'
      when 'issue' then 'receipt' when 'writeoff' then 'receipt' when 'defect' then 'receipt'
      when 'reserve' then 'unreserve' when 'unreserve' then 'reserve' when 'transfer' then 'transfer' end;
    insert into public.warehouse_document_items(organization_id,document_id,material_id,batch_id,quantity,unit,
      unit_cost,landed_unit_cost,condition,notes,cost_code_id,project_cost_code_id)
    values(v_org,v_id,m.material_id,m.batch_id,m.quantity,coalesce(m.unit,'pcs'),m.unit_cost,
      coalesce(m.landed_unit_cost,0),coalesce(m.condition,'returned'),'Reversal of movement '||m.id,m.cost_code_id,m.project_cost_code_id);
    insert into public.stock_movements(organization_id,material_id,warehouse_id,source_warehouse_id,destination_warehouse_id,
      project_id,task_id,stage_id,movement_type,quantity,unit_cost,landed_unit_cost,movement_date,performed_by,
      notes,reference,unit,supplier_id,warehouse_document_id,batch_id,storage_node_id,condition,cost_code_id,
      project_cost_code_id,reversal_of_id)
    values(v_org,m.material_id,case when v_mtype='transfer' then null
      when v_mtype in ('receipt','return','inventory') then coalesce(m.source_warehouse_id,m.warehouse_id)
      else coalesce(m.destination_warehouse_id,m.warehouse_id) end,
      case when v_mtype='transfer' then m.destination_warehouse_id end,
      case when v_mtype='transfer' then m.source_warehouse_id end,
      m.project_id,m.task_id,m.stage_id,v_mtype,m.quantity,m.unit_cost,m.landed_unit_cost,now(),auth.uid(),
      p_reason,v_number,m.unit,m.supplier_id,v_id,m.batch_id,m.storage_node_id,m.condition,m.cost_code_id,
      m.project_cost_code_id,m.id);
  end loop;
  perform set_config('app.phase19_stock_post','',true);
  perform set_config('app.phase19_stock_reversal',d.id::text,true);
  update public.stock_movements set reversed_at=now(),updated_at=now() where warehouse_document_id=d.id and reversed_at is null;
  perform set_config('app.phase19_warehouse_reversal',d.id::text,true);
  update public.warehouse_documents set status='reversed',reversal_document_id=v_id,cancelled_at=now(),cancelled_by=auth.uid(),updated_at=now() where id=d.id;
  perform set_config('app.phase19_warehouse_reversal','',true);
  update public.warehouse_documents set status='posted',posted_at=now(),posted_by=auth.uid(),updated_at=now() where id=v_id;
  perform set_config('app.phase19_stock_reversal','',true);
  return v_id;
end;$$;

create or replace function public.release_reserve_on_issue()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_reserved numeric(14,3);
begin
  if new.movement_type='issue' and new.project_id is not null then
    select greatest(0,coalesce(sum(case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end),0))
      into v_reserved from public.stock_movements sm
      where sm.organization_id=new.organization_id and sm.material_id=new.material_id and sm.project_id=new.project_id
        and coalesce(sm.warehouse_id,sm.source_warehouse_id,sm.destination_warehouse_id)=coalesce(new.warehouse_id,new.source_warehouse_id)
        and sm.id<>new.id and public.stock_movement_effective_v19(sm.id,sm.reversed_at);
    if v_reserved>0 then
      insert into public.stock_movements(organization_id,material_id,warehouse_id,project_id,task_id,movement_type,
        quantity,unit_cost,movement_date,performed_by,notes,reference,unit,supplier_id,warehouse_document_id,
        cost_code_id,project_cost_code_id)
      values(new.organization_id,new.material_id,coalesce(new.warehouse_id,new.source_warehouse_id),new.project_id,new.task_id,
        'unreserve',least(v_reserved,new.quantity),new.unit_cost,new.movement_date,new.performed_by,
        'Automatic reserve release on issue',new.reference,new.unit,new.supplier_id,new.warehouse_document_id,
        new.cost_code_id,new.project_cost_code_id);
    end if;
  end if;return new;
end;$$;

create or replace function public.protect_legacy_financial_fields_v19()
returns trigger language plpgsql set search_path=public as $$
declare v_role text:=public.current_user_role();v_guard text;
begin
  if tg_table_name='projects' then
    if tg_op='INSERT' and v_role not in ('owner','admin','accountant','project_manager') then
      new.budget:=0;new.spent:=0;new.contract_amount:=0;new.received_payments:=0;new.planned_expenses:=0;
      new.actual_expenses:=0;new.planned_profit:=0;new.actual_profit:=0;
    elsif tg_op='UPDATE' and v_role not in ('owner','admin','accountant','project_manager') and (
      new.budget is distinct from old.budget or new.spent is distinct from old.spent
      or new.contract_amount is distinct from old.contract_amount
      or new.received_payments is distinct from old.received_payments or new.planned_expenses is distinct from old.planned_expenses
      or new.actual_expenses is distinct from old.actual_expenses or new.planned_profit is distinct from old.planned_profit
      or new.actual_profit is distinct from old.actual_profit) then
      raise exception 'Not allowed to change project financial fields';
    end if;
  elsif tg_table_name='materials' then
    if tg_op='INSERT' and v_role not in ('owner','admin','accountant','project_manager','procurement') then
      new.purchase_price:=0;new.average_price:=0;new.sale_price:=0;
    elsif tg_op='UPDATE' and v_role not in ('owner','admin','accountant','project_manager','procurement') and (
      new.purchase_price is distinct from old.purchase_price or new.average_price is distinct from old.average_price
      or new.sale_price is distinct from old.sale_price) then
      v_guard:=current_setting('app.phase19_material_average',true);
      if v_guard=old.id::text and new.purchase_price is not distinct from old.purchase_price
        and new.sale_price is not distinct from old.sale_price then return new;end if;
      raise exception 'Not allowed to change material prices';
    end if;
  elsif tg_table_name='warehouse_document_items' then
    if tg_op='INSERT' and v_role not in ('owner','admin','accountant','project_manager','procurement') then
      new.unit_cost:=0;new.landed_unit_cost:=0;
    elsif tg_op='UPDATE' and v_role not in ('owner','admin','accountant','project_manager','procurement') and (
      new.unit_cost is distinct from old.unit_cost or new.landed_unit_cost is distinct from old.landed_unit_cost) then
      raise exception 'Not allowed to change warehouse item costs';
    end if;
  elsif tg_table_name='warehouse_documents' then
    v_guard:=current_setting('app.phase19_warehouse_total',true);
    if tg_op='UPDATE' and new.total_cost is distinct from old.total_cost
      and v_guard is distinct from old.id::text and v_role not in ('owner','admin','accountant','project_manager','procurement') then
      raise exception 'Warehouse document total is server controlled';
    end if;
  end if;
  return new;
end;$$;
drop trigger if exists projects_protect_finance_v19 on public.projects;
create trigger projects_protect_finance_v19 before insert or update on public.projects
for each row execute function public.protect_legacy_financial_fields_v19();
drop trigger if exists materials_protect_prices_v19 on public.materials;
create trigger materials_protect_prices_v19 before insert or update on public.materials
for each row execute function public.protect_legacy_financial_fields_v19();
drop trigger if exists warehouse_items_protect_cost_v19 on public.warehouse_document_items;
create trigger warehouse_items_protect_cost_v19 before insert or update on public.warehouse_document_items
for each row execute function public.protect_legacy_financial_fields_v19();
drop trigger if exists warehouse_documents_protect_total_v19 on public.warehouse_documents;
create trigger warehouse_documents_protect_total_v19 before update on public.warehouse_documents
for each row execute function public.protect_legacy_financial_fields_v19();

create or replace function public.recalculate_warehouse_document_total()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_document uuid:=case when tg_op='DELETE' then old.document_id else new.document_id end;
begin
  perform set_config('app.phase19_warehouse_total',v_document::text,true);
  update public.warehouse_documents d set total_cost=coalesce((select sum(quantity*coalesce(nullif(landed_unit_cost,0),unit_cost))
    from public.warehouse_document_items where document_id=v_document),0),updated_at=now() where d.id=v_document;
  perform set_config('app.phase19_warehouse_total','',true);
  if tg_op='DELETE' then return old;end if;return new;
end;$$;

-- ---------------------------------------------------------------------------
-- 12. Audit, RLS, indexes and API grants.
-- ---------------------------------------------------------------------------

create or replace function public.can_access_project_v19(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select coalesce(case when p_project_id is null then
    public.current_user_role() in ('owner','admin','accountant','procurement','storekeeper')
  else exists(
    select 1 from public.projects p
    where p.id=p_project_id and p.organization_id=public.current_user_organization_id()
      and (
        public.current_user_role() in ('owner','admin','accountant','procurement','storekeeper')
        or p.created_by=auth.uid() or p.manager_id=auth.uid() or p.foreman_id=auth.uid() or p.designer_id=auth.uid()
        or exists(select 1 from public.project_members pm where pm.project_id=p.id and pm.profile_id=auth.uid())
      )
  ) end,false)
$$;

-- Compatibility-safe privacy surfaces. These views always apply their own
-- organization/project boundary and field masking under the migration owner.
-- Legacy base-table SELECT remains available in this zero-downtime migration;
-- run phase1_9_security_cutover.sql only after the Phase 1.9 frontend has been
-- published and verified against these views.
create or replace view public.projects_secure_v19 with (security_invoker=false,security_barrier=true) as
select p.id,p.organization_id,p.name,p.number,p.client,p.client_id,p.site_id,p.project_type_id,
  p.manager_id,p.foreman_id,p.designer_id,p.category,p.project_category,p.location,p.address,p.district,
  p.status,p.progress,p.start_date,p.due_date,p.actual_end_date,p.note,p.currency,p.photo_url,p.attachments,p.custom_fields,
  p.template_source_id,p.archived_at,p.deleted_at,p.created_by,p.created_at,p.updated_at,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager') then p.budget else 0 end budget,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager') then p.spent else 0 end spent,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager') then p.contract_amount else 0 end contract_amount,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager') then p.received_payments else 0 end received_payments,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager') then p.planned_expenses else 0 end planned_expenses,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager') then p.actual_expenses else 0 end actual_expenses,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager') then p.planned_profit else 0 end planned_profit,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager') then p.actual_profit else 0 end actual_profit
from public.projects p where p.organization_id=public.current_user_organization_id() and public.can_access_project_v19(p.id);

create or replace view public.materials_secure_v19 with (security_invoker=false,security_barrier=true) as
select m.id,m.organization_id,m.code,m.sku,m.name,m.category_id,m.subcategory_id,m.subcategory,m.material_type,
  m.brand,m.brand_id,m.collection,m.color,m.decor,m.texture,m.dimensions,m.length,m.width,m.thickness,m.size,m.unit,
  m.minimum_stock,m.minimum_order_quantity,m.delivery_lead_days,m.photo_url,m.additional_photos,m.technical_drawing_url,
  m.packaging_photo_url,m.texture_photo_url,m.technical_description,m.barcode,m.qr_code,m.supplier_id,m.standard_supplier_id,
  m.supplier_links,m.attachments,m.expiry_tracking,m.batch_tracking,m.notes,m.is_active,m.archived_at,m.deleted_at,
  m.currency,m.created_at,m.updated_at,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager','procurement') then m.purchase_price end purchase_price,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager','procurement') then m.average_price end average_price,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager','procurement') then m.sale_price end sale_price
from public.materials m where m.organization_id=public.current_user_organization_id();

create or replace view public.warehouse_stock_secure_v19 with (security_invoker=false,security_barrier=true) as
select s.organization_id,s.warehouse_id,s.material_id,s.quantity_on_hand,s.reserved,s.last_receipt_at,s.available,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager','procurement') then s.average_purchase_price end average_purchase_price,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager','procurement') then s.inventory_value end inventory_value
from public.warehouse_stock s where s.organization_id=public.current_user_organization_id();

create or replace view public.warehouse_documents_secure_v19 with (security_invoker=false,security_barrier=true) as
select d.id,d.organization_id,d.document_number,d.document_type,d.document_date,d.status,d.source_warehouse_id,
  d.destination_warehouse_id,d.project_id,d.stage_id,d.task_id,d.purchase_order_record_id,d.commitment_id,
  d.supplier_invoice_id,d.supplier_id,d.recipient_id,d.foreman_id,d.responsible_id,d.reason,d.transport,d.reference,
  d.currency,d.notes,d.signatures,d.data,d.posted_at,d.posted_by,d.cancelled_at,d.cancelled_by,d.reversal_document_id,
  d.created_by,d.created_at,d.updated_at,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager','procurement') then d.total_cost end total_cost
from public.warehouse_documents d where d.organization_id=public.current_user_organization_id()
  and (d.project_id is null and public.current_user_role() in ('owner','admin','accountant','procurement','storekeeper')
    or public.can_access_project_v19(d.project_id));

create or replace view public.warehouse_document_items_secure_v19 with (security_invoker=false,security_barrier=true) as
select i.id,i.organization_id,i.document_id,i.material_id,i.order_line_id,i.commitment_item_id,i.supplier_invoice_item_id,
  i.batch_id,i.source_storage_node_id,i.destination_storage_node_id,i.ordered_quantity,i.delivered_quantity,
  i.accepted_quantity,i.damaged_quantity,i.missing_quantity,i.extra_quantity,i.quantity,i.unit,i.condition,
  i.photos,i.notes,i.cost_code_id,i.project_cost_code_id,i.created_at,i.updated_at,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager','procurement') then i.unit_cost end unit_cost,
  case when public.current_user_role() in ('owner','admin','accountant','project_manager','procurement') then i.landed_unit_cost end landed_unit_cost
from public.warehouse_document_items i join public.warehouse_documents d on d.id=i.document_id
where i.organization_id=public.current_user_organization_id()
  and d.organization_id=public.current_user_organization_id()
  and (d.project_id is null and public.current_user_role() in ('owner','admin','accountant','procurement','storekeeper')
    or public.can_access_project_v19(d.project_id));

create or replace function public.enforce_parent_organization_v19()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_row jsonb:=to_jsonb(new);v_parent uuid;v_parent_org uuid;
begin
  if nullif(v_row->>tg_argv[1],'') is null then return new;end if;
  v_parent:=(v_row->>tg_argv[1])::uuid;
  execute format('select organization_id from public.%I where id=$1',tg_argv[0])
    into v_parent_org using v_parent;
  if v_parent_org is null then raise exception 'Parent record not found';end if;
  if v_parent_org is distinct from new.organization_id then
    raise exception 'Cross-organization relation is not allowed';
  end if;
  return new;
end;
$$;

create or replace function public.validate_project_links_v19()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_row jsonb:=to_jsonb(new);v_project uuid;v_org uuid:=new.organization_id;v_parent uuid;
  v_ref_project uuid;v_ref_org uuid;v_ref_cost uuid;v_id uuid;
begin
  if tg_nargs>=2 then
    v_parent:=nullif(v_row->>tg_argv[1],'')::uuid;
    if v_parent is not null then
      execute format('select project_id,organization_id from public.%I where id=$1',tg_argv[0])
        into v_project,v_ref_org using v_parent;
      if v_ref_org is distinct from v_org then raise exception 'Cross-organization parent link is not allowed';end if;
    end if;
  else v_project:=nullif(v_row->>'project_id','')::uuid;end if;

  v_id:=nullif(v_row->>'cost_code_id','')::uuid;
  if v_id is not null then
    select organization_id into v_ref_org from public.cost_codes where id=v_id;
    if v_ref_org is distinct from v_org then raise exception 'Cost code belongs to another organization';end if;
  end if;
  v_id:=nullif(v_row->>'project_cost_code_id','')::uuid;
  if v_id is not null then
    select project_id,organization_id,cost_code_id into v_ref_project,v_ref_org,v_ref_cost from public.project_cost_codes where id=v_id;
    if v_ref_org is distinct from v_org or v_project is null or v_ref_project is distinct from v_project then
      raise exception 'Project cost code does not belong to this project';
    end if;
    if nullif(v_row->>'cost_code_id','') is not null and v_ref_cost is distinct from (v_row->>'cost_code_id')::uuid then
      raise exception 'Master and project cost codes do not match';
    end if;
  end if;

  v_id:=nullif(v_row->>'task_id','')::uuid;
  if v_id is not null then
    select project_id,organization_id into v_ref_project,v_ref_org from public.tasks where id=v_id;
    if v_ref_org is distinct from v_org or v_project is null or v_ref_project is distinct from v_project then raise exception 'Task does not belong to this project';end if;
  end if;
  v_id:=coalesce(nullif(v_row->>'stage_id','')::uuid,nullif(v_row->>'project_stage_id','')::uuid);
  if v_id is not null then
    select project_id,organization_id into v_ref_project,v_ref_org from public.project_stages where id=v_id;
    if v_ref_org is distinct from v_org or v_project is null or v_ref_project is distinct from v_project then raise exception 'Stage does not belong to this project';end if;
  end if;
  v_id:=nullif(v_row->>'schedule_activity_id','')::uuid;
  if v_id is not null then
    select project_id,organization_id into v_ref_project,v_ref_org from public.schedule_activities where id=v_id;
    if v_ref_org is distinct from v_org or v_project is null or v_ref_project is distinct from v_project then raise exception 'Schedule activity does not belong to this project';end if;
  end if;
  v_id:=nullif(v_row->>'material_id','')::uuid;
  if v_id is not null then
    select organization_id into v_ref_org from public.materials where id=v_id;
    if v_ref_org is distinct from v_org then raise exception 'Material belongs to another organization';end if;
  end if;
  v_id:=nullif(v_row->>'supplier_id','')::uuid;
  if v_id is not null then
    select organization_id into v_ref_org from public.suppliers where id=v_id;
    if v_ref_org is distinct from v_org then raise exception 'Supplier belongs to another organization';end if;
  end if;
  v_id:=nullif(v_row->>'commitment_id','')::uuid;
  if v_id is not null then
    select project_id,organization_id into v_ref_project,v_ref_org from public.procurement_commitments where id=v_id;
    if v_ref_org is distinct from v_org or (v_project is not null and v_ref_project is not null and v_ref_project is distinct from v_project) then
      raise exception 'Procurement commitment does not belong to this project';
    end if;
  end if;
  v_id:=nullif(v_row->>'commitment_item_id','')::uuid;
  if v_id is not null then
    select c.project_id,i.organization_id into v_ref_project,v_ref_org from public.procurement_commitment_items i
      join public.procurement_commitments c on c.id=i.commitment_id where i.id=v_id;
    if v_ref_org is distinct from v_org or (v_project is not null and v_ref_project is not null and v_ref_project is distinct from v_project) then
      raise exception 'Commitment item does not belong to this project';
    end if;
  end if;
  v_id:=coalesce(nullif(v_row->>'document_revision_id','')::uuid,nullif(v_row->>'related_revision_id','')::uuid,
    nullif(v_row->>'drawing_revision_id','')::uuid);
  if v_id is not null then
    select d.project_id,r.organization_id into v_ref_project,v_ref_org from public.document_revisions r
      join public.project_documents d on d.id=r.document_id where r.id=v_id;
    if v_ref_org is distinct from v_org or (v_project is not null and v_ref_project is distinct from v_project) then
      raise exception 'Document revision does not belong to this project';
    end if;
  end if;
  return new;
end;$$;

do $$ declare r record;v_trigger text;begin
  for r in select * from (values
    ('project_cost_codes',null::text,null::text),('schedule_activities',null,null),
    ('project_documents',null,null),('transmittals',null,null),('change_orders',null,null),
    ('change_order_items','change_orders','change_order_id'),('procurement_commitment_items','procurement_commitments','commitment_id'),
    ('supplier_invoice_items','supplier_invoices','invoice_id'),('production_orders',null,null),
    ('production_bom_items','production_orders','production_order_id'),('daily_log_labor','daily_logs','daily_log_id'),
    ('daily_log_progress','daily_logs','daily_log_id'),('daily_log_materials','daily_logs','daily_log_id'),
    ('daily_log_media','daily_logs','daily_log_id'),('quality_records',null,null),
    ('handover_items','handovers','handover_id'),('transmittal_items','transmittals','transmittal_id'),
    ('submittals',null,null),('client_decisions',null,null),('rfis',null,null),
    ('procurement_commitments',null,null),('supplier_invoices',null,null)
  ) as x(table_name,parent_table,parent_field) loop
    v_trigger:=substr(r.table_name||'_validate_project_links_v19',1,63);
    execute format('drop trigger if exists %I on public.%I',v_trigger,r.table_name);
    if r.parent_table is null then
      execute format('create trigger %I before insert or update on public.%I for each row execute function public.validate_project_links_v19()',v_trigger,r.table_name);
    else
      execute format('create trigger %I before insert or update on public.%I for each row execute function public.validate_project_links_v19(%L,%L)',
        v_trigger,r.table_name,r.parent_table,r.parent_field);
    end if;
  end loop;
end $$;

do $$ declare r record;v_trigger text;begin
  for r in select * from (values
    ('cost_codes','cost_codes','parent_id'),
    ('project_cost_codes','projects','project_id'),
    ('schedule_activities','projects','project_id'),('activity_dependencies','projects','project_id'),
    ('schedule_baselines','projects','project_id'),('schedule_baseline_items','schedule_baselines','baseline_id'),
    ('project_documents','projects','project_id'),('document_revisions','project_documents','document_id'),
    ('transmittals','projects','project_id'),('transmittal_items','transmittals','transmittal_id'),
    ('change_orders','projects','project_id'),('change_order_items','change_orders','change_order_id'),
    ('rfis','projects','project_id'),('submittals','projects','project_id'),
    ('submittal_revisions','submittals','submittal_id'),('client_decisions','projects','project_id'),
    ('procurement_commitments','projects','project_id'),
    ('procurement_commitment_items','procurement_commitments','commitment_id'),
    ('supplier_invoices','projects','project_id'),('supplier_invoices','procurement_commitments','commitment_id'),
    ('supplier_invoice_items','supplier_invoices','invoice_id'),
    ('production_orders','projects','project_id'),('production_bom_items','production_orders','production_order_id'),
    ('production_routing_steps','production_orders','production_order_id'),
    ('daily_logs','projects','project_id'),('daily_log_labor','daily_logs','daily_log_id'),
    ('daily_log_progress','daily_logs','daily_log_id'),('daily_log_materials','daily_logs','daily_log_id'),
    ('daily_log_media','daily_logs','daily_log_id'),('quality_records','projects','project_id'),
    ('quality_checklist_items','quality_records','quality_record_id'),('handovers','projects','project_id'),
    ('handover_items','handovers','handover_id')
  ) as x(child_table,parent_table,parent_field) loop
    v_trigger:=substr(r.child_table||'_'||r.parent_field||'_same_org_v19',1,63);
    execute format('drop trigger if exists %I on public.%I',v_trigger,r.child_table);
    execute format('create trigger %I before insert or update of organization_id,%I on public.%I for each row execute function public.enforce_parent_organization_v19(%L,%L)',
      v_trigger,r.parent_field,r.child_table,r.parent_table,r.parent_field);
  end loop;
end $$;

create or replace function public.audit_project_control_v19()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_old jsonb;v_new jsonb;v_row jsonb;v_org uuid;v_id uuid;
begin
  if tg_op in ('UPDATE','DELETE') then v_old:=to_jsonb(old);end if;
  if tg_op in ('INSERT','UPDATE') then v_new:=to_jsonb(new);end if;
  v_row:=coalesce(v_new,v_old);
  v_org:=nullif(v_row->>'organization_id','')::uuid;
  v_id:=nullif(v_row->>'id','')::uuid;
  insert into public.activity_log(organization_id,entity_type,entity_id,action,old_data,new_data,actor_id)
  values(v_org,tg_table_name,v_id,lower(tg_op),v_old,v_new,auth.uid());
  if tg_op='DELETE' then return old;end if;return new;
end;
$$;

do $$ declare t text;begin
  foreach t in array array[
    'cost_codes','project_cost_codes','schedule_activities','activity_dependencies','schedule_baselines',
    'schedule_baseline_items','project_documents','document_revisions','transmittals','transmittal_items',
    'change_orders','change_order_items','rfis','submittals','submittal_revisions','client_decisions',
    'procurement_commitments','procurement_commitment_items','supplier_invoices','supplier_invoice_items',
    'production_orders','production_bom_items','production_routing_steps','daily_logs','daily_log_labor',
    'daily_log_progress','daily_log_materials','daily_log_media','quality_records','quality_checklist_items',
    'handovers','handover_items'
  ] loop
    execute format('drop trigger if exists %I on public.%I',t||'_audit_v19',t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_project_control_v19()',t||'_audit_v19',t);
  end loop;
end $$;

do $$ declare t text;begin
  foreach t in array array[
    'cost_codes','project_cost_codes','schedule_activities','activity_dependencies','schedule_baselines',
    'project_documents','document_revisions','transmittals','change_orders','change_order_items','rfis',
    'submittals','submittal_revisions','client_decisions','procurement_commitments','procurement_commitment_items',
    'supplier_invoices','supplier_invoice_items','production_orders','production_bom_items','production_routing_steps',
    'daily_logs','daily_log_labor','daily_log_progress','daily_log_materials','quality_records',
    'quality_checklist_items','handovers','handover_items'
  ] loop
    execute format('drop trigger if exists %I on public.%I',t||'_touch_updated_at_v19',t);
    execute format('create trigger %I before update on public.%I for each row execute function public.touch_updated_at()',t||'_touch_updated_at_v19',t);
  end loop;
end $$;

-- Operational records are visible only inside the organization and only to
-- working project roles. Write permissions are split by business domain below:
-- a designer cannot issue a PO, and procurement/store roles cannot alter
-- controlled documents or approve site records.
do $$ declare t text;p text;begin
  foreach t in array array[
    'schedule_activities','activity_dependencies','schedule_baselines','schedule_baseline_items',
    'project_documents','document_revisions','transmittals','transmittal_items','rfis','submittals',
    'submittal_revisions','client_decisions','production_orders','production_routing_steps','daily_logs',
    'daily_log_progress','daily_log_materials','daily_log_media','quality_records','quality_checklist_items'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    p:=t||'_phase19_read';execute format('drop policy if exists %I on public.%I',p,t);
    execute format('create policy %I on public.%I for select to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant'',''project_manager'',''foreman'',''designer'',''procurement'',''storekeeper''))',p,t);
    p:=t||'_phase19_write';execute format('drop policy if exists %I on public.%I',p,t);
  end loop;
end $$;

do $$ declare r record;p text;begin
  for r in select * from (values
    ('schedule_activities','owner,admin,project_manager,foreman'),
    ('activity_dependencies','owner,admin,project_manager,foreman'),
    ('schedule_baselines','owner,admin,project_manager'),
    ('schedule_baseline_items','owner,admin,project_manager'),
    ('project_documents','owner,admin,project_manager,designer'),
    ('document_revisions','owner,admin,project_manager,designer'),
    ('transmittals','owner,admin,project_manager,designer'),
    ('transmittal_items','owner,admin,project_manager,designer'),
    ('rfis','owner,admin,project_manager,foreman,designer'),
    ('submittals','owner,admin,project_manager,designer'),
    ('submittal_revisions','owner,admin,project_manager,designer'),
    ('client_decisions','owner,admin,project_manager,foreman,designer'),
    ('production_orders','owner,admin,project_manager,foreman,storekeeper'),
    ('production_routing_steps','owner,admin,project_manager,foreman,storekeeper'),
    ('daily_logs','owner,admin,project_manager,foreman'),
    ('daily_log_progress','owner,admin,project_manager,foreman'),
    ('daily_log_materials','owner,admin,project_manager,foreman'),
    ('daily_log_media','owner,admin,project_manager,foreman'),
    ('quality_records','owner,admin,project_manager,foreman'),
    ('quality_checklist_items','owner,admin,project_manager,foreman')
  ) as x(table_name,roles_csv) loop
    p:=r.table_name||'_phase19_domain_write';
    execute format('drop policy if exists %I on public.%I',p,r.table_name);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role()=any(string_to_array(%L,'',''))) with check (organization_id=public.current_user_organization_id() and public.current_user_role()=any(string_to_array(%L,'','')))',
      p,r.table_name,r.roles_csv,r.roles_csv);
  end loop;
end $$;

-- Tables containing rates, costs, margins, labour cost or retention are kept
-- behind finance/procurement roles at the database layer.
do $$ declare t text;p text;begin
  foreach t in array array[
    'project_cost_codes','change_orders','change_order_items','procurement_commitments',
    'procurement_commitment_items','supplier_invoices','supplier_invoice_items','production_bom_items',
    'daily_log_labor','handovers','handover_items'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    p:=t||'_phase19_finance_read';execute format('drop policy if exists %I on public.%I',p,t);
    execute format('create policy %I on public.%I for select to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant'',''project_manager'',''procurement''))',p,t);
    p:=t||'_phase19_finance_write';execute format('drop policy if exists %I on public.%I',p,t);
  end loop;
end $$;

do $$ declare r record;p text;begin
  for r in select * from (values
    ('project_cost_codes','owner,admin,accountant,project_manager'),
    ('change_orders','owner,admin,accountant,project_manager'),
    ('change_order_items','owner,admin,accountant,project_manager'),
    ('procurement_commitments','owner,admin,project_manager,procurement'),
    ('procurement_commitment_items','owner,admin,project_manager,procurement'),
    ('supplier_invoices','owner,admin,accountant,project_manager,procurement'),
    ('supplier_invoice_items','owner,admin,accountant,project_manager,procurement'),
    ('production_bom_items','owner,admin,project_manager,procurement'),
    ('daily_log_labor','owner,admin,project_manager'),
    ('handovers','owner,admin,project_manager'),
    ('handover_items','owner,admin,project_manager')
  ) as x(table_name,roles_csv) loop
    p:=r.table_name||'_phase19_domain_write';
    execute format('drop policy if exists %I on public.%I',p,r.table_name);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role()=any(string_to_array(%L,'',''))) with check (organization_id=public.current_user_organization_id() and public.current_user_role()=any(string_to_array(%L,'','')))',
      p,r.table_name,r.roles_csv,r.roles_csv);
  end loop;
end $$;

alter table public.cost_codes enable row level security;
drop policy if exists cost_codes_phase19_read on public.cost_codes;
create policy cost_codes_phase19_read on public.cost_codes for select to authenticated
using(organization_id=public.current_user_organization_id());
drop policy if exists cost_codes_phase19_manage on public.cost_codes;
create policy cost_codes_phase19_manage on public.cost_codes for all to authenticated
using(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','accountant','project_manager'))
with check(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','accountant','project_manager'));

-- Legacy finance tables receive a restrictive project-membership boundary in
-- addition to their existing can_view_finance policy. NULL-project overhead is
-- intentionally company-wide only for owner/admin/accountant.
drop policy if exists expenses_phase19_project_scope on public.expenses;
create policy expenses_phase19_project_scope on public.expenses as restrictive for all to authenticated
using(organization_id=public.current_user_organization_id() and
  (project_id is not null and public.can_access_project_v19(project_id)
    or project_id is null and public.current_user_role() in ('owner','admin','accountant')))
with check(organization_id=public.current_user_organization_id() and
  (project_id is not null and public.can_access_project_v19(project_id)
    or project_id is null and public.current_user_role() in ('owner','admin','accountant')));
drop policy if exists payments_phase19_project_scope on public.payments;
create policy payments_phase19_project_scope on public.payments as restrictive for all to authenticated
using(organization_id=public.current_user_organization_id() and
  (project_id is not null and public.can_access_project_v19(project_id)
    or project_id is null and public.current_user_role() in ('owner','admin','accountant')))
with check(organization_id=public.current_user_organization_id() and
  (project_id is not null and public.can_access_project_v19(project_id)
    or project_id is null and public.current_user_role() in ('owner','admin','accountant')));

-- Contractor operations contain project costs. This restrictive boundary is
-- ANDed with the Phase 1.8 role policy: a project manager only reaches an
-- assigned/member project, while company overhead without a project remains
-- limited to owner/admin/accountant.
alter table public.contractor_operations enable row level security;
drop policy if exists contractor_operations_phase19_project_scope on public.contractor_operations;
create policy contractor_operations_phase19_project_scope on public.contractor_operations
as restrictive for all to authenticated
using(organization_id=public.current_user_organization_id() and
  (project_id is not null and public.can_access_project_v19(project_id)
    or project_id is null and public.current_user_role() in ('owner','admin','accountant')))
with check(organization_id=public.current_user_organization_id() and
  (project_id is not null and public.can_access_project_v19(project_id)
    or project_id is null and public.current_user_role() in ('owner','admin','accountant')));

-- Replace the old permissive ALL policy on the immutable stock ledger.
alter table public.stock_movements enable row level security;
drop policy if exists stock_movements_organization_access on public.stock_movements;
drop policy if exists stock_movements_operations_access on public.stock_movements;
drop policy if exists stock_movements_phase19_read on public.stock_movements;
create policy stock_movements_phase19_read on public.stock_movements for select to authenticated
using(organization_id=public.current_user_organization_id() and public.current_user_role() in
  ('owner','admin','accountant','project_manager','foreman','procurement','storekeeper')
  and (project_id is null and public.current_user_role() in ('owner','admin','accountant','procurement','storekeeper')
    or project_id is not null and public.can_access_project_v19(project_id)));
drop policy if exists stock_movements_phase19_insert on public.stock_movements;
do $$
begin
  -- Kept only for the zero-downtime Phase 1.8 compatibility window. After the
  -- security cutover revokes INSERT, a later main-migration rerun must not
  -- recreate even a dormant direct-ledger policy.
  if has_table_privilege('authenticated','public.stock_movements','insert') then
    create policy stock_movements_phase19_insert on public.stock_movements for insert to authenticated
    with check(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','storekeeper')
      and (project_id is null or public.can_access_project_v19(project_id)));
  end if;
end
$$;

-- A foreman may submit labour attendance but cost-bearing rows remain unreadable
-- unless the same user also has a finance/project-manager role.
drop policy if exists daily_log_labor_phase19_foreman_insert on public.daily_log_labor;
create policy daily_log_labor_phase19_foreman_insert on public.daily_log_labor for insert to authenticated
with check(organization_id=public.current_user_organization_id() and public.current_user_role()='foreman');
drop policy if exists daily_log_labor_phase19_foreman_update on public.daily_log_labor;
create policy daily_log_labor_phase19_foreman_update on public.daily_log_labor for update to authenticated
using(organization_id=public.current_user_organization_id() and public.current_user_role()='foreman')
with check(organization_id=public.current_user_organization_id() and public.current_user_role()='foreman');

-- Restrictive project-scope policies are ANDed with the role policies above.
-- Project managers, foremen and designers only reach projects assigned directly
-- to them or listed in project_members. Owner/admin/accountant and operational
-- procurement/storekeeper roles retain company-wide access where their base
-- table policy already permits it.
do $$ declare r record;p text;begin
  for r in select * from (values
    ('project_cost_codes','public.can_access_project_v19(project_id)'),
    ('schedule_activities','public.can_access_project_v19(project_id)'),
    ('activity_dependencies','public.can_access_project_v19(project_id)'),
    ('schedule_baselines','public.can_access_project_v19(project_id)'),
    ('schedule_baseline_items','exists(select 1 from public.schedule_baselines h where h.id=baseline_id and public.can_access_project_v19(h.project_id))'),
    ('project_documents','public.can_access_project_v19(project_id)'),
    ('document_revisions','exists(select 1 from public.project_documents h where h.id=document_id and public.can_access_project_v19(h.project_id))'),
    ('transmittals','public.can_access_project_v19(project_id)'),
    ('transmittal_items','exists(select 1 from public.transmittals h where h.id=transmittal_id and public.can_access_project_v19(h.project_id))'),
    ('change_orders','public.can_access_project_v19(project_id)'),
    ('change_order_items','exists(select 1 from public.change_orders h where h.id=change_order_id and public.can_access_project_v19(h.project_id))'),
    ('rfis','public.can_access_project_v19(project_id)'),
    ('submittals','public.can_access_project_v19(project_id)'),
    ('submittal_revisions','exists(select 1 from public.submittals h where h.id=submittal_id and public.can_access_project_v19(h.project_id))'),
    ('client_decisions','public.can_access_project_v19(project_id)'),
    ('procurement_commitments','public.can_access_project_v19(project_id)'),
    ('procurement_commitment_items','exists(select 1 from public.procurement_commitments h where h.id=commitment_id and public.can_access_project_v19(h.project_id))'),
    ('supplier_invoices','public.can_access_project_v19(project_id)'),
    ('supplier_invoice_items','exists(select 1 from public.supplier_invoices h where h.id=invoice_id and public.can_access_project_v19(h.project_id))'),
    ('production_orders','public.can_access_project_v19(project_id)'),
    ('production_bom_items','exists(select 1 from public.production_orders h where h.id=production_order_id and public.can_access_project_v19(h.project_id))'),
    ('production_routing_steps','exists(select 1 from public.production_orders h where h.id=production_order_id and public.can_access_project_v19(h.project_id))'),
    ('daily_logs','public.can_access_project_v19(project_id)'),
    ('daily_log_labor','exists(select 1 from public.daily_logs h where h.id=daily_log_id and public.can_access_project_v19(h.project_id))'),
    ('daily_log_progress','exists(select 1 from public.daily_logs h where h.id=daily_log_id and public.can_access_project_v19(h.project_id))'),
    ('daily_log_materials','exists(select 1 from public.daily_logs h where h.id=daily_log_id and public.can_access_project_v19(h.project_id))'),
    ('daily_log_media','exists(select 1 from public.daily_logs h where h.id=daily_log_id and public.can_access_project_v19(h.project_id))'),
    ('quality_records','public.can_access_project_v19(project_id)'),
    ('quality_checklist_items','exists(select 1 from public.quality_records h where h.id=quality_record_id and public.can_access_project_v19(h.project_id))'),
    ('handovers','public.can_access_project_v19(project_id)'),
    ('handover_items','exists(select 1 from public.handovers h where h.id=handover_id and public.can_access_project_v19(h.project_id))')
  ) as x(table_name,predicate) loop
    p:=r.table_name||'_phase19_project_scope';execute format('drop policy if exists %I on public.%I',p,r.table_name);
    execute format('create policy %I on public.%I as restrictive for all to authenticated using (organization_id=public.current_user_organization_id() and (%s)) with check (organization_id=public.current_user_organization_id() and (%s))',
      p,r.table_name,r.predicate,r.predicate);
  end loop;
end $$;

create index if not exists idx_cost_codes_parent on public.cost_codes(organization_id,parent_id,sort_order);
create index if not exists idx_project_cost_codes_project on public.project_cost_codes(project_id,cost_code_id);
create index if not exists idx_project_cost_codes_estimate on public.project_cost_codes(estimate_record_id,estimate_line_id);
create index if not exists idx_schedule_activities_project_dates on public.schedule_activities(project_id,current_start,current_end,status);
create index if not exists idx_schedule_activities_responsible on public.schedule_activities(responsible_id,status,current_end);
create index if not exists idx_activity_dependencies_successor on public.activity_dependencies(successor_id,predecessor_id);
create index if not exists idx_schedule_baselines_project on public.schedule_baselines(project_id,version desc);
create index if not exists idx_schedule_baseline_items_baseline on public.schedule_baseline_items(baseline_id,sort_order);
create index if not exists idx_project_documents_project on public.project_documents(project_id,document_type,status);
create index if not exists idx_document_revisions_document on public.document_revisions(document_id,revision_no desc);
create index if not exists idx_transmittals_project on public.transmittals(project_id,status,sent_at desc);
create index if not exists idx_change_orders_project on public.change_orders(project_id,status,created_at desc);
create index if not exists idx_change_order_items_header on public.change_order_items(change_order_id,sort_order);
create index if not exists idx_rfis_due on public.rfis(project_id,status,due_date);
create index if not exists idx_submittals_due on public.submittals(project_id,status,due_date);
create index if not exists idx_submittal_revisions_header on public.submittal_revisions(submittal_id,revision_no desc);
create index if not exists idx_client_decisions_due on public.client_decisions(project_id,status,due_date);
create index if not exists idx_procurement_commitments_project on public.procurement_commitments(project_id,status,expected_date);
create index if not exists idx_procurement_commitment_items_header on public.procurement_commitment_items(commitment_id,material_id);
create index if not exists idx_procurement_commitment_items_cost on public.procurement_commitment_items(project_cost_code_id,cost_code_id);
create index if not exists idx_supplier_invoices_commitment on public.supplier_invoices(commitment_id,status,invoice_date);
create index if not exists idx_supplier_invoice_items_commitment on public.supplier_invoice_items(commitment_item_id,invoice_id);
create index if not exists idx_warehouse_items_commitment on public.warehouse_document_items(commitment_item_id,document_id);
create index if not exists idx_production_orders_project on public.production_orders(project_id,status,planned_start_date,planned_end_date);
create index if not exists idx_production_bom_order on public.production_bom_items(production_order_id,material_id);
create index if not exists idx_production_routing_order on public.production_routing_steps(production_order_id,sequence_no,status);
create index if not exists idx_daily_logs_project_date on public.daily_logs(project_id,log_date desc,status);
create index if not exists idx_daily_log_labor_log on public.daily_log_labor(daily_log_id,employee_id,contractor_id);
create index if not exists idx_daily_log_progress_activity on public.daily_log_progress(schedule_activity_id,daily_log_id);
create index if not exists idx_daily_log_materials_log on public.daily_log_materials(daily_log_id,material_id);
create index if not exists idx_daily_log_media_log on public.daily_log_media(daily_log_id,created_at desc);
create index if not exists idx_quality_records_due on public.quality_records(project_id,status,severity,due_date);
create index if not exists idx_quality_checklist_record on public.quality_checklist_items(quality_record_id,item_no);
create index if not exists idx_handovers_project on public.handovers(project_id,status,planned_date);
create index if not exists idx_handover_items_header on public.handover_items(handover_id,item_no,status);
create index if not exists idx_module_lines_cost_code_v19 on public.module_record_lines(cost_code_id,project_cost_code_id);
create index if not exists idx_tasks_cost_code_v19 on public.tasks(project_id,cost_code_id,project_cost_code_id);
create index if not exists idx_stages_cost_code_v19 on public.project_stages(project_id,cost_code_id,project_cost_code_id);
create index if not exists idx_expenses_cost_code_v19 on public.expenses(project_id,project_cost_code_id,cost_code_id);
create index if not exists idx_stock_movements_cost_code_v19 on public.stock_movements(project_id,project_cost_code_id,cost_code_id);
create index if not exists idx_payroll_adjustments_cost_code_v19 on public.payroll_adjustments(project_id,project_cost_code_id,cost_code_id);
create index if not exists idx_contractor_operations_cost_code_v19 on public.contractor_operations(project_id,project_cost_code_id,cost_code_id);

grant select,insert,update,delete on
  public.cost_codes,public.project_cost_codes,public.schedule_activities,public.activity_dependencies,
  public.schedule_baselines,public.schedule_baseline_items,public.project_documents,public.document_revisions,
  public.transmittals,public.transmittal_items,public.change_orders,public.change_order_items,public.rfis,
  public.submittals,public.submittal_revisions,public.client_decisions,public.procurement_commitments,
  public.procurement_commitment_items,public.supplier_invoices,public.supplier_invoice_items,
  public.production_orders,public.production_bom_items,public.production_routing_steps,public.daily_logs,
  public.daily_log_labor,public.daily_log_progress,public.daily_log_materials,public.daily_log_media,
  public.quality_records,public.quality_checklist_items,public.handovers,public.handover_items
to authenticated;

grant select on public.project_schedule_variance,public.procurement_three_way_match,
  public.project_cost_forecast,public.project_financial_summary,public.project_action_center,
  public.projects_secure_v19,public.materials_secure_v19,public.warehouse_stock_secure_v19,
  public.warehouse_documents_secure_v19,public.warehouse_document_items_secure_v19 to authenticated;

grant execute on function public.create_schedule_baseline(uuid,text) to authenticated;
grant execute on function public.approve_schedule_baseline(uuid) to authenticated;
grant execute on function public.sync_project_control_from_estimate(uuid) to authenticated;
grant execute on function public.apply_approved_change_order(uuid) to authenticated;
grant execute on function public.refresh_project_cost_control(uuid) to authenticated;
grant execute on function public.post_warehouse_document(uuid) to authenticated;
grant execute on function public.reverse_warehouse_document_v19(uuid,text) to authenticated;
grant execute on function public.reopen_daily_log_correction_v19(uuid,text) to authenticated;

revoke execute on function public.stock_balance_v19(uuid,uuid,uuid,uuid) from public,authenticated;
grant execute on function public.stock_movement_effective_v19(uuid,timestamptz) to authenticated;
revoke execute on function public.set_commitment_derived_v19(uuid) from public,authenticated;
revoke execute on function public.refresh_commitment_receipt_v19(uuid) from public,authenticated;

-- Populate the first forecast immediately after legacy classification. In the
-- SQL Editor there is no auth profile, so the refresh safely derives the company
-- from each explicit project id.
do $$ declare r record;begin
  for r in select id from public.projects where organization_id is not null loop
    perform public.refresh_project_cost_control(r.id);
  end loop;
end $$;

-- REQUIRED DEPLOYMENT STEP: after publishing and verifying the Phase 1.9
-- frontend, run phase1_9_security_cutover.sql. It removes legacy direct reads
-- of cost-bearing base tables and direct writes to the stock ledger. Keeping
-- that final step separate avoids breaking the still-live Phase 1.8 loaders.
notify pgrst,'reload schema';

-- End Phase 1.9 Project Control Core.
