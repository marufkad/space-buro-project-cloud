-- Space Buro Project Cloud — Phase 1.2 stability and connected operations
-- Additive migration. Existing projects, clients, materials, stock and payroll data are preserved.

create extension if not exists "pgcrypto";

-- 1. Standard material templates. A template creates an editable material record.
create table if not exists public.material_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  category text not null,
  subcategory text,
  default_unit text not null default 'pcs',
  typical_dimensions jsonb not null default '[]'::jsonb,
  typical_thicknesses jsonb not null default '[]'::jsonb,
  suggested_brands jsonb not null default '[]'::jsonb,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, code)
);

with seed(category,subcategory,default_unit,names,dimensions,thicknesses,brands) as (
  values
  ('furniture','Panels','sheet',array['MDF','Moisture-resistant MDF','HDF','Plywood','Chipboard','Laminated chipboard','Egger','Painted MDF','Plywood veneer'],
    '["2440×1220 mm","2800×2070 mm"]'::jsonb,'[3,6,9,12,16,18,25]'::jsonb,'["Egger","Kronospan","Finsa","Alvic"]'::jsonb),
  ('furniture','Surfaces','sheet',array['Laminate','HPL','Compact laminate','Acrylic','Veneer','Natural veneer','PVC'],
    '["2440×1220 mm","3050×1300 mm"]'::jsonb,'[0.8,1,3,6,12]'::jsonb,'["Formica","Abet Laminati","Fenix","Rehau"]'::jsonb),
  ('furniture','Edges and profiles','m',array['ABS edge','Melamine edge','Aluminium profile','Gola profiles'],
    '[]'::jsonb,'[0.4,0.8,1,2]'::jsonb,'["Rehau","Hranipex","Häfele"]'::jsonb),
  ('furniture','Wood and metal','m2',array['Solid wood','Stainless steel','Mild steel'],
    '[]'::jsonb,'[]'::jsonb,'[]'::jsonb),
  ('furniture','Glass and mirror','m2',array['Glass','Tempered glass','Fluted glass','Mirror'],
    '[]'::jsonb,'[4,6,8,10,12]'::jsonb,'[]'::jsonb),
  ('furniture','Stone and ceramic','m2',array['Quartz','Porcelain','Ceramic','Natural stone','Artificial stone'],
    '[]'::jsonb,'[6,12,20,30]'::jsonb,'["Caesarstone","Silestone","Dekton"]'::jsonb),
  ('furniture','Upholstery','m',array['Leather','Artificial leather','Fabric','Foam'],
    '[]'::jsonb,'[]'::jsonb,'[]'::jsonb),
  ('furniture','Hardware','pcs',array['Furniture hardware','Hinges','Drawer runners','Drawer systems','Handles','Transformers','Sensors'],
    '[]'::jsonb,'[]'::jsonb,'["Blum","Hettich","Häfele","Grass"]'::jsonb),
  ('furniture','Lighting','m',array['LED'],
    '[]'::jsonb,'[]'::jsonb,'["Häfele","Osram","Philips"]'::jsonb),
  ('furniture','Consumables','pcs',array['Glue','Silicone','Screws','Fasteners','Packaging materials'],
    '[]'::jsonb,'[]'::jsonb,'[]'::jsonb),
  ('construction','Structural','pcs',array['Cement','Sand','Blocks','Concrete','Reinforcement steel'],
    '[]'::jsonb,'[]'::jsonb,'[]'::jsonb),
  ('construction','Drywall','sheet',array['Gypsum board','Moisture-resistant gypsum board','Cement board','Metal profiles'],
    '["2400×1200 mm","3000×1200 mm"]'::jsonb,'[9.5,12.5,15]'::jsonb,'["Knauf","Gyproc"]'::jsonb),
  ('construction','Finishing','kg',array['Plaster','Putty','Primer','Paint','Waterproofing','Tile adhesive','Grout','Microcement'],
    '[]'::jsonb,'[]'::jsonb,'["Jotun","National Paints","Sika","Mapei","Weber"]'::jsonb),
  ('construction','Floor and wall','m2',array['Tiles','SPC','Vinyl','Parquet','Skirting'],
    '[]'::jsonb,'[]'::jsonb,'[]'::jsonb),
  ('construction','Electrical','pcs',array['Electrical cables','Conduits','Switches','Sockets','Distribution boards','Breakers'],
    '[]'::jsonb,'[]'::jsonb,'["Schneider Electric","Legrand","ABB"]'::jsonb),
  ('construction','Plumbing','pcs',array['Plumbing pipes','Fittings','Sanitary ware'],
    '[]'::jsonb,'[]'::jsonb,'["Geberit","Grohe","RAK Ceramics"]'::jsonb),
  ('construction','MEP','pcs',array['Ventilation materials','AC materials'],
    '[]'::jsonb,'[]'::jsonb,'[]'::jsonb),
  ('construction','General','pcs',array['Glass','Metal','Sealants','Consumables'],
    '[]'::jsonb,'[]'::jsonb,'[]'::jsonb)
), expanded as (
  select category,subcategory,default_unit,unnest(names) as name,dimensions,thicknesses,brands from seed
)
insert into public.material_templates
  (organization_id,code,name,category,subcategory,default_unit,typical_dimensions,typical_thicknesses,suggested_brands,description)
