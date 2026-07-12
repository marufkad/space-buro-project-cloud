-- Space Buro Project Cloud — Phase 1.3 company modules
-- Additive migration. Existing projects, clients, materials, stock and payroll
-- records are preserved. Flexible records let every module grow without data loss.

create extension if not exists "pgcrypto";

-- Unified records for the nine horizontal modules. Module-specific details live
-- in structured JSON and normalized child lines, so fields can be extended safely.
create table if not exists public.module_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  module_code text not null check (module_code in (
    'estimates','work_schedule','financial_accounting','procurement','site_control',
    'rate_catalog','management_reports','tasks','warehouse_accounting'
  )),
  record_type text not null,
  record_number text,
  name text not null,
  project_id uuid references public.projects(id) on delete set null,
  client_id uuid references public.clients(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  parent_id uuid references public.module_records(id) on delete set null,
  source_record_id uuid references public.module_records(id) on delete set null,
  status text not null default 'draft',
  priority text not null default 'normal',
  currency text not null default 'AED',
  planned_amount numeric(14,2) not null default 0,
  actual_amount numeric(14,2) not null default 0,
  cost_amount numeric(14,2) not null default 0,
  sale_amount numeric(14,2) not null default 0,
  planned_start date,
  planned_finish date,
  actual_start date,
  actual_finish date,
  progress numeric(7,3) not null default 0,
  responsible_id uuid references public.profiles(id) on delete set null,
  data jsonb not null default '{}'::jsonb,
  is_client_visible boolean not null default false,
  client_access_token uuid default gen_random_uuid(),
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  deleted_at timestamptz,
  unique (organization_id,module_code,record_number)
);

create table if not exists public.module_record_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  record_id uuid not null references public.module_records(id) on delete cascade,
  parent_line_id uuid references public.module_record_lines(id) on delete cascade,
  line_type text not null default 'item',
  code text,
  name text not null,
  description text,
  material_id uuid references public.materials(id) on delete set null,
  project_stage_id uuid references public.project_stages(id) on delete set null,
  linked_task_id uuid references public.tasks(id) on delete set null,
  quantity numeric(14,3) not null default 1,
  unit text not null default 'pcs',
  unit_cost numeric(14,2) not null default 0,
  unit_sale numeric(14,2) not null default 0,
  planned_amount numeric(14,2) not null default 0,
  actual_amount numeric(14,2) not null default 0,
  planned_start date,
  planned_finish date,
  actual_start date,
  actual_finish date,
  progress numeric(7,3) not null default 0,
  status text not null default 'draft',
  responsible_id uuid references public.profiles(id) on delete set null,
  sort_order integer not null default 0,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.module_relations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  source_record_id uuid not null references public.module_records(id) on delete cascade,
  target_record_id uuid references public.module_records(id) on delete cascade,
  target_entity_type text,
  target_entity_id uuid,
  relation_type text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.module_participants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  record_id uuid not null references public.module_records(id) on delete cascade,
  profile_id uuid references public.profiles(id) on delete cascade,
  external_name text,
  participant_role text not null,
  permissions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (record_id,profile_id,external_name,participant_role)
);

