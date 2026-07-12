-- Space Buro Project Cloud — Phase 1.7 estimate builder
-- Additive migration. Reuses the existing rate catalog and BOQ line tables.

-- Phase 1.3 used a CASE expression against two different trigger row shapes.
-- PostgreSQL validates both record-field references, so module_records inserts
-- could incorrectly try to read NEW.record_id. Branch before reading fields.
create or replace function public.audit_module_change_v17()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_record uuid;
  v_org uuid;
  v_line uuid;
  v_old jsonb;
  v_new jsonb;
begin
  if tg_table_name='module_records' then
    if tg_op='DELETE' then
      v_record:=old.id;
      v_org:=old.organization_id;
    else
      v_record:=new.id;
      v_org:=new.organization_id;
    end if;
    v_line:=null;
  elsif tg_table_name='module_record_lines' then
    if tg_op='DELETE' then
      v_record:=old.record_id;
      v_org:=old.organization_id;
      v_line:=old.id;
    else
      v_record:=new.record_id;
      v_org:=new.organization_id;
      v_line:=new.id;
    end if;
  else
    raise exception 'Unsupported audit table: %',tg_table_name;
  end if;

  if tg_op in ('UPDATE','DELETE') then v_old:=to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then v_new:=to_jsonb(new); end if;

  insert into public.module_history(
    organization_id,record_id,line_id,action,old_data,new_data,actor_id
  ) values (
    v_org,v_record,v_line,lower(tg_op),v_old,v_new,auth.uid()
  );

  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

-- Rewire both triggers explicitly. A new function name avoids any stale cached
-- trigger plan that may still reference the Phase 1.3 implementation.
drop trigger if exists module_records_audit on public.module_records;
create trigger module_records_audit
after insert or update on public.module_records
for each row execute function public.audit_module_change_v17();

drop trigger if exists module_record_lines_audit on public.module_record_lines;
create trigger module_record_lines_audit
after insert or update or delete on public.module_record_lines
for each row execute function public.audit_module_change_v17();

create or replace function public.sync_estimate_execution(p_estimate_id uuid)
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
  v_task uuid;
  v_parent_task uuid;
  v_schedule_line uuid;
  v_schedule_parent uuid;
  v_task_count integer:=0;
