(function(){
  'use strict';

  const baseLoad=loadAll,baseRender=renderPage,baseAction=actionForPage;
  const n=v=>Number(v||0);
  const roleCanManage=()=>['owner','admin','accountant','project_manager','designer'].includes(state.profile?.role);
  const taskTypes={documentation:'Documentation',design:'Design',construction:'Construction',production:'Production',procurement:'Procurement',handover:'Handover',project:'Project'};
  const taskStatuses={created:'Создана',blocked:'Заблокирована',in_progress:'В работе',review:'Проверка',done:'Выполнена',accepted:'Принята',new:'Новая',assigned:'Назначена',waiting_materials:'Ожидает материалы',completed:'Завершена'};
  const localNode=x=>state.serviceLanguage111==='en'?(x.name_en||x.name_ru):(x.name_ru||x.name_en);
  const nodeById=id=>state.serviceNodes111.find(x=>x.id===id);
  const childNodes=id=>state.serviceNodes111.filter(x=>(x.parent_id||null)===(id||null)&&x.is_active!==false).sort((a,b)=>n(a.sort_order)-n(b.sort_order)||localNode(a).localeCompare(localNode(b)));
  const componentsFor=id=>state.serviceComponents111.filter(x=>x.parent_node_id===id);
  const editableEstimates=()=>state.moduleRecords.filter(x=>x.module_code==='estimates'&&!['agreed','approved','confirmed','archived','superseded'].includes(x.status)&&!x.deleted_at);

  Object.assign(state,{
    serviceNodes111:state.serviceNodes111||[],serviceComponents111:state.serviceComponents111||[],
    serviceRules111:state.serviceRules111||[],estimateTaskLinks111:state.estimateTaskLinks111||[],
    serviceLibraryMode111:state.serviceLibraryMode111||'estimates',serviceLanguage111:state.serviceLanguage111||'ru',
    serviceSelected111:state.serviceSelected111||new Set(),serviceReady111:true,taskTypeFilter111:'',taskSourceFilter111:''
  });

  async function safe(path){try{return {rows:await rawApi(path),error:null}}catch(error){console.warn('Service library request failed',path,error);return {rows:[],error}}}
  async function loadServiceLibrary111(){
    const results=await Promise.all([
      safe('/rest/v1/service_library_nodes?select=*&order=domain_code.asc,sort_order.asc,name_en.asc'),
      safe('/rest/v1/service_library_components?select=*&order=sort_order.asc'),
      safe('/rest/v1/service_task_rules?select=*&order=priority.desc'),
      safe('/rest/v1/estimate_task_links?select=*&order=created_at.desc')
    ]);
    [state.serviceNodes111,state.serviceComponents111,state.serviceRules111,state.estimateTaskLinks111]=results.map(x=>x.rows);
    state.serviceReady111=!results.some(x=>x.error&&missingRelation(x.error));
  }

  loadAll=async function(){await baseLoad();await loadServiceLibrary111();updateShell();renderPage()};

  function readiness(){return state.serviceReady111?'':`<div class="sl-readiness"><div><b>Phase 1.11 ожидает миграцию Supabase</b><span>Запустите phase1_10_security_hotfix.sql, затем phase1_11_1_service_library_core.sql.</span></div><button class="btn" data-sl-action="retry">Повторить</button></div>`}
  function topTabs(){return `<div class="sl-tabs"><button class="btn ${state.serviceLibraryMode111==='estimates'?'active':''}" data-sl-view="estimates">Сметы и BOQ</button><button class="btn ${state.serviceLibraryMode111==='library'?'active':''}" data-sl-view="library">Библиотека услуг и работ</button></div>`}

  function componentRows(node){
    const rows=componentsFor(node.id);if(!rows.length)return '';
    return `<div class="sl-components">${rows.map(c=>{const material=state.materials.find(x=>x.id===c.material_id),linked=nodeById(c.component_node_id),name=material?.name||localNode(linked||{})||'Component';return `<div class="sl-component"><span>${esc(name)} · ${n(c.quantity_factor)} ${esc(c.unit||material?.unit||'item')}</span>${roleCanManage()?`<button type="button" data-sl-action="delete-component" data-id="${esc(c.id)}" aria-label="Удалить компонент">×</button>`:''}</div>`}).join('')}</div>`
  }
  function nodeTree(node,depth=0){
    const children=childNodes(node.id),rule=state.serviceRules111.find(x=>x.catalog_node_id===node.id&&x.is_active),selectable=node.is_estimate_selectable!==false;
    return `<article class="sl-node" data-depth="${Math.min(depth,6)}"><div class="sl-node-row">${selectable?`<input class="sl-node-check" type="checkbox" data-node-id="${esc(node.id)}" ${state.serviceSelected111.has(node.id)?'checked':''} aria-label="Выбрать ${esc(localNode(node))}">`:'<span style="width:17px"></span>'}<span class="sl-node-code">${esc(node.code)}</span><div class="sl-node-copy"><b>${esc(localNode(node))}</b><small>${esc(state.serviceLanguage111==='en'?node.name_ru:node.name_en)} · ${esc(node.node_kind)}${rule?` · ${esc(taskTypes[rule.task_type]||rule.task_type)}`:''}</small></div><div class="sl-node-price"><b>${money(node.default_sale)} AED</b><small>${esc(node.default_unit)} · ${n(node.default_duration_days)} d</small></div>${roleCanManage()?`<div class="sl-node-actions"><button class="btn" type="button" data-sl-action="component" data-id="${esc(node.id)}">Материал</button><button class="btn" type="button" data-sl-action="add-child" data-id="${esc(node.id)}">＋</button><button class="btn" type="button" data-sl-action="edit" data-id="${esc(node.id)}">Edit</button></div>`:''}</div>${componentRows(node)}${children.length?`<div class="sl-children">${children.map(x=>nodeTree(x,depth+1)).join('')}</div>`:''}</article>`
  }
  function libraryPage(){
    const roots=childNodes(null),drafts=editableEstimates();
    return topTabs()+readiness()+`<div class="module-hero"><div><h2>Библиотека услуг и работ Space Buro</h2><p>Единая RU/EN-иерархия: документация, проектирование, строительство, мебель и материалы. Выберите пункты галочками и добавьте их в BOQ.</p></div><div class="action-row"><button class="btn" data-sl-action="language">${state.serviceLanguage111==='ru'?'English':'Русский'}</button>${roleCanManage()?'<button class="btn primary" data-sl-action="add-root">＋ Новый раздел</button>':''}</div></div><div class="sl-layout section-gap"><section class="panel"><div class="panel-head"><div><h2>Иерархия</h2><p>Неограниченные разделы и подразделы</p></div><span class="tag">${state.serviceNodes111.length} пунктов</span></div><div class="sl-tree">${roots.map(x=>nodeTree(x)).join('')||'<div class="empty">После миграции здесь появится библиотека услуг.</div>'}</div></section><aside class="panel sl-selection"><h2>Добавить в смету</h2><p>Цены и названия копируются в BOQ как снимок. Последующие изменения библиотеки не изменят старую смету.</p><div class="sl-selection-count">${state.serviceSelected111.size}</div><small>выбрано пунктов</small><label>Смета<select class="field" id="slEstimate"><option value="">Выберите черновик</option>${drafts.map(x=>`<option value="${esc(x.id)}">${esc(x.record_number||'EST')} · ${esc(x.name)}</option>`).join('')}</select></label><label><input type="checkbox" id="slIncludeChildren" checked> Добавить все дочерние пункты</label><button class="btn primary" data-sl-action="add-to-boq" ${!drafts.length?'disabled':''}>Добавить выбранное в BOQ</button><button class="btn" data-sl-action="clear-selection">Очистить выбор</button></aside></div>`
  }

  function taskPage111(){
    const projects=state.projects.map(p=>`<option value="${esc(p.id)}">${esc(p.name)}</option>`).join('');
    const types=[...new Set(state.tasks.map(x=>x.task_type).filter(Boolean))].sort();
    const statuses=[...new Set(state.tasks.map(x=>x.status).filter(Boolean))].sort();
    return readiness()+`<section class="panel"><div class="panel-head"><div><h2>Единый список задач</h2><p>Ручные задачи и задачи, автоматически созданные из BOQ</p></div><span class="tag">${state.tasks.length} задач</span></div><div class="sl-task-toolbar"><select class="field" id="slTaskProject"><option value="">Все проекты</option>${projects}</select><select class="field" id="slTaskType"><option value="">Все типы</option>${types.map(x=>`<option value="${esc(x)}">${esc(taskTypes[x]||x)}</option>`).join('')}</select><select class="field" id="slTaskStatus"><option value="">Все статусы</option>${statuses.map(x=>`<option value="${esc(x)}">${esc(taskStatuses[x]||x)}</option>`).join('')}</select><select class="field" id="slTaskSource"><option value="">Все источники</option><option value="boq">Из BOQ</option><option value="manual">Ручные</option></select></div><div id="slTaskRows"></div></section>`
  }
  function taskRows111(){
    const project=document.querySelector('#slTaskProject')?.value||'',type=document.querySelector('#slTaskType')?.value||'',status=document.querySelector('#slTaskStatus')?.value||'',source=document.querySelector('#slTaskSource')?.value||'';
    const rows=state.tasks.filter(t=>(!project||t.project_id===project)&&(!type||t.task_type===type)&&(!status||t.status===status)&&(!source||(source==='boq'?!!t.source_estimate_line_id:!t.source_estimate_line_id)));
    const html=`<div class="table-wrap"><table class="data-table"><thead><tr><th>ЗАДАЧА</th><th>ПРОЕКТ</th><th>ТИП</th><th>СТАТУС</th><th>ИСТОЧНИК</th><th>ЗАВИСИМОСТИ</th><th>СРОК</th></tr></thead><tbody>${rows.map(t=>{const deps=(state.taskDependencies||[]).filter(x=>x.successor_task_id===t.id),open=deps.filter(d=>!['done','accepted','completed'].includes(state.tasks.find(x=>x.id===d.predecessor_task_id)?.status));return `<tr data-task-id="${esc(t.id)}"><td><b>${esc(t.title)}</b><br><small>${esc(t.description||'')}</small></td><td>${esc(state.projects.find(x=>x.id===t.project_id)?.name||'—')}</td><td><span class="sl-task-type">${esc(taskTypes[t.task_type]||t.task_type||'project')}</span></td><td><span class="status ${statusTone(t.status)}">${esc(taskStatuses[t.status]||t.status)}</span></td><td><span class="sl-source">${t.source_estimate_line_id?'BOQ':'Manual'}</span></td><td><span class="sl-status-note"><i class="${open.length?'blocked':''}"></i>${open.length} / ${deps.length} open</span></td><td>${date(t.due_date)}</td></tr>`}).join('')||'<tr><td colspan="7"><div class="empty">По выбранным фильтрам задач нет.</div></td></tr>'}</tbody></table></div>`;
    const host=document.querySelector('#slTaskRows');if(host){host.innerHTML=html;host.querySelectorAll('[data-task-id]').forEach(row=>row.addEventListener('click',()=>openTask(row.dataset.taskId)))}
  }

  renderPage=function(){
    if(state.page==='estimates'&&state.serviceLibraryMode111==='library'){
      document.querySelector('#content').innerHTML=libraryPage();bind111();return;
    }
    if(state.page==='tasks'){
      document.querySelector('#content').innerHTML=taskPage111();bind111();taskRows111();return;
    }
    baseRender();
    if(state.page==='estimates'){
      const content=document.querySelector('#content');content.insertAdjacentHTML('afterbegin',topTabs()+readiness());bind111();
    }
  };

  actionForPage=function(){if(state.page==='estimates'&&state.serviceLibraryMode111==='library')return openNode111();return baseAction()};

  function bind111(){
    const root=document.querySelector('#content');if(!root)return;
    root.querySelectorAll('[data-sl-view]').forEach(b=>b.addEventListener('click',()=>{state.serviceLibraryMode111=b.dataset.slView;renderPage()}));
    root.querySelectorAll('[data-node-id]').forEach(x=>x.addEventListener('change',()=>{x.checked?state.serviceSelected111.add(x.dataset.nodeId):state.serviceSelected111.delete(x.dataset.nodeId);renderPage()}));
    root.querySelectorAll('[data-sl-action]').forEach(b=>b.addEventListener('click',async()=>{
      try{await handleAction111(b.dataset.slAction,b.dataset.id)}catch(error){console.error(error);toast(error.message||'Операция не выполнена')}
    }));
    ['slTaskProject','slTaskType','slTaskStatus','slTaskSource'].forEach(id=>document.querySelector('#'+id)?.addEventListener('change',taskRows111));
  }

  async function handleAction111(action,id){
    if(action==='retry'){await loadServiceLibrary111();renderPage()}
    if(action==='language'){state.serviceLanguage111=state.serviceLanguage111==='ru'?'en':'ru';renderPage()}
    if(action==='add-root')openNode111();
    if(action==='add-child')openNode111('',id);
    if(action==='edit')openNode111(id);
    if(action==='component')openComponent111(id);
    if(action==='delete-component')await deleteComponent111(id);
    if(action==='clear-selection'){state.serviceSelected111.clear();renderPage()}
    if(action==='add-to-boq')await addSelectedToBoq111();
  }

  function openNode111(id='',parentPreset=''){
    const x=nodeById(id)||{},parent=nodeById(x.parent_id||parentPreset),parents=state.serviceNodes111.filter(n=>n.id!==id&&n.is_active!==false),rule=state.serviceRules111.find(r=>r.catalog_node_id===id&&r.is_active);
    const domain=parent?.domain_code||x.domain_code||'construction';
    openModal(id?'Изменить пункт библиотеки':'Новый пункт библиотеки',
      select('parent_id','Родительский раздел',`<option value="">Корневой раздел</option>${parents.map(p=>`<option value="${esc(p.id)}" ${p.id===(x.parent_id||parentPreset)?'selected':''}>${esc(p.code)} · ${esc(localNode(p))}</option>`).join('')}`)+
      select('domain_code','Область',`<option value="documentation" ${domain==='documentation'?'selected':''}>Documentation</option><option value="design" ${domain==='design'?'selected':''}>Design</option><option value="construction" ${domain==='construction'?'selected':''}>Construction</option><option value="furniture" ${domain==='furniture'?'selected':''}>Furniture</option><option value="materials" ${domain==='materials'?'selected':''}>Materials</option>`)+
      select('node_kind','Тип пункта',['domain','section','subsection','software','document','service','stage'].map(v=>`<option value="${v}" ${x.node_kind===v?'selected':''}>${v}</option>`).join(''))+
      input('code','Код','text',x.code||'','required')+input('name_ru','Название · RU','text',x.name_ru||'','required')+input('name_en','Name · EN','text',x.name_en||'','required')+
      input('default_unit','Единица','text',x.default_unit||'item')+input('default_cost','Себестоимость · AED','number',x.default_cost||0,'min="0" step="0.01"')+input('default_sale','Цена продажи · AED','number',x.default_sale||0,'min="0" step="0.01"')+
      input('default_duration_days','Продолжительность · дней','number',x.default_duration_days||0,'min="0" step="0.5"')+
      select('task_type','Автоматическая задача',`<option value="">Не создавать</option>${Object.entries(taskTypes).filter(([k])=>k!=='handover'&&k!=='project').map(([v,l])=>`<option value="${v}" ${rule?.task_type===v?'selected':''}>${l}</option>`).join('')}`)+
      select('is_estimate_selectable','Можно добавлять в BOQ',`<option value="true" ${x.is_estimate_selectable!==false?'selected':''}>Yes</option><option value="false" ${x.is_estimate_selectable===false?'selected':''}>No</option>`)+
      select('include_children_default','По умолчанию добавлять подэтапы',`<option value="false">No</option><option value="true" ${x.include_children_default?'selected':''}>Yes</option>`)+
      `<label class="full">Описание · RU<textarea name="description_ru">${esc(x.description_ru||'')}</textarea></label><label class="full">Description · EN<textarea name="description_en">${esc(x.description_en||'')}</textarea></label>`+
      (id?`<div class="full warning-box">Удаление используется только для ошибочно созданных пунктов. Для истории безопаснее отключить пункт.</div>`:''),
      async d=>{
        const rec={parent_id:d.parent_id||null,domain_code:d.domain_code,node_kind:d.node_kind,code:d.code.trim(),name_ru:d.name_ru.trim(),name_en:d.name_en.trim(),description_ru:d.description_ru||null,description_en:d.description_en||null,default_unit:d.default_unit||'item',default_cost:n(d.default_cost),default_sale:n(d.default_sale),default_duration_days:n(d.default_duration_days),is_estimate_selectable:d.is_estimate_selectable==='true',include_children_default:d.include_children_default==='true',is_active:true};
        const saved=id?await update('service_library_nodes',id,rec):await insert('service_library_nodes',rec);
        const existing=state.serviceRules111.find(r=>r.catalog_node_id===saved.id&&r.rule_code.startsWith('USER-'));
        if(d.task_type){const rr={catalog_node_id:saved.id,domain_code:null,rule_code:existing?.rule_code||`USER-${saved.code}-${d.task_type}`,task_type:d.task_type,applies_to_descendants:true,requires_verification:true,priority:150,is_active:true};existing?await update('service_task_rules',existing.id,rr):await insert('service_task_rules',rr)}
        else if(existing)await update('service_task_rules',existing.id,{is_active:false});
        await loadServiceLibrary111();renderPage();return saved;
      }
    );
  }

  function openComponent111(nodeId){
    const node=nodeById(nodeId);openModal('Материал для услуги',
      select('material_id','Материал',`<option value="">Выберите материал</option>${state.materials.map(m=>`<option value="${esc(m.id)}">${esc(m.name)} · ${esc(m.unit||'pcs')} · ${money(m.purchase_price)} AED</option>`).join('')}`)+
      input('quantity_factor','Расход на единицу работы','number',1,'min="0.001" step="0.001"')+input('unit','Единица','text',node?.default_unit||'pcs')+input('waste_percent','Запас / отходы · %','number',0,'min="0" step="0.01"')+input('default_cost','Себестоимость · AED','number',0,'min="0" step="0.01"')+input('default_sale','Цена в смете · AED','number',0,'min="0" step="0.01"')+`<label class="full">Комментарий<textarea name="comment_ru"></textarea></label>`,
      async d=>{if(!d.material_id)throw new Error('Выберите материал');const rec=await insert('service_library_components',{parent_node_id:nodeId,material_id:d.material_id,component_node_id:null,quantity_factor:n(d.quantity_factor)||1,unit:d.unit||'pcs',waste_percent:n(d.waste_percent),default_cost:n(d.default_cost),default_sale:n(d.default_sale),comment_ru:d.comment_ru||null,sort_order:componentsFor(nodeId).length+1});await loadServiceLibrary111();renderPage();return rec}
    )
  }
  async function deleteComponent111(id){if(!confirm('Удалить материал из состава услуги?'))return;await rawApi(`/rest/v1/service_library_components?id=eq.${encodeURIComponent(id)}`,{method:'DELETE'});await loadServiceLibrary111();renderPage();toast('Компонент удалён')}
  async function addSelectedToBoq111(){const estimate=document.querySelector('#slEstimate')?.value;if(!estimate){toast('Выберите смету');return}if(!state.serviceSelected111.size){toast('Выберите пункты библиотеки');return}await rawApi('/rest/v1/rpc/add_service_nodes_to_estimate_v111',{method:'POST',body:JSON.stringify({p_estimate_id:estimate,p_node_ids:[...state.serviceSelected111],p_include_children:document.querySelector('#slIncludeChildren')?.checked!==false})});state.serviceSelected111.clear();await loadAll();state.serviceLibraryMode111='estimates';renderPage();toast('Выбранные услуги добавлены в BOQ')}

  // Existing approved estimates use the established Phase 1.6/1.7 buttons.
  // Run the new idempotent engine first so old BOQs receive typed tasks too.
  function connectLegacyEstimateAction111(name){
    const previous=window[name];if(typeof previous!=='function')return;
    window[name]=async id=>{
      try{await rawApi('/rest/v1/rpc/generate_estimate_tasks_v111',{method:'POST',body:JSON.stringify({p_estimate_id:id})})}
      catch(error){
        const unavailable=missingRelation(error)||error?.code==='PGRST202'||(error?.status===404&&/function|schema cache/i.test(error?.message||''));
        if(!unavailable)throw error;
      }
      return previous(id);
    };
  }
  connectLegacyEstimateAction111('activateEstimate16');
  connectLegacyEstimateAction111('syncEstimateExecution17');

  function setCloudStatus(){const el=document.querySelector('#cloudStatus');if(!el)return;const online=navigator.onLine;el.classList.toggle('offline',!online);el.textContent=online?'● Облако активно':'● Нет подключения'}
  window.addEventListener('online',setCloudStatus);window.addEventListener('offline',setCloudStatus);setCloudStatus();
  document.querySelector('#pageAction').onclick=actionForPage;

  if(state.session?.access_token)setTimeout(()=>loadServiceLibrary111().then(renderPage),700);
})();