create table if not exists public.module_approvals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  record_id uuid not null references public.module_records(id) on delete cascade,
  line_id uuid references public.module_record_lines(id) on delete cascade,
  approval_type text not null default 'standard',
  status text not null default 'pending' check (status in ('pending','approved','rejected','changes_required','cancelled')),
  requested_by uuid default auth.uid() references public.profiles(id) on delete set null,
  approver_id uuid references public.profiles(id) on delete set null,
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decision_comment text,
  snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.module_comments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  record_id uuid not null references public.module_records(id) on delete cascade,
  line_id uuid references public.module_record_lines(id) on delete cascade,
  parent_id uuid references public.module_comments(id) on delete cascade,
  comment_text text not null,
  is_client_visible boolean not null default false,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.module_attachments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  record_id uuid not null references public.module_records(id) on delete cascade,
  line_id uuid references public.module_record_lines(id) on delete cascade,
  attachment_type text,
  file_name text not null,
  storage_path text,
  public_url text,
  mime_type text,
  file_size bigint,
  version_number integer not null default 1,
  data jsonb not null default '{}'::jsonb,
  uploaded_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.module_history (
  id bigint generated always as identity primary key,
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  record_id uuid not null references public.module_records(id) on delete cascade,
  line_id uuid references public.module_record_lines(id) on delete set null,
  action text not null,
  old_data jsonb,
  new_data jsonb,
  reason text,
  comment text,
  actor_id uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Storage hierarchy and unified material catalog extensions.
alter table public.warehouse_locations add column if not exists code text;
alter table public.warehouse_locations add column if not exists warehouse_type text not null default 'main';
alter table public.warehouse_locations add column if not exists district text;
alter table public.warehouse_locations add column if not exists responsible_id uuid references public.profiles(id) on delete set null;
alter table public.warehouse_locations add column if not exists storekeeper_id uuid references public.profiles(id) on delete set null;
alter table public.warehouse_locations add column if not exists phone text;
alter table public.warehouse_locations add column if not exists status text not null default 'active';
alter table public.warehouse_locations add column if not exists notes text;
alter table public.warehouse_locations add column if not exists photos jsonb not null default '[]'::jsonb;
alter table public.warehouse_locations add column if not exists documents jsonb not null default '[]'::jsonb;

alter table public.materials add column if not exists sku text;
alter table public.materials add column if not exists material_type text;
alter table public.materials add column if not exists collection text;
alter table public.materials add column if not exists decor text;
alter table public.materials add column if not exists texture text;
alter table public.materials add column if not exists length numeric(14,3);
alter table public.materials add column if not exists width numeric(14,3);
alter table public.materials add column if not exists size text;
alter table public.materials add column if not exists technical_description text;
alter table public.materials add column if not exists barcode text;
alter table public.materials add column if not exists qr_code text;
alter table public.materials add column if not exists standard_supplier_id uuid references public.suppliers(id) on delete set null;
alter table public.materials add column if not exists expiry_tracking boolean not null default false;
alter table public.materials add column if not exists batch_tracking boolean not null default false;

create table if not exists public.warehouse_storage_nodes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  warehouse_id uuid not null references public.warehouse_locations(id) on delete cascade,
  parent_id uuid references public.warehouse_storage_nodes(id) on delete cascade,
  node_type text not null check (node_type in ('zone','rack','shelf','bin')),
  code text,
  name text not null,
  barcode text,
  qr_code text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  notes text,
  unique (warehouse_id,code)
);

create table if not exists public.material_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete restrict,
  warehouse_id uuid references public.warehouse_locations(id) on delete set null,
  storage_node_id uuid references public.warehouse_storage_nodes(id) on delete set null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  batch_number text not null,
  serial_number text,
  shade text,
  production_date date,
  expiry_date date,
  received_at timestamptz,
  purchase_price numeric(14,2) not null default 0,
  quantity_received numeric(14,3) not null default 0,
  quantity_remaining numeric(14,3) not null default 0,
  condition text not null default 'new',
  certificate_path text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,material_id,batch_number)
);

create table if not exists public.warehouse_documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  document_number text not null,
  document_type text not null check (document_type in (
    'receipt','acceptance','issue','reserve','unreserve','return','supplier_return',
    'transfer','writeoff','inventory','adjustment','defect'
  )),
  document_date timestamptz not null default now(),
  status text not null default 'draft' check (status in (
    'draft','pending_approval','approved','posted','in_transit','partially_received',
    'received','cancelled','reversed'
  )),
  source_warehouse_id uuid references public.warehouse_locations(id) on delete set null,
  destination_warehouse_id uuid references public.warehouse_locations(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  stage_id uuid references public.project_stages(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  purchase_order_record_id uuid references public.module_records(id) on delete set null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  recipient_id uuid references public.profiles(id) on delete set null,
  foreman_id uuid references public.profiles(id) on delete set null,
  responsible_id uuid references public.profiles(id) on delete set null,
  reason text,
  transport text,
  reference text,
  total_cost numeric(14,2) not null default 0,
  currency text not null default 'AED',
  notes text,
  signatures jsonb not null default '[]'::jsonb,
  data jsonb not null default '{}'::jsonb,
  posted_at timestamptz,
  posted_by uuid references public.profiles(id) on delete set null,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles(id) on delete set null,
  reversal_document_id uuid references public.warehouse_documents(id) on delete set null,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,document_number)
);

