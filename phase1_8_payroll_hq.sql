-- Space Buro Project Cloud — Phase 1.8 Payroll HQ
-- Additive migration: existing employees, payroll periods and design calculations are preserved.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- 1. Employee hierarchy and flexible rates.
-- ---------------------------------------------------------------------------

alter table public.employees add column if not exists supervisor_id uuid;
alter table public.employees add column if not exists hierarchy_level text not null default 'staff';
alter table public.employees add column if not exists display_order integer not null default 100;
alter table public.employees add column if not exists department_code text;
alter table public.employees add column if not exists job_title_code text;
alter table public.employees add column if not exists contract_rate numeric(14,2) not null default 0;
alter table public.employees add column if not exists end_date date;
alter table public.employees add column if not exists standard_hours_per_day numeric(6,2) not null default 10;
alter table public.employees add column if not exists employment_terms jsonb not null default '{}'::jsonb;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='employees_supervisor_id_fkey' and conrelid='public.employees'::regclass
  ) then
    alter table public.employees
      add constraint employees_supervisor_id_fkey
      foreign key (supervisor_id) references public.employees(id) on delete set null;
  end if;
end $$;

-- Classify existing cards without overwriting hierarchy already chosen by the user.
update public.employees
set hierarchy_level=case
  when coalesce(job_title,'') ~* '(owner|director|руковод|директор|founder|генераль)' then 'executive'
  when coalesce(job_title,'') ~* '(manager|менеджер|accountant|бухгалтер|architect|архитектор|engineer|инженер)' then 'manager'
  when coalesce(job_title,'') ~* '(supervisor|foreman|прораб|супервайзер|начальник)' then 'supervisor'
  when coalesce(job_title,'') ~* '(designer|дизайнер|draft|чертеж)' then 'core'
  else hierarchy_level
end
where hierarchy_level='staff';

-- ---------------------------------------------------------------------------
-- 2. Editable company dictionaries for employee forms.
-- ---------------------------------------------------------------------------

insert into public.dictionary_groups(organization_id,code,name,is_system)
select o.id,'department','{"ru":"Департаменты","en":"Departments"}'::jsonb,true
from public.organizations o
on conflict(organization_id,code) do update set name=excluded.name,is_system=true;

insert into public.dictionary_groups(organization_id,code,name,is_system)
select o.id,'job_title','{"ru":"Должности","en":"Job titles"}'::jsonb,true
from public.organizations o
on conflict(organization_id,code) do update set name=excluded.name,is_system=true;

insert into public.dictionary_groups(organization_id,code,name,is_system)
select o.id,'hierarchy_level','{"ru":"Уровни иерархии","en":"Hierarchy levels"}'::jsonb,true
from public.organizations o
on conflict(organization_id,code) do update set name=excluded.name,is_system=true;

insert into public.dictionary_groups(organization_id,code,name,is_system)
select o.id,'contractor_type','{"ru":"Типы контракторов","en":"Contractor types"}'::jsonb,true
from public.organizations o
on conflict(organization_id,code) do update set name=excluded.name,is_system=true;

with values_to_add as (select * from (values
  ('executive_management','Руководство','Executive Management',10),
  ('project_management','Управление проектами','Project Management',20),
  ('design_architecture','Дизайн и архитектура','Design & Architecture',30),
  ('engineering','Инженерный отдел','Engineering',40),
  ('construction','Строительство','Construction',50),
  ('renovation_fitout','Ремонт и fit-out','Renovation & Fit-Out',60),
  ('joinery_furniture','Мебельное производство','Joinery & Furniture Production',70),
  ('site_operations','Работы на объектах','Site Operations',80),
  ('mep','MEP: электрика, сантехника, HVAC','MEP',90),
  ('procurement_supply','Закупки и снабжение','Procurement & Supply Chain',100),
  ('warehouse_logistics','Склад и логистика','Warehouse & Logistics',110),
  ('quality_hse','Контроль качества и HSE','Quality Control & HSE',120),
  ('finance_accounting','Финансы и бухгалтерия','Finance & Accounting',130),
  ('sales_clients','Продажи и работа с клиентами','Sales & Client Relations',140),
  ('marketing','Маркетинг','Marketing',150),
  ('hr_admin','HR и администрация','HR & Administration',160),
  ('transport','Транспорт','Drivers & Transport',170),
  ('maintenance_service','Сервис и обслуживание','Maintenance & Service',180)
) as v(code,ru,en,sort_order))
insert into public.dictionary_items(organization_id,group_id,code,name,sort_order)
select g.organization_id,g.id,v.code,jsonb_build_object('ru',v.ru,'en',v.en),v.sort_order
from public.dictionary_groups g cross join values_to_add v
where g.code='department'
on conflict(group_id,code) do update
set name=excluded.name,sort_order=excluded.sort_order,is_active=true;

