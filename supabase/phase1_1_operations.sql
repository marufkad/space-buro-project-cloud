-- Space Buro Project Cloud — Phase 1.1 operations and editing
-- Additive migration. Existing records are preserved.

create extension if not exists "pgcrypto";

-- 1. Branding and company settings.
alter table public.organizations add column if not exists logo_url text;
alter table public.organizations add column if not exists menu_logo_url text;
alter table public.organizations add column if not exists favicon_url text;

create table if not exists public.app_settings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  setting_key text not null,
  setting_value jsonb not null default '{}'::jsonb,
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, setting_key)
);

insert into public.app_settings (organization_id, setting_key, setting_value)
values
  ('00000000-0000-0000-0000-000000000001','branding','{"logo_url":null,"menu_logo_url":null,"favicon_url":null}'),
  ('00000000-0000-0000-0000-000000000001','localization','{"default_language":"ru","supported_languages":["ru","en"],"currency":"AED"}')
on conflict (organization_id, setting_key) do nothing;

-- 2. Extend records for complete editing and soft deletion.
alter table public.profiles add column if not exists photo_url text;
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists whatsapp text;
alter table public.profiles add column if not exists archived_at timestamptz;

alter table public.clients add column if not exists photo_url text;
alter table public.clients add column if not exists status text not null default 'active';
alter table public.clients add column if not exists attachments jsonb not null default '[]'::jsonb;
alter table public.clients add column if not exists custom_fields jsonb not null default '{}'::jsonb;
alter table public.clients add column if not exists archived_at timestamptz;
alter table public.clients add column if not exists deleted_at timestamptz;

alter table public.client_contacts add column if not exists notes text;
alter table public.client_contacts add column if not exists updated_at timestamptz not null default now();
alter table public.client_contacts add column if not exists deleted_at timestamptz;

alter table public.project_sites add column if not exists photo_url text;
alter table public.project_sites add column if not exists attachments jsonb not null default '[]'::jsonb;
alter table public.project_sites add column if not exists archived_at timestamptz;

alter table public.projects add column if not exists address text;
alter table public.projects add column if not exists district text;
alter table public.projects add column if not exists project_category text;
alter table public.projects add column if not exists received_payments numeric(14,2) not null default 0;
alter table public.projects add column if not exists photo_url text;
alter table public.projects add column if not exists attachments jsonb not null default '[]'::jsonb;
alter table public.projects add column if not exists custom_fields jsonb not null default '{}'::jsonb;
alter table public.projects add column if not exists template_source_id uuid references public.projects(id) on delete set null;
alter table public.projects add column if not exists deleted_at timestamptz;

alter table public.tasks add column if not exists collaborators uuid[] not null default '{}'::uuid[];
alter table public.tasks add column if not exists recurrence_rule text;
alter table public.tasks add column if not exists attachments jsonb not null default '[]'::jsonb;
alter table public.tasks add column if not exists required_materials jsonb not null default '[]'::jsonb;
alter table public.tasks add column if not exists archived_at timestamptz;
alter table public.tasks add column if not exists deleted_at timestamptz;

alter table public.expenses add column if not exists currency text not null default 'AED';
alter table public.expenses add column if not exists employee_id uuid references public.employees(id) on delete set null;
alter table public.expenses add column if not exists payment_method text;
alter table public.expenses add column if not exists receipt_url text;
alter table public.expenses add column if not exists photo_url text;
alter table public.expenses add column if not exists attachments jsonb not null default '[]'::jsonb;
alter table public.expenses add column if not exists archived_at timestamptz;
alter table public.expenses add column if not exists deleted_at timestamptz;

alter table public.employees add column if not exists last_name text;
alter table public.employees add column if not exists whatsapp text;
alter table public.employees add column if not exists email text;
alter table public.employees add column if not exists status text not null default 'working';
alter table public.employees add column if not exists bonuses numeric(14,2) not null default 0;
alter table public.employees add column if not exists penalties numeric(14,2) not null default 0;
alter table public.employees add column if not exists archived_at timestamptz;
alter table public.employees add column if not exists deleted_at timestamptz;