begin
  if public.current_user_role() not in ('owner','admin','accountant','project_manager','procurement') then
    raise exception 'Not allowed to synchronize estimate execution';
  end if;

  select * into e from public.module_records
  where id=p_estimate_id and organization_id=v_org and module_code='estimates' and deleted_at is null;

  if e.id is null then raise exception 'Estimate not found'; end if;
  if e.status not in ('agreed','approved') then raise exception 'Approve the estimate before synchronization'; end if;

  select id into v_schedule from public.module_records
  where organization_id=v_org and module_code='work_schedule' and source_record_id=e.id and deleted_at is null
  order by created_at limit 1;

  if v_schedule is null then
    raise exception 'Run activate_estimate_workflow before synchronization';
  end if;

  select id into v_procurement from public.module_records
  where organization_id=v_org and module_code='procurement' and source_record_id=e.id and deleted_at is null
  order by created_at limit 1;

  -- Parent rows are processed first by sort order. Work and subwork rows become tasks.
  for l in
    select * from public.module_record_lines
    where record_id=e.id and line_type in ('section','subsection','work','subwork','task','milestone')
    order by sort_order,created_at,id
  loop
    v_task:=l.linked_task_id;
    v_parent_task:=null;
    if l.parent_line_id is not null then
      select linked_task_id into v_parent_task from public.module_record_lines where id=l.parent_line_id;
    end if;

    if l.line_type in ('work','subwork','task') then
      if v_task is null then
        insert into public.tasks(
          organization_id,project_id,parent_id,title,description,assignee_id,start_date,due_date,
          priority,status,progress,cost,requires_verification,created_by
        ) values (
          v_org,e.project_id,v_parent_task,l.name,l.description,l.responsible_id,l.planned_start,l.planned_finish,
          case when e.priority in ('low','normal','high','critical') then e.priority else 'normal' end,
          case when l.progress>=100 then 'completed' else 'new' end,
          greatest(0,least(100,round(l.progress)::integer)),l.quantity*l.unit_cost,true,auth.uid()
        ) returning id into v_task;
      else
        update public.tasks set
          project_id=e.project_id,parent_id=v_parent_task,title=l.name,description=l.description,
          assignee_id=l.responsible_id,start_date=l.planned_start,due_date=l.planned_finish,
          progress=greatest(0,least(100,round(l.progress)::integer)),cost=l.quantity*l.unit_cost,
          requires_verification=true,updated_at=now()
        where id=v_task and organization_id=v_org;
      end if;
      update public.module_record_lines set linked_task_id=v_task,updated_at=now() where id=l.id;
      v_task_count:=v_task_count+1;
    end if;

    v_schedule_parent:=null;
    if l.parent_line_id is not null then
      select id into v_schedule_parent from public.module_record_lines
      where record_id=v_schedule and data->>'source_estimate_line_id'=l.parent_line_id::text
      order by created_at limit 1;
    end if;

    select id into v_schedule_line from public.module_record_lines
    where record_id=v_schedule and data->>'source_estimate_line_id'=l.id::text
    order by created_at limit 1;

    if v_schedule_line is null then
      insert into public.module_record_lines(
        organization_id,record_id,parent_line_id,line_type,code,name,description,material_id,linked_task_id,
        quantity,unit,unit_cost,unit_sale,planned_amount,planned_start,planned_finish,progress,status,
        responsible_id,sort_order,data
      ) values (
        v_org,v_schedule,v_schedule_parent,l.line_type,l.code,l.name,l.description,l.material_id,v_task,
        l.quantity,l.unit,l.unit_cost,l.unit_sale,l.quantity*l.unit_sale,l.planned_start,l.planned_finish,
        l.progress,'active',l.responsible_id,l.sort_order,
        jsonb_build_object('source_estimate_line_id',l.id,'source_parent_line_id',l.parent_line_id,'synced_by','phase1_7')
      ) returning id into v_schedule_line;
    else
      update public.module_record_lines set
        parent_line_id=v_schedule_parent,line_type=l.line_type,code=l.code,name=l.name,description=l.description,
        material_id=l.material_id,linked_task_id=v_task,quantity=l.quantity,unit=l.unit,unit_cost=l.unit_cost,
        unit_sale=l.unit_sale,planned_amount=l.quantity*l.unit_sale,planned_start=l.planned_start,
        planned_finish=l.planned_finish,progress=l.progress,status='active',responsible_id=l.responsible_id,
        sort_order=l.sort_order,data=data||jsonb_build_object('synced_by','phase1_7'),updated_at=now()
      where id=v_schedule_line;
    end if;
  end loop;

  -- Materials inherit the task of their parent work and remain linked to procurement.
  for l in
    select * from public.module_record_lines
    where record_id=e.id and line_type='material'
    order by sort_order,created_at,id
  loop
    v_parent_task:=null;
    if l.parent_line_id is not null then
      select linked_task_id into v_parent_task from public.module_record_lines where id=l.parent_line_id;
    end if;
    update public.module_record_lines set linked_task_id=v_parent_task,updated_at=now() where id=l.id;
    if v_procurement is not null then
      update public.module_record_lines set linked_task_id=v_parent_task,updated_at=now()
      where record_id=v_procurement and data->>'source_estimate_line_id'=l.id::text;
    end if;
  end loop;

  update public.module_records set
    progress=coalesce((select avg(progress) from public.module_record_lines
      where record_id=v_schedule and line_type in ('work','subwork','task')),0),
    data=data||jsonb_build_object('last_estimate_sync_at',now(),'estimate_id',e.id),updated_at=now()
  where id=v_schedule;

  update public.module_records set
    data=data||jsonb_build_object('execution_synced_at',now(),'task_count',v_task_count),updated_at=now()
  where id=e.id;

  return jsonb_build_object('estimate_id',e.id,'schedule_id',v_schedule,'procurement_id',v_procurement,'task_count',v_task_count);
end;
$$;

grant execute on function public.sync_estimate_execution(uuid) to authenticated;

-- Starter library. Prices intentionally remain editable because company rates and
-- Dubai supplier prices vary; user data is never overwritten on repeated runs.
insert into public.module_records(
  organization_id,module_code,record_type,record_number,name,status,currency,data
)
select o.id,'rate_catalog','work_category','WLIB-CAT-'||v.code,v.name,'active','AED',
  jsonb_build_object('unit','item','description',v.description,'starter_library',true)
from public.organizations o
cross join (values
  ('DEMOLITION','Demolition','Removal and dismantling works'),
  ('MASONRY','Masonry & Plaster','Blockwork, plaster and screed'),
  ('GYPSUM','Gypsum & Ceiling','Partitions, linings and ceilings'),
  ('TILING','Tiling & Stone','Waterproofing, tiles, stone and grout'),
  ('PAINTING','Painting','Surface preparation and paint systems'),
  ('ELECTRICAL','Electrical','Cables, sockets, lighting and panels'),
  ('PLUMBING','Plumbing','Pipework and sanitary installation'),
  ('HVAC','HVAC & Ventilation','Air conditioning and ventilation'),
  ('JOINERY','Joinery & Furniture','Kitchens, wardrobes, panels and doors'),
  ('INSTALLATION','Installation & Handover','Installation, testing and handover')
) v(code,name,description)
on conflict(organization_id,module_code,record_number) do nothing;

insert into public.module_records(
  organization_id,module_code,record_type,record_number,name,parent_id,status,currency,
  cost_amount,sale_amount,data
)
select o.id,'rate_catalog','work_type','WLIB-WORK-'||v.code,v.name,c.id,'active','AED',0,0,
  jsonb_build_object('unit',v.unit,'description',v.description,'default_duration_days',1,'task_required',true,'starter_library',true)