with values_to_add as (select * from (values
  ('owner_managing_director','Владелец / управляющий директор','Owner / Managing Director',10),
  ('general_manager','Генеральный менеджер','General Manager',20),
  ('operations_manager','Операционный менеджер','Operations Manager',30),
  ('project_director','Директор проектов','Project Director',40),
  ('project_manager','Менеджер проекта','Project Manager',50),
  ('assistant_project_manager','Ассистент менеджера проекта','Assistant Project Manager',60),
  ('construction_supervisor','Супервайзер строительства','Construction Supervisor',70),
  ('site_supervisor','Супервайзер объекта','Site Supervisor',80),
  ('foreman','Прораб','Foreman',90),
  ('senior_interior_designer','Старший интерьерный дизайнер','Senior Interior Designer',100),
  ('interior_designer','Интерьерный дизайнер','Interior Designer',110),
  ('architect','Архитектор','Architect',120),
  ('cad_drafter','Чертёжник CAD','CAD Drafter',130),
  ('bim_revit_specialist','BIM / Revit специалист','BIM / Revit Specialist',140),
  ('quantity_surveyor','Сметчик / Quantity Surveyor','Quantity Surveyor / Estimator',150),
  ('civil_engineer','Инженер-строитель','Civil Engineer',160),
  ('mep_engineer','MEP инженер','MEP Engineer',170),
  ('electrical_engineer','Инженер-электрик','Electrical Engineer',180),
  ('plumbing_engineer','Инженер-сантехник','Plumbing Engineer',190),
  ('procurement_manager','Менеджер по закупкам','Procurement Manager',200),
  ('procurement_officer','Специалист по закупкам','Procurement Officer',210),
  ('warehouse_manager','Руководитель склада','Warehouse Manager',220),
  ('storekeeper','Кладовщик','Storekeeper',230),
  ('logistics_coordinator','Координатор логистики','Logistics Coordinator',240),
  ('furniture_production_manager','Руководитель мебельного производства','Furniture Production Manager',250),
  ('joinery_supervisor','Супервайзер столярного производства','Joinery Supervisor',260),
  ('carpenter_furniture_maker','Мебельщик / столяр','Carpenter / Furniture Maker',270),
  ('installer','Монтажник','Installer',280),
  ('electrician','Электрик','Electrician',290),
  ('plumber','Сантехник','Plumber',300),
  ('painter','Маляр','Painter',310),
  ('tiler','Плиточник','Tiler',320),
  ('gypsum_installer','Гипсокартонщик','Gypsum Installer',330),
  ('mason','Каменщик','Mason',340),
  ('welder_metal_worker','Сварщик / специалист по металлу','Welder / Metal Worker',350),
  ('glass_installer','Монтажник стекла','Glass Installer',360),
  ('hvac_technician','Техник HVAC','HVAC Technician',370),
  ('quality_inspector','Инспектор качества','Quality Inspector',380),
  ('hse_officer','Специалист HSE','HSE Officer',390),
  ('sales_manager','Менеджер по продажам','Sales Manager',400),
  ('client_relationship_manager','Менеджер по работе с клиентами','Client Relationship Manager',410),
  ('marketing_manager','Маркетолог','Marketing Manager',420),
  ('accountant','Бухгалтер','Accountant',430),
  ('payroll_accountant','Бухгалтер по зарплате','Payroll Accountant',440),
  ('hr_administrator','HR / администратор','HR / Administrator',450),
  ('driver','Водитель','Driver',460),
  ('maintenance_technician','Техник по обслуживанию','Maintenance Technician',470),
  ('general_worker','Подсобный рабочий','General Worker',480)
) as v(code,ru,en,sort_order))
insert into public.dictionary_items(organization_id,group_id,code,name,sort_order)
select g.organization_id,g.id,v.code,jsonb_build_object('ru',v.ru,'en',v.en),v.sort_order
from public.dictionary_groups g cross join values_to_add v
where g.code='job_title'
on conflict(group_id,code) do update
set name=excluded.name,sort_order=excluded.sort_order,is_active=true;