-- 3. Universal files and comments.
create table if not exists public.entity_files (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  file_type text,
  file_name text not null,
  bucket_id text not null default 'company-files',
  object_path text not null,
  mime_type text,
  size_bytes bigint,
  uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.entity_comments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  comment text not null,
  author_id uuid default auth.uid(),
  parent_id uuid references public.entity_comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- Private storage. Files are stored under /<organization_id>/<entity_type>/<entity_id>/...
insert into storage.buckets (id, name, public, file_size_limit)
values ('company-files','company-files',false,52428800)
on conflict (id) do update set public = false;

drop policy if exists company_files_read on storage.objects;
create policy company_files_read on storage.objects
for select to authenticated
using (
  bucket_id = 'company-files'
  and (storage.foldername(name))[1] = public.current_user_organization_id()::text
);

drop policy if exists company_files_insert on storage.objects;
create policy company_files_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'company-files'
  and (storage.foldername(name))[1] = public.current_user_organization_id()::text
);

drop policy if exists company_files_update on storage.objects;
create policy company_files_update on storage.objects
for update to authenticated
using (
  bucket_id = 'company-files'
  and (storage.foldername(name))[1] = public.current_user_organization_id()::text
)
with check (
  bucket_id = 'company-files'
  and (storage.foldername(name))[1] = public.current_user_organization_id()::text
);

drop policy if exists company_files_delete on storage.objects;
create policy company_files_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'company-files'
  and (storage.foldername(name))[1] = public.current_user_organization_id()::text
);

-- 4. Planning events for calendar/week/month views.
create table if not exists public.planning_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id) on delete cascade,
  task_id uuid references public.tasks(id) on delete set null,
  event_type text not null default 'work',
  title text not null,
  description text,
  responsible_id uuid references public.profiles(id) on delete set null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  status text not null default 'planned',
  color text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_at >= start_at)
);

-- 5. Suppliers, material brands and expanded material database.
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  name text not null,
  contact_person text,
  phone text,
  whatsapp text,
  email text,
  address text,
  category text,
  rating numeric(3,2),
  logo_url text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.material_brands (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  name text not null,
  logo_url text,
  website_url text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);

alter table public.materials add column if not exists subcategory text;
alter table public.materials add column if not exists brand_id uuid references public.material_brands(id) on delete set null;
alter table public.materials add column if not exists supplier_id uuid references public.suppliers(id) on delete set null;
alter table public.materials add column if not exists sale_price numeric(14,2) not null default 0;
alter table public.materials add column if not exists currency text not null default 'AED';
alter table public.materials add column if not exists minimum_order_quantity numeric(14,3) not null default 0;
alter table public.materials add column if not exists delivery_lead_days integer not null default 0;
alter table public.materials add column if not exists additional_photos jsonb not null default '[]'::jsonb;
alter table public.materials add column if not exists technical_drawing_url text;
alter table public.materials add column if not exists packaging_photo_url text;
alter table public.materials add column if not exists texture_photo_url text;
alter table public.materials add column if not exists supplier_links jsonb not null default '[]'::jsonb;
alter table public.materials add column if not exists attachments jsonb not null default '[]'::jsonb;
alter table public.materials add column if not exists archived_at timestamptz;
alter table public.materials add column if not exists deleted_at timestamptz;

-- Inventory movements are corrected by reversal, not silently deleted.
alter table public.stock_movements add column if not exists source_warehouse_id uuid references public.warehouse_locations(id) on delete set null;
alter table public.stock_movements add column if not exists destination_warehouse_id uuid references public.warehouse_locations(id) on delete set null;
alter table public.stock_movements add column if not exists reference text;
alter table public.stock_movements add column if not exists reversal_of_id uuid references public.stock_movements(id) on delete set null;
alter table public.stock_movements add column if not exists reversed_at timestamptz;
alter table public.stock_movements add column if not exists updated_at timestamptz not null default now();