create table if not exists public.warehouse_document_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  document_id uuid not null references public.warehouse_documents(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete restrict,
  order_line_id uuid references public.module_record_lines(id) on delete set null,
  batch_id uuid references public.material_batches(id) on delete set null,
  source_storage_node_id uuid references public.warehouse_storage_nodes(id) on delete set null,
  destination_storage_node_id uuid references public.warehouse_storage_nodes(id) on delete set null,
  ordered_quantity numeric(14,3) not null default 0,
  delivered_quantity numeric(14,3) not null default 0,
  accepted_quantity numeric(14,3) not null default 0,
  damaged_quantity numeric(14,3) not null default 0,
  missing_quantity numeric(14,3) not null default 0,
  extra_quantity numeric(14,3) not null default 0,
  quantity numeric(14,3) not null,
  unit text not null default 'pcs',
  unit_cost numeric(14,2) not null default 0,
  landed_unit_cost numeric(14,2) not null default 0,
  condition text not null default 'new',
  photos jsonb not null default '[]'::jsonb,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.stock_reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete restrict,
  warehouse_id uuid not null references public.warehouse_locations(id) on delete restrict,
  project_id uuid references public.projects(id) on delete cascade,
  stage_id uuid references public.project_stages(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  source_line_id uuid references public.module_record_lines(id) on delete set null,
  quantity numeric(14,3) not null,
  issued_quantity numeric(14,3) not null default 0,
  planned_issue_date date,
  expires_at timestamptz,
  status text not null default 'active' check (status in ('active','partially_used','used','expired','cancelled')),
  responsible_id uuid references public.profiles(id) on delete set null,
  notes text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tools_equipment (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  inventory_number text not null,
  name text not null,
  tool_type text,
  serial_number text,
  brand text,
  model text,
  photo_url text,
  condition text not null default 'good',
  status text not null default 'warehouse' check (status in (
    'warehouse','issued_employee','site','repair','damaged','lost','written_off'
  )),
  purchase_cost numeric(14,2) not null default 0,
  warehouse_id uuid references public.warehouse_locations(id) on delete set null,
  responsible_id uuid references public.profiles(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  issued_at timestamptz,
  planned_return_at timestamptz,
  returned_at timestamptz,
  warranty_until date,
  repair_history jsonb not null default '[]'::jsonb,
  documents jsonb not null default '[]'::jsonb,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,inventory_number)
);

create table if not exists public.stocktakes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  stocktake_number text not null,
  warehouse_id uuid not null references public.warehouse_locations(id) on delete restrict,
  category_id uuid references public.material_categories(id) on delete set null,
  status text not null default 'draft' check (status in ('draft','counting','review','approved','posted','cancelled')),
  started_at timestamptz,
  completed_at timestamptz,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  notes text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,stocktake_number)
);

create table if not exists public.stocktake_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  stocktake_id uuid not null references public.stocktakes(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete restrict,
  batch_id uuid references public.material_batches(id) on delete set null,
  storage_node_id uuid references public.warehouse_storage_nodes(id) on delete set null,
  system_quantity numeric(14,3) not null default 0,
  counted_quantity numeric(14,3),
  variance_quantity numeric(14,3) generated always as (coalesce(counted_quantity,0)-system_quantity) stored,
  unit_cost numeric(14,2) not null default 0,
  condition text,
  reason text,
  photo_url text,
  notes text,
  counted_by uuid references public.profiles(id) on delete set null,
  counted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (stocktake_id,material_id,batch_id,storage_node_id)
);

alter table public.stock_movements add column if not exists warehouse_document_id uuid references public.warehouse_documents(id) on delete set null;
alter table public.stock_movements add column if not exists batch_id uuid references public.material_batches(id) on delete set null;
alter table public.stock_movements add column if not exists storage_node_id uuid references public.warehouse_storage_nodes(id) on delete set null;
alter table public.stock_movements add column if not exists stage_id uuid references public.project_stages(id) on delete set null;
alter table public.stock_movements add column if not exists reservation_id uuid references public.stock_reservations(id) on delete set null;
alter table public.stock_movements add column if not exists condition text;
alter table public.stock_movements add column if not exists landed_unit_cost numeric(14,2);