with values_to_add as (select * from (values
  ('executive','Руководство','Executive',10),
  ('manager','Менеджеры и специалисты','Managers & Specialists',20),
  ('supervisor','Супервайзеры и прорабы','Supervisors & Foremen',30),
  ('core','Ключевые сотрудники','Core Team',40),
  ('staff','Основной штат','Staff',50)
) as v(code,ru,en,sort_order))
insert into public.dictionary_items(organization_id,group_id,code,name,sort_order)
select g.organization_id,g.id,v.code,jsonb_build_object('ru',v.ru,'en',v.en),v.sort_order
from public.dictionary_groups g cross join values_to_add v
where g.code='hierarchy_level'
on conflict(group_id,code) do update
set name=excluded.name,sort_order=excluded.sort_order,is_active=true;

with values_to_add as (select * from (values
  ('individual','Частный контрактор','Individual Contractor',10),
  ('designer','Дизайнер','Designer',20),
  ('drafter','Чертёжник','Drafter',30),
  ('consultant','Консультант','Consultant',40),
  ('trade_crew','Специализированная бригада','Trade Crew',50),
  ('installer','Монтажник','Installer',60),
  ('subcontractor','Субподрядчик','Subcontractor',70),
  ('project_specialist','Проектный специалист','Project Specialist',80)
) as v(code,ru,en,sort_order))
insert into public.dictionary_items(organization_id,group_id,code,name,sort_order)
select g.organization_id,g.id,v.code,jsonb_build_object('ru',v.ru,'en',v.en),v.sort_order
from public.dictionary_groups g cross join values_to_add v
where g.code='contractor_type'
on conflict(group_id,code) do update
set name=excluded.name,sort_order=excluded.sort_order,is_active=true;

-- ---------------------------------------------------------------------------
-- 3. Contractors, operation-based accruals and payments.
-- ---------------------------------------------------------------------------

create table if not exists public.contractors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  contractor_number text,
  full_name text not null,
  company_name text,
  photo_url text,
  contractor_type text not null default 'individual',
  job_title text,
  department text,
  phone text,
  whatsapp text,
  email text,
  start_date date,
  end_date date,
  payment_model text not null default 'variable',
  default_rate numeric(14,2) not null default 0,
  currency text not null default 'AED',
  status text not null default 'active',
  bank_details jsonb not null default '{}'::jsonb,
  documents jsonb not null default '[]'::jsonb,
  notes text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,contractor_number)
);