insert into public.warehouse_locations (organization_id, name, address)
select '00000000-0000-0000-0000-000000000001','Основной склад','Dubai'
where not exists (
  select 1 from public.warehouse_locations
  where organization_id='00000000-0000-0000-0000-000000000001' and name='Основной склад'
);

create or replace view public.warehouse_stock
with (security_invoker = true)
as
with movement_lines as (
  select
    organization_id,
    coalesce(warehouse_id, source_warehouse_id, destination_warehouse_id) as warehouse_id,
    material_id,
    case
      when movement_type in ('receipt','return','inventory') then quantity
      when movement_type in ('issue','writeoff','defect') then -quantity
      else 0
    end as quantity_delta,
    case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end as reserve_delta
  from public.stock_movements
  where movement_type<>'transfer' and reversed_at is null
  union all
  select organization_id, source_warehouse_id, material_id, -quantity, 0
  from public.stock_movements
  where movement_type='transfer' and reversed_at is null and source_warehouse_id is not null
  union all
  select organization_id, destination_warehouse_id, material_id, quantity, 0
  from public.stock_movements
  where movement_type='transfer' and reversed_at is null and destination_warehouse_id is not null
)
select
  organization_id,
  warehouse_id,
  material_id,
  sum(quantity_delta) as quantity_on_hand,
  sum(reserve_delta) as reserved
from movement_lines
group by organization_id,warehouse_id,material_id;

-- 6. Payroll foundation.
create table if not exists public.timesheets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  work_date date not null,
  regular_hours numeric(6,2) not null default 0,
  overtime_hours numeric(6,2) not null default 0,
  absent_hours numeric(6,2) not null default 0,
  status text not null default 'worked',
  notes text,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (employee_id, work_date, project_id)
);

create table if not exists public.payroll_periods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  period_year integer not null,
  period_month integer not null check (period_month between 1 and 12),
  status text not null default 'draft',
  calculated_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, period_year, period_month)
);

create table if not exists public.payroll_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  payroll_period_id uuid not null references public.payroll_periods(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  base_amount numeric(14,2) not null default 0,
  daily_amount numeric(14,2) not null default 0,
  hourly_amount numeric(14,2) not null default 0,
  overtime_amount numeric(14,2) not null default 0,
  project_amount numeric(14,2) not null default 0,
  bonuses numeric(14,2) not null default 0,
  penalties numeric(14,2) not null default 0,
  absence_deduction numeric(14,2) not null default 0,
  advances numeric(14,2) not null default 0,
  accrued numeric(14,2) not null default 0,
  paid numeric(14,2) not null default 0,
  balance numeric(14,2) not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (payroll_period_id, employee_id)
);