-- Expanded tasks: roles, reminders, checklists, dependencies and verification.
alter table public.tasks add column if not exists task_type text not null default 'project';
alter table public.tasks add column if not exists creator_id uuid default auth.uid() references public.profiles(id) on delete set null;
alter table public.tasks add column if not exists verifier_id uuid references public.profiles(id) on delete set null;
alter table public.tasks add column if not exists recurrence_rule jsonb;
alter table public.tasks add column if not exists reminder_rules jsonb not null default '[]'::jsonb;
alter table public.tasks add column if not exists checklist jsonb not null default '[]'::jsonb;
alter table public.tasks add column if not exists result_text text;
alter table public.tasks add column if not exists waiting_reason text;
alter table public.tasks add column if not exists entity_type text;
alter table public.tasks add column if not exists entity_id uuid;

create table if not exists public.task_participants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  participant_role text not null check (participant_role in (
    'assignee','co_assignee','observer','verifier','contractor','client'
  )),
  created_at timestamptz not null default now(),
  unique (task_id,profile_id,participant_role)
);

-- Configurable automatic numbers (GRN-2026-0001, ISSUE-2026-0001, etc.).
create table if not exists public.document_sequences (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  document_type text not null,
  prefix text not null,
  year_number integer not null,
  last_number integer not null default 0,
  padding integer not null default 4,
  unique (organization_id,document_type,year_number)
);

create or replace function public.next_document_number(p_document_type text,p_prefix text)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_year integer := extract(year from current_date)::integer;
  v_number integer;
  v_padding integer;
begin
  insert into public.document_sequences(organization_id,document_type,prefix,year_number,last_number)
  values(v_org,p_document_type,p_prefix,v_year,1)
  on conflict(organization_id,document_type,year_number)
  do update set last_number=public.document_sequences.last_number+1,prefix=excluded.prefix
  returning last_number,padding into v_number,v_padding;
  return p_prefix||'-'||v_year||'-'||lpad(v_number::text,v_padding,'0');
end;
$$;

-- Recalculate BOQ / estimate totals from its nested lines.
create or replace function public.recalculate_module_record_totals()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_record uuid := coalesce(new.record_id,old.record_id);
begin
  update public.module_records r
  set cost_amount=x.cost_total,
      sale_amount=x.sale_total,
      planned_amount=x.planned_total,
      actual_amount=x.actual_total,
      updated_at=now()
  from (
    select record_id,
      coalesce(sum(quantity*unit_cost),0) cost_total,
      coalesce(sum(quantity*unit_sale),0) sale_total,
      coalesce(sum(planned_amount),0) planned_total,
      coalesce(sum(actual_amount),0) actual_total
    from public.module_record_lines where record_id=v_record group by record_id
  ) x
  where r.id=v_record and r.id=x.record_id;
  if not found then
    update public.module_records set cost_amount=0,sale_amount=0,planned_amount=0,actual_amount=0,updated_at=now()
    where id=v_record;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists module_record_lines_recalculate on public.module_record_lines;
create trigger module_record_lines_recalculate
after insert or update or delete on public.module_record_lines
for each row execute function public.recalculate_module_record_totals();

-- Confirmed warehouse documents and lines cannot be silently changed or deleted.
create or replace function public.protect_posted_warehouse_document()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if tg_op='DELETE' and old.status in ('posted','received','reversed') then
    raise exception 'Confirmed warehouse documents cannot be deleted; create a reversal document';
  end if;
  if tg_op='UPDATE' and old.status in ('posted','received','reversed') then
    if new.status not in ('cancelled','reversed') or
       (to_jsonb(new)-array['status','cancelled_at','cancelled_by','updated_at','reversal_document_id']) <>
       (to_jsonb(old)-array['status','cancelled_at','cancelled_by','updated_at','reversal_document_id']) then
      raise exception 'Confirmed warehouse documents are immutable; use cancellation or reversal';
    end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists warehouse_documents_protect_posted on public.warehouse_documents;
