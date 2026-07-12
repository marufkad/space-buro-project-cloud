-- Space Buro Project Cloud — Phase 1.4
-- Navigation support, material libraries, suppliers, attendance payroll,
-- designer/drafter project compensation and advanced Gantt relations.
-- Additive migration: no project, payroll, material or employee data is removed.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- 1. Material category → subcategory → material → brand → supplier libraries.
-- ---------------------------------------------------------------------------

create table if not exists public.material_subcategories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  category_id uuid not null references public.material_categories(id) on delete cascade,
  code text not null,
  name jsonb not null default '{}'::jsonb,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,category_id,code)
);

alter table public.materials add column if not exists subcategory_id uuid references public.material_subcategories(id) on delete set null;

alter table public.suppliers add column if not exists supplier_type text not null default 'material_supplier';
alter table public.suppliers add column if not exists material_categories jsonb not null default '[]'::jsonb;
alter table public.suppliers add column if not exists brands jsonb not null default '[]'::jsonb;
alter table public.suppliers add column if not exists payment_terms text;
alter table public.suppliers add column if not exists delivery_terms text;
alter table public.suppliers add column if not exists lead_time_days integer not null default 0;
alter table public.suppliers add column if not exists currency text not null default 'AED';
alter table public.suppliers add column if not exists trade_license text;
alter table public.suppliers add column if not exists documents jsonb not null default '[]'::jsonb;

create table if not exists public.supplier_materials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete cascade,
  supplier_sku text,
  unit text not null default 'pcs',
  unit_price numeric(14,2) not null default 0,
  currency text not null default 'AED',
  minimum_order_quantity numeric(14,3) not null default 0,
  lead_time_days integer not null default 0,
  valid_from date,
  valid_until date,
  is_preferred boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (supplier_id,material_id,supplier_sku)
);

with seed(category_code,subcategory_code,name_ru,name_en,sort_order) as (
  values
  ('furniture','panels','Панели и плитные материалы','Panels and boards',10),
  ('furniture','surfaces','Фасады и декоративные поверхности','Facades and decorative surfaces',20),
  ('furniture','edges','Кромки и профили','Edges and profiles',30),
  ('furniture','wood','Массив дерева и шпон','Solid wood and veneer',40),
  ('furniture','glass_mirror','Стекло и зеркало для мебели','Furniture glass and mirror',50),
  ('furniture','stone_ceramic','Камень и керамика для мебели','Furniture stone and ceramic',60),
  ('furniture','upholstery','Мягкая мебель и ткани','Upholstery and fabrics',70),
  ('furniture','furniture_hardware','Мебельная фурнитура','Furniture hardware',80),
  ('furniture','furniture_lighting','Мебельное освещение','Furniture lighting',90),
  ('furniture','furniture_consumables','Мебельные расходники','Furniture consumables',100),
  ('construction','structural','Цемент, бетон, блоки и арматура','Structural materials',10),
  ('construction','drywall','Гипсокартон и профили','Drywall and profiles',20),
  ('construction','masonry','Кладочные и штукатурные материалы','Masonry and plastering',30),
  ('construction','roof_facade','Кровля и фасад','Roofing and facade',40),
  ('construction','general_construction','Общестроительные материалы','General construction materials',50),
  ('electrical','cables','Кабели и провода','Cables and wires',10),
  ('electrical','protection','Автоматы и распределительные щиты','Protection and distribution boards',20),
  ('electrical','switches_sockets','Розетки и выключатели','Switches and sockets',30),
  ('electrical','low_voltage','Слаботочные системы','Low voltage systems',40),
  ('plumbing','pipes','Трубы','Pipes',10),
  ('plumbing','fittings','Фитинги и соединения','Fittings and connections',20),
  ('plumbing','sanitary','Сантехника и смесители','Sanitary ware and mixers',30),
  ('plumbing','pumps_tanks','Насосы и резервуары','Pumps and tanks',40),
  ('finishing','paint','Грунтовка, шпаклёвка и краска','Primer, putty and paint',10),
  ('finishing','tiles','Плитка, клей и затирка','Tiles, adhesive and grout',20),
  ('finishing','flooring','SPC, паркет и напольные покрытия','Floor coverings',30),
  ('finishing','waterproofing','Гидроизоляция','Waterproofing',40),
  ('finishing','microcement','Микроцемент','Microcement',50),
  ('glass','glass','Стекло','Glass',10),
  ('glass','mirror','Зеркало','Mirror',20),
  ('glass','glass_hardware','Профили и фурнитура для стекла','Glass profiles and hardware',30),
  ('metal','stainless','Нержавеющая сталь','Stainless steel',10),
  ('metal','mild_steel','Чёрный металл','Mild steel',20),
  ('metal','aluminium','Алюминий','Aluminium',30),
  ('metal','metal_profiles','Металлические профили','Metal profiles',40),
  ('stone','quartz','Кварц','Quartz',10),
  ('stone','porcelain','Керамогранит','Porcelain',20),
  ('stone','natural_stone','Натуральный камень','Natural stone',30),
  ('stone','artificial_stone','Искусственный камень','Artificial stone',40),
  ('hardware','hinges','Петли','Hinges',10),
  ('hardware','drawer_systems','Направляющие и системы ящиков','Drawer systems',20),
  ('hardware','handles_profiles','Ручки и профили','Handles and profiles',30),
  ('hardware','fasteners','Крепёж','Fasteners',40),
  ('lighting','led','LED-ленты и светильники','LED and luminaires',10),
  ('lighting','drivers','Трансформаторы и драйверы','Drivers and transformers',20),
  ('lighting','sensors','Датчики и управление','Sensors and controls',30),
  ('lighting','lighting_profiles','Профили для освещения','Lighting profiles',40),
  ('consumables','adhesives','Клей и силикон','Adhesives and silicone',10),
  ('consumables','abrasives','Абразивы','Abrasives',20),
  ('consumables','chemicals','Химические материалы','Chemicals',30),
  ('consumables','general_consumables','Общие расходники','General consumables',40),
  ('tools','power_tools','Электроинструмент','Power tools',10),
  ('tools','hand_tools','Ручной инструмент','Hand tools',20),
  ('tools','measuring_tools','Измерительное оборудование','Measuring tools',30),
  ('tools','safety_equipment','Средства защиты','Safety equipment',40),
  ('packaging','boxes','Коробки и картон','Boxes and cardboard',10),
  ('packaging','film_foam','Плёнка и защитная пена','Film and protective foam',20),
  ('packaging','labels','Этикетки и маркировка','Labels and marking',30)
)
insert into public.material_subcategories(organization_id,category_id,code,name,sort_order)
select '00000000-0000-0000-0000-000000000001',c.id,s.subcategory_code,
  jsonb_build_object('ru',s.name_ru,'en',s.name_en),s.sort_order