create table if not exists public.payroll_adjustments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  adjustment_date date not null default current_date,
  adjustment_type text not null check (adjustment_type in ('advance','bonus','penalty','project_payment','other')),
  amount numeric(14,2) not null,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.payroll_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  payroll_entry_id uuid not null references public.payroll_entries(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  amount numeric(14,2) not null,
  payment_date date not null default current_date,
  payment_method text,
  reference text,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- Calculate or recalculate one monthly payroll period.
create or replace function public.calculate_payroll(p_year integer, p_month integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_period uuid;
begin
  if public.current_user_role() not in ('owner','admin','accountant') then
    raise exception 'Not allowed to calculate payroll';
  end if;

  insert into public.payroll_periods (organization_id, period_year, period_month, status, calculated_at)
  values (v_org, p_year, p_month, 'draft', now())
  on conflict (organization_id, period_year, period_month)
  do update set calculated_at = now()
  returning id into v_period;

  insert into public.payroll_entries (
    organization_id, payroll_period_id, employee_id,
    base_amount, daily_amount, hourly_amount, overtime_amount, project_amount,
    bonuses, penalties, absence_deduction, advances, accrued, paid, balance
  )
  select
    v_org,
    v_period,
    e.id,
    case when e.payment_type = 'monthly' then e.monthly_salary else 0 end,
    case when e.payment_type = 'daily' then count(distinct t.work_date) filter (where t.status='worked') * e.daily_rate else 0 end,
    case when e.payment_type = 'hourly' then coalesce(sum(t.regular_hours),0) * e.hourly_rate else 0 end,
    coalesce(sum(t.overtime_hours),0) * e.overtime_rate,
    coalesce((select sum(a.amount) from public.payroll_adjustments a
      where a.employee_id=e.id and a.adjustment_type='project_payment'
      and extract(year from a.adjustment_date)=p_year and extract(month from a.adjustment_date)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a
      where a.employee_id=e.id and a.adjustment_type='bonus'
      and extract(year from a.adjustment_date)=p_year and extract(month from a.adjustment_date)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a
      where a.employee_id=e.id and a.adjustment_type='penalty'
      and extract(year from a.adjustment_date)=p_year and extract(month from a.adjustment_date)=p_month),0),
    coalesce(sum(t.absent_hours),0) * e.hourly_rate,
    coalesce((select sum(a.amount) from public.payroll_adjustments a
      where a.employee_id=e.id and a.adjustment_type='advance'
      and extract(year from a.adjustment_date)=p_year and extract(month from a.adjustment_date)=p_month),0),
    0, 0, 0
  from public.employees e
  left join public.timesheets t on t.employee_id=e.id
    and extract(year from t.work_date)=p_year and extract(month from t.work_date)=p_month
  where e.organization_id=v_org and e.is_active=true and e.deleted_at is null
  group by e.id
  on conflict (payroll_period_id, employee_id)
  do update set
    base_amount=excluded.base_amount,
    daily_amount=excluded.daily_amount,
    hourly_amount=excluded.hourly_amount,
    overtime_amount=excluded.overtime_amount,
    project_amount=excluded.project_amount,
    bonuses=excluded.bonuses,
    penalties=excluded.penalties,
    absence_deduction=excluded.absence_deduction,
    advances=excluded.advances,
    updated_at=now();

  update public.payroll_entries pe
  set
    paid = coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.payroll_entry_id=pe.id),0),
    accrued = pe.base_amount + pe.daily_amount + pe.hourly_amount + pe.overtime_amount + pe.project_amount + pe.bonuses - pe.penalties - pe.absence_deduction,
    balance = (pe.base_amount + pe.daily_amount + pe.hourly_amount + pe.overtime_amount + pe.project_amount + pe.bonuses - pe.penalties - pe.absence_deduction) - pe.advances - coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.payroll_entry_id=pe.id),0),
    updated_at = now()
  where pe.payroll_period_id=v_period;

  return v_period;
end;
$$;

-- 7. Expanded editable dictionaries.
insert into public.dictionary_groups (id, organization_id, code, name, is_system)
values
  ('10000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001','unit','{"ru":"Единицы измерения","en":"Units"}',true),
  ('10000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001','material_category','{"ru":"Категории материалов","en":"Material categories"}',true),
  ('10000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001','payment_method','{"ru":"Способы оплаты","en":"Payment methods"}',true),
  ('10000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000001','currency','{"ru":"Валюты","en":"Currencies"}',true),
  ('10000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000001','department','{"ru":"Отделы","en":"Departments"}',true),
  ('10000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','dubai_area','{"ru":"Районы Дубая","en":"Dubai areas"}',true)
on conflict (id) do nothing;

