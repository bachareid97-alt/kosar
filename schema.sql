-- Kosár database, version 5 (adds workers and daily wages, cash or credit purchases)
-- Paste this whole file into Supabase > SQL Editor > New query, then Run. Run it once on a new project.
--
-- Roles
--   owner      sees and changes everything in the company
--   partner    reads the shops where their share is above 0, the shared warehouse, and their own withdrawals
--   staff      works in one shop: daily close and evening stock count for that shop only
--   warehouse  receives goods and sends them to the shops
-- Every rule below is enforced by the database itself (row-level security), not by the web page.

-- ---------- tables ----------
create table public.orgs (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 80),
  waste_mode text not null default 'separate' check (waste_mode in ('separate','own','pull')),
  wh_own jsonb not null default '{"o":50,"a":25,"b":25}',
  created_at timestamptz not null default now()
);

create table public.shops (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs on delete cascade,
  hu text not null,
  ar text not null,
  own jsonb not null default '{"o":100,"a":0,"b":0}',
  sort int not null default 0,
  created_at timestamptz not null default now()
);

-- 'o' is the owner; every other row is a partner. Shares per shop live in shops.own as {"o":50,"a":25,...}
create table public.partners (
  org_id uuid not null references public.orgs on delete cascade,
  key text not null check (key ~ '^[a-z0-9]{1,12}$'),
  name text not null check (length(trim(name)) between 1 and 60),
  c text not null default '#ffc247',
  sort int not null default 0,
  created_at timestamptz not null default now(),
  primary key (org_id, key)
);

create table public.members (
  org_id uuid not null references public.orgs on delete cascade,
  user_id uuid not null unique references auth.users on delete cascade,  -- one company per login in v1
  email text not null,
  role text not null check (role in ('owner','partner','staff','warehouse')),
  partner_key text check (partner_key <> 'o'),
  shop_id uuid references public.shops on delete cascade,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id),
  check ((role = 'partner') = (partner_key is not null)),
  check ((role = 'staff') = (shop_id is not null))
);

create table public.invites (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs on delete cascade,
  email text not null unique,
  role text not null check (role in ('partner','staff','warehouse')),
  partner_key text check (partner_key <> 'o'),
  shop_id uuid references public.shops on delete cascade,
  created_at timestamptz not null default now(),
  check ((role = 'partner') = (partner_key is not null)),
  check ((role = 'staff') = (shop_id is not null))
);

-- ---------- who am I ----------
-- security definer so the rules can read `members` without looping back into its own rules
create function public.my_org() returns uuid language sql stable security definer set search_path = public as
  $$ select org_id from members where user_id = auth.uid() $$;
create function public.my_role() returns text language sql stable security definer set search_path = public as
  $$ select role from members where user_id = auth.uid() $$;
create function public.my_shop() returns uuid language sql stable security definer set search_path = public as
  $$ select shop_id from members where user_id = auth.uid() $$;
create function public.my_pkey() returns text language sql stable security definer set search_path = public as
  $$ select partner_key from members where user_id = auth.uid() $$;
create function public.can_see_shop(s uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from shops sh join members m on m.org_id = sh.org_id
    where sh.id = s and m.user_id = auth.uid() and (
      m.role = 'owner'
      or (m.role = 'partner' and coalesce((sh.own ->> m.partner_key)::numeric, 0) > 0)
      or (m.role = 'staff' and m.shop_id = sh.id)
    )
  )
$$;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  hu text not null, ar text not null,
  e text not null default '📦', c text not null default '#888888',
  kg numeric not null default 10 check (kg > 0),
  price numeric not null default 0 check (price >= 0),  -- selling price per kg; 0 = not set
  cost numeric not null default 0 check (cost >= 0),    -- cost per kg typed by the owner; 0 = use the invoices
  sh int not null default 7 check (sh > 0),
  cat text not null default 'v' check (cat in ('v','f','h')),  -- vegetable, fruit, herb
  created_at timestamptz not null default now()
);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  date date not null,
  pid uuid not null references public.products,
  boxes int not null check (boxes > 0),
  total numeric not null check (total >= 0),
  supplier text not null default '—',
  photo boolean not null default false,
  photo_path text,
  paid_cash boolean not null default true,  -- false = bought on credit, counted in what is owed to the supplier
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);

create table public.transfers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  date date not null,
  pid uuid not null references public.products,
  boxes int not null check (boxes > 0),
  shop uuid not null references public.shops,
  cost numeric not null check (cost >= 0),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);

create table public.wh_waste (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  date date not null,
  pid uuid not null references public.products,
  boxes int not null check (boxes > 0),
  cost numeric not null check (cost >= 0),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);