create trigger warehouse_documents_protect_posted
before update or delete on public.warehouse_documents
for each row execute function public.protect_posted_warehouse_document();

create or replace function public.protect_posted_warehouse_line()
returns trigger
language plpgsql
set search_path=public
as $$
declare v_document uuid := coalesce(new.document_id,old.document_id);
begin
  if exists(select 1 from public.warehouse_documents where id=v_document and status in ('posted','received','reversed')) then
    raise exception 'Lines of a confirmed warehouse document are immutable';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists warehouse_document_items_protect_posted on public.warehouse_document_items;
create trigger warehouse_document_items_protect_posted
before insert or update or delete on public.warehouse_document_items
for each row execute function public.protect_posted_warehouse_line();

create or replace function public.recalculate_warehouse_document_total()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_document uuid := coalesce(new.document_id,old.document_id);
begin
  update public.warehouse_documents d set total_cost=coalesce(x.total_cost,0),updated_at=now()
  from (
    select document_id,sum(quantity*coalesce(nullif(landed_unit_cost,0),unit_cost)) total_cost
    from public.warehouse_document_items where document_id=v_document group by document_id
  ) x where d.id=v_document and d.id=x.document_id;
  if not found then update public.warehouse_documents set total_cost=0,updated_at=now() where id=v_document; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists warehouse_document_items_recalculate on public.warehouse_document_items;
create trigger warehouse_document_items_recalculate
after insert or update or delete on public.warehouse_document_items
for each row execute function public.recalculate_warehouse_document_total();

-- Stock view: actual, reserved, available, average cost and inventory value.
-- Transfers retain their historical unit cost at the destination warehouse.
create or replace view public.warehouse_stock
with (security_invoker=true)
as
with movement_lines as (
  select organization_id,coalesce(warehouse_id,source_warehouse_id,destination_warehouse_id) warehouse_id,material_id,
    case when movement_type in ('receipt','return','inventory') then quantity
         when movement_type in ('issue','writeoff','defect') then -quantity else 0 end quantity_delta,
    case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end reserve_delta,
    case when movement_type in ('receipt','return','inventory') and unit_cost>0 then quantity*unit_cost else 0 end receipt_value,
    case when movement_type in ('receipt','return','inventory') and unit_cost>0 then quantity else 0 end priced_quantity,
    case when movement_type='receipt' then movement_date end receipt_at
  from public.stock_movements where movement_type<>'transfer' and reversed_at is null
  union all
  select organization_id,source_warehouse_id,material_id,-quantity,0,0,0,null
  from public.stock_movements where movement_type='transfer' and reversed_at is null and source_warehouse_id is not null
  union all
  select organization_id,destination_warehouse_id,material_id,quantity,0,quantity*unit_cost,quantity,null
  from public.stock_movements where movement_type='transfer' and reversed_at is null and destination_warehouse_id is not null
), totals as (
  select organization_id,warehouse_id,material_id,
    coalesce(sum(quantity_delta),0) quantity_on_hand,
    greatest(0,coalesce(sum(reserve_delta),0)) reserved,
    case when sum(priced_quantity)>0 then sum(receipt_value)/sum(priced_quantity) else 0 end average_purchase_price,
    max(receipt_at) last_receipt_at
  from movement_lines group by organization_id,warehouse_id,material_id
)
select organization_id,warehouse_id,material_id,quantity_on_hand,reserved,
  average_purchase_price,quantity_on_hand*average_purchase_price inventory_value,last_receipt_at,
  greatest(0,quantity_on_hand-reserved) available
from totals;