select
  '00000000-0000-0000-0000-000000000001',
  category||'_'||regexp_replace(lower(name),'[^a-z0-9]+','_','g'),
  name,category,subcategory,default_unit,dimensions,thicknesses,brands,
  'Standard '||lower(name)||' template. All fields can be changed after selection.'
from expanded
on conflict (organization_id,code) do update set
  name=excluded.name, category=excluded.category, subcategory=excluded.subcategory,
  default_unit=excluded.default_unit, typical_dimensions=excluded.typical_dimensions,
  typical_thicknesses=excluded.typical_thicknesses, suggested_brands=excluded.suggested_brands;

-- 2. Warehouse movements retain supplier and unit details.
alter table public.stock_movements add column if not exists supplier_id uuid references public.suppliers(id) on delete set null;
alter table public.stock_movements add column if not exists unit text;
alter table public.stock_movements add column if not exists storage_note text;

-- The stock view is the single source of truth for quantity, reserve and valuation.
create or replace view public.warehouse_stock
with (security_invoker = true)
as
with movement_lines as (
  select
    organization_id,
    coalesce(warehouse_id,source_warehouse_id,destination_warehouse_id) as warehouse_id,
    material_id,
    case
      when movement_type in ('receipt','return','inventory') then quantity
      when movement_type in ('issue','writeoff','defect') then -quantity
      else 0
    end as quantity_delta,
    case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end as reserve_delta,
    case when movement_type='receipt' and unit_cost>0 then quantity*unit_cost else 0 end as receipt_value,
    case when movement_type='receipt' and unit_cost>0 then quantity else 0 end as priced_receipt_quantity,
    case when movement_type='receipt' then movement_date end as receipt_at
  from public.stock_movements
  where movement_type<>'transfer' and reversed_at is null
  union all
  select organization_id,source_warehouse_id,material_id,-quantity,0,0,0,null
  from public.stock_movements
  where movement_type='transfer' and reversed_at is null and source_warehouse_id is not null
  union all
  select organization_id,destination_warehouse_id,material_id,quantity,0,0,0,null
  from public.stock_movements
  where movement_type='transfer' and reversed_at is null and destination_warehouse_id is not null
), totals as (
  select organization_id,warehouse_id,material_id,
    coalesce(sum(quantity_delta),0) as quantity_on_hand,
    greatest(0,coalesce(sum(reserve_delta),0)) as reserved,
    case when sum(priced_receipt_quantity)>0 then sum(receipt_value)/sum(priced_receipt_quantity) else 0 end as average_purchase_price,
    max(receipt_at) as last_receipt_at
  from movement_lines
  group by organization_id,warehouse_id,material_id
)
select organization_id,warehouse_id,material_id,quantity_on_hand,reserved,
  average_purchase_price,
  quantity_on_hand*average_purchase_price as inventory_value,
  last_receipt_at
from totals;