insert into public.dictionary_items (organization_id, group_id, code, name, sort_order)
values
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','pcs','{"ru":"Штука","en":"Piece","short":"pcs"}',10),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','m2','{"ru":"Квадратный метр","en":"Square meter","short":"m²"}',20),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','lm','{"ru":"Погонный метр","en":"Linear meter","short":"lm"}',30),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','m','{"ru":"Метр","en":"Meter","short":"m"}',40),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','kg','{"ru":"Килограмм","en":"Kilogram","short":"kg"}',50),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','g','{"ru":"Грамм","en":"Gram","short":"g"}',60),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','l','{"ru":"Литр","en":"Liter","short":"L"}',70),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','set','{"ru":"Комплект","en":"Set","short":"set"}',80),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','box','{"ru":"Упаковка","en":"Box","short":"box"}',90),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','sheet','{"ru":"Лист","en":"Sheet","short":"sheet"}',100),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','roll','{"ru":"Рулон","en":"Roll","short":"roll"}',110),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000005','pair','{"ru":"Пара","en":"Pair","short":"pair"}',120),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','furniture','{"ru":"Мебельные материалы","en":"Furniture materials"}',10),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','construction','{"ru":"Строительные материалы","en":"Construction materials"}',20),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','electrical','{"ru":"Электрика","en":"Electrical"}',30),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','plumbing','{"ru":"Сантехника","en":"Plumbing"}',40),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','finishing','{"ru":"Отделочные материалы","en":"Finishing materials"}',50),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','glass','{"ru":"Стекло и зеркало","en":"Glass and mirror"}',60),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','metal','{"ru":"Металл","en":"Metal"}',70),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','stone','{"ru":"Камень","en":"Stone"}',80),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','hardware','{"ru":"Фурнитура","en":"Hardware"}',90),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','lighting','{"ru":"Освещение","en":"Lighting"}',100),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','consumables','{"ru":"Расходные материалы","en":"Consumables"}',110),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','tools','{"ru":"Инструменты","en":"Tools"}',120),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000006','packaging','{"ru":"Упаковка","en":"Packaging"}',130),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000007','cash','{"ru":"Наличные","en":"Cash"}',10),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000007','bank_transfer','{"ru":"Банковский перевод","en":"Bank transfer"}',20),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000007','card','{"ru":"Карта","en":"Card"}',30),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000008','AED','{"ru":"Дирхам ОАЭ","en":"UAE Dirham","short":"AED"}',10),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000008','USD','{"ru":"Доллар США","en":"US Dollar","short":"USD"}',20),
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000008','EUR','{"ru":"Евро","en":"Euro","short":"EUR"}',30)
on conflict (group_id, code) do nothing;

insert into public.material_categories (id,organization_id,code,name,sort_order)
values
  ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','furniture','{"ru":"Мебельные материалы","en":"Furniture materials"}',10),
  ('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','construction','{"ru":"Строительные материалы","en":"Construction materials"}',20),
  ('20000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','electrical','{"ru":"Электрика","en":"Electrical"}',30),
  ('20000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','plumbing','{"ru":"Сантехника","en":"Plumbing"}',40),
  ('20000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000001','finishing','{"ru":"Отделочные материалы","en":"Finishing materials"}',50),
  ('20000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001','glass','{"ru":"Стекло и зеркало","en":"Glass and mirror"}',60),
  ('20000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001','metal','{"ru":"Металл","en":"Metal"}',70),
  ('20000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000001','stone','{"ru":"Камень","en":"Stone"}',80),
  ('20000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000001','hardware','{"ru":"Фурнитура","en":"Hardware"}',90),
  ('20000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','lighting','{"ru":"Освещение","en":"Lighting"}',100),
  ('20000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000001','consumables','{"ru":"Расходные материалы","en":"Consumables"}',110),
  ('20000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000001','tools','{"ru":"Инструменты","en":"Tools"}',120),
  ('20000000-0000-0000-0000-000000000013','00000000-0000-0000-0000-000000000001','packaging','{"ru":"Упаковка","en":"Packaging"}',130)
on conflict (id) do nothing;