-- Post a warehouse document atomically. Issues are valued at the current average
-- cost and cannot exceed available stock without an approved override in data.
create or replace function public.post_warehouse_document(p_document_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  d public.warehouse_documents%rowtype;
  i public.warehouse_document_items%rowtype;
  v_type text;
  v_warehouse uuid;
  v_available numeric(14,3);
  v_cost numeric(14,2);
begin
  if public.current_user_role() not in ('owner','admin','storekeeper') then raise exception 'Not allowed to post warehouse documents'; end if;
  select * into d from public.warehouse_documents where id=p_document_id and organization_id=public.current_user_organization_id() for update;
  if d.id is null then raise exception 'Warehouse document not found'; end if;
  if d.status in ('posted','received') then return d.id; end if;
  if not exists(select 1 from public.warehouse_document_items where document_id=d.id) then raise exception 'Add at least one material before posting'; end if;

  for i in select * from public.warehouse_document_items where document_id=d.id order by created_at loop
    v_type:=case d.document_type
      when 'acceptance' then 'receipt' when 'supplier_return' then 'issue'
      when 'adjustment' then 'inventory' else d.document_type end;
    v_warehouse:=case when v_type in ('receipt','return','inventory')
      then coalesce(d.destination_warehouse_id,d.source_warehouse_id)
      else coalesce(d.source_warehouse_id,d.destination_warehouse_id) end;
    select coalesce(available,0),coalesce(average_purchase_price,0) into v_available,v_cost
    from public.warehouse_stock where material_id=i.material_id and warehouse_id=coalesce(d.source_warehouse_id,v_warehouse);
    v_available:=coalesce(v_available,0);v_cost:=coalesce(v_cost,0);
    if v_type in ('issue','writeoff','defect','transfer') and i.quantity>v_available
       and coalesce((d.data->>'over_issue_approved')::boolean,false)=false then
      raise exception 'Quantity exceeds available stock for material %',i.material_id;
    end if;
    if v_type in ('issue','writeoff','defect','transfer') then i.unit_cost:=v_cost; end if;
    insert into public.stock_movements(
      organization_id,material_id,warehouse_id,source_warehouse_id,destination_warehouse_id,
      project_id,task_id,stage_id,movement_type,quantity,unit_cost,landed_unit_cost,
      movement_date,performed_by,notes,reference,unit,supplier_id,warehouse_document_id,batch_id,storage_node_id,condition
    ) values(
      d.organization_id,i.material_id,case when v_type='transfer' then null else v_warehouse end,
      case when v_type='transfer' then d.source_warehouse_id end,
      case when v_type='transfer' then d.destination_warehouse_id end,
      d.project_id,d.task_id,d.stage_id,v_type,i.quantity,i.unit_cost,
      nullif(i.landed_unit_cost,0),d.document_date,auth.uid(),i.notes,d.document_number,i.unit,d.supplier_id,d.id,i.batch_id,
      coalesce(i.destination_storage_node_id,i.source_storage_node_id),i.condition
    );
  end loop;
  update public.warehouse_documents set status='posted',posted_at=now(),posted_by=auth.uid(),updated_at=now() where id=d.id;
  return d.id;
end;
$$;

-- Forecast combines physical stock, active reservations and planned procurement.
create or replace view public.warehouse_stock_forecast
with (security_invoker=true)
as
select s.*,
  coalesce(r.reserved_quantity,0) active_reservations,
  coalesce(p.expected_quantity,0) expected_receipts,
  coalesce(r.planned_issue_quantity,0) planned_issue_quantity,
  s.quantity_on_hand+coalesce(p.expected_quantity,0)-greatest(s.reserved,coalesce(r.reserved_quantity,0))-coalesce(r.planned_issue_quantity,0) forecast_quantity
from public.warehouse_stock s
left join (
  select organization_id,warehouse_id,material_id,sum(quantity-issued_quantity) reserved_quantity,
    sum(case when planned_issue_date is not null then quantity-issued_quantity else 0 end) planned_issue_quantity
  from public.stock_reservations where status in ('active','partially_used') group by organization_id,warehouse_id,material_id
) r using(organization_id,warehouse_id,material_id)
left join (
  select d.organization_id,d.destination_warehouse_id warehouse_id,i.material_id,sum(i.quantity) expected_quantity
  from public.warehouse_documents d join public.warehouse_document_items i on i.document_id=d.id
  where d.document_type in ('receipt','acceptance') and d.status in ('draft','pending_approval','approved','in_transit','partially_received')
  group by d.organization_id,d.destination_warehouse_id,i.material_id
) p using(organization_id,warehouse_id,material_id);

-- Role-aware access for horizontal modules.
create or replace function public.can_access_module_record(p_record_id uuid,p_write boolean default false)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1 from public.module_records r
    where r.id=p_record_id and r.organization_id=public.current_user_organization_id()
      and (
        public.current_user_role() in ('owner','admin')
        or (r.module_code in ('financial_accounting','management_reports') and public.current_user_role() in ('accountant','project_manager'))
        or (r.module_code='estimates' and public.current_user_role() in ('accountant','project_manager','procurement'))
        or (r.module_code='work_schedule' and public.current_user_role() in ('project_manager','foreman','designer','procurement'))
        or (r.module_code='procurement' and public.current_user_role() in ('project_manager','foreman','procurement','storekeeper','accountant'))
        or (r.module_code='site_control' and public.current_user_role() in ('project_manager','foreman','employee'))
        or (r.module_code='rate_catalog' and public.current_user_role() in ('project_manager','procurement','accountant'))
        or (r.module_code='tasks' and public.current_user_role() in ('project_manager','foreman','designer','procurement','storekeeper','accountant','marketing','employee'))
        or (r.module_code='warehouse_accounting' and public.current_user_role() in ('project_manager','foreman','procurement','storekeeper','accountant'))
      )
      and (
        not p_write or public.current_user_role() in ('owner','admin','accountant','project_manager','foreman','procurement','storekeeper')
      )
  )