create table public.closes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  date date not null,
  shop uuid not null references public.shops,
  open numeric not null default 0 check (open >= 0),
  cash numeric not null check (cash >= 0),
  card numeric not null check (card >= 0),
  exp numeric not null default 0 check (exp >= 0),
  wages numeric not null default 0 check (wages >= 0),  -- paid to workers out of the drawer that day
  pay jsonb not null default '{}',                      -- {"worker name": amount}
  waste numeric not null default 0 check (waste >= 0),
  counted numeric not null,
  handed numeric not null default 0 check (handed >= 0),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);

create table public.counts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  date date not null,
  shop uuid not null references public.shops,
  items jsonb not null default '{}',
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);

create table public.draws (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  date date not null,
  partner text not null,
  amount numeric not null check (amount > 0),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  name text not null check (length(trim(name)) between 1 and 60),
  phone text,
  created_at timestamptz not null default now(),
  unique (org_id, name)
);

-- One row per product ordered from a supplier. `received` grows as deliveries arrive; status turns 'done' when it reaches `boxes`.
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  date date not null,
  supplier text not null,
  pid uuid not null references public.products,
  boxes int not null check (boxes > 0),
  received int not null default 0 check (received >= 0),
  status text not null default 'open' check (status in ('open','done','cancelled')),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
alter table public.receipts add column order_id uuid references public.orders on delete set null;

-- Money paid to suppliers. What is still owed = all receipts from that supplier − all payments to them.
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  date date not null,
  supplier text not null,
  amount numeric not null check (amount > 0),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create index on public.payments (org_id, date);

create table public.workers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null default public.my_org() references public.orgs on delete cascade,
  name text not null check (length(trim(name)) between 1 and 40),
  shop uuid not null references public.shops on delete cascade,
  created_at timestamptz not null default now()
);
create index on public.orders (org_id, status);
create index on public.shops (org_id);
create index on public.products (org_id);
create index on public.receipts (org_id, date);
create index on public.transfers (org_id, date);
create index on public.wh_waste (org_id, date);
create index on public.closes (org_id, date);
create index on public.counts (org_id, date);
create index on public.draws (org_id, date);

-- ---------- sign-up actions ----------
create function public.create_org(org_name text) returns uuid language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if exists (select 1 from members where user_id = auth.uid()) then raise exception 'this login already belongs to a company'; end if;
  insert into orgs (name) values (org_name) returning id into o;
  insert into partners (org_id, key, name, c, sort) values (o, 'o', 'Tulajdonos', '#ff5b3a', 0);
  insert into members (org_id, user_id, email, role) values (o, auth.uid(), coalesce(auth.jwt() ->> 'email', ''), 'owner');
  return o;
end $$;

-- Joins the company that invited this login's e-mail address. Keep "Confirm email" switched on in
-- Supabase > Authentication, otherwise someone could sign up with an address they do not own.
create function public.accept_invite() returns boolean language plpgsql security definer set search_path = public as $$
declare i invites; mail text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null or mail = '' then return false; end if;
  if exists (select 1 from members where user_id = auth.uid()) then return false; end if;
  select * into i from invites where lower(email) = mail;
  if not found then return false; end if;
  insert into members (org_id, user_id, email, role, partner_key, shop_id) values (i.org_id, auth.uid(), mail, i.role, i.partner_key, i.shop_id);
  delete from invites where id = i.id;
  return true;
end $$;

revoke execute on function public.create_org(text), public.accept_invite() from public, anon;
grant execute on function public.create_org(text), public.accept_invite(),
  public.my_org(), public.my_role(), public.my_shop(), public.my_pkey(), public.can_see_shop(uuid) to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- ---------- rules ----------
alter table public.orgs enable row level security;
alter table public.shops enable row level security;
alter table public.members enable row level security;
alter table public.partners enable row level security;
alter table public.invites enable row level security;
alter table public.products enable row level security;
alter table public.receipts enable row level security;
alter table public.transfers enable row level security;
alter table public.wh_waste enable row level security;
alter table public.closes enable row level security;
alter table public.counts enable row level security;
alter table public.draws enable row level security;
alter table public.suppliers enable row level security;
alter table public.orders enable row level security;
alter table public.payments enable row level security;
alter table public.workers enable row level security;

create policy orgs_read on public.orgs for select to authenticated using (id = my_org());
create policy orgs_edit on public.orgs for update to authenticated using (id = my_org() and my_role() = 'owner') with check (id = my_org());

create policy members_read on public.members for select to authenticated using (user_id = auth.uid() or (org_id = my_org() and my_role() = 'owner'));
create policy members_remove on public.members for delete to authenticated using (org_id = my_org() and my_role() = 'owner' and user_id <> auth.uid());

create policy partners_read on public.partners for select to authenticated using (org_id = my_org());
create policy partners_add on public.partners for insert to authenticated with check (org_id = my_org() and my_role() = 'owner');
create policy partners_edit on public.partners for update to authenticated using (org_id = my_org() and my_role() = 'owner') with check (org_id = my_org());

