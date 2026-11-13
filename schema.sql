-- LANCHES COLETIVOS DA EXPOSIÇÃO • Banco de dados compartilhado Supabase
-- Usa prefixo lc_ e schema privado lc_private. Não modifica tabelas pré-existentes.
-- Execute no Supabase SQL Editor como proprietário do projeto.
create schema if not exists lc_private;
revoke all on schema lc_private from public, anon, authenticated;

create table if not exists public.lc_events (
  event_key text primary key,
  title text not null,
  subtitle text not null default '',
  event_date date,
  event_time time not null default '15:00',
  location text default '',
  target_attendees integer not null default 30 check (target_attendees between 1 and 10000),
  icecream_note text not null default '',
  allow_registration boolean not null default true,
  updated_at timestamptz not null default now()
);
create table if not exists public.lc_items (
  id uuid primary key default gen_random_uuid(),
  event_key text not null references public.lc_events(event_key) on delete cascade,
  name text not null check (char_length(name) between 1 and 110),
  emoji text not null default '📦',
  category text not null check (category in ('comida','bebida','logistica')),
  group_name text not null default 'Outros',
  target_quantity integer not null default 0 check (target_quantity between 0 and 10000),
  unit text not null default 'un.',
  active boolean not null default true,
  position integer not null default 0
);
create table if not exists public.lc_attendees (
  id uuid primary key default gen_random_uuid(),
  event_key text not null references public.lc_events(event_key) on delete cascade,
  name text not null check (char_length(name) between 2 and 80),
  notes text not null default '',
  drink_share_with text not null default '',
  icecream_ready boolean not null default false,
  status text not null default 'inscrito' check (status in ('inscrito','cancelado')),
  checked_in_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.lc_pledges (
  id uuid primary key default gen_random_uuid(),
  event_key text not null references public.lc_events(event_key) on delete cascade,
  attendee_id uuid not null references public.lc_attendees(id) on delete cascade,
  item_id uuid not null references public.lc_items(id),
  quantity integer not null check (quantity between 1 and 1000),
  delivered_quantity integer not null default 0 check(delivered_quantity >= 0 and delivered_quantity <= quantity),
  delivered_at timestamptz,
  unique(attendee_id,item_id)
);
create index if not exists lc_pledges_event_idx on public.lc_pledges(event_key);
create index if not exists lc_attendees_event_idx on public.lc_attendees(event_key);
create index if not exists lc_items_event_idx on public.lc_items(event_key);
create table if not exists public.lc_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists lc_private.lc_secrets (
  attendee_id uuid primary key references public.lc_attendees(id) on delete cascade,
  secret_sha256 text not null
);

-- POLÍTICAS: visitantes só leem; inscrições exigem RPC; edições/entregas só gestores.
alter table public.lc_events enable row level security;
alter table public.lc_items enable row level security;
alter table public.lc_attendees enable row level security;
alter table public.lc_pledges enable row level security;
alter table public.lc_admins enable row level security;
alter table lc_private.lc_secrets enable row level security;

grant select on public.lc_events,public.lc_items,public.lc_attendees,public.lc_pledges to anon,authenticated;
grant insert,update,delete on public.lc_events,public.lc_items,public.lc_attendees,public.lc_pledges to authenticated;
revoke all on public.lc_admins from anon,authenticated;
revoke all on lc_private.lc_secrets from anon,authenticated;

create or replace function public.lc_is_admin()
returns boolean language sql stable security definer
set search_path = '' as $$
  select auth.uid() is not null and exists(
    select 1 from public.lc_admins where user_id = auth.uid()
  );
$$;
revoke all on function public.lc_is_admin() from public;
grant execute on function public.lc_is_admin() to anon,authenticated;

drop policy if exists lc_read_events on public.lc_events;
create policy lc_read_events on public.lc_events for select to anon,authenticated using (true);
drop policy if exists lc_admin_events on public.lc_events;
create policy lc_admin_events on public.lc_events for all to authenticated using (public.lc_is_admin()) with check (public.lc_is_admin());
drop policy if exists lc_read_items on public.lc_items;
create policy lc_read_items on public.lc_items for select to anon,authenticated using (true);
drop policy if exists lc_admin_items on public.lc_items;
create policy lc_admin_items on public.lc_items for all to authenticated using (public.lc_is_admin()) with check (public.lc_is_admin());
drop policy if exists lc_read_attendees on public.lc_attendees;
create policy lc_read_attendees on public.lc_attendees for select to anon,authenticated using (true);
drop policy if exists lc_admin_attendees on public.lc_attendees;
create policy lc_admin_attendees on public.lc_attendees for all to authenticated using (public.lc_is_admin()) with check (public.lc_is_admin());
drop policy if exists lc_read_pledges on public.lc_pledges;
create policy lc_read_pledges on public.lc_pledges for select to anon,authenticated using (true);
drop policy if exists lc_admin_pledges on public.lc_pledges;
create policy lc_admin_pledges on public.lc_pledges for all to authenticated using (public.lc_is_admin()) with check (public.lc_is_admin());

-- Valida TODAS as contribuições antes de inserir/substituir (incluindo alimentação).
create or replace function lc_private.lc_write_pledges(
  v_attendee uuid, v_event_key text, v_pledges jsonb, v_share text
) returns void language plpgsql set search_path = '' as $$
declare r jsonb; item record; v_id uuid; v_q integer; n_food integer:=0; n_drink integer:=0;
begin
 if jsonb_typeof(v_pledges) is distinct from 'array' then raise exception 'A lista de itens é inválida.'; end if;
 if jsonb_array_length(v_pledges)>50 or jsonb_array_length(v_pledges)<1 then raise exception 'Quantidade de itens inválida.'; end if;
 delete from public.lc_pledges where attendee_id=v_attendee;
 for r in select value from jsonb_array_elements(v_pledges) loop
   begin
     v_id := (r->>'item_id')::uuid;
     v_q := (r->>'quantity')::integer;
   exception when others then raise exception 'Item ou quantidade inválida.';
   end;
   if v_q is null or v_q<1 or v_q>1000 then raise exception 'A quantidade deve estar entre 1 e 1000.'; end if;
   select * into item from public.lc_items where id=v_id and event_key=v_event_key and active=true;
   if not found then raise exception 'Um dos itens não pertence a este evento.'; end if;
   if item.category='comida' then n_food:=n_food+1; end if;
   if item.category='bebida' then n_drink:=n_drink+1; end if;
   insert into public.lc_pledges(event_key,attendee_id,item_id,quantity)
   values(v_event_key,v_attendee,v_id,v_q);
 end loop;
 if n_food<>1 then raise exception 'Selecione um alimento por participante.'; end if;
 if n_drink<>case when char_length(btrim(v_share))>0 then 0 else 1 end then
   raise exception 'Escolha uma bebida ou informe o irmão com quem vai compartilhar.';
 end if;
end;
$$;
revoke all on function lc_private.lc_write_pledges(uuid,text,jsonb,text) from public,anon,authenticated;

create or replace function public.lc_join(
 p_event_key text,p_name text,p_notes text,p_drink_share_with text,
 p_icecream_ready boolean,p_pledges jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_token text;
begin
 if not exists(select 1 from public.lc_events where event_key=p_event_key and allow_registration=true) then
   raise exception 'As inscrições estão fechadas ou o evento não existe.';
 end if;
 if char_length(btrim(coalesce(p_name,''))) not between 2 and 80 then raise exception 'Informe um nome entre 2 e 80 caracteres.';end if;
 if char_length(coalesce(p_notes,''))>250 or char_length(coalesce(p_drink_share_with,''))>80 then raise exception 'Texto muito longo.';end if;
 insert into public.lc_attendees(event_key,name,notes,drink_share_with,icecream_ready)
 values(p_event_key,btrim(p_name),coalesce(p_notes,''),btrim(coalesce(p_drink_share_with,'')),coalesce(p_icecream_ready,false)) returning id into v_id;
 perform lc_private.lc_write_pledges(v_id,p_event_key,p_pledges,coalesce(p_drink_share_with,''));
 v_token:=gen_random_uuid()::text || gen_random_uuid()::text;
 insert into lc_private.lc_secrets(attendee_id,secret_sha256)
 values(v_id,encode(sha256(convert_to(v_token,'UTF8')),'hex'));
 return jsonb_build_object('attendee_id',v_id,'access_code',v_id::text||'.'||v_token);
end;
$$;
revoke all on function public.lc_join(text,text,text,text,boolean,jsonb) from public;
grant execute on function public.lc_join(text,text,text,text,boolean,jsonb) to anon,authenticated;

create or replace function public.lc_update_mine(
 p_event_key text,p_attendee_id uuid,p_secret text,p_name text,p_notes text,
 p_drink_share_with text,p_icecream_ready boolean,p_pledges jsonb,p_cancel boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_attendee public.lc_attendees%rowtype;
begin
 select * into v_attendee from public.lc_attendees where id=p_attendee_id and event_key=p_event_key for update;
 if not found then raise exception 'Inscrição não encontrada.';end if;
 if not exists(select 1 from lc_private.lc_secrets where attendee_id=p_attendee_id and secret_sha256=encode(sha256(convert_to(coalesce(p_secret,''),'UTF8')),'hex')) then
   raise exception 'Código de edição incorreto.';
 end if;
 if v_attendee.checked_in_at is not null or exists(select 1 from public.lc_pledges where attendee_id=p_attendee_id and delivered_quantity>0) then
   raise exception 'Inscrição já conferida pela organização. Procure o responsável para alterar.';
 end if;
 if coalesce(p_cancel,false) then
   update public.lc_attendees set status='cancelado',updated_at=now() where id=p_attendee_id;
   return jsonb_build_object('cancelled',true);
 end if;
 if not exists(select 1 from public.lc_events where event_key=p_event_key and allow_registration=true) then
   raise exception 'As alterações de inscrição estão fechadas.';
 end if;
 if char_length(btrim(coalesce(p_name,''))) not between 2 and 80 then raise exception 'Informe um nome entre 2 e 80 caracteres.';end if;
 if char_length(coalesce(p_notes,''))>250 or char_length(coalesce(p_drink_share_with,''))>80 then raise exception 'Texto muito longo.';end if;
 update public.lc_attendees set name=btrim(p_name),notes=coalesce(p_notes,''),drink_share_with=btrim(coalesce(p_drink_share_with,'')),icecream_ready=coalesce(p_icecream_ready,false),status='inscrito',updated_at=now() where id=p_attendee_id;
 perform lc_private.lc_write_pledges(p_attendee_id,p_event_key,p_pledges,coalesce(p_drink_share_with,''));
 return jsonb_build_object('updated',true);
end;
$$;
revoke all on function public.lc_update_mine(text,uuid,text,text,text,text,boolean,jsonb,boolean) from public;
grant execute on function public.lc_update_mine(text,uuid,text,text,text,text,boolean,jsonb,boolean) to anon,authenticated;

insert into public.lc_events(event_key,title,subtitle,event_date,event_time,location,target_attendees,icecream_note,allow_registration)
values('exposicao-universo-criativo-2026','Lanche coletivo da exposição','Universo Criativo • Exposição de desenho','2026-11-15','15:00','Praça São Sebastião',30,'Dinheiro para sorvete na sorveteria',true)
on conflict(event_key) do nothing;

-- Os itens iniciais serão incluídos abaixo. Você pode editar tudo no painel após autorizar um gestor.

-- 135 itens: 100 alimentos + 3 bebidas + 32 apoios.
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('7191408c-cd99-5188-a7e3-e5883f766b0b','exposicao-universo-criativo-2026','Salgadinho de milho sabor queijo','🥨','comida','Salgadinhos e pipocas',0,'un.',true,1) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('b9e09219-1646-56aa-a1ca-f8561aedeb63','exposicao-universo-criativo-2026','Salgadinho de milho sabor churrasco','🥨','comida','Salgadinhos e pipocas',0,'un.',true,2) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('9b0449d8-1928-5b35-b68c-552ff0a789a1','exposicao-universo-criativo-2026','Salgadinho de milho sabor cebola','🥨','comida','Salgadinhos e pipocas',0,'un.',true,3) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('f3905e23-c48d-541a-a306-b0ac3c907dd9','exposicao-universo-criativo-2026','Batata chips tradicional','🥨','comida','Salgadinhos e pipocas',0,'un.',true,4) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('eecf56a5-9516-519b-a1c9-a2c749c57e2d','exposicao-universo-criativo-2026','Batata chips ondulada','🥨','comida','Salgadinhos e pipocas',0,'un.',true,5) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('db939822-b158-5acf-8e9f-cbc0be70199b','exposicao-universo-criativo-2026','Salgadinho tipo torcida','🥨','comida','Salgadinhos e pipocas',0,'un.',true,6) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('4117b04c-cc5d-5516-8a38-a628f3d4917e','exposicao-universo-criativo-2026','Salgadinho tipo bacon','🥨','comida','Salgadinhos e pipocas',0,'un.',true,7) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('9ca0bd81-4355-5f33-ba8e-6b0d632f3add','exposicao-universo-criativo-2026','Salgadinho de trigo','🥨','comida','Salgadinhos e pipocas',0,'un.',true,8) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('64b833d5-92d4-55a7-ab28-0d86e029378e','exposicao-universo-criativo-2026','Salgadinho de queijo de pacote','🥨','comida','Salgadinhos e pipocas',0,'un.',true,9) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('211ec21e-7b5c-5562-965c-375325ef20b4','exposicao-universo-criativo-2026','Salgadinho de presunto','🥨','comida','Salgadinhos e pipocas',0,'un.',true,10) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('4a6e64f8-29b9-5095-a53b-1d71c43d02a6','exposicao-universo-criativo-2026','Salgadinho tipo nachos','🥨','comida','Salgadinhos e pipocas',0,'un.',true,11) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('0dfd7bd6-badb-5bf0-9b0c-49e791c1350d','exposicao-universo-criativo-2026','Pipoca salgada de pacote','🥨','comida','Salgadinhos e pipocas',0,'un.',true,12) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('b2d005e6-6bd7-5a80-8572-83d08333ee90','exposicao-universo-criativo-2026','Pipoca salgada pronta (pacote pequeno)','🥨','comida','Salgadinhos e pipocas',0,'un.',true,13) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('57528f59-c519-56dc-907a-c83159e9e146','exposicao-universo-criativo-2026','Milho torrado salgado','🥨','comida','Salgadinhos e pipocas',0,'un.',true,14) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('b7707f94-2d75-56b0-a2f6-2f1693d26801','exposicao-universo-criativo-2026','Amendoim torrado salgado','🥨','comida','Salgadinhos e pipocas',0,'un.',true,15) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('9efc3cea-3ee9-5be5-81f2-959e22b4625c','exposicao-universo-criativo-2026','Amendoim japonês','🥨','comida','Salgadinhos e pipocas',0,'un.',true,16) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('da17c2bb-dc42-56dc-ad62-c5b3149ac502','exposicao-universo-criativo-2026','Amendoim doce de pacote','🥨','comida','Salgadinhos e pipocas',0,'un.',true,17) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('aefd34bc-aab9-5cc0-8028-0fab8380ef9b','exposicao-universo-criativo-2026','Salgadinho de mandioca','🥨','comida','Salgadinhos e pipocas',0,'un.',true,18) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('e2b2191d-2cc7-5bfa-ad4a-5779179c11f8','exposicao-universo-criativo-2026','Salgadinho de arroz','🥨','comida','Salgadinhos e pipocas',0,'un.',true,19) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('752626a0-8289-597b-827c-7c2eb87fdcbc','exposicao-universo-criativo-2026','Mini pretzels de pacote','🥨','comida','Salgadinhos e pipocas',0,'un.',true,20) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('9f49574a-6f11-5f9a-9634-fd879a06b816','exposicao-universo-criativo-2026','Bolacha recheada de chocolate','🍪','comida','Bolachas doces',0,'un.',true,21) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('7559a4ec-f8a0-5adc-9882-4d05aaa38a3f','exposicao-universo-criativo-2026','Bolacha recheada de morango','🍪','comida','Bolachas doces',0,'un.',true,22) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('48f07fe7-423b-594f-a1cd-cb6c14d0d4ac','exposicao-universo-criativo-2026','Bolacha recheada de baunilha','🍪','comida','Bolachas doces',0,'un.',true,23) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('20711e40-eb7f-5932-8f6e-5104f21e025d','exposicao-universo-criativo-2026','Bolacha recheada de limão','🍪','comida','Bolachas doces',0,'un.',true,24) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('b76e1216-14b4-53f0-8a78-9f321e9d55bd','exposicao-universo-criativo-2026','Bolacha recheada de doce de leite','🍪','comida','Bolachas doces',0,'un.',true,25) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('161a9fcd-2e6f-5d60-b9b3-b9d175744e15','exposicao-universo-criativo-2026','Bolacha tipo maisena','🍪','comida','Bolachas doces',0,'un.',true,26) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('59c46a34-7abb-5a4f-808a-467348c507c8','exposicao-universo-criativo-2026','Bolacha tipo Maria','🍪','comida','Bolachas doces',0,'un.',true,27) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('36e62938-7636-55ba-a882-0da81cc5d97d','exposicao-universo-criativo-2026','Bolacha de leite','🍪','comida','Bolachas doces',0,'un.',true,28) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('2fe0bdb0-4dd3-573d-a134-3bb41ee6fed5','exposicao-universo-criativo-2026','Bolacha amanteigada','🍪','comida','Bolachas doces',0,'un.',true,29) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('776c8ba8-dad3-51bf-8455-7368bf90919d','exposicao-universo-criativo-2026','Bolacha de coco','🍪','comida','Bolachas doces',0,'un.',true,30) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('aace0102-9f25-57cd-8735-627217cf7a60','exposicao-universo-criativo-2026','Bolacha de chocolate','🍪','comida','Bolachas doces',0,'un.',true,31) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('d66c6f3e-f4cd-551d-97f5-502e5485c8b9','exposicao-universo-criativo-2026','Bolacha wafer chocolate','🍪','comida','Bolachas doces',0,'un.',true,32) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('e5e3abec-86c8-5617-b9e7-ae7528c9517e','exposicao-universo-criativo-2026','Bolacha wafer morango','🍪','comida','Bolachas doces',0,'un.',true,33) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('fae3d0ea-84d1-5ba9-ac48-c31c1407c256','exposicao-universo-criativo-2026','Bolacha wafer baunilha','🍪','comida','Bolachas doces',0,'un.',true,34) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3c45f1fe-6b55-510d-8161-6d9e83530c4e','exposicao-universo-criativo-2026','Rosquinha de coco','🍪','comida','Bolachas doces',0,'un.',true,35) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('2165b373-ff09-5b10-a652-0da16c6b7f4b','exposicao-universo-criativo-2026','Rosquinha de chocolate','🍪','comida','Bolachas doces',0,'un.',true,36) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('fdf5f1cb-966e-576c-a7ac-fe04710a8567','exposicao-universo-criativo-2026','Rosquinha de leite','🍪','comida','Bolachas doces',0,'un.',true,37) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('30dd7a8a-47ed-5e44-8051-541efab67511','exposicao-universo-criativo-2026','Biscoito de polvilho doce','🍪','comida','Bolachas doces',0,'un.',true,38) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('a75a6095-29f4-5e68-b418-e8b19ffb3dcb','exposicao-universo-criativo-2026','Bolachinha tipo sequilho','🍪','comida','Bolachas doces',0,'un.',true,39) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('0549f92e-41cc-57f5-83f0-2c9c112178eb','exposicao-universo-criativo-2026','Bolacha doce sortida','🍪','comida','Bolachas doces',0,'un.',true,40) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('0bf9f10e-dfe5-5a43-9015-103535e0ad3b','exposicao-universo-criativo-2026','Biscoito água e sal','🧂','comida','Biscoitos salgados',0,'un.',true,41) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('8792c583-0af9-5987-b884-2f9f87c16add','exposicao-universo-criativo-2026','Biscoito cream cracker','🧂','comida','Biscoitos salgados',0,'un.',true,42) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('0f1d1b08-dc16-59b7-958b-f665db402e96','exposicao-universo-criativo-2026','Biscoito salgado integral','🧂','comida','Biscoitos salgados',0,'un.',true,43) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('9aaf99d5-556b-58d1-a2d8-dde52cf8832b','exposicao-universo-criativo-2026','Biscoito salgado sabor queijo','🧂','comida','Biscoitos salgados',0,'un.',true,44) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('a7056395-3d44-5866-aa6f-f7127a671039','exposicao-universo-criativo-2026','Biscoito salgado sabor cebola','🧂','comida','Biscoitos salgados',0,'un.',true,45) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('df5bee4c-4e48-5c88-aa07-97d72e185050','exposicao-universo-criativo-2026','Biscoito tipo club social','🧂','comida','Biscoitos salgados',0,'un.',true,46) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('653e8b7e-b077-5034-bc1c-705da1750652','exposicao-universo-criativo-2026','Biscoito salgado com gergelim','🧂','comida','Biscoitos salgados',0,'un.',true,47) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('ccbe8eb1-1911-536f-9b2c-c656c8ce30b8','exposicao-universo-criativo-2026','Biscoito de polvilho salgado','🧂','comida','Biscoitos salgados',0,'un.',true,48) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('72880adf-3b17-5f49-974f-1716fc87bb5c','exposicao-universo-criativo-2026','Palitinho salgado de pacote','🧂','comida','Biscoitos salgados',0,'un.',true,49) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('bb471659-8bb9-5bfc-81bc-6e00d3963116','exposicao-universo-criativo-2026','Torradinha de pacote','🧂','comida','Biscoitos salgados',0,'un.',true,50) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('e7857c1e-45fb-5e33-aa3b-a4a0a175c6ac','exposicao-universo-criativo-2026','Mini torradas salgadas','🧂','comida','Biscoitos salgados',0,'un.',true,51) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('6e8bf262-03dc-53fc-840d-5621019bf30e','exposicao-universo-criativo-2026','Biscoito salgado de leite','🧂','comida','Biscoitos salgados',0,'un.',true,52) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('a14e2b94-a408-5905-a11e-9eb3eb5e56c4','exposicao-universo-criativo-2026','Rosquinha salgada','🧂','comida','Biscoitos salgados',0,'un.',true,53) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('447021f0-fe14-586a-a3a4-33d74e8fb82c','exposicao-universo-criativo-2026','Cracker de pacote','🧂','comida','Biscoitos salgados',0,'un.',true,54) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('bf9cac9a-5bcc-533a-a5d8-a3907640431b','exposicao-universo-criativo-2026','Bolo caseiro de fubá','🍞','comida','Bolos e pães simples',0,'un.',true,55) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('f882468b-5909-5920-a296-10ac323bdb5a','exposicao-universo-criativo-2026','Bolo simples de cenoura','🍞','comida','Bolos e pães simples',0,'un.',true,56) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3459cf02-980f-58e8-bfc3-4aec738d76c5','exposicao-universo-criativo-2026','Bolo caseiro de chocolate','🍞','comida','Bolos e pães simples',0,'un.',true,57) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('48bb74c8-9791-597c-9b3b-cdd5da7696bd','exposicao-universo-criativo-2026','Bolo de laranja simples','🍞','comida','Bolos e pães simples',0,'un.',true,58) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('f30dc2a2-c986-5cca-af10-beba81dea3b4','exposicao-universo-criativo-2026','Bolo de milho simples','🍞','comida','Bolos e pães simples',0,'un.',true,59) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('1c893dd4-6e9d-5ed2-82d4-756621c4b762','exposicao-universo-criativo-2026','Bolo mesclado simples','🍞','comida','Bolos e pães simples',0,'un.',true,60) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('f3943103-ac5a-546b-9f6d-7c539eb2759f','exposicao-universo-criativo-2026','Bolo de baunilha simples','🍞','comida','Bolos e pães simples',0,'un.',true,61) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('d7920105-9e90-5f74-82d6-a46e3a78ab07','exposicao-universo-criativo-2026','Bolo de coco simples','🍞','comida','Bolos e pães simples',0,'un.',true,62) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('11dad551-ba2c-58fa-9784-2273cbd63183','exposicao-universo-criativo-2026','Bolo simples de limão','🍞','comida','Bolos e pães simples',0,'un.',true,63) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('8f1c5e61-4024-594c-b882-ce62886c4867','exposicao-universo-criativo-2026','Pão de forma tradicional','🍞','comida','Bolos e pães simples',0,'un.',true,64) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('07d9f819-210e-5ea5-b03e-5469effceb43','exposicao-universo-criativo-2026','Pão francês simples','🍞','comida','Bolos e pães simples',0,'un.',true,65) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('61c3aea1-3f1b-5134-974a-56b8e28c3211','exposicao-universo-criativo-2026','Bisnaguinha de pacote','🍞','comida','Bolos e pães simples',0,'un.',true,66) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('64370c52-bd67-5eea-9810-fb2727465f1d','exposicao-universo-criativo-2026','Pão doce simples','🍞','comida','Bolos e pães simples',0,'un.',true,67) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('81bd82f5-0235-55f7-8a2a-1c83dda06275','exposicao-universo-criativo-2026','Pão de leite de pacote','🍞','comida','Bolos e pães simples',0,'un.',true,68) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('be6d4188-649b-59d1-bb6f-7881ca748845','exposicao-universo-criativo-2026','Mini pão francês','🍞','comida','Bolos e pães simples',0,'un.',true,69) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('32d86205-600d-52ac-9d0c-6524b0bde279','exposicao-universo-criativo-2026','Pão de queijo pronto de mercado','🍞','comida','Bolos e pães simples',0,'un.',true,70) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3bf6631c-436b-5b1b-ac35-4d6e64fbeb88','exposicao-universo-criativo-2026','Paçoca de rolha','🍬','comida','Doces baratos de mercado',0,'un.',true,71) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('c2bbe552-f41a-5ef3-a514-85ae1100ce34','exposicao-universo-criativo-2026','Paçoca quadrada','🍬','comida','Doces baratos de mercado',0,'un.',true,72) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('1c851c5c-cfa2-513a-93d0-e772d1343b70','exposicao-universo-criativo-2026','Pé de moleque de pacote','🍬','comida','Doces baratos de mercado',0,'un.',true,73) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('14b407de-0e14-5c64-8160-b7d5366ff00e','exposicao-universo-criativo-2026','Bala de goma de pacote','🍬','comida','Doces baratos de mercado',0,'un.',true,74) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('65338935-e645-5499-bc69-5f9c87c83fb0','exposicao-universo-criativo-2026','Bala mastigável de pacote','🍬','comida','Doces baratos de mercado',0,'un.',true,75) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('76fdda42-a08c-5811-a8e5-6455aadd7876','exposicao-universo-criativo-2026','Bala de coco','🍬','comida','Doces baratos de mercado',0,'un.',true,76) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('99f76c37-1de9-5478-9193-106f83beee9c','exposicao-universo-criativo-2026','Bala de hortelã','🍬','comida','Doces baratos de mercado',0,'un.',true,77) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('e6703853-43a5-541b-8280-7f698578570f','exposicao-universo-criativo-2026','Pirulito de pacote','🍬','comida','Doces baratos de mercado',0,'un.',true,78) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('26747008-0d7e-5127-96e6-f1a55521dc70','exposicao-universo-criativo-2026','Marshmallow simples de pacote','🍬','comida','Doces baratos de mercado',0,'un.',true,79) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('d3b7fb46-8fd8-5e1e-ade1-10e239f2e955','exposicao-universo-criativo-2026','Tablete de chocolate econômico','🍬','comida','Doces baratos de mercado',0,'un.',true,80) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('9e55fc68-bee3-5d43-b602-5abf213ee249','exposicao-universo-criativo-2026','Bombom de pacote econômico','🍬','comida','Doces baratos de mercado',0,'un.',true,81) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('d3a4cd8a-95ad-53e8-9fab-d55544d571bd','exposicao-universo-criativo-2026','Doce de amendoim de pacote','🍬','comida','Doces baratos de mercado',0,'un.',true,82) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3001f805-1f8a-5b3c-98a8-b86ad4141ad9','exposicao-universo-criativo-2026','Goiabada em cubinhos','🍬','comida','Doces baratos de mercado',0,'un.',true,83) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('dff42075-44c6-57c5-8a25-881e1b01a377','exposicao-universo-criativo-2026','Rapadura em pedaços','🍬','comida','Doces baratos de mercado',0,'un.',true,84) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('84056db5-de0d-559a-b547-4e8b343ac6f7','exposicao-universo-criativo-2026','Mini sanduíches de pão de forma','🥪','comida','Lanches econômicos',0,'un.',true,85) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('ead4644a-4186-52b9-b923-372f42de025d','exposicao-universo-criativo-2026','Sanduíches de pão com margarina','🥪','comida','Lanches econômicos',0,'un.',true,86) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('19511719-8b18-54f0-b422-e7862514b3c7','exposicao-universo-criativo-2026','Sanduíches com queijo (em bolsa térmica)','🥪','comida','Lanches econômicos',0,'un.',true,87) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('8b7308c2-8eb8-5dc1-b446-9bc1bce99428','exposicao-universo-criativo-2026','Pão com mortadela (em bolsa térmica)','🥪','comida','Lanches econômicos',0,'un.',true,88) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('87dd69c3-9d2c-58d9-92e9-8ca858449356','exposicao-universo-criativo-2026','Pão com presunto (em bolsa térmica)','🥪','comida','Lanches econômicos',0,'un.',true,89) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('2c0bea2b-cbad-569c-985b-e82176a21b5e','exposicao-universo-criativo-2026','Pão com requeijão (em bolsa térmica)','🥪','comida','Lanches econômicos',0,'un.',true,90) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('7ad0863b-9afa-5044-8d3b-234d829bcf95','exposicao-universo-criativo-2026','Mini cachorro-quente simples','🥪','comida','Lanches econômicos',0,'un.',true,91) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('e1ef32a4-20a8-55b5-beb9-44d0495d23dc','exposicao-universo-criativo-2026','Pão com patê (em bolsa térmica)','🥪','comida','Lanches econômicos',0,'un.',true,92) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('10c7be7e-b3ac-5028-b952-0e1ac7c9bfcb','exposicao-universo-criativo-2026','Mini torradas com margarina','🥪','comida','Lanches econômicos',0,'un.',true,93) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('5c7e21c7-1533-5932-b0d8-42445c5eb8b8','exposicao-universo-criativo-2026','Torradas com geleia em pote','🥪','comida','Lanches econômicos',0,'un.',true,94) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('6b713937-1024-59f9-8461-3e51ee05986e','exposicao-universo-criativo-2026','Pão de alho assado','🥪','comida','Lanches econômicos',0,'un.',true,95) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3533a4ad-affa-542e-8589-ad0457d39fe5','exposicao-universo-criativo-2026','Pãozinho recheado simples','🥪','comida','Lanches econômicos',0,'un.',true,96) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('d5055632-5b71-5898-ba75-fe5177956719','exposicao-universo-criativo-2026','Bolo pronto de pacote (fatiado)','🥪','comida','Lanches econômicos',0,'un.',true,97) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('143af39d-c384-526d-85f0-c115377c2bf0','exposicao-universo-criativo-2026','Pão de milho simples','🥪','comida','Lanches econômicos',0,'un.',true,98) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('05cc59df-0629-5a8a-b8b2-a316e30dd46c','exposicao-universo-criativo-2026','Mini pão doce embalado','🥪','comida','Lanches econômicos',0,'un.',true,99) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('eb0e79b1-210d-50bd-a68a-841a53662e83','exposicao-universo-criativo-2026','Sanduíche natural simples (em bolsa térmica)','🥪','comida','Lanches econômicos',0,'un.',true,100) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('f69c7ce4-e862-5aeb-9cb7-15b533336100','exposicao-universo-criativo-2026','Refrigerante de 2 litros','🥤','bebida','Bebidas',0,'garrafas',true,101) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('1e10c29f-bffc-54af-ad7e-ac93f343554d','exposicao-universo-criativo-2026','Água mineral (para quem não bebe refrigerante)','💧','bebida','Bebidas',0,'garrafas',true,102) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('b5bc235a-bccf-5806-8abe-8567bd1d74a0','exposicao-universo-criativo-2026','Suco (para quem não bebe refrigerante)','🧃','bebida','Bebidas',0,'un.',true,103) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('b05929ce-f689-5007-8e37-706c53fb7c36','exposicao-universo-criativo-2026','Mesa dobrável','🪑','logistica','Organização e utensílios',3,'un.',true,104) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3c731f01-c19f-58a6-89de-37cc8b56ffda','exposicao-universo-criativo-2026','Mesa auxiliar','🪑','logistica','Organização e utensílios',1,'un.',true,105) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('b20e62d3-00ed-5ae7-9b77-494cb669f58a','exposicao-universo-criativo-2026','Toalha para mesa','🧺','logistica','Organização e utensílios',4,'un.',true,106) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('c898e537-bfcb-55cf-bdf0-31e3db7667a3','exposicao-universo-criativo-2026','Cadeiras dobráveis','🪑','logistica','Organização e utensílios',6,'un.',true,107) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('695a3b2f-e106-5ce1-92ce-0e711d02421f','exposicao-universo-criativo-2026','Cooler / caixa térmica','🧊','logistica','Organização e utensílios',3,'un.',true,108) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('d32e630c-0970-5586-857b-a413d1016027','exposicao-universo-criativo-2026','Gelo em saco','🧊','logistica','Organização e utensílios',6,'sacos',true,109) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('fe53d92e-6a02-5aa7-b8e9-c943d9c45809','exposicao-universo-criativo-2026','Copos descartáveis','🥤','logistica','Organização e utensílios',120,'un.',true,110) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('35324c67-eb5e-5a5f-af02-93d1c3a99d60','exposicao-universo-criativo-2026','Pratos descartáveis','🍽️','logistica','Organização e utensílios',80,'un.',true,111) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3c0a293c-3377-5fd7-824d-6d756a68141a','exposicao-universo-criativo-2026','Guardanapos','🧻','logistica','Organização e utensílios',5,'pacotes',true,112) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('2ab24773-b6cc-5ab7-9d75-042c3e23ab80','exposicao-universo-criativo-2026','Papel-toalha','🧻','logistica','Organização e utensílios',3,'rolos',true,113) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('8555b1b1-4c42-5623-b117-fddb3b115c3c','exposicao-universo-criativo-2026','Sacos de lixo reforçados','🗑️','logistica','Organização e utensílios',10,'un.',true,114) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('853b8a35-f2d7-5614-962b-a153493c96d6','exposicao-universo-criativo-2026','Sacolas extras para transporte','🛍️','logistica','Organização e utensílios',8,'un.',true,115) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('6949678c-6c8e-56b5-b29f-e4d8c8395497','exposicao-universo-criativo-2026','Garfos descartáveis','🍴','logistica','Organização e utensílios',60,'un.',true,116) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('150a3d88-cab4-528e-89f7-b31d20e96cb1','exposicao-universo-criativo-2026','Colheres descartáveis','🥄','logistica','Organização e utensílios',60,'un.',true,117) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('77c7a42b-aca4-55d2-a1cc-88452cdbddd9','exposicao-universo-criativo-2026','Facas de servir','🔪','logistica','Organização e utensílios',3,'un.',true,118) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3e9af842-b37a-50e5-b03a-b2aa0464745d','exposicao-universo-criativo-2026','Facas descartáveis','🍴','logistica','Organização e utensílios',60,'un.',true,119) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('ca135599-7f82-557c-967d-3e004c358798','exposicao-universo-criativo-2026','Tábuas de corte','🪵','logistica','Organização e utensílios',2,'un.',true,120) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('57513402-11fe-57c5-a18f-2d3efee0faba','exposicao-universo-criativo-2026','Abridor de garrafa','🍾','logistica','Organização e utensílios',2,'un.',true,121) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('403a0f71-37b0-5a7b-9e96-dadef0a7a566','exposicao-universo-criativo-2026','Tesoura','✂️','logistica','Organização e utensílios',2,'un.',true,122) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('4299e67d-ca71-51ed-ad17-ddb0750ffdf0','exposicao-universo-criativo-2026','Potes com tampa','🥡','logistica','Organização e utensílios',8,'un.',true,123) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('103c9d1b-1353-565d-a774-1cfe9c1a182a','exposicao-universo-criativo-2026','Bandejas para servir','🍽️','logistica','Organização e utensílios',6,'un.',true,124) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('8dff0493-cbb5-5e2a-9282-2862d5dd2508','exposicao-universo-criativo-2026','Pegadores de alimentos','🥢','logistica','Organização e utensílios',3,'un.',true,125) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('1e03e213-2f8f-574e-a6b8-19ca549268a9','exposicao-universo-criativo-2026','Pano para limpeza','🧽','logistica','Organização e utensílios',3,'un.',true,126) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('a9f2ee98-03f6-5a33-b658-a29157875f10','exposicao-universo-criativo-2026','Álcool em gel','🧴','logistica','Organização e utensílios',3,'frascos',true,127) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('e958e5ea-e8e3-5f28-80dc-a2310ebee592','exposicao-universo-criativo-2026','Lenços umedecidos','🧻','logistica','Organização e utensílios',2,'pacotes',true,128) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('626ab9a2-8658-5b6b-ac74-ff440202ef81','exposicao-universo-criativo-2026','Caixas para organização','📦','logistica','Organização e utensílios',4,'un.',true,129) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('2e203be7-11d9-5fbd-86e2-cc1e5e4fde9e','exposicao-universo-criativo-2026','Prendedores de toalha','📎','logistica','Organização e utensílios',8,'un.',true,130) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('53b17920-0cd6-51fb-80b2-3e2401319c13','exposicao-universo-criativo-2026','Extensão elétrica (se necessária)','🔌','logistica','Organização e utensílios',1,'un.',true,131) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('15a0ef0a-8aaa-5399-ada4-fd1bed3420a5','exposicao-universo-criativo-2026','Guarda-sol / cobertura','⛱️','logistica','Organização e utensílios',2,'un.',true,132) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('8d72bee2-0cf7-5a4e-80fd-d10571fe95f3','exposicao-universo-criativo-2026','Fita adesiva','📦','logistica','Organização e utensílios',2,'rolos',true,133) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('da0190c4-7add-5c7e-a9e9-862239939c95','exposicao-universo-criativo-2026','Toalha de chão / canga','🧺','logistica','Organização e utensílios',3,'un.',true,134) on conflict(id) do nothing;
insert into public.lc_items(id,event_key,name,emoji,category,group_name,target_quantity,unit,active,position) values ('3746f0e7-55a9-5348-ba8f-6ea136405571','exposicao-universo-criativo-2026','Colher grande para servir','🥄','logistica','Organização e utensílios',3,'un.',true,135) on conflict(id) do nothing;

-- Conceder a um responsável após criar o usuário no Authentication:
-- insert into public.lc_admins(user_id) select id from auth.users where email='email-do-organizador@exemplo.com';