from seed s join public.material_categories c
  on c.organization_id='00000000-0000-0000-0000-000000000001' and c.code=s.category_code
on conflict(organization_id,category_id,code) do update set name=excluded.name,sort_order=excluded.sort_order;

insert into public.material_brands(organization_id,name,website_url)
values
('00000000-0000-0000-0000-000000000001','Egger','https://www.egger.com'),
('00000000-0000-0000-0000-000000000001','Blum','https://www.blum.com'),
('00000000-0000-0000-0000-000000000001','Hettich','https://www.hettich.com'),
('00000000-0000-0000-0000-000000000001','Häfele','https://www.hafele.com'),
('00000000-0000-0000-0000-000000000001','Grass','https://www.grass.eu'),
('00000000-0000-0000-0000-000000000001','Kronospan','https://www.kronospan.com'),
('00000000-0000-0000-0000-000000000001','Finsa','https://www.finsa.com'),
('00000000-0000-0000-0000-000000000001','Alvic','https://www.alvic.com'),
('00000000-0000-0000-0000-000000000001','Formica','https://www.formica.com'),
('00000000-0000-0000-0000-000000000001','Fenix','https://www.fenixforinteriors.com'),
('00000000-0000-0000-0000-000000000001','Rehau','https://www.rehau.com'),
('00000000-0000-0000-0000-000000000001','Knauf','https://www.knauf.com'),
('00000000-0000-0000-0000-000000000001','Gyproc','https://www.gyproc.ae'),
('00000000-0000-0000-0000-000000000001','Jotun','https://www.jotun.com'),
('00000000-0000-0000-0000-000000000001','National Paints','https://www.national-paints.com'),
('00000000-0000-0000-0000-000000000001','Sika','https://www.sika.com'),
('00000000-0000-0000-0000-000000000001','Mapei','https://www.mapei.com'),
('00000000-0000-0000-0000-000000000001','Weber','https://www.middleeast.weber'),
('00000000-0000-0000-0000-000000000001','Schneider Electric','https://www.se.com'),
('00000000-0000-0000-0000-000000000001','Legrand','https://www.legrand.com'),
('00000000-0000-0000-0000-000000000001','ABB','https://global.abb'),
('00000000-0000-0000-0000-000000000001','Geberit','https://www.geberit.com'),
('00000000-0000-0000-0000-000000000001','Grohe','https://www.grohe.com'),
('00000000-0000-0000-0000-000000000001','RAK Ceramics','https://www.rakceramics.com'),
('00000000-0000-0000-0000-000000000001','Osram','https://www.osram.com'),
('00000000-0000-0000-0000-000000000001','Philips','https://www.lighting.philips.com'),
('00000000-0000-0000-0000-000000000001','Caesarstone','https://www.caesarstone.com'),
('00000000-0000-0000-0000-000000000001','Silestone','https://www.cosentino.com/silestone'),
('00000000-0000-0000-0000-000000000001','Dekton','https://www.cosentino.com/dekton')
on conflict(organization_id,name) do update set website_url=excluded.website_url,is_active=true;

-- ---------------------------------------------------------------------------
-- 2. Staff payroll copied from SPACE BURO SALARY LIST.xlsx.
-- Default presence; journal contains only absence, overtime and advance.
-- ---------------------------------------------------------------------------

