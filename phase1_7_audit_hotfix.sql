-- Space Buro Project Cloud — audit trigger hotfix for Phase 1.7
-- Run this query separately before the Phase 1.7 estimate migration.

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

drop trigger if exists module_records_audit on public.module_records;
create trigger module_records_audit
after insert or update on public.module_records
for each row execute function public.audit_module_change_v17();

drop trigger if exists module_record_lines_audit on public.module_record_lines;
create trigger module_record_lines_audit
after insert or update or delete on public.module_record_lines
for each row execute function public.audit_module_change_v17();

select 'Phase 1.7 audit trigger hotfix completed successfully' as result;