-- 8. Notification generation.
create or replace function public.refresh_operational_notifications()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_count integer;
begin
  delete from public.notifications
  where organization_id=v_org and read_at is null
    and notification_type in ('task_overdue','project_late','low_stock','payment_due');

  insert into public.notifications (organization_id, recipient_id, notification_type, title, message, entity_type, entity_id, due_at)
  select v_org, t.assignee_id, 'task_overdue', 'Просроченная задача', t.title, 'task', t.id, t.due_date::timestamptz
  from public.tasks t
  where t.organization_id=v_org and t.deleted_at is null and t.status<>'completed'
    and t.due_date<current_date;

  insert into public.notifications (organization_id, recipient_id, notification_type, title, message, entity_type, entity_id, due_at)
  select v_org, p.manager_id, 'project_late', 'Задержка проекта', p.name, 'project', p.id, p.due_date::timestamptz
  from public.projects p
  where p.organization_id=v_org and p.deleted_at is null and p.archived_at is null
    and p.status<>'Завершён' and p.due_date<current_date;

  insert into public.notifications (organization_id, notification_type, title, message, entity_type, entity_id)
  select v_org, 'low_stock', 'Низкий остаток', m.name, 'material', m.id
  from public.materials m
  left join public.warehouse_stock ws on ws.material_id=m.id and ws.organization_id=v_org
  where m.organization_id=v_org and m.deleted_at is null
    and (coalesce(ws.quantity_on_hand,0)-coalesce(ws.reserved,0))<=m.minimum_stock;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 9. Audit all important editable tables.
create or replace function public.log_entity_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_id uuid;
begin
  if tg_op='DELETE' then
    v_org=old.organization_id;
    v_id=old.id;
  else
    v_org=new.organization_id;
    v_id=new.id;
  end if;

  insert into public.activity_log (organization_id, entity_type, entity_id, action, old_data, new_data, actor_id)
  values (
    v_org, tg_table_name, v_id, lower(tg_op),
    case when tg_op='INSERT' then null else to_jsonb(old) end,
    case when tg_op='DELETE' then null else to_jsonb(new) end,
    auth.uid()
  );
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['clients','tasks','expenses','materials','employees','stock_movements','planning_events','payroll_entries']
  loop
    execute format('drop trigger if exists %I_audit on public.%I',t,t);
    execute format('create trigger %I_audit after insert or update or delete on public.%I for each row execute function public.log_entity_change()',t,t);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'app_settings','entity_comments','planning_events','suppliers','material_brands',
    'timesheets','payroll_periods','payroll_entries'
  ]
  loop
    execute format('drop trigger if exists %I_touch_updated_at on public.%I',t,t);
    execute format('create trigger %I_touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()',t,t);
  end loop;
end $$;

-- 10. RLS for new tables and stricter access to sensitive records.
do $$
declare t text; p text;
begin
  foreach t in array array['app_settings','entity_files','entity_comments','planning_events','suppliers','material_brands']
  loop
    execute format('alter table public.%I enable row level security',t);
    p=t||'_organization_access';
    execute format('drop policy if exists %I on public.%I',p,t);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id()) with check (organization_id=public.current_user_organization_id())',p,t);
  end loop;
end $$;

do $$
declare t text; p text;
begin
  foreach t in array array['timesheets','payroll_periods','payroll_entries','payroll_adjustments','payroll_payments']
  loop
    execute format('alter table public.%I enable row level security',t);
    p=t||'_payroll_access';
    execute format('drop policy if exists %I on public.%I',p,t);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant'')) with check (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant''))',p,t);
  end loop;
end $$;

drop policy if exists employees_organization_access on public.employees;
drop policy if exists employees_sensitive_access on public.employees;
create policy employees_sensitive_access on public.employees
for all to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','accountant')
)
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','accountant')
);

drop policy if exists activity_log_organization_access on public.activity_log;
drop policy if exists activity_log_sensitive_access on public.activity_log;
create policy activity_log_sensitive_access on public.activity_log
for select to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','accountant')
);

drop policy if exists clients_organization_access on public.clients;
drop policy if exists clients_business_access on public.clients;
create policy clients_business_access on public.clients
for all to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','marketing','accountant')
)
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','marketing','accountant')
);

drop policy if exists client_contacts_organization_access on public.client_contacts;
drop policy if exists client_contacts_business_access on public.client_contacts;
create policy client_contacts_business_access on public.client_contacts
for all to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','marketing','accountant')
)
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','marketing','accountant')
);

drop policy if exists project_sites_organization_access on public.project_sites;
drop policy if exists project_sites_business_access on public.project_sites;
create policy project_sites_business_access on public.project_sites
for all to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','marketing','accountant')
)
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','marketing','accountant')
);