create table if not exists public.payroll_settings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  salary_day_divisor numeric(6,2) not null default 30,
  hours_per_day numeric(6,2) not null default 10,
  default_present boolean not null default true,
  overtime_multiplier numeric(6,3) not null default 1,
  currency text not null default 'AED',
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id)
);

insert into public.payroll_settings(organization_id,salary_day_divisor,hours_per_day,default_present,overtime_multiplier,currency)
values('00000000-0000-0000-0000-000000000001',30,10,true,1,'AED')
on conflict(organization_id) do nothing;

create table if not exists public.payroll_attendance_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  event_date date not null default current_date,
  event_type text not null check(event_type in ('absence','overtime','advance')),
  quantity numeric(10,2) not null default 0,
  rate numeric(14,4) not null default 0,
  amount numeric(14,2) not null default 0,
  notes text,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.calculate_payroll_event_amount()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare e public.employees%rowtype; s public.payroll_settings%rowtype; v_hourly numeric(14,4);
begin
  select * into e from public.employees where id=new.employee_id and organization_id=new.organization_id;
  select * into s from public.payroll_settings where organization_id=new.organization_id;
  if e.id is null then raise exception 'Employee not found'; end if;
  v_hourly:=case
    when e.hourly_rate>0 then e.hourly_rate
    when e.monthly_salary>0 then e.monthly_salary/coalesce(nullif(s.salary_day_divisor,0),30)/coalesce(nullif(s.hours_per_day,0),10)
    else 0 end;
  if new.event_type='overtime' then
    new.rate:=case when e.overtime_rate>0 then e.overtime_rate else v_hourly*coalesce(s.overtime_multiplier,1) end;
    new.amount:=round(new.quantity*new.rate,2);
  elsif new.event_type='absence' then
    new.rate:=v_hourly;
    new.amount:=-round(new.quantity*new.rate,2);
  elsif new.event_type='advance' then
    new.rate:=1;
    new.amount:=round(new.quantity,2);
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Contract payments for designers and drafters.
-- Architecture follows Учет_проектов_v6.xlsx: SketchUp, Revit and
-- Basis-Mebelshchik are calculated separately, then combined with the
-- material bonus and a configurable minimum project payment.
-- ---------------------------------------------------------------------------

create table if not exists public.design_payment_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  rule_type text not null check(rule_type in (
    'base_rate','sheet_rate','stage_weight','change_amount','error_amount',
    'material_bonus','minimum_payment','material_bonus_cap'
  )),
  program text not null default 'all',
  code text not null,
  name jsonb not null default '{}'::jsonb,
  numeric_value numeric(14,4) not null default 0,
  threshold_amount numeric(14,2),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,rule_type,program,code)
);

create table if not exists public.design_compensations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  project_number text,
  room_type text,
  client_or_project text,
  designer_id uuid references public.employees(id) on delete set null,
  designer_name text,
  surveyor_id uuid references public.employees(id) on delete set null,
  surveyor_name text,
  start_date date,
  planned_finish_date date,
  actual_finish_date date,
  status text not null default 'new',
  manager_comment text,
  egger_actual_cost numeric(14,2) not null default 0,
  additional_material_cost numeric(14,2) not null default 0,
  hardware_cost numeric(14,2) not null default 0,
  repeat_order_error_cost numeric(14,2) not null default 0,
  material_total numeric(14,2) not null default 0,
  material_bonus numeric(14,2) not null default 0,
  program_total numeric(14,2) not null default 0,
  final_payment numeric(14,2) not null default 0,
  currency text not null default 'AED',
  notes text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.design_program_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  compensation_id uuid not null references public.design_compensations(id) on delete cascade,
  program text not null check(program in ('sketchup','revit','basis')),
  base_rate numeric(14,2) not null default 0,
  sheet_count numeric(10,2) not null default 0,
  sheet_rate numeric(14,2) not null default 0,
  changes_coefficient integer not null default 0 check(changes_coefficient between 0 and 10),
  errors_coefficient integer not null default 0 check(errors_coefficient between 0 and 10),
  progress_percent numeric(6,2) not null default 0,
  stage_amount numeric(14,2) not null default 0,
  sheet_amount numeric(14,2) not null default 0,
  changes_amount numeric(14,2) not null default 0,
  error_deduction numeric(14,2) not null default 0,
  total_amount numeric(14,2) not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(compensation_id,program)
);

create table if not exists public.design_stage_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  program_entry_id uuid not null references public.design_program_entries(id) on delete cascade,
  stage_code text not null,
  stage_name jsonb not null default '{}'::jsonb,
  weight_percent numeric(6,2) not null default 0,
  is_completed boolean not null default false,
  completed_at timestamptz,
  sort_order integer not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(program_entry_id,stage_code)
);

