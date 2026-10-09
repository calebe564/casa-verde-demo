-- Já rodei tudo isso no seu projeto Supabase (casa-verde-demo).
-- Este arquivo é só para referência/histórico, não precisa rodar de novo.

create table if not exists restaurants (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists restaurant_members (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('waiter','kitchen','manager','owner')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(restaurant_id, user_id)
);

create table if not exists categories (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  name text not null,
  position int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists menu_items (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  category_id bigint references categories(id) on delete set null,
  name text not null,
  description text not null default '',
  price numeric(10,2) not null default 0,
  img_url text,
  video_url text,
  tags jsonb not null default '[]',
  promo boolean not null default false,
  available boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists calls (
  id bigint generated always as identity primary key,
  mesa text not null check (char_length(mesa) <= 6),
  kind text not null default 'garcom' check (kind in ('garcom','conta')),
  status text not null default 'new' check (status in ('new','done')),
  restaurant_id uuid references restaurants(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists orders (
  id bigint generated always as identity primary key,
  mesa text not null check (char_length(mesa) <= 6),
  items jsonb not null,
  status text not null default 'novo' check (status in ('novo','done')),
  restaurant_id uuid references restaurants(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Funções auxiliares de permissão
create or replace function is_platform_admin() returns boolean language sql security definer stable as $$
  select exists(select 1 from platform_admins where user_id = auth.uid());
$$;

create or replace function has_role(rid uuid, roles text[]) returns boolean language sql security definer stable as $$
  select exists(
    select 1 from restaurant_members
    where restaurant_id = rid and user_id = auth.uid() and role = any(roles) and active
  ) or is_platform_admin();
$$;

alter table restaurants enable row level security;
alter table platform_admins enable row level security;
alter table restaurant_members enable row level security;
alter table categories enable row level security;
alter table menu_items enable row level security;
alter table calls enable row level security;
alter table orders enable row level security;

create policy "restaurants read" on restaurants for select using (true);
create policy "restaurants write" on restaurants for insert with check (is_platform_admin());
create policy "restaurants update" on restaurants for update using (is_platform_admin() or has_role(id, array['owner'])) with check (true);

create policy "platform_admins self read" on platform_admins for select using (user_id = auth.uid());

create policy "members read" on restaurant_members for select using (user_id = auth.uid() or has_role(restaurant_id, array['owner','manager']));
create policy "members write" on restaurant_members for insert with check (has_role(restaurant_id, array['owner']) or is_platform_admin());
create policy "members update" on restaurant_members for update using (has_role(restaurant_id, array['owner'])) with check (true);

create policy "categories read" on categories for select using (true);
create policy "categories write" on categories for insert with check (has_role(restaurant_id, array['owner','manager']));
create policy "categories update" on categories for update using (has_role(restaurant_id, array['owner','manager'])) with check (true);
create policy "categories delete" on categories for delete using (has_role(restaurant_id, array['owner','manager']));

create policy "items read" on menu_items for select using (true);
create policy "items write" on menu_items for insert with check (has_role(restaurant_id, array['owner','manager']));
create policy "items update" on menu_items for update using (has_role(restaurant_id, array['owner','manager'])) with check (true);
create policy "items delete" on menu_items for delete using (has_role(restaurant_id, array['owner','manager']));

create policy "calls read staff" on calls for select using (has_role(restaurant_id, array['waiter','kitchen','manager','owner']));
create policy "calls insert public" on calls for insert with check (restaurant_id is not null);
create policy "calls update staff" on calls for update using (has_role(restaurant_id, array['waiter','manager','owner'])) with check (true);

create policy "orders read staff" on orders for select using (has_role(restaurant_id, array['waiter','kitchen','manager','owner']));
create policy "orders insert public" on orders for insert with check (restaurant_id is not null);
create policy "orders update staff" on orders for update using (has_role(restaurant_id, array['waiter','manager','owner'])) with check (true);

-- Seed: restaurante Casa Verde + cardápio
insert into restaurants (slug, name) values ('casa-verde', 'Casa Verde') on conflict (slug) do nothing;

-- Adições mais recentes (mesas reais, equipe, analytics, upload de mídia, fechamento de conta)
create table if not exists tables (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  number text not null,
  status text not null default 'open' check (status in ('open','closed')),
  created_at timestamptz not null default now(),
  unique(restaurant_id, number)
);
alter table tables enable row level security;
create policy "tables read" on tables for select using (true);
create policy "tables write" on tables for insert with check (has_role(restaurant_id, array['owner','manager']));
create policy "tables delete" on tables for delete using (has_role(restaurant_id, array['owner','manager']));
create policy "tables update" on tables for update using (true) with check (true);

create or replace function validate_table_exists() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from tables where restaurant_id = new.restaurant_id and number = new.mesa) then
    raise exception 'Mesa % não existe neste restaurante', new.mesa;
  end if;
  return new;
end;
$$;
create trigger calls_validate_table before insert on calls for each row execute function validate_table_exists();
create trigger orders_validate_table before insert on orders for each row execute function validate_table_exists();

create or replace function find_user_id_by_email(p_email text) returns uuid language sql security definer stable as $$
  select id from auth.users where email = p_email limit 1;
$$;
create or replace function list_restaurant_team(p_restaurant_id uuid) returns table(id bigint, user_id uuid, email text, role text, active boolean) language sql security definer stable as $$
  select rm.id, rm.user_id, u.email, rm.role, rm.active
  from restaurant_members rm join auth.users u on u.id = rm.user_id
  where rm.restaurant_id = p_restaurant_id and has_role(p_restaurant_id, array['owner','manager']);
$$;
create policy "members delete owner" on restaurant_members for delete using (has_role(restaurant_id, array['owner']));

alter table calls add column if not exists attended_at timestamptz;
alter table orders add column if not exists attended_at timestamptz;

create table if not exists item_views (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  item_id bigint not null references menu_items(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table item_views enable row level security;
create policy "item_views insert public" on item_views for insert with check (true);
create policy "item_views read staff" on item_views for select using (has_role(restaurant_id, array['manager','owner']));

insert into storage.buckets (id, name, public) values ('menu-media','menu-media', true) on conflict (id) do nothing;
create policy "menu-media public read" on storage.objects for select using (bucket_id = 'menu-media');
create policy "menu-media staff upload" on storage.objects for insert with check (bucket_id = 'menu-media' and auth.role() = 'authenticated');
