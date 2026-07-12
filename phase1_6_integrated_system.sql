-- Space Buro Project Cloud — Phase 1.6 integrated operating system
-- Additive migration. Existing records and historic calculations are preserved.

create extension if not exists "pgcrypto";

alter table public.warehouse_locations
  add column if not exists business_area text not null default 'construction';

alter table public.warehouse_locations
  drop constraint if exists warehouse_locations_business_area_check;
alter table public.warehouse_locations
  add constraint warehouse_locations_business_area_check
  check (business_area in ('construction','furniture','shared'));

update public.warehouse_locations
set business_area=case
  when lower(name) like '%меб%' or lower(name) like '%furniture%' then 'furniture'
  when warehouse_type in ('furniture','finished_goods','production') then 'furniture'
  else coalesce(nullif(business_area,''),'construction')
end;

alter table public.design_compensations add column if not exists approval_status text not null default 'draft';
alter table public.design_compensations add column if not exists paid_amount numeric(14,2) not null default 0;
alter table public.design_compensations add column if not exists payment_date date;
alter table public.design_compensations add column if not exists payment_method text;
alter table public.design_compensations add column if not exists actual_days numeric(10,2) not null default 0;
alter table public.design_compensations add column if not exists revision_count integer not null default 0;
alter table public.design_compensations add column if not exists drawing_links jsonb not null default '[]'::jsonb;
alter table public.design_compensations add column if not exists payroll_adjustment_id uuid references public.payroll_adjustments(id) on delete set null;

create table if not exists public.estimate_payment_milestones (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  estimate_id uuid not null references public.module_records(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  installment_no integer not null check (installment_no between 1 and 20),
  milestone_name text not null,
  percent numeric(7,3) not null default 0 check (percent between 0 and 100),
  amount numeric(14,2) not null default 0,
  due_date date,
  status text not null default 'expected',
  paid_amount numeric(14,2) not null default 0,
  paid_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (estimate_id,installment_no)
);

create table if not exists public.estimate_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  estimate_id uuid not null references public.module_records(id) on delete cascade,
  version_no integer not null,
  status text not null default 'draft',
  snapshot jsonb not null default '{}'::jsonb,
  change_reason text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (estimate_id,version_no)
);

alter table public.estimate_payment_milestones enable row level security;
alter table public.estimate_versions enable row level security;

drop policy if exists estimate_payment_milestones_access on public.estimate_payment_milestones;
create policy estimate_payment_milestones_access on public.estimate_payment_milestones
for all to authenticated
using (organization_id=public.current_user_organization_id())
with check (organization_id=public.current_user_organization_id());

drop policy if exists estimate_versions_access on public.estimate_versions;
create policy estimate_versions_access on public.estimate_versions
for all to authenticated
using (organization_id=public.current_user_organization_id())
with check (organization_id=public.current_user_organization_id());

create or replace function public.create_management_snapshot(p_snapshot_type text default 'pnl')
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid:=public.current_user_organization_id();
  v_id uuid;
  v_income numeric(14,2);
  v_expenses numeric(14,2);
  v_payroll numeric(14,2);
  v_receivable numeric(14,2);