create table if not exists public.contractor_operations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  contractor_id uuid not null references public.contractors(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  task_id uuid references public.tasks(id) on delete set null,
  operation_date date not null default current_date,
  due_date date,
  operation_type text not null default 'project_work',
  description text not null,
  pricing_type text not null default 'variable',
  quantity numeric(14,3) not null default 1,
  unit text not null default 'job',
  rate numeric(14,2) not null default 0,
  base_amount numeric(14,2) not null default 0,
  percentage numeric(7,3) not null default 0,
  amount numeric(14,2) not null default 0,
  approved_amount numeric(14,2) not null default 0,
  status text not null default 'draft',
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  documents jsonb not null default '[]'::jsonb,
  notes text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.contractor_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  contractor_id uuid not null references public.contractors(id) on delete cascade,
  operation_id uuid references public.contractor_operations(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  payment_date date not null default current_date,
  amount numeric(14,2) not null default 0,
  payment_method text,
  reference text,
  status text not null default 'paid',
  document_url text,
  notes text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.calculate_contractor_operation_v18()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  new.amount:=round(case new.pricing_type
    when 'unit' then new.quantity*new.rate
    when 'daily' then new.quantity*new.rate
    when 'hourly' then new.quantity*new.rate
    when 'percentage' then new.base_amount*new.percentage/100
    when 'fixed' then coalesce(nullif(new.amount,0),nullif(new.rate,0),new.base_amount,0)
    when 'milestone' then coalesce(nullif(new.amount,0),new.base_amount,0)
    else coalesce(new.amount,0)
  end,2);
  if new.status in ('approved','partially_paid','paid') and coalesce(new.approved_amount,0)=0 then
    new.approved_amount:=new.amount;
  end if;
  if new.status='approved' and new.approved_at is null then
    new.approved_at:=now();
    new.approved_by:=coalesce(new.approved_by,auth.uid());
  end if;
  return new;
end;
$$;

create or replace trigger contractor_operations_calculate_v18
before insert or update of pricing_type,quantity,rate,base_amount,percentage,amount,status
on public.contractor_operations
for each row execute function public.calculate_contractor_operation_v18();

create or replace view public.contractor_operation_balances
with (security_invoker=true)
as
select
  o.*,
  coalesce(sum(p.amount) filter (where p.status='paid'),0)::numeric(14,2) as paid_amount,
  (case when o.approved_amount>0 then o.approved_amount else o.amount end
    -coalesce(sum(p.amount) filter (where p.status='paid'),0))::numeric(14,2) as balance
from public.contractor_operations o
left join public.contractor_payments p on p.operation_id=o.id
group by o.id;

-- ---------------------------------------------------------------------------
-- 4. Unified payroll adjustments and exact design-stage percentages.
-- ---------------------------------------------------------------------------

alter table public.payroll_adjustments add column if not exists source_type text;
alter table public.payroll_adjustments add column if not exists source_id uuid;
alter table public.payroll_adjustments add column if not exists quantity numeric(14,3) not null default 1;
alter table public.payroll_adjustments add column if not exists unit text;
alter table public.payroll_adjustments add column if not exists rate numeric(14,2) not null default 0;
alter table public.payroll_adjustments add column if not exists percentage numeric(7,3) not null default 0;
alter table public.payroll_adjustments add column if not exists base_amount numeric(14,2) not null default 0;
alter table public.payroll_adjustments add column if not exists approval_status text not null default 'approved';
alter table public.payroll_adjustments add column if not exists approved_by uuid references public.profiles(id) on delete set null;
alter table public.payroll_adjustments add column if not exists approved_at timestamptz;

alter table public.design_stage_entries add column if not exists completion_percent numeric(6,2) not null default 0;
update public.design_stage_entries
set completion_percent=100
where is_completed=true and completion_percent=0;

alter table public.design_compensations add column if not exists manual_adjustment numeric(14,2) not null default 0;
alter table public.design_compensations add column if not exists calculation_notes text;

create or replace function public.recalculate_design_program(p_program_entry_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  p public.design_program_entries%rowtype;
  v_progress numeric(6,2);
  v_stage numeric(14,2);
  v_sheet numeric(14,2);
  v_change numeric(14,2);
  v_error numeric(14,2);
  v_total numeric(14,2);
begin
  select * into p from public.design_program_entries
  where id=p_program_entry_id and organization_id=public.current_user_organization_id();
  if p.id is null then return; end if;

  select coalesce(sum(
    s.weight_percent*least(100,greatest(0,
      case when s.completion_percent>0 then s.completion_percent
           when s.is_completed then 100 else 0 end
    ))/100
  ),0) into v_progress
  from public.design_stage_entries s where s.program_entry_id=p.id;

  v_stage:=round(p.base_rate*v_progress/100,2);
  v_sheet:=round(p.sheet_count*p.sheet_rate,2);
  select coalesce(max(r.numeric_value),0) into v_change
  from public.design_payment_rules r
  where r.organization_id=p.organization_id and r.rule_type='change_amount'
    and r.code='coefficient_'||p.changes_coefficient and r.is_active;
  select coalesce(max(r.numeric_value),0) into v_error
  from public.design_payment_rules r
  where r.organization_id=p.organization_id and r.rule_type='error_amount'
    and r.code='coefficient_'||p.errors_coefficient and r.is_active;
  v_total:=greatest(0,v_stage+v_sheet+v_change-v_error);

  update public.design_program_entries
  set progress_percent=v_progress,stage_amount=v_stage,sheet_amount=v_sheet,
      changes_amount=v_change,error_deduction=v_error,total_amount=v_total,updated_at=now()
  where id=p.id;
  perform public.recalculate_design_compensation(p.compensation_id);
end;
$$;

create or replace function public.recalculate_design_compensation(p_compensation_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  c public.design_compensations%rowtype;
  v_material numeric(14,2);
  v_bonus numeric(14,2);
  v_cap numeric(14,2);
  v_program numeric(14,2);
  v_min numeric(14,2);
  v_before_minimum numeric(14,2);
begin
  select * into c from public.design_compensations
  where id=p_compensation_id and organization_id=public.current_user_organization_id();
  if c.id is null then return; end if;
  v_material:=coalesce(c.egger_actual_cost,0)+coalesce(c.additional_material_cost,0)+coalesce(c.hardware_cost,0);
  select coalesce(max(r.numeric_value),0) into v_bonus
  from public.design_payment_rules r
  where r.organization_id=c.organization_id and r.rule_type='material_bonus' and r.is_active
    and coalesce(r.threshold_amount,0)<=v_material;
  select coalesce(max(r.numeric_value),300) into v_cap
  from public.design_payment_rules r
  where r.organization_id=c.organization_id and r.rule_type='material_bonus_cap' and r.is_active;
  select coalesce(sum(p.total_amount),0) into v_program
  from public.design_program_entries p where p.compensation_id=c.id;
  select coalesce(max(r.numeric_value),150) into v_min
  from public.design_payment_rules r
  where r.organization_id=c.organization_id and r.rule_type='minimum_payment' and r.is_active;
  v_before_minimum:=greatest(0,v_program+least(v_bonus,v_cap)-coalesce(c.repeat_order_error_cost,0)+coalesce(c.manual_adjustment,0));

  update public.design_compensations set
    material_total=v_material,
    material_bonus=least(v_bonus,v_cap),
    program_total=v_program,
    final_payment=case when v_program>0 then greatest(v_before_minimum,v_min) else v_before_minimum end,
    updated_at=now()
  where id=c.id;
end;
$$;

create or replace trigger design_material_recalculate
after insert or update of egger_actual_cost,additional_material_cost,hardware_cost,
  repeat_order_error_cost,manual_adjustment
on public.design_compensations
for each row execute function public.design_material_recalculate_trigger();

create or replace function public.sync_design_payroll_adjustment_v18()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_date date;
begin
  if new.payroll_adjustment_id is not null and new.designer_id is not null then
    v_date:=coalesce(new.payment_date,current_date);
    update public.payroll_adjustments
    set employee_id=new.designer_id,
        project_id=new.project_id,
        amount=new.final_payment,
        adjustment_date=v_date,
        period_year=extract(year from v_date)::integer,
        period_month=extract(month from v_date)::integer,
        source_type='design_compensation',
        source_id=new.id,
        updated_at=now()
    where id=new.payroll_adjustment_id and organization_id=new.organization_id;
  end if;
  return new;
end;
$$;

create or replace trigger design_payroll_sync_v18
after update of final_payment,designer_id,project_id,payment_date,payroll_adjustment_id
on public.design_compensations
for each row execute function public.sync_design_payroll_adjustment_v18();

-- ---------------------------------------------------------------------------
-- 5. Range payroll preview: month, three months, custom dates and all time.
-- ---------------------------------------------------------------------------

create or replace function public.payroll_range_preview(
  p_from date,
  p_to date,
  p_employee_id uuid default null
)
returns table(
  employee_id uuid,
  active_days numeric,
  base_amount numeric,
  overtime_hours numeric,
  overtime_amount numeric,
  absence_hours numeric,
  absence_deduction numeric,
  project_amount numeric,
  bonuses numeric,
  other_accruals numeric,
  penalties numeric,
  other_deductions numeric,
  advances numeric,
  salary_paid numeric,
  paid_total numeric,
  accrued numeric,
  balance numeric
)
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid:=public.current_user_organization_id();
begin
  if public.current_user_role() not in ('owner','admin','accountant') then
    raise exception 'Not allowed to calculate payroll';
  end if;
  if p_from is null or p_to is null or p_to<p_from then
    raise exception 'Invalid payroll date range';
  end if;

  return query
  with cfg as (
    select coalesce(nullif(s.salary_day_divisor,0),30)::numeric as divisor,
           coalesce(nullif(s.hours_per_day,0),10)::numeric as hours_day,
           coalesce(s.overtime_multiplier,1)::numeric as ot_multiplier
    from (select 1) q
    left join public.payroll_settings s on s.organization_id=v_org
    limit 1
  ), employees_in_scope as (
    select e.*,
      greatest(p_from,coalesce(e.start_date,p_from)) as active_from,
      least(p_to,coalesce(e.end_date,p_to)) as active_to
    from public.employees e
    where e.organization_id=v_org and e.is_active=true and e.deleted_at is null
      and (p_employee_id is null or e.id=p_employee_id)
      and coalesce(e.start_date,p_to)<=p_to
      and coalesce(e.end_date,p_from)>=p_from
  )
  select
    e.id,
    greatest(0,e.active_to-e.active_from+1)::numeric as active_days,
    round(base.base_amount,2),
    coalesce(ev.ot_hours,0),
    round(coalesce(ev.ot_amount,0),2),
    coalesce(ev.abs_hours,0),
    round(case when e.payment_type='monthly' then coalesce(ev.abs_amount,0) else 0 end,2),
    round(coalesce(adj.project_amount,0),2),
    round(coalesce(adj.bonuses,0),2),
    round(coalesce(adj.other_accruals,0),2),
    round(coalesce(adj.penalties,0),2),
    round(coalesce(adj.other_deductions,0),2),
    round(coalesce(ev.advances,0)+coalesce(adj.advances,0),2),
    round(coalesce(adj.salary_paid,0),2),
    round(coalesce(ev.advances,0)+coalesce(adj.advances,0)+coalesce(adj.salary_paid,0),2),
    round(base.base_amount+coalesce(ev.ot_amount,0)+coalesce(adj.project_amount,0)+coalesce(adj.bonuses,0)+coalesce(adj.other_accruals,0)-case when e.payment_type='monthly' then coalesce(ev.abs_amount,0) else 0 end-coalesce(adj.penalties,0)-coalesce(adj.other_deductions,0),2),
    round(base.base_amount+coalesce(ev.ot_amount,0)+coalesce(adj.project_amount,0)+coalesce(adj.bonuses,0)+coalesce(adj.other_accruals,0)-case when e.payment_type='monthly' then coalesce(ev.abs_amount,0) else 0 end-coalesce(adj.penalties,0)-coalesce(adj.other_deductions,0)-coalesce(ev.advances,0)-coalesce(adj.advances,0)-coalesce(adj.salary_paid,0),2)
  from employees_in_scope e
  cross join cfg c
  left join lateral (
    select
      coalesce(sum(a.quantity) filter(where a.event_type='overtime'),0) as ot_hours,
      coalesce(sum(case when a.event_type='overtime' then
        a.quantity*coalesce(nullif(a.rate,0),nullif(e.overtime_rate,0),
          (case when e.hourly_rate>0 then e.hourly_rate
                when e.daily_rate>0 then e.daily_rate/c.hours_day
                else e.monthly_salary/c.divisor/c.hours_day end)*c.ot_multiplier)
        else 0 end),0) as ot_amount,
      coalesce(sum(a.quantity) filter(where a.event_type='absence'),0) as abs_hours,
      coalesce(sum(case when a.event_type='absence' then
        a.quantity*coalesce(nullif(a.rate,0),nullif(e.hourly_rate,0),
          case when e.daily_rate>0 then e.daily_rate/c.hours_day else e.monthly_salary/c.divisor/c.hours_day end)
        else 0 end),0) as abs_amount,
      coalesce(sum(case when a.event_type='advance' then coalesce(nullif(a.amount,0),a.quantity) else 0 end),0) as advances
    from public.payroll_attendance_events a
    where a.organization_id=v_org and a.employee_id=e.id and a.event_date between p_from and p_to
  ) ev on true
  left join lateral (
    select
      coalesce(sum(a.amount) filter(where a.adjustment_type='project_payment'),0) as project_amount,
      coalesce(sum(a.amount) filter(where a.adjustment_type='bonus'),0) as bonuses,
      coalesce(sum(a.amount) filter(where a.adjustment_type in ('additional_accrual','correction','other')),0) as other_accruals,
      coalesce(sum(a.amount) filter(where a.adjustment_type='penalty'),0) as penalties,
      coalesce(sum(a.amount) filter(where a.adjustment_type='deduction'),0) as other_deductions,
      coalesce(sum(a.amount) filter(where a.adjustment_type='advance'),0) as advances,
      coalesce(sum(a.amount) filter(where a.adjustment_type='salary_payment'),0)
        +coalesce((select sum(pp.amount) from public.payroll_payments pp
          where pp.organization_id=v_org and pp.employee_id=e.id
            and pp.payment_date between p_from and p_to),0) as salary_paid
    from public.payroll_adjustments a
    where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_date between p_from and p_to
      and coalesce(a.approval_status,'approved') in ('approved','paid')
  ) adj on true
  left join lateral (
    select count(distinct t.work_date) filter(where t.status='worked')::numeric as work_days,
           coalesce(sum(t.regular_hours),0)::numeric as regular_hours
    from public.timesheets t
    where t.organization_id=v_org and t.employee_id=e.id and t.work_date between p_from and p_to
  ) ts on true
  left join lateral (
    select coalesce(sum(case
      when x.segment_end<x.segment_start then 0
      when x.segment_start=x.month_start and x.segment_end=x.month_end then e.monthly_salary
      else e.monthly_salary*least(1,(x.segment_end-x.segment_start+1)::numeric/c.divisor)
    end),0) as monthly_base
    from (
      select gs::date as month_start,
        (gs+interval '1 month - 1 day')::date as month_end,
        greatest(gs::date,e.active_from) as segment_start,
        least((gs+interval '1 month - 1 day')::date,e.active_to) as segment_end
      from generate_series(date_trunc('month',p_from)::date,date_trunc('month',p_to)::date,interval '1 month') gs
    ) x
  ) mb on true
  left join lateral (
    select case e.payment_type
      when 'monthly' then mb.monthly_base
      when 'daily' then coalesce(ts.regular_hours,0)/c.hours_day
        *coalesce(nullif(e.daily_rate,0),e.monthly_salary/c.divisor)
      when 'hourly' then coalesce(ts.regular_hours,0)
        *coalesce(nullif(e.hourly_rate,0),nullif(e.daily_rate,0)/c.hours_day,e.monthly_salary/c.divisor/c.hours_day)
      else 0
    end::numeric as base_amount
  ) base on true
  order by e.full_name;
end;
$$;

-- Keep the old monthly API, but calculate it through the corrected range engine.
create or replace function public.calculate_payroll(p_year integer,p_month integer)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid:=public.current_user_organization_id();
  v_period uuid;
  v_from date:=make_date(p_year,p_month,1);
  v_to date:=(make_date(p_year,p_month,1)+interval '1 month - 1 day')::date;
begin
  if public.current_user_role() not in ('owner','admin','accountant') then
    raise exception 'Not allowed to calculate payroll';
  end if;
  insert into public.payroll_periods(organization_id,period_year,period_month,status,calculated_at)
  values(v_org,p_year,p_month,'draft',now())
  on conflict(organization_id,period_year,period_month) do update set calculated_at=now()
  returning id into v_period;

  insert into public.payroll_entries(
    organization_id,payroll_period_id,employee_id,base_amount,daily_amount,hourly_amount,
    overtime_amount,project_amount,bonuses,penalties,absence_deduction,advances,
    other_accruals,other_deductions,accrued,paid,balance
  )
  select v_org,v_period,r.employee_id,
    case when e.payment_type='monthly' then r.base_amount else 0 end,
    case when e.payment_type='daily' then r.base_amount else 0 end,
    case when e.payment_type='hourly' then r.base_amount else 0 end,
    r.overtime_amount,r.project_amount,r.bonuses,r.penalties,r.absence_deduction,r.advances,
    r.other_accruals,r.other_deductions,r.accrued,r.salary_paid,r.balance
  from public.payroll_range_preview(v_from,v_to,null) r
  join public.employees e on e.id=r.employee_id
  on conflict(payroll_period_id,employee_id) do update set
    base_amount=excluded.base_amount,daily_amount=excluded.daily_amount,hourly_amount=excluded.hourly_amount,
    overtime_amount=excluded.overtime_amount,project_amount=excluded.project_amount,
    bonuses=excluded.bonuses,penalties=excluded.penalties,
    absence_deduction=excluded.absence_deduction,advances=excluded.advances,
    other_accruals=excluded.other_accruals,other_deductions=excluded.other_deductions,
    accrued=excluded.accrued,paid=excluded.paid,balance=excluded.balance,updated_at=now();
  return v_period;
end;
$$;

-- Empty absence hours mean one standard 10-hour workday. Rates stay configurable.
create or replace function public.calculate_payroll_event_amount()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare e public.employees%rowtype;s public.payroll_settings%rowtype;v_daily numeric;v_hourly numeric;
begin
  select * into e from public.employees where id=new.employee_id and organization_id=new.organization_id;
  select * into s from public.payroll_settings where organization_id=new.organization_id;
  if e.id is null then raise exception 'Employee not found'; end if;
  v_daily:=coalesce(nullif(e.daily_rate,0),e.monthly_salary/coalesce(nullif(s.salary_day_divisor,0),30));
  v_hourly:=coalesce(nullif(e.hourly_rate,0),v_daily/coalesce(nullif(e.standard_hours_per_day,0),coalesce(nullif(s.hours_per_day,0),10)));
  if new.event_type='absence' and coalesce(new.quantity,0)<=0 then
    new.quantity:=coalesce(nullif(e.standard_hours_per_day,0),coalesce(nullif(s.hours_per_day,0),10));
  end if;
  if new.event_type='overtime' then
    new.rate:=coalesce(nullif(e.overtime_rate,0),v_hourly*coalesce(s.overtime_multiplier,1));
    new.amount:=round(new.quantity*new.rate,2);
  elsif new.event_type='absence' then
    new.rate:=v_hourly;
    new.amount:=-round(new.quantity*new.rate,2);
  else
    new.rate:=1;
    new.amount:=round(new.quantity,2);
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Security, indexes and API grants.
-- ---------------------------------------------------------------------------

alter table public.contractors enable row level security;
alter table public.contractor_operations enable row level security;
alter table public.contractor_payments enable row level security;

do $$
begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='contractors' and policyname='contractors_phase18_access') then
    create policy contractors_phase18_access on public.contractors for all to authenticated
    using(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','accountant','project_manager'))
    with check(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','accountant','project_manager'));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='contractor_operations' and policyname='contractor_operations_phase18_access') then
    create policy contractor_operations_phase18_access on public.contractor_operations for all to authenticated
    using(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','accountant','project_manager'))
    with check(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','accountant','project_manager'));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='contractor_payments' and policyname='contractor_payments_phase18_access') then
    create policy contractor_payments_phase18_access on public.contractor_payments for all to authenticated
    using(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','accountant'))
    with check(organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','accountant'));
  end if;
end $$;

create or replace trigger contractors_touch_updated_at_v18
before update on public.contractors
for each row execute function public.touch_updated_at();
create or replace trigger contractor_operations_touch_updated_at_v18
before update on public.contractor_operations
for each row execute function public.touch_updated_at();
create or replace trigger contractor_payments_touch_updated_at_v18
before update on public.contractor_payments
for each row execute function public.touch_updated_at();

create index if not exists idx_employees_hierarchy_v18
  on public.employees(organization_id,hierarchy_level,display_order,full_name);
create index if not exists idx_contractors_status_v18
  on public.contractors(organization_id,status,full_name);
create index if not exists idx_contractor_operations_period_v18
  on public.contractor_operations(organization_id,operation_date,contractor_id,project_id);
create index if not exists idx_contractor_payments_period_v18
  on public.contractor_payments(organization_id,payment_date,contractor_id,project_id);
create index if not exists idx_payroll_adjustments_source_v18
  on public.payroll_adjustments(organization_id,source_type,source_id);

grant select,insert,update,delete on public.contractors,public.contractor_operations,public.contractor_payments to authenticated;
grant select on public.contractor_operation_balances to authenticated;
grant execute on function public.calculate_contractor_operation_v18() to authenticated;
grant execute on function public.payroll_range_preview(date,date,uuid) to authenticated;
grant execute on function public.calculate_payroll(integer,integer) to authenticated;
grant execute on function public.calculate_payroll_event_amount() to authenticated;
grant execute on function public.recalculate_design_program(uuid) to authenticated;
grant execute on function public.recalculate_design_compensation(uuid) to authenticated;

notify pgrst,'reload schema';