insert into public.design_payment_rules(organization_id,rule_type,program,code,name,numeric_value,threshold_amount,sort_order)
values
('00000000-0000-0000-0000-000000000001','base_rate','sketchup','base','{"ru":"База SketchUp","en":"SketchUp base"}',150,null,10),
('00000000-0000-0000-0000-000000000001','base_rate','revit','base','{"ru":"База Revit","en":"Revit base"}',60,null,20),
('00000000-0000-0000-0000-000000000001','base_rate','basis','base','{"ru":"База Базис-Мебельщик","en":"Basis base"}',60,null,30),
('00000000-0000-0000-0000-000000000001','sheet_rate','revit','sheet','{"ru":"Лист Revit","en":"Revit sheet"}',25,null,40),
('00000000-0000-0000-0000-000000000001','sheet_rate','basis','sheet','{"ru":"Лист Базис-Мебельщик","en":"Basis sheet"}',25,null,50),
('00000000-0000-0000-0000-000000000001','stage_weight','sketchup','sketch','{"ru":"Эскиз","en":"Sketch"}',14,null,110),
('00000000-0000-0000-0000-000000000001','stage_weight','sketchup','client_drawing','{"ru":"Чертёж для клиента","en":"Client drawing"}',20,null,120),
('00000000-0000-0000-0000-000000000001','stage_weight','sketchup','approved_drawing','{"ru":"Чертёж после согласования","en":"Approved drawing"}',16,null,130),
('00000000-0000-0000-0000-000000000001','stage_weight','sketchup','material_order','{"ru":"Таблица заказа материалов","en":"Material order table"}',16,null,140),
('00000000-0000-0000-0000-000000000001','stage_weight','sketchup','production_drawing','{"ru":"Производственный чертёж","en":"Production drawing"}',28,null,150),
('00000000-0000-0000-0000-000000000001','stage_weight','sketchup','social_media','{"ru":"Изображения и схемы","en":"Images and schemes"}',6,null,160),
('00000000-0000-0000-0000-000000000001','stage_weight','revit','measurement','{"ru":"Замер","en":"Measurement"}',10,null,210),
('00000000-0000-0000-0000-000000000001','stage_weight','revit','sketch','{"ru":"Эскиз","en":"Sketch"}',25,null,220),
('00000000-0000-0000-0000-000000000001','stage_weight','revit','drawings','{"ru":"Чертежи","en":"Drawings"}',65,null,230),
('00000000-0000-0000-0000-000000000001','stage_weight','basis','measurement','{"ru":"Замер","en":"Measurement"}',10,null,310),
('00000000-0000-0000-0000-000000000001','stage_weight','basis','sketch','{"ru":"Эскиз","en":"Sketch"}',25,null,320),
('00000000-0000-0000-0000-000000000001','stage_weight','basis','drawings','{"ru":"Чертежи","en":"Drawings"}',65,null,330),
('00000000-0000-0000-0000-000000000001','minimum_payment','all','project_minimum','{"ru":"Минимальная выплата за проект","en":"Minimum project payment"}',150,null,400),
('00000000-0000-0000-0000-000000000001','material_bonus_cap','all','material_cap','{"ru":"Максимальный бонус за материалы","en":"Material bonus cap"}',300,null,410)
on conflict(organization_id,rule_type,program,code) do update set
  name=excluded.name,numeric_value=excluded.numeric_value,threshold_amount=excluded.threshold_amount,sort_order=excluded.sort_order;

insert into public.design_payment_rules(organization_id,rule_type,program,code,name,numeric_value,threshold_amount,sort_order)
select '00000000-0000-0000-0000-000000000001','change_amount','all','coefficient_'||x,
  jsonb_build_object('ru','Правки · коэффициент '||x,'en','Changes coefficient '||x),x*40,null,500+x
from generate_series(1,10) x
on conflict(organization_id,rule_type,program,code) do update set numeric_value=excluded.numeric_value;

insert into public.design_payment_rules(organization_id,rule_type,program,code,name,numeric_value,threshold_amount,sort_order)
select '00000000-0000-0000-0000-000000000001','error_amount','all','coefficient_'||x,
  jsonb_build_object('ru','Ошибки · коэффициент '||x,'en','Errors coefficient '||x),x*30,null,600+x
from generate_series(1,10) x
on conflict(organization_id,rule_type,program,code) do update set numeric_value=excluded.numeric_value;

insert into public.design_payment_rules(organization_id,rule_type,program,code,name,numeric_value,threshold_amount,sort_order)
values
('00000000-0000-0000-0000-000000000001','material_bonus','all','from_0','{"ru":"Бонус от 0 AED","en":"Bonus from AED 0"}',0,0,700),
('00000000-0000-0000-0000-000000000001','material_bonus','all','from_5000','{"ru":"Бонус от 5 000 AED","en":"Bonus from AED 5,000"}',80,5000,710),
('00000000-0000-0000-0000-000000000001','material_bonus','all','from_15000','{"ru":"Бонус от 15 000 AED","en":"Bonus from AED 15,000"}',150,15000,720),
('00000000-0000-0000-0000-000000000001','material_bonus','all','from_40000','{"ru":"Бонус от 40 000 AED","en":"Bonus from AED 40,000"}',220,40000,730),
('00000000-0000-0000-0000-000000000001','material_bonus','all','from_100000','{"ru":"Бонус от 100 000 AED","en":"Bonus from AED 100,000"}',300,100000,740)
on conflict(organization_id,rule_type,program,code) do update set
  numeric_value=excluded.numeric_value,threshold_amount=excluded.threshold_amount;