begin
  if public.current_user_role() not in ('owner','admin','accountant') then
    raise exception 'Not allowed to create management snapshots';
  end if;
  select coalesce(sum(amount),0) into v_income from public.payments
    where organization_id=v_org and direction='income' and status='paid';
  select coalesce(sum(actual_amount),0) into v_expenses from public.expenses
    where organization_id=v_org and deleted_at is null and archived_at is null;
  select coalesce(sum(accrued),0) into v_payroll from public.payroll_entries pe
    join public.payroll_periods pp on pp.id=pe.payroll_period_id
    where pe.organization_id=v_org
      and pp.period_year=extract(year from current_date)::integer
      and pp.period_month=extract(month from current_date)::integer;
  select coalesce(sum(amount),0) into v_receivable from public.payments
    where organization_id=v_org and direction='income' and status<>'paid';
  insert into public.module_records(
    organization_id,module_code,record_type,record_number,name,status,
    planned_amount,actual_amount,data,approved_at,approved_by
  ) values (
    v_org,'management_reports',coalesce(nullif(p_snapshot_type,''),'pnl'),
    'RPT-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)),
    'Management snapshot · '||to_char(now(),'YYYY-MM-DD HH24:MI'),'approved',
    v_income,v_expenses+v_payroll,
    jsonb_build_object(
      'snapshot_date',now(),'income',v_income,'direct_and_operating_expenses',v_expenses,
      'payroll',v_payroll,'gross_operating_result',v_income-v_expenses-v_payroll,
      'receivables',v_receivable,'source','phase1_6_snapshot'
    ),now(),auth.uid()
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.activate_estimate_workflow(p_estimate_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid:=public.current_user_organization_id();
  e public.module_records%rowtype;
  l public.module_record_lines%rowtype;
  v_schedule uuid;
  v_procurement uuid;
  v_finance uuid;
  v_task uuid;
  v_schedule_line uuid;
  v_pct numeric;
  v_sale numeric(14,2);
begin
  if public.current_user_role() not in ('owner','admin','accountant','project_manager','procurement') then
    raise exception 'Not allowed to activate an estimate';
  end if;
  select * into e from public.module_records
    where id=p_estimate_id and organization_id=v_org and module_code='estimates' and deleted_at is null;
  if e.id is null then raise exception 'Estimate not found'; end if;
  if e.status not in ('agreed','approved') then raise exception 'Approve the estimate before activation'; end if;
  v_sale:=coalesce(nullif(e.sale_amount,0),e.planned_amount,0);

  select id into v_schedule from public.module_records
    where organization_id=v_org and module_code='work_schedule' and source_record_id=e.id and deleted_at is null limit 1;
  if v_schedule is null then
    insert into public.module_records(organization_id,module_code,record_type,record_number,name,project_id,client_id,
      source_record_id,status,currency,planned_amount,cost_amount,sale_amount,planned_start,planned_finish,responsible_id,data)
    values(v_org,'work_schedule','schedule','SCH-'||extract(year from current_date)::integer||'-'||upper(substr(replace(e.id::text,'-',''),1,8)),
      e.name||' · Work schedule',e.project_id,e.client_id,e.id,'active',e.currency,e.planned_amount,e.cost_amount,e.sale_amount,
      e.planned_start,e.planned_finish,e.responsible_id,jsonb_build_object('generated_from_estimate',e.id,'automation_version','1.6'))
    returning id into v_schedule;
  else
    update public.module_records set name=e.name||' · Work schedule',project_id=e.project_id,client_id=e.client_id,
      planned_amount=e.planned_amount,cost_amount=e.cost_amount,sale_amount=e.sale_amount,
      planned_start=e.planned_start,planned_finish=e.planned_finish,updated_at=now() where id=v_schedule;
    delete from public.module_record_lines where record_id=v_schedule and data ? 'source_estimate_line_id';
  end if;

  select id into v_procurement from public.module_records
    where organization_id=v_org and module_code='procurement' and source_record_id=e.id and deleted_at is null limit 1;
  if v_procurement is null then
    insert into public.module_records(organization_id,module_code,record_type,record_number,name,project_id,client_id,
      source_record_id,status,currency,planned_amount,planned_start,planned_finish,responsible_id,data)
    values(v_org,'procurement','request','PR-'||extract(year from current_date)::integer||'-'||upper(substr(replace(e.id::text,'-',''),1,8)),
      e.name||' · Material request',e.project_id,e.client_id,e.id,'submitted',e.currency,e.cost_amount,
      e.planned_start,e.planned_finish,e.responsible_id,jsonb_build_object('generated_from_estimate',e.id,'warehouse_check_required',true))
    returning id into v_procurement;
  else
    delete from public.module_record_lines where record_id=v_procurement and data ? 'source_estimate_line_id';
  end if;

  select id into v_finance from public.module_records
    where organization_id=v_org and module_code='financial_accounting' and source_record_id=e.id and deleted_at is null limit 1;
  if v_finance is null then
    insert into public.module_records(organization_id,module_code,record_type,record_number,name,project_id,client_id,
      source_record_id,status,currency,planned_amount,cost_amount,sale_amount,planned_start,planned_finish,responsible_id,data)
    values(v_org,'financial_accounting','project_budget','FIN-'||extract(year from current_date)::integer||'-'||upper(substr(replace(e.id::text,'-',''),1,8)),
      e.name||' · Project financial plan',e.project_id,e.client_id,e.id,'active',e.currency,v_sale,e.cost_amount,v_sale,
      e.planned_start,e.planned_finish,e.responsible_id,
      jsonb_build_object('generated_from_estimate',e.id,'allocations',coalesce(e.data->'allocations','{}'::jsonb),
        'payment_plan',coalesce(e.data->'payment_plan','{}'::jsonb)))
    returning id into v_finance;
  else
    update public.module_records set planned_amount=v_sale,cost_amount=e.cost_amount,sale_amount=v_sale,
      data=data||jsonb_build_object('allocations',coalesce(e.data->'allocations','{}'::jsonb),
      'payment_plan',coalesce(e.data->'payment_plan','{}'::jsonb)),updated_at=now() where id=v_finance;
  end if;

  for l in select * from public.module_record_lines where record_id=e.id order by sort_order,id loop
    if l.line_type in ('section','subsection','work','task','milestone') then
      v_task:=l.linked_task_id;
      if l.line_type in ('work','task') and v_task is null then
        insert into public.tasks(organization_id,project_id,title,description,assignee_id,start_date,due_date,priority,status,
          progress,cost,requires_verification,created_by)
        values(v_org,e.project_id,l.name,l.description,l.responsible_id,l.planned_start,l.planned_finish,
          case when e.priority in ('low','normal','high','critical') then e.priority else 'normal' end,
          'new',round(l.progress)::integer,l.quantity*l.unit_cost,true,auth.uid()) returning id into v_task;
        update public.module_record_lines set linked_task_id=v_task,updated_at=now() where id=l.id;
      end if;
      insert into public.module_record_lines(organization_id,record_id,line_type,code,name,description,material_id,
        linked_task_id,quantity,unit,unit_cost,unit_sale,planned_amount,planned_start,planned_finish,progress,status,
        responsible_id,sort_order,data)
      values(v_org,v_schedule,l.line_type,l.code,l.name,l.description,l.material_id,v_task,l.quantity,l.unit,l.unit_cost,l.unit_sale,
        l.quantity*l.unit_sale,l.planned_start,l.planned_finish,l.progress,'active',l.responsible_id,l.sort_order,
        jsonb_build_object('source_estimate_line_id',l.id,'source_parent_line_id',l.parent_line_id))
      returning id into v_schedule_line;
    end if;
    if l.line_type='material' or l.material_id is not null then
      insert into public.module_record_lines(organization_id,record_id,line_type,code,name,description,material_id,
        quantity,unit,unit_cost,unit_sale,planned_amount,planned_start,planned_finish,status,responsible_id,sort_order,data)
      values(v_org,v_procurement,'material',l.code,l.name,l.description,l.material_id,l.quantity,l.unit,l.unit_cost,l.unit_sale,
        l.quantity*l.unit_cost,l.planned_start,l.planned_finish,'submitted',l.responsible_id,l.sort_order,
        jsonb_build_object('source_estimate_line_id',l.id,'requires_stock_check',true));
      if l.material_id is not null and nullif(l.data->>'warehouse_id','') is not null then
        insert into public.stock_reservations(organization_id,material_id,warehouse_id,project_id,source_line_id,quantity,
          planned_issue_date,status,responsible_id,notes)
        select v_org,l.material_id,(l.data->>'warehouse_id')::uuid,e.project_id,l.id,l.quantity,l.planned_start,'active',
          l.responsible_id,'Automatically created from approved estimate'
        where not exists (
          select 1 from public.stock_reservations sr
          where sr.organization_id=v_org and sr.source_line_id=l.id and sr.status in ('active','partially_used')
        );
      end if;
    end if;
  end loop;

  insert into public.estimate_payment_milestones(organization_id,estimate_id,project_id,installment_no,milestone_name,percent,amount,status)
  select v_org,e.id,e.project_id,n,'Payment '||n,pct,round(v_sale*pct/100,2),'expected'
  from (values
    (1,coalesce(nullif((e.data#>>'{payment_plan,payment_1_percent}')::numeric,0),0)),
    (2,coalesce(nullif((e.data#>>'{payment_plan,payment_2_percent}')::numeric,0),0)),
    (3,coalesce(nullif((e.data#>>'{payment_plan,payment_3_percent}')::numeric,0),0)),
    (4,coalesce(nullif((e.data#>>'{payment_plan,payment_4_percent}')::numeric,0),0))
  ) p(n,pct) where pct>0
  on conflict(estimate_id,installment_no) do update set percent=excluded.percent,amount=excluded.amount,updated_at=now();

  insert into public.module_relations(organization_id,source_record_id,target_record_id,relation_type)
  select v_org,e.id,x.target_id,x.relation_type
  from (values (v_schedule,'estimate_to_schedule'),(v_procurement,'estimate_to_procurement'),
               (v_finance,'estimate_to_finance')) x(target_id,relation_type)
  where not exists (
    select 1 from public.module_relations mr
    where mr.organization_id=v_org and mr.source_record_id=e.id
      and mr.target_record_id=x.target_id and mr.relation_type=x.relation_type
  );

  if e.project_id is not null then
    update public.projects set planned_expenses=e.cost_amount,planned_profit=v_sale-e.cost_amount,updated_at=now()
      where id=e.project_id and organization_id=v_org;
  end if;
  update public.module_records set data=data||jsonb_build_object('workflow_activated_at',now(),
    'schedule_id',v_schedule,'procurement_id',v_procurement,'finance_id',v_finance),updated_at=now() where id=e.id;

  return jsonb_build_object('estimate_id',e.id,'schedule_id',v_schedule,'procurement_id',v_procurement,'finance_id',v_finance);
end;
$$;

grant select,insert,update,delete on public.estimate_payment_milestones,public.estimate_versions to authenticated;
grant execute on function public.create_management_snapshot(text) to authenticated;
grant execute on function public.activate_estimate_workflow(uuid) to authenticated;

create index if not exists idx_estimate_milestones_estimate on public.estimate_payment_milestones(estimate_id,installment_no);
create index if not exists idx_estimate_versions_estimate on public.estimate_versions(estimate_id,version_no desc);

select 'Phase 1.6 integrated system migration completed successfully' as result;