$$;

alter table public.module_records enable row level security;
drop policy if exists module_records_role_read on public.module_records;
create policy module_records_role_read on public.module_records for select to authenticated
using (public.can_access_module_record(id,false));
drop policy if exists module_records_role_insert on public.module_records;
create policy module_records_role_insert on public.module_records for insert to authenticated
with check (
  organization_id=public.current_user_organization_id() and
  public.current_user_role() in ('owner','admin','accountant','project_manager','foreman','procurement','storekeeper')
);
drop policy if exists module_records_role_update on public.module_records;
create policy module_records_role_update on public.module_records for update to authenticated
using (public.can_access_module_record(id,true)) with check (public.can_access_module_record(id,true));
drop policy if exists module_records_role_delete on public.module_records;
create policy module_records_role_delete on public.module_records for delete to authenticated
using (public.current_user_role() in ('owner','admin') and organization_id=public.current_user_organization_id());

do $$
declare t text;
begin
  foreach t in array array['module_record_lines','module_relations','module_participants','module_approvals','module_comments','module_attachments','module_history'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists %I on public.%I',t||'_parent_read',t);
    execute format('create policy %I on public.%I for select to authenticated using (public.can_access_module_record(%s,false))',t||'_parent_read',t,case when t='module_relations' then 'source_record_id' else 'record_id' end);
    execute format('drop policy if exists %I on public.%I',t||'_parent_write',t);
    execute format('create policy %I on public.%I for all to authenticated using (public.can_access_module_record(%s,true)) with check (public.can_access_module_record(%s,true))',t||'_parent_write',t,case when t='module_relations' then 'source_record_id' else 'record_id' end,case when t='module_relations' then 'source_record_id' else 'record_id' end);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['warehouse_storage_nodes','material_batches','warehouse_documents','warehouse_document_items','stock_reservations','tools_equipment','stocktakes','stocktake_items','document_sequences'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists %I on public.%I',t||'_org_read',t);
    execute format('create policy %I on public.%I for select to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant'',''project_manager'',''foreman'',''procurement'',''storekeeper''))',t||'_org_read',t);
    execute format('drop policy if exists %I on public.%I',t||'_org_write',t);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''storekeeper'')) with check (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''storekeeper''))',t||'_org_write',t);
  end loop;
end $$;

alter table public.task_participants enable row level security;
drop policy if exists task_participants_org_read on public.task_participants;
create policy task_participants_org_read on public.task_participants for select to authenticated
using (organization_id=public.current_user_organization_id());
drop policy if exists task_participants_org_write on public.task_participants;
create policy task_participants_org_write on public.task_participants for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','project_manager','foreman'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','project_manager','foreman'));