create or replace function public.recalculate_design_compensation(p_compensation_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare c public.design_compensations%rowtype;v_material numeric(14,2);v_bonus numeric(14,2);v_cap numeric(14,2);v_program numeric(14,2);v_min numeric(14,2);
begin
  select * into c from public.design_compensations where id=p_compensation_id and organization_id=public.current_user_organization_id();
  if c.id is null then return; end if;
  v_material:=coalesce(c.egger_actual_cost,0)+coalesce(c.additional_material_cost,0)+coalesce(c.hardware_cost,0);
  select coalesce(max(r.numeric_value),0) into v_bonus from public.design_payment_rules r
    where r.organization_id=c.organization_id and r.rule_type='material_bonus' and r.is_active
      and coalesce(r.threshold_amount,0)<=v_material;
  select coalesce(max(r.numeric_value),300) into v_cap from public.design_payment_rules r
    where r.organization_id=c.organization_id and r.rule_type='material_bonus_cap' and r.is_active;
  select coalesce(sum(p.total_amount),0) into v_program from public.design_program_entries p
    where p.compensation_id=c.id;
  select coalesce(max(r.numeric_value),150) into v_min from public.design_payment_rules r
    where r.organization_id=c.organization_id and r.rule_type='minimum_payment' and r.is_active;
  update public.design_compensations set
    material_total=v_material,
    material_bonus=least(v_bonus,v_cap),
    program_total=v_program,
    final_payment=case when v_program>0 then greatest(v_program+least(v_bonus,v_cap),v_min) else least(v_bonus,v_cap) end,
    updated_at=now()
  where id=c.id;
end;
$$;

create or replace function public.recalculate_design_program(p_program_entry_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare p public.design_program_entries%rowtype;v_progress numeric(6,2);v_stage numeric(14,2);v_sheet numeric(14,2);v_change numeric(14,2);v_error numeric(14,2);v_total numeric(14,2);
begin
  select * into p from public.design_program_entries where id=p_program_entry_id and organization_id=public.current_user_organization_id();
  if p.id is null then return; end if;
  select coalesce(sum(case when s.is_completed then s.weight_percent else 0 end),0) into v_progress
    from public.design_stage_entries s where s.program_entry_id=p.id;
  v_stage:=round(p.base_rate*v_progress/100,2);
  v_sheet:=round(p.sheet_count*p.sheet_rate,2);
  select coalesce(max(r.numeric_value),0) into v_change from public.design_payment_rules r
    where r.organization_id=p.organization_id and r.rule_type='change_amount' and r.code='coefficient_'||p.changes_coefficient and r.is_active;
  select coalesce(max(r.numeric_value),0) into v_error from public.design_payment_rules r
    where r.organization_id=p.organization_id and r.rule_type='error_amount' and r.code='coefficient_'||p.errors_coefficient and r.is_active;
  v_total:=greatest(0,v_stage+v_sheet+v_change-v_error);
  update public.design_program_entries set progress_percent=v_progress,stage_amount=v_stage,sheet_amount=v_sheet,
    changes_amount=v_change,error_deduction=v_error,total_amount=v_total,updated_at=now() where id=p.id;
  perform public.recalculate_design_compensation(p.compensation_id);
end;
$$;

create or replace function public.create_design_program(p_compensation_id uuid,p_program text)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare c public.design_compensations%rowtype;v_id uuid;v_base numeric(14,2);v_sheet numeric(14,2);
begin
  if p_program not in ('sketchup','revit','basis') then raise exception 'Unknown design program'; end if;
  select * into c from public.design_compensations where id=p_compensation_id and organization_id=public.current_user_organization_id();
  if c.id is null then raise exception 'Compensation record not found'; end if;
  select coalesce(max(numeric_value),0) into v_base from public.design_payment_rules
    where organization_id=c.organization_id and rule_type='base_rate' and program=p_program and is_active;
  select coalesce(max(numeric_value),0) into v_sheet from public.design_payment_rules
    where organization_id=c.organization_id and rule_type='sheet_rate' and program=p_program and is_active;
  insert into public.design_program_entries(organization_id,compensation_id,program,base_rate,sheet_rate)
  values(c.organization_id,c.id,p_program,v_base,v_sheet)
  on conflict(compensation_id,program) do update set base_rate=excluded.base_rate,sheet_rate=excluded.sheet_rate
  returning id into v_id;
  insert into public.design_stage_entries(organization_id,program_entry_id,stage_code,stage_name,weight_percent,sort_order)
  select c.organization_id,v_id,r.code,r.name,r.numeric_value,r.sort_order
  from public.design_payment_rules r
  where r.organization_id=c.organization_id and r.rule_type='stage_weight' and r.program=p_program and r.is_active
  on conflict(program_entry_id,stage_code) do update set stage_name=excluded.stage_name,weight_percent=excluded.weight_percent,sort_order=excluded.sort_order;
  perform public.recalculate_design_program(v_id);
  return v_id;
end;
$$;

create or replace function public.design_stage_recalculate_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform public.recalculate_design_program(coalesce(new.program_entry_id,old.program_entry_id));
  return coalesce(new,old);
end;
$$;

drop trigger if exists design_stage_recalculate on public.design_stage_entries;
create trigger design_stage_recalculate after insert or update or delete on public.design_stage_entries
for each row execute function public.design_stage_recalculate_trigger();

create or replace function public.design_material_recalculate_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
begin perform public.recalculate_design_compensation(new.id);return new;end;$$;

drop trigger if exists design_material_recalculate on public.design_compensations;
create trigger design_material_recalculate after insert or update of egger_actual_cost,additional_material_cost,hardware_cost,repeat_order_error_cost
on public.design_compensations for each row execute function public.design_material_recalculate_trigger();

-- ---------------------------------------------------------------------------
-- 4. Advanced Gantt: many-to-many dependencies with a note, plus task comments.
-- ---------------------------------------------------------------------------

create table if not exists public.task_dependencies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  predecessor_task_id uuid not null references public.tasks(id) on delete cascade,
  successor_task_id uuid not null references public.tasks(id) on delete cascade,
  dependency_type text not null default 'finish_to_start' check(dependency_type in ('finish_to_start','start_to_start','finish_to_finish','start_to_finish')),
  lag_days integer not null default 0,
  comment text,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(predecessor_task_id<>successor_task_id),
  unique(predecessor_task_id,successor_task_id)
);

create table if not exists public.task_comments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default public.current_user_organization_id()
    references public.organizations(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  comment text not null,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 5. Ready-made business dictionaries requested for every select field.
-- ---------------------------------------------------------------------------

insert into public.dictionary_groups(id,organization_id,code,name,is_system)
values
('10000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000001','room_type','{"ru":"Типы помещений","en":"Room types"}',true),
('10000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000001','design_program','{"ru":"Программы чертежей","en":"Drawing programs"}',true)
on conflict(id) do update set name=excluded.name;

with expense(code,ru,en,n) as (values
('materials','Материалы','Materials',10),('delivery','Доставка','Delivery',20),('salaries','Зарплаты','Salaries',30),
('contractors','Подрядчики','Contractors',40),('permits','Разрешения','Permits',50),('rent','Аренда','Rent',60),
('transport','Транспорт','Transport',70),('tools','Инструменты','Tools',80),('marketing','Маркетинг','Marketing',90),
('utilities','Коммунальные расходы','Utilities',100),('bank_fees','Банковские комиссии','Bank fees',110),
('unexpected','Непредвиденные расходы','Unexpected expenses',120),('other','Другое','Other',130))
insert into public.dictionary_items(organization_id,group_id,code,name,sort_order)
select '00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000003',code,jsonb_build_object('ru',ru,'en',en),n from expense
on conflict(group_id,code) do update set name=excluded.name,sort_order=excluded.sort_order,is_active=true;

with area(code,ru,en,n) as (values
('downtown','Downtown Dubai','Downtown Dubai',10),('business_bay','Business Bay','Business Bay',20),
('dubai_hills','Dubai Hills Estate','Dubai Hills Estate',30),('palm_jumeirah','Palm Jumeirah','Palm Jumeirah',40),
('jvc','Jumeirah Village Circle (JVC)','Jumeirah Village Circle (JVC)',50),('jvt','Jumeirah Village Triangle (JVT)','Jumeirah Village Triangle (JVT)',60),
('dubai_marina','Dubai Marina','Dubai Marina',70),('jbr','Jumeirah Beach Residence (JBR)','Jumeirah Beach Residence (JBR)',80),
('creek_harbour','Dubai Creek Harbour','Dubai Creek Harbour',90),('al_barari','Al Barari','Al Barari',100),
('al_furjan','Al Furjan','Al Furjan',110),('motor_city','Motor City','Motor City',120),('sports_city','Dubai Sports City','Dubai Sports City',130),
('production_city','Dubai Production City','Dubai Production City',140),('arabian_ranches','Arabian Ranches','Arabian Ranches',150),
('tilal_al_ghaf','Tilal Al Ghaf','Tilal Al Ghaf',160),('damac_hills','Damac Hills','Damac Hills',170),
('mbr_city','Mohammed Bin Rashid City','Mohammed Bin Rashid City',180),('jumeirah','Jumeirah','Jumeirah',190),
('umm_suqeim','Umm Suqeim','Umm Suqeim',200),('al_quoz','Al Quoz','Al Quoz',210),('deira','Deira','Deira',220),
('bur_dubai','Bur Dubai','Bur Dubai',230),('dubai_south','Dubai South','Dubai South',240),
('dubai_investments_park','Dubai Investments Park','Dubai Investments Park',250),('international_city','International City','International City',260),
('other','Другой район','Other area',999))
insert into public.dictionary_items(organization_id,group_id,code,name,sort_order)
select '00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000010',code,jsonb_build_object('ru',ru,'en',en),n from area
on conflict(group_id,code) do update set name=excluded.name,sort_order=excluded.sort_order,is_active=true;

with room(code,ru,en,n) as (values
('kitchen','Кухня','Kitchen',10),('living_room','Гостиная','Living room',20),('bedroom','Спальня','Bedroom',30),
('master_bedroom','Главная спальня','Master bedroom',40),('wardrobe','Гардеробная','Walk-in wardrobe',50),
('bathroom','Ванная','Bathroom',60),('hallway','Прихожая','Hallway',70),('laundry','Прачечная','Laundry',80),
('majlis','Меджлис','Majlis',90),('home_office','Домашний офис','Home office',100),('kids_room','Детская','Kids room',110),
('office','Офис','Office',120),('meeting_room','Переговорная','Meeting room',130),('reception','Ресепшен','Reception',140),
('restaurant_hall','Зал ресторана','Restaurant hall',150),('bar','Бар','Bar',160),('hotel_room','Номер отеля','Hotel room',170),
('retail','Торговое помещение','Retail space',180),('other','Другое помещение','Other room',999))
insert into public.dictionary_items(organization_id,group_id,code,name,sort_order)
select '00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000011',code,jsonb_build_object('ru',ru,'en',en),n from room
on conflict(group_id,code) do update set name=excluded.name,sort_order=excluded.sort_order,is_active=true;

insert into public.dictionary_items(organization_id,group_id,code,name,sort_order)
values
('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000012','sketchup','{"ru":"SketchUp","en":"SketchUp"}',10),
('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000012','revit','{"ru":"Revit","en":"Revit"}',20),
('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000012','basis','{"ru":"Базис-Мебельщик","en":"Basis-Mebelshchik"}',30)
on conflict(group_id,code) do update set name=excluded.name,sort_order=excluded.sort_order,is_active=true;

-- ---------------------------------------------------------------------------
-- 6. Security, audit timestamps, indexes and API grants.
-- ---------------------------------------------------------------------------

alter table public.material_subcategories enable row level security;
alter table public.supplier_materials enable row level security;
alter table public.payroll_settings enable row level security;
alter table public.payroll_attendance_events enable row level security;
alter table public.design_payment_rules enable row level security;
alter table public.design_compensations enable row level security;
alter table public.design_program_entries enable row level security;
alter table public.design_stage_entries enable row level security;
alter table public.task_dependencies enable row level security;
alter table public.task_comments enable row level security;

do $$ declare t text;p text; begin
  foreach t in array array['material_subcategories','supplier_materials'] loop
    p:=t||'_phase14_access';execute format('drop policy if exists %I on public.%I',p,t);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''procurement'',''storekeeper'',''project_manager'',''foreman'')) with check (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''procurement'',''storekeeper'',''project_manager''))',p,t);
  end loop;
  foreach t in array array['payroll_settings','payroll_attendance_events'] loop
    p:=t||'_phase14_access';execute format('drop policy if exists %I on public.%I',p,t);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant'')) with check (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant''))',p,t);
  end loop;
  foreach t in array array['design_payment_rules','design_compensations','design_program_entries','design_stage_entries'] loop
    p:=t||'_phase14_access';execute format('drop policy if exists %I on public.%I',p,t);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant'',''project_manager'',''designer'')) with check (organization_id=public.current_user_organization_id() and public.current_user_role() in (''owner'',''admin'',''accountant'',''project_manager'',''designer''))',p,t);
  end loop;
  foreach t in array array['task_dependencies','task_comments'] loop
    p:=t||'_phase14_access';execute format('drop policy if exists %I on public.%I',p,t);
    execute format('create policy %I on public.%I for all to authenticated using (organization_id=public.current_user_organization_id()) with check (organization_id=public.current_user_organization_id())',p,t);
  end loop;