drop policy if exists project_members_organization_access on public.project_members;
drop policy if exists project_members_read on public.project_members;
create policy project_members_read on public.project_members
for select to authenticated
using (
  organization_id=public.current_user_organization_id()
  and (profile_id=auth.uid() or public.current_user_role() in ('owner','admin','project_manager','foreman'))
);
drop policy if exists project_members_manage on public.project_members;
create policy project_members_manage on public.project_members
for all to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager')
)
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager')
);

drop policy if exists projects_organization_access on public.projects;
drop policy if exists projects_read on public.projects;
create policy projects_read on public.projects
for select to authenticated
using (
  organization_id=public.current_user_organization_id()
  and (
    public.current_user_role() in ('owner','admin','accountant','project_manager','foreman','procurement','storekeeper')
    or created_by=auth.uid()
    or exists (select 1 from public.project_members pm where pm.project_id=projects.id and pm.profile_id=auth.uid())
  )
);
drop policy if exists projects_create on public.projects;
create policy projects_create on public.projects
for insert to authenticated
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager')
);
drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects
for update to authenticated
using (
  organization_id=public.current_user_organization_id()
  and (
    public.current_user_role() in ('owner','admin','project_manager','foreman')
    or exists (
      select 1 from public.project_members pm
      where pm.project_id=projects.id and pm.profile_id=auth.uid()
        and pm.project_role in ('manager','foreman')
    )
  )
)
with check (organization_id=public.current_user_organization_id());
drop policy if exists projects_delete on public.projects;
create policy projects_delete on public.projects
for delete to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin')
);

drop policy if exists tasks_organization_access on public.tasks;
drop policy if exists tasks_read on public.tasks;
create policy tasks_read on public.tasks
for select to authenticated
using (
  organization_id=public.current_user_organization_id()
  and (
    public.current_user_role() in ('owner','admin','project_manager','foreman')
    or assignee_id=auth.uid()
    or auth.uid()=any(collaborators)
    or exists (select 1 from public.project_members pm where pm.project_id=tasks.project_id and pm.profile_id=auth.uid())
  )
);
drop policy if exists tasks_create on public.tasks;
create policy tasks_create on public.tasks
for insert to authenticated
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','foreman')
);
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks
for update to authenticated
using (
  organization_id=public.current_user_organization_id()
  and (public.current_user_role() in ('owner','admin','project_manager','foreman') or assignee_id=auth.uid())
)
with check (organization_id=public.current_user_organization_id());
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks
for delete to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager')
);

drop policy if exists stock_movements_organization_access on public.stock_movements;
drop policy if exists stock_movements_operations_access on public.stock_movements;
create policy stock_movements_operations_access on public.stock_movements
for all to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','foreman','procurement','storekeeper','accountant')
)
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','foreman','procurement','storekeeper')
);

drop policy if exists project_stages_organization_access on public.project_stages;
drop policy if exists project_stages_read on public.project_stages;
create policy project_stages_read on public.project_stages
for select to authenticated
using (
  organization_id=public.current_user_organization_id()
  and exists (select 1 from public.projects p where p.id=project_stages.project_id)
);
drop policy if exists project_stages_manage on public.project_stages;
create policy project_stages_manage on public.project_stages
for all to authenticated
using (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','foreman','designer')
)
with check (
  organization_id=public.current_user_organization_id()
  and public.current_user_role() in ('owner','admin','project_manager','foreman','designer')
);

drop policy if exists project_history_organization_access on public.project_history;
drop policy if exists project_history_read on public.project_history;
create policy project_history_read on public.project_history
for select to authenticated
using (
  organization_id=public.current_user_organization_id()
  and exists (select 1 from public.projects p where p.id=project_history.project_id)
);