-- Generic audit history for module headers and lines.
create or replace function public.audit_module_change()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_record uuid;
begin
  v_record:=case when tg_table_name='module_records' then coalesce(new.id,old.id) else coalesce(new.record_id,old.record_id) end;
  insert into public.module_history(organization_id,record_id,line_id,action,old_data,new_data,actor_id)
  values(
    coalesce(new.organization_id,old.organization_id),v_record,
    case when tg_table_name='module_record_lines' and tg_op<>'DELETE' then new.id else null end,
    lower(tg_op),case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,auth.uid()
  );
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists module_records_audit on public.module_records;
create trigger module_records_audit after insert or update on public.module_records
for each row execute function public.audit_module_change();
drop trigger if exists module_record_lines_audit on public.module_record_lines;
create trigger module_record_lines_audit after insert or update or delete on public.module_record_lines
for each row execute function public.audit_module_change();

do $$
declare t text;
begin
  foreach t in array array[
    'module_records','module_record_lines','module_approvals','module_comments','warehouse_documents',
    'warehouse_document_items','material_batches','stock_reservations','tools_equipment','stocktakes','stocktake_items'
  ] loop
    execute format('drop trigger if exists %I on public.%I',t||'_touch_updated_at',t);
    execute format('create trigger %I before update on public.%I for each row execute function public.touch_updated_at()',t||'_touch_updated_at',t);
  end loop;
end $$;

create index if not exists idx_module_records_module_status on public.module_records(organization_id,module_code,status,updated_at desc);
create index if not exists idx_module_records_project on public.module_records(project_id,module_code);
create index if not exists idx_module_lines_record_order on public.module_record_lines(record_id,parent_line_id,sort_order);
create index if not exists idx_module_lines_material on public.module_record_lines(material_id,record_id);
create index if not exists idx_module_history_record on public.module_history(record_id,created_at desc);
create index if not exists idx_warehouse_documents_date on public.warehouse_documents(organization_id,document_type,document_date desc,status);
create index if not exists idx_warehouse_document_items_material on public.warehouse_document_items(material_id,document_id);
create index if not exists idx_stock_reservations_active on public.stock_reservations(organization_id,material_id,warehouse_id,status);
create index if not exists idx_material_batches_expiry on public.material_batches(organization_id,material_id,expiry_date);
create index if not exists idx_tools_status on public.tools_equipment(organization_id,status,warehouse_id);
create index if not exists idx_task_participants_profile on public.task_participants(profile_id,task_id);

grant select,insert,update,delete on public.module_records,public.module_record_lines,public.module_relations,
  public.module_participants,public.module_approvals,public.module_comments,public.module_attachments,
  public.warehouse_storage_nodes,public.material_batches,public.warehouse_documents,
  public.warehouse_document_items,public.stock_reservations,public.tools_equipment,public.stocktakes,
  public.stocktake_items,public.task_participants,public.document_sequences to authenticated;
grant select on public.warehouse_stock,public.warehouse_stock_forecast to authenticated;
grant select on public.module_history to authenticated;
grant execute on function public.next_document_number(text,text) to authenticated;
grant execute on function public.post_warehouse_document(uuid) to authenticated;

-- Default prefixes and editable module status dictionaries.
insert into public.document_sequences(organization_id,document_type,prefix,year_number,last_number)
values
('00000000-0000-0000-0000-000000000001','warehouse_receipt','GRN',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','warehouse_issue','ISSUE',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','warehouse_transfer','TRF',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','warehouse_return','RET',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','warehouse_writeoff','WOFF',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','stocktake','INV',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','estimate','EST',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','purchase_request','PR',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','purchase_order','PO',extract(year from current_date)::integer,0),
('00000000-0000-0000-0000-000000000001','site_report','SR',extract(year from current_date)::integer,0)
on conflict(organization_id,document_type,year_number) do nothing;

insert into public.dictionary_groups(organization_id,code,name,is_system)
values
('00000000-0000-0000-0000-000000000001','estimate_statuses','{"ru":"Статусы смет","en":"Estimate statuses"}',true),
('00000000-0000-0000-0000-000000000001','procurement_statuses','{"ru":"Статусы снабжения","en":"Procurement statuses"}',true),
('00000000-0000-0000-0000-000000000001','warehouse_document_types','{"ru":"Складские документы","en":"Warehouse documents"}',true),
('00000000-0000-0000-0000-000000000001','rate_types','{"ru":"Типы расценок","en":"Rate types"}',true)
on conflict(organization_id,code) do nothing;