end $$;

do $$ declare t text;begin
  foreach t in array array['material_subcategories','supplier_materials','payroll_settings','payroll_attendance_events','design_payment_rules','design_compensations','design_program_entries','design_stage_entries','task_dependencies','task_comments'] loop
    execute format('drop trigger if exists %I on public.%I',t||'_touch_updated_at',t);
    execute format('create trigger %I before update on public.%I for each row execute function public.touch_updated_at()',t||'_touch_updated_at',t);
  end loop;
end $$;

create index if not exists idx_material_subcategories_category on public.material_subcategories(organization_id,category_id,sort_order);
create index if not exists idx_supplier_materials_supplier on public.supplier_materials(organization_id,supplier_id);
create index if not exists idx_payroll_attendance_period on public.payroll_attendance_events(organization_id,event_date,employee_id);
create index if not exists idx_design_compensations_designer on public.design_compensations(organization_id,designer_id,status);
create index if not exists idx_design_program_compensation on public.design_program_entries(compensation_id,program);
create index if not exists idx_task_dependencies_successor on public.task_dependencies(successor_task_id);
create index if not exists idx_task_comments_task on public.task_comments(task_id,created_at);

grant select,insert,update,delete on public.material_subcategories,public.supplier_materials,
  public.payroll_settings,public.payroll_attendance_events,public.design_payment_rules,
  public.design_compensations,public.design_program_entries,public.design_stage_entries,
  public.task_dependencies,public.task_comments to authenticated;