drop policy if exists app_settings_organization_access on public.app_settings;
drop policy if exists app_settings_read on public.app_settings;
create policy app_settings_read on public.app_settings
for select to authenticated
using (organization_id=public.current_user_organization_id());
drop policy if exists app_settings_admin on public.app_settings;
create policy app_settings_admin on public.app_settings
for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin'));

drop policy if exists materials_organization_access on public.materials;
drop policy if exists materials_read on public.materials;
create policy materials_read on public.materials
for select to authenticated
using (organization_id=public.current_user_organization_id());
drop policy if exists materials_manage on public.materials;
create policy materials_manage on public.materials
for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','procurement','storekeeper'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','procurement','storekeeper'));

drop policy if exists material_categories_organization_access on public.material_categories;
drop policy if exists material_categories_read on public.material_categories;
create policy material_categories_read on public.material_categories
for select to authenticated
using (organization_id=public.current_user_organization_id());
drop policy if exists material_categories_manage on public.material_categories;
create policy material_categories_manage on public.material_categories
for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','procurement'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','procurement'));

drop policy if exists warehouse_locations_organization_access on public.warehouse_locations;
drop policy if exists warehouse_locations_read on public.warehouse_locations;
create policy warehouse_locations_read on public.warehouse_locations
for select to authenticated
using (organization_id=public.current_user_organization_id());
drop policy if exists warehouse_locations_manage on public.warehouse_locations;
create policy warehouse_locations_manage on public.warehouse_locations
for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','storekeeper'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','storekeeper'));

drop policy if exists suppliers_organization_access on public.suppliers;
drop policy if exists suppliers_operations_access on public.suppliers;
create policy suppliers_operations_access on public.suppliers
for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','project_manager','procurement','accountant'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','procurement'));

drop policy if exists notifications_organization_access on public.notifications;
drop policy if exists notifications_recipient_access on public.notifications;
create policy notifications_recipient_access on public.notifications
for select to authenticated
using (
  organization_id=public.current_user_organization_id()
  and (recipient_id is null or recipient_id=auth.uid() or public.current_user_role() in ('owner','admin'))
);
drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
for update to authenticated
using (
  organization_id=public.current_user_organization_id()
  and (recipient_id is null or recipient_id=auth.uid() or public.current_user_role() in ('owner','admin'))
)
with check (organization_id=public.current_user_organization_id());

-- Restrict dictionary changes to administrators while allowing all organization users to read.
drop policy if exists dictionary_groups_organization_access on public.dictionary_groups;
drop policy if exists dictionary_items_organization_access on public.dictionary_items;
drop policy if exists dictionary_groups_read on public.dictionary_groups;
create policy dictionary_groups_read on public.dictionary_groups for select to authenticated
using (organization_id=public.current_user_organization_id());
drop policy if exists dictionary_items_read on public.dictionary_items;
create policy dictionary_items_read on public.dictionary_items for select to authenticated
using (organization_id=public.current_user_organization_id());
drop policy if exists dictionary_groups_admin on public.dictionary_groups;
create policy dictionary_groups_admin on public.dictionary_groups for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin'));
drop policy if exists dictionary_items_admin on public.dictionary_items;
create policy dictionary_items_admin on public.dictionary_items for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin'));

-- 11. Indexes and grants.
create index if not exists idx_entity_files_entity on public.entity_files(entity_type,entity_id,created_at desc);
create index if not exists idx_entity_comments_entity on public.entity_comments(entity_type,entity_id,created_at desc);
create index if not exists idx_planning_events_dates on public.planning_events(start_at,end_at);
create index if not exists idx_timesheets_month on public.timesheets(employee_id,work_date);
create index if not exists idx_payroll_entries_period on public.payroll_entries(payroll_period_id,employee_id);
create index if not exists idx_notifications_recipient on public.notifications(recipient_id,read_at,created_at desc);

grant select,insert,update,delete on all tables in schema public to authenticated;
grant usage,select on all sequences in schema public to authenticated;
grant execute on function public.calculate_payroll(integer,integer) to authenticated;
grant execute on function public.refresh_operational_notifications() to authenticated;

-- Phase 1.1 complete. Existing data has not been removed.
