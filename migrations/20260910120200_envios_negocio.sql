-- =============================================================================
-- 03 · Envío, partes y paquetes · HU-01, HU-03, HU-05, HU-06
--
-- Novedad frente a ../supabase/: la columna `version`.
--
-- Hoy, en un solo Postgres, la carrera entre dos eventos del mismo envío la
-- corta un SELECT ... FOR UPDATE. Al partir los servicios eso desaparece: dos
-- instancias de MS-Eventos pueden resolver contra el mismo estado de partida y
-- ambas creerse ganadoras. `version` convierte esa carrera silenciosa en un
-- 409 visible que el consumidor del outbox reintenta.
--
-- El número de seguimiento es una secuencia con relleno. La mezcla de Feistel
-- de ../supabase/ es ortogonal a esta discusión y se puede portar tal cual.
-- =============================================================================

create sequence envios.tracking_seq start 1;

create or replace function envios.gen_tracking_number() returns text
language sql volatile as $$
  select 'FDX' || lpad(nextval('envios.tracking_seq')::text, 12, '0');
$$;

-- -----------------------------------------------------------------------------
-- Envío.
-- -----------------------------------------------------------------------------
create table envios.envio (
  id                uuid primary key default gen_random_uuid(),
  tracking_number   text not null unique default envios.gen_tracking_number(),
  tipo_servicio     text not null references envios.tipo_servicio(codigo),
  horas_sla         integer not null check (horas_sla > 0),   -- copia congelada al alta
  estado_actual     text not null references envios.estado_envio(codigo)
                    default envios.estado_inicial(),
  version           integer not null default 0,               -- bloqueo optimista del PATCH
  punto_origen_id   uuid not null references envios.punto_red(id),
  punto_destino_id  uuid references envios.punto_red(id),
  registrado_en     timestamptz not null default now(),
  registrado_por    text not null references envios.operador(codigo),
  admitido_en       timestamptz,   -- primer evento: arranca el reloj del SLA
  ultimo_evento_en  timestamptz,   -- caché para HU-03
  ultimo_punto_id   uuid references envios.punto_red(id),
  cerrado_en        timestamptz,   -- llegó a estado final (como sea)
  entregado_en      timestamptz,   -- final exitoso
  actualizado_en    timestamptz not null default now(),
  constraint ck_envio_cierre check (entregado_en is null or cerrado_en is not null)
);

comment on table  envios.envio is 'Un envío registrado en la red. Fuente única para HU-01, HU-03, HU-05 y HU-06.';
comment on column envios.envio.horas_sla is 'SLA congelado al alta: subir el SLA hoy no reescribe si el envío de ayer llegó tarde.';
comment on column envios.envio.admitido_en is 'Primer evento: la entrada real a la red. El reloj del SLA arranca aquí, no en registrado_en.';
comment on column envios.envio.version is 'Bloqueo optimista. El PATCH del outbox exige la versión que leyó; si no coincide, 409 y reintento.';

create index idx_envio_estado on envios.envio (estado_actual);
create index idx_envio_en_red on envios.envio (ultimo_evento_en) where cerrado_en is null;
create index idx_envio_origen on envios.envio (punto_origen_id, registrado_en);

-- El SLA se copia al alta desde la vigencia que corresponda.
create or replace function envios.fijar_sla() returns trigger
language plpgsql as $$
begin
  if new.horas_sla is null then
    new.horas_sla := envios.sla_horas(new.tipo_servicio, new.registrado_en);
  end if;
  if new.horas_sla is null then
    raise exception 'El servicio % no tiene SLA vigente al %', new.tipo_servicio, new.registrado_en
      using errcode = '23502',
            hint    = 'Insertar la vigencia en envios.sla_servicio antes de vender el servicio.';
  end if;
  return new;
end $$;

create trigger trg_envio_sla before insert on envios.envio
  for each row execute function envios.fijar_sla();