from public.organizations o
join (values
  ('DEMOLITION','DEMOLITION','General demolition','m2','Removal of existing finishes and elements'),
  ('MASONRY','BLOCKWORK','Block wall construction','m2','Blockwork including alignment and preparation'),
  ('MASONRY','PLASTER','Wall plastering','m2','Internal plaster system'),
  ('GYPSUM','PARTITION','Gypsum partition','m2','Metal frame gypsum partition'),
  ('GYPSUM','CEILING','Gypsum ceiling','m2','Suspended gypsum ceiling'),
  ('TILING','FLOOR_TILE','Floor tiling','m2','Floor tile installation system'),
  ('TILING','WALL_TILE','Wall tiling','m2','Wall tile installation system'),
  ('PAINTING','WALL_PAINT','Wall painting','m2','Primer, putty and finish coats'),
  ('ELECTRICAL','SOCKETS','Sockets and switches','pcs','Electrical point installation'),
  ('ELECTRICAL','LIGHTING','Lighting installation','pcs','Lighting point and fixture installation'),
  ('PLUMBING','PIPEWORK','Water and drainage pipework','lm','Plumbing pipe installation'),
  ('PLUMBING','SANITARY','Sanitary fixture installation','pcs','Installation and connection of sanitary ware'),
  ('HVAC','AC_UNIT','AC unit installation','pcs','Air conditioning installation and testing'),
  ('JOINERY','KITCHEN','Kitchen cabinetry','lm','Kitchen cabinets production and installation'),
  ('JOINERY','WARDROBE','Wardrobe','m2','Wardrobe production and installation'),
  ('JOINERY','WALL_PANEL','Decorative wall panels','m2','Wall panel production and installation'),
  ('JOINERY','DOOR','Internal door','pcs','Door production and installation'),
  ('INSTALLATION','FINAL_INSTALL','Final installation and handover','lot','Final fixing, testing and handover')
) v(category_code,code,name,unit,description) on true
join public.module_records c on c.organization_id=o.id and c.module_code='rate_catalog'
  and c.record_number='WLIB-CAT-'||v.category_code and c.deleted_at is null
on conflict(organization_id,module_code,record_number) do nothing;

insert into public.module_records(
  organization_id,module_code,record_type,record_number,name,parent_id,status,currency,
  cost_amount,sale_amount,data
)
select o.id,'rate_catalog','subwork','WLIB-SUB-'||v.code,v.name,w.id,'active','AED',0,0,
  jsonb_build_object('unit',v.unit,'description',v.description,'default_duration_days',1,'task_required',true,'starter_library',true)
from public.organizations o
join (values
  ('DEMOLITION','PROTECTION','Site protection','m2','Protection before demolition'),
  ('DEMOLITION','REMOVE_FINISH','Remove existing finishes','m2','Removal and disposal preparation'),
  ('FLOOR_TILE','TILE_PREP','Surface preparation','m2','Cleaning, levelling and primer'),
  ('FLOOR_TILE','WATERPROOF','Waterproofing','m2','Waterproofing system where required'),
  ('FLOOR_TILE','TILE_LAY','Tile laying','m2','Adhesive, laying and alignment'),
  ('FLOOR_TILE','GROUT','Grouting and silicone','m2','Final grout and sealant'),
  ('WALL_PAINT','PAINT_PREP','Surface preparation','m2','Repair, sanding and cleaning'),
  ('WALL_PAINT','PRIMER','Primer coat','m2','Primer application'),
  ('WALL_PAINT','FINISH_COATS','Finish paint coats','m2','Two finish coats'),
  ('SOCKETS','CABLE_ROUTE','Cable routing','lm','Cable, conduit and accessories'),
  ('SOCKETS','ACCESSORY_FIX','Socket / switch fixing','pcs','Installation and testing'),
  ('KITCHEN','KITCHEN_CARCASS','Cabinet carcass','lm','Carcass production'),
  ('KITCHEN','KITCHEN_FRONTS','Doors and fronts','m2','Front production and finish'),
  ('KITCHEN','KITCHEN_HARDWARE','Hardware installation','set','Hinges, runners and accessories'),
  ('KITCHEN','KITCHEN_INSTALL','Kitchen installation','lm','Delivery, installation and adjustment'),
  ('WARDROBE','WARDROBE_CARCASS','Wardrobe carcass','m2','Carcass production'),
  ('WARDROBE','WARDROBE_FRONTS','Wardrobe fronts','m2','Doors, profiles and finish'),
  ('WARDROBE','WARDROBE_INSTALL','Wardrobe installation','m2','Delivery and installation')
) v(work_code,code,name,unit,description) on true
join public.module_records w on w.organization_id=o.id and w.module_code='rate_catalog'
  and w.record_number='WLIB-WORK-'||v.work_code and w.deleted_at is null
on conflict(organization_id,module_code,record_number) do nothing;

select 'Phase 1.7 estimate builder migration completed successfully' as result;