grant execute on function public.calculate_payroll_event_amount() to authenticated;
grant execute on function public.recalculate_design_compensation(uuid) to authenticated;
grant execute on function public.recalculate_design_program(uuid) to authenticated;
grant execute on function public.create_design_program(uuid,text) to authenticated;

drop trigger if exists payroll_attendance_events_calculate on public.payroll_attendance_events;
create trigger payroll_attendance_events_calculate
before insert or update of employee_id,event_type,quantity,event_date on public.payroll_attendance_events
for each row execute function public.calculate_payroll_event_amount();

-- Monthly calculation: full salary by default; subtract absence, add overtime,
-- count advances as already paid. Existing bonuses and project payments remain.
create or replace function public.calculate_payroll(p_year integer,p_month integer)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid:=public.current_user_organization_id();v_period uuid;
begin
  if public.current_user_role() not in ('owner','admin','accountant') then raise exception 'Not allowed to calculate payroll'; end if;
  insert into public.payroll_periods(organization_id,period_year,period_month,status,calculated_at)
  values(v_org,p_year,p_month,'draft',now())
  on conflict(organization_id,period_year,period_month) do update set calculated_at=now()
  returning id into v_period;

  insert into public.payroll_entries(
    organization_id,payroll_period_id,employee_id,base_amount,daily_amount,hourly_amount,
    overtime_amount,project_amount,bonuses,penalties,absence_deduction,advances,
    other_accruals,other_deductions,accrued,paid,balance
  )
  select v_org,v_period,e.id,
    case when e.payment_type='monthly' then e.monthly_salary else 0 end,
    case when e.payment_type='daily' then coalesce(sum(t.regular_hours),0)/10*e.daily_rate else 0 end,
    case when e.payment_type='hourly' then coalesce(sum(t.regular_hours),0)*e.hourly_rate else 0 end,
    coalesce((select sum(a.amount) from public.payroll_attendance_events a where a.organization_id=v_org and a.employee_id=e.id and a.event_type='overtime' and extract(year from a.event_date)=p_year and extract(month from a.event_date)=p_month),0)
      +coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='overtime' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='project_payment' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='bonus' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='penalty' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    abs(coalesce((select sum(a.amount) from public.payroll_attendance_events a where a.organization_id=v_org and a.employee_id=e.id and a.event_type='absence' and extract(year from a.event_date)=p_year and extract(month from a.event_date)=p_month),0))
      +coalesce(sum(t.absent_hours),0)*case when e.hourly_rate>0 then e.hourly_rate else e.monthly_salary/30/10 end,
    coalesce((select sum(a.amount) from public.payroll_attendance_events a where a.organization_id=v_org and a.employee_id=e.id and a.event_type='advance' and extract(year from a.event_date)=p_year and extract(month from a.event_date)=p_month),0)
      +coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='advance' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type in ('additional_accrual','correction','other') and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=e.id and a.adjustment_type='deduction' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    0,0,0
  from public.employees e
  left join public.timesheets t on t.employee_id=e.id and extract(year from t.work_date)=p_year and extract(month from t.work_date)=p_month
  where e.organization_id=v_org and e.is_active=true and e.deleted_at is null
  group by e.id
  on conflict(payroll_period_id,employee_id) do update set
    base_amount=excluded.base_amount,daily_amount=excluded.daily_amount,hourly_amount=excluded.hourly_amount,
    overtime_amount=excluded.overtime_amount,project_amount=excluded.project_amount,bonuses=excluded.bonuses,
    penalties=excluded.penalties,absence_deduction=excluded.absence_deduction,advances=excluded.advances,
    other_accruals=excluded.other_accruals,other_deductions=excluded.other_deductions,updated_at=now();

  update public.payroll_entries pe set
    accrued=pe.base_amount+pe.daily_amount+pe.hourly_amount+pe.overtime_amount+pe.project_amount+pe.bonuses+pe.other_accruals-pe.penalties-pe.absence_deduction-pe.other_deductions,
    paid=coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.payroll_entry_id=pe.id),0)
      +coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=pe.employee_id and a.adjustment_type='salary_payment' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0),
    balance=(pe.base_amount+pe.daily_amount+pe.hourly_amount+pe.overtime_amount+pe.project_amount+pe.bonuses+pe.other_accruals-pe.penalties-pe.absence_deduction-pe.other_deductions)-pe.advances-
      (coalesce((select sum(pp.amount) from public.payroll_payments pp where pp.payroll_entry_id=pe.id),0)+coalesce((select sum(a.amount) from public.payroll_adjustments a where a.organization_id=v_org and a.employee_id=pe.employee_id and a.adjustment_type='salary_payment' and coalesce(a.period_year,extract(year from a.adjustment_date)::integer)=p_year and coalesce(a.period_month,extract(month from a.adjustment_date)::integer)=p_month),0)),
    updated_at=now()
  where pe.payroll_period_id=v_period;
  return v_period;
end;
$$;

grant execute on function public.calculate_payroll(integer,integer) to authenticated;
notify pgrst,'reload schema';