-- When reserved material is issued to the same project, release the matching reserve automatically.
create or replace function public.release_reserve_on_issue()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_reserved numeric(14,3);
begin
  if new.movement_type='issue' and new.project_id is not null then
    select greatest(0,coalesce(sum(case when movement_type='reserve' then quantity when movement_type='unreserve' then -quantity else 0 end),0))
    into v_reserved
    from public.stock_movements
    where organization_id=new.organization_id and material_id=new.material_id
      and project_id=new.project_id and reversed_at is null
      and coalesce(warehouse_id,'00000000-0000-0000-0000-000000000000'::uuid)=coalesce(new.warehouse_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and id<>new.id;
    if v_reserved>0 then
      insert into public.stock_movements
        (organization_id,material_id,warehouse_id,project_id,task_id,movement_type,quantity,unit_cost,movement_date,performed_by,notes,reference,unit,supplier_id)
      values
        (new.organization_id,new.material_id,new.warehouse_id,new.project_id,new.task_id,'unreserve',least(v_reserved,new.quantity),new.unit_cost,new.movement_date,new.performed_by,'Automatic reserve release on issue',new.reference,new.unit,new.supplier_id);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists stock_movements_release_reserve on public.stock_movements;
create trigger stock_movements_release_reserve
after insert on public.stock_movements
for each row execute function public.release_reserve_on_issue();

-- 3. Payroll corrections are tied to a month and keep payment metadata.
alter table public.payroll_adjustments add column if not exists period_year integer;
alter table public.payroll_adjustments add column if not exists period_month integer;
alter table public.payroll_adjustments add column if not exists payment_method text;
alter table public.payroll_adjustments add column if not exists modified_by uuid default auth.uid();
alter table public.payroll_adjustments add column if not exists updated_at timestamptz not null default now();

update public.payroll_adjustments
set period_year=extract(year from adjustment_date)::integer,
    period_month=extract(month from adjustment_date)::integer
where period_year is null or period_month is null;

alter table public.payroll_adjustments drop constraint if exists payroll_adjustments_adjustment_type_check;
alter table public.payroll_adjustments add constraint payroll_adjustments_adjustment_type_check
check (adjustment_type in (
  'advance','bonus','penalty','project_payment','overtime','salary_payment',
  'additional_accrual','deduction','correction','other'
));

alter table public.payroll_entries add column if not exists other_accruals numeric(14,2) not null default 0;
alter table public.payroll_entries add column if not exists other_deductions numeric(14,2) not null default 0;

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

  insert into public.payroll_periods (organization_id,period_year,period_month,status,calculated_at)
  values (v_org,p_year,p_month,'draft',now())
  on conflict (organization_id,period_year,period_month)
  do update set calculated_at=now()
  returning id into v_period;

  insert into public.payroll_entries (
    organization_id,payroll_period_id,employee_id,
    base_amount,daily_amount,hourly_amount,overtime_amount,project_amount,
    bonuses,penalties,absence_deduction,advances,other_accruals,other_deductions,
    accrued,paid,balance
  )
  select
    v_org,v_period,e.id,
    case when e.payment_type='monthly' then e.monthly_salary else 0 end,
    case when e.payment_type='daily' then count(distinct t.work_date) filter (where t.status='worked')*e.daily_rate else 0 end,
    case when e.payment_type='hourly' then coalesce(sum(t.regular_hours),0)*e.hourly_rate else 0 end,
    coalesce(sum(t.overtime_hours),0)*e.overtime_rate + coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='overtime' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='project_payment' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='bonus' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='penalty' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce(sum(t.absent_hours),0)*e.hourly_rate,
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='advance' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type in ('additional_accrual','correction','other') and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='deduction' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    0,0,0
  from public.employees e
  left join public.timesheets t on t.employee_id=e.id and extract(year from t.work_date)=p_year and extract(month from t.work_date)=p_month
  where e.organization_id=v_org and e.is_active=true and e.deleted_at is null
  group by e.id
  on conflict (payroll_period_id,employee_id)
  do update set
    base_amount=excluded.base_amount,daily_amount=excluded.daily_amount,hourly_amount=excluded.hourly_amount,
    overtime_amount=excluded.overtime_amount,project_amount=excluded.project_amount,bonuses=excluded.bonuses,
    penalties=excluded.penalties,absence_deduction=excluded.absence_deduction,advances=excluded.advances,
    other_accruals=excluded.other_accruals,other_deductions=excluded.other_deductions,updated_at=now();

  update public.payroll_entries pe
  set
    paid=coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.payroll_entry_id=pe.id),0)
      +coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=pe.employee_id and a.adjustment_type='salary_payment' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    accrued=pe.base_amount+pe.daily_amount+pe.hourly_amount+pe.overtime_amount+pe.project_amount+pe.bonuses+pe.other_accruals-pe.penalties-pe.absence_deduction-pe.other_deductions,
    balance=(pe.base_amount+pe.daily_amount+pe.hourly_amount+pe.overtime_amount+pe.project_amount+pe.bonuses+pe.other_accruals-pe.penalties-pe.absence_deduction-pe.other_deductions)-pe.advances-
      (coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.payroll_entry_id=pe.id),0)+coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=pe.employee_id and a.adjustment_type='salary_payment' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0)),
    updated_at=now()
  where pe.payroll_period_id=v_period;

  return v_period;
end;
$$;

-- 4. Security and audit for the new catalog.
alter table public.material_templates enable row level security;
drop policy if exists material_templates_read on public.material_templates;
create policy material_templates_read on public.material_templates for select to authenticated
using (organization_id=public.current_user_organization_id());
drop policy if exists material_templates_manage on public.material_templates;
create policy material_templates_manage on public.material_templates for all to authenticated
using (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','procurement'))
with check (organization_id=public.current_user_organization_id() and public.current_user_role() in ('owner','admin','procurement'));

drop trigger if exists material_templates_touch_updated_at on public.material_templates;
create trigger material_templates_touch_updated_at before update on public.material_templates
for each row execute function public.touch_updated_at();

drop trigger if exists payroll_adjustments_touch_updated_at on public.payroll_adjustments;
create trigger payroll_adjustments_touch_updated_at before update on public.payroll_adjustments
for each row execute function public.touch_updated_at();

create index if not exists idx_material_templates_category on public.material_templates(organization_id,category,subcategory);
create index if not exists idx_payroll_adjustments_period on public.payroll_adjustments(organization_id,period_year,period_month,employee_id);

grant select,insert,update,delete on public.material_templates to authenticated;
grant execute on function public.calculate_payroll(integer,integer) to authenticated;