-- -----------------------------------------------------------------------------
-- Partes del envío. Una tabla con rol en vez de duplicar columnas para
-- remitente y destinatario. Los NOT NULL son los datos obligatorios de HU-01.
-- -----------------------------------------------------------------------------
create table envios.parte (
  id              uuid primary key default gen_random_uuid(),
  envio_id        uuid not null references envios.envio(id) on delete restrict,
  rol             text not null check (rol in ('REMITENTE','DESTINATARIO')),
  nombre          text not null check (length(btrim(nombre)) > 0),
  tipo_documento  text check (tipo_documento in ('CC','CE','NIT','PAS')),
  documento       text,
  telefono        text not null check (length(btrim(telefono)) > 0),
  email           text check (email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  direccion       text not null check (length(btrim(direccion)) > 0),
  ciudad_codigo   text not null references envios.ciudad(codigo),
  unique (envio_id, rol),
  constraint ck_parte_documento check ((tipo_documento is null) = (documento is null))
);

comment on table envios.parte is 'Remitente y destinatario. unique(envio_id, rol) impide dos remitentes en el mismo envío (HU-01).';

create index idx_parte_envio on envios.parte (envio_id);

-- -----------------------------------------------------------------------------
-- Paquetes. 1..N por envío.
-- -----------------------------------------------------------------------------
create table envios.paquete (
  id               uuid primary key default gen_random_uuid(),
  envio_id         uuid not null references envios.envio(id) on delete restrict,
  consecutivo      smallint not null check (consecutivo > 0),
  peso_kg          numeric(8,3) not null check (peso_kg > 0),
  alto_cm          numeric(7,2) check (alto_cm  > 0),
  ancho_cm         numeric(7,2) check (ancho_cm > 0),
  largo_cm         numeric(7,2) check (largo_cm > 0),
  contenido        text not null,
  valor_declarado  numeric(14,2) check (valor_declarado >= 0),
  unique (envio_id, consecutivo)
);

create index idx_paquete_envio on envios.paquete (envio_id);

-- =============================================================================
-- La costura nº 3: PATCH /envios/{id}/estado
--
-- Esto es lo que en ../supabase/ hacía el trigger trg_evento_aplicar_estado
-- escribiendo directamente sobre la tabla del otro servicio. Aquí es una
-- función del lado de MS-Envíos, que solo MS-Envíos puede ejecutar, y que el
-- consumidor del outbox invoca con la versión que leyó.
--
-- Devuelve la nueva versión, o NULL si la versión esperada ya no era la actual
-- (equivalente al 409 Conflict de la API).
-- =============================================================================
create or replace function envios.aplicar_estado(
  p_envio_id          uuid,
  p_estado_resultante text,
  p_ocurrido_en       timestamptz,
  p_punto_red_id      uuid,
  p_version_esperada  integer
) returns integer
language plpgsql as $$
declare
  v_destino  envios.estado_envio%rowtype;
  v_version  integer;
begin
  select * into v_destino from envios.estado_envio where codigo = p_estado_resultante;
  if not found then
    raise exception 'Estado desconocido: %', p_estado_resultante using errcode = '23503';
  end if;

  update envios.envio set
    estado_actual    = v_destino.codigo,
    ultimo_evento_en = p_ocurrido_en,
    ultimo_punto_id  = p_punto_red_id,
    admitido_en      = coalesce(admitido_en, p_ocurrido_en),
    cerrado_en       = case when v_destino.es_final then p_ocurrido_en else cerrado_en end,
    entregado_en     = case when v_destino.resultado = 'EXITOSO' then p_ocurrido_en else entregado_en end,
    version          = version + 1,
    actualizado_en   = now()
  where id = p_envio_id
    and version = p_version_esperada
  returning version into v_version;

  return v_version;   -- null = 0 filas afectadas = 409 Conflict
end $$;

comment on function envios.aplicar_estado(uuid, text, timestamptz, uuid, integer) is
  'PATCH /envios/{id}/estado. Bloqueo optimista: devuelve NULL (409) si la versión esperada ya cambió.';

-- =============================================================================
-- La costura nº 2: GET /envios/{tracking}
--
-- Lo que MS-Eventos necesita saber de un envío para poder aceptar eventos suyos.
-- Se llama una vez por envío, no una vez por evento.
-- =============================================================================
create or replace function envios.referencia_envio(p_tracking text)
returns table (
  envio_id          uuid,
  tracking_number   text,
  estado_actual     text,
  version           integer,
  admitido_en       timestamptz,
  ultimo_evento_en  timestamptz,
  ultimo_punto_id   uuid,
  cerrado           boolean
)
language sql stable as $$
  select e.id, e.tracking_number, e.estado_actual, e.version,
         e.admitido_en, e.ultimo_evento_en, e.ultimo_punto_id,
         (e.cerrado_en is not null)
    from envios.envio e
   where e.tracking_number = p_tracking;
$$;

comment on function envios.referencia_envio(text) is
  'GET /envios/{tracking}. Lo único que MS-Eventos sabe de un envío, y lo guarda en su propia tabla.';