create policy invites_owner on public.invites for all to authenticated
  using (org_id = my_org() and my_role() = 'owner') with check (org_id = my_org() and my_role() = 'owner');

create policy shops_read on public.shops for select to authenticated using (org_id = my_org() and (my_role() in ('owner','warehouse') or can_see_shop(id)));
create policy shops_add on public.shops for insert to authenticated with check (org_id = my_org() and my_role() = 'owner');
create policy shops_edit on public.shops for update to authenticated using (org_id = my_org() and my_role() = 'owner') with check (org_id = my_org());

create policy products_read on public.products for select to authenticated using (org_id = my_org());
create policy products_add on public.products for insert to authenticated with check (org_id = my_org() and my_role() in ('owner','warehouse'));
create policy products_edit on public.products for update to authenticated using (org_id = my_org() and my_role() in ('owner','warehouse')) with check (org_id = my_org());

create policy receipts_read on public.receipts for select to authenticated using (org_id = my_org() and my_role() in ('owner','partner','warehouse'));
create policy receipts_add on public.receipts for insert to authenticated with check (org_id = my_org() and my_role() in ('owner','warehouse'));
create policy receipts_remove on public.receipts for delete to authenticated using (org_id = my_org() and my_role() = 'owner');

create policy wh_waste_read on public.wh_waste for select to authenticated using (org_id = my_org() and my_role() in ('owner','partner','warehouse'));
create policy wh_waste_add on public.wh_waste for insert to authenticated with check (org_id = my_org() and my_role() in ('owner','warehouse'));
create policy wh_waste_remove on public.wh_waste for delete to authenticated using (org_id = my_org() and my_role() = 'owner');

create policy transfers_read on public.transfers for select to authenticated using (org_id = my_org() and (my_role() in ('owner','warehouse') or can_see_shop(shop)));
create policy transfers_add on public.transfers for insert to authenticated with check (org_id = my_org() and my_role() in ('owner','warehouse'));
create policy transfers_remove on public.transfers for delete to authenticated using (org_id = my_org() and my_role() = 'owner');

create policy closes_read on public.closes for select to authenticated using (org_id = my_org() and can_see_shop(shop));
create policy closes_add on public.closes for insert to authenticated with check (org_id = my_org() and (my_role() = 'owner' or (my_role() = 'staff' and shop = my_shop())));
create policy closes_remove on public.closes for delete to authenticated using (org_id = my_org() and my_role() = 'owner');

create policy counts_read on public.counts for select to authenticated using (org_id = my_org() and can_see_shop(shop));
create policy counts_add on public.counts for insert to authenticated with check (org_id = my_org() and (my_role() = 'owner' or (my_role() = 'staff' and shop = my_shop())));
create policy counts_remove on public.counts for delete to authenticated using (org_id = my_org() and my_role() = 'owner');

create policy draws_read on public.draws for select to authenticated using (org_id = my_org() and (my_role() = 'owner' or (my_role() = 'partner' and partner = my_pkey())));
create policy draws_add on public.draws for insert to authenticated with check (org_id = my_org() and my_role() = 'owner');
create policy draws_remove on public.draws for delete to authenticated using (org_id = my_org() and my_role() = 'owner');

create policy suppliers_read on public.suppliers for select to authenticated using (org_id = my_org() and my_role() in ('owner','partner','warehouse'));
create policy suppliers_add on public.suppliers for insert to authenticated with check (org_id = my_org() and my_role() in ('owner','warehouse'));
create policy suppliers_edit on public.suppliers for update to authenticated using (org_id = my_org() and my_role() = 'owner') with check (org_id = my_org());

create policy orders_read on public.orders for select to authenticated using (org_id = my_org() and my_role() in ('owner','partner','warehouse'));
create policy orders_add on public.orders for insert to authenticated with check (org_id = my_org() and my_role() in ('owner','warehouse'));
create policy orders_edit on public.orders for update to authenticated using (org_id = my_org() and my_role() in ('owner','warehouse')) with check (org_id = my_org());
create policy orders_remove on public.orders for delete to authenticated using (org_id = my_org() and my_role() = 'owner');

create policy payments_read on public.payments for select to authenticated using (org_id = my_org() and my_role() in ('owner','partner'));
create policy payments_add on public.payments for insert to authenticated with check (org_id = my_org() and my_role() = 'owner');
create policy payments_remove on public.payments for delete to authenticated using (org_id = my_org() and my_role() = 'owner');

create policy workers_read on public.workers for select to authenticated using (org_id = my_org() and (my_role() = 'owner' or (my_role() = 'staff' and shop = my_shop())));
create policy workers_add on public.workers for insert to authenticated with check (org_id = my_org() and my_role() = 'owner');
create policy workers_remove on public.workers for delete to authenticated using (org_id = my_org() and my_role() = 'owner');
