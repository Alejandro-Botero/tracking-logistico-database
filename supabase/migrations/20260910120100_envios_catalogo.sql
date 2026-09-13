-- =============================================================================
-- 02 · Catálogo maestro · vive dentro de MS-Envíos, no en un tercer schema
--
-- Mismas tablas que tenía `catalogo` en el modelo completo, movidas al schema
-- de su dueño. MS-Eventos no las lee jamás: se lleva una copia (migración 04).
-- Los estados, tipos de evento y transiciones siguen siendo datos y no código,
-- así que cambiar la operación es un INSERT y no un despliegue.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Ciudades (DIVIPOLA). No se replica a MS-Eventos: allá la ciudad viaja
-- aplanada dentro de ref_punto_red, que es lo único que el historial necesita.
-- -----------------------------------------------------------------------------
create table envios.ciudad (
  codigo        text primary key,
  nombre        text not null,
  departamento  text,
  pais          text not null default 'CO' check (length(pais) = 2),
  activa        boolean not null default true
);

comment on table envios.ciudad is 'Catálogo de ciudades. Exclusivo de MS-Envíos: no se replica.';

-- -----------------------------------------------------------------------------
-- Operadores: quién registra envíos y eventos (NFR-04). `codigo` es el claim
-- `sub` del token del proveedor de identidad, estable aunque cambie el correo.
-- -----------------------------------------------------------------------------
create table envios.operador (
  codigo     text primary key check (length(btrim(codigo)) > 0),
  nombre     text,
  activo     boolean not null default true,
  creado_en  timestamptz not null default now()
);

comment on table envios.operador is 'Directorio para auditar y unir por persona (NFR-04). Se replica a eventos.ref_operador.';

-- -----------------------------------------------------------------------------
-- Puntos de la red.
-- -----------------------------------------------------------------------------
create table envios.punto_red (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique,
  nombre         text not null,
  tipo           text not null
                 check (tipo in ('CENTRO_DISTRIBUCION','PUNTO_VENTA','VEHICULO','DESTINO')),
  ciudad_codigo  text not null references envios.ciudad(codigo),
  latitud        numeric(9,6)  check (latitud  between  -90 and  90),
  longitud       numeric(9,6)  check (longitud between -180 and 180),
  activo         boolean not null default true,
  creado_en      timestamptz not null default now()
);

comment on table envios.punto_red is 'Puntos físicos por los que pasa un envío. Se replica a eventos.ref_punto_red.';

-- -----------------------------------------------------------------------------
-- Estados del envío. El camino feliz lleva `orden`; la excepción lo lleva nulo
-- porque no está sobre la barra de progreso de HU-03.
-- -----------------------------------------------------------------------------
create table envios.estado_envio (
  codigo        text primary key,
  nombre        text not null,
  descripcion   text,
  es_inicial    boolean not null default false,
  es_final      boolean not null default false,
  es_excepcion  boolean not null default false,
  resultado     text check (resultado in ('EXITOSO','FALLIDO')),
  orden         smallint,
  constraint ck_estado_resultado check ((resultado is not null) = es_final),
  constraint ck_estado_orden     check (es_excepcion or orden is not null)
);

comment on table envios.estado_envio is 'Estados válidos de un envío. `orden` da la barra de progreso de HU-03.';

create unique index uq_estado_inicial on envios.estado_envio (es_inicial) where es_inicial;
create unique index uq_estado_orden   on envios.estado_envio (orden)      where orden is not null;

create or replace function envios.estado_inicial() returns text
language sql stable as $$
  select codigo from envios.estado_envio where es_inicial;
$$;

comment on function envios.estado_inicial() is 'Estado con el que nace un envío. DEFAULT de envios.envio.estado_actual.';

-- -----------------------------------------------------------------------------
-- Tipos de evento. El tipo NO define el estado resultante: eso depende también
-- del estado de partida y vive en transicion_valida.
-- -----------------------------------------------------------------------------
create table envios.tipo_evento (
  codigo                  text primary key,
  nombre                  text not null,
  descripcion             text,
  requiere_receptor       boolean not null default false,
  requiere_observaciones  boolean not null default false,
  visible_cliente         boolean not null default true,
  orden                   smallint not null default 0
);

comment on column envios.tipo_evento.requiere_receptor      is 'TRUE en la entrega: obliga a registrar quién recibió (HU-02).';
comment on column envios.tipo_evento.requiere_observaciones is 'TRUE en los eventos de excepción: sin motivo escrito no sirven.';
comment on column envios.tipo_evento.visible_cliente        is 'FALSE en eventos internos que no se muestran en el historial público (HU-04).';

-- -----------------------------------------------------------------------------
-- La máquina de estados, completa: origen + evento -> destino.
-- Definida una sola vez, aquí. MS-Eventos la recibe replicada y la evalúa
-- localmente; no hay dos implementaciones que puedan divergir.
-- -----------------------------------------------------------------------------
create table envios.transicion_valida (
  estado_origen   text not null references envios.estado_envio(codigo),
  tipo_evento     text not null references envios.tipo_evento(codigo),
  estado_destino  text not null references envios.estado_envio(codigo),
  primary key (estado_origen, tipo_evento)
);

comment on table envios.transicion_valida is 'Máquina de estados de la operación. Editarla cambia las reglas sin desplegar código.';

create or replace function envios.verificar_transicion() returns trigger
language plpgsql as $$
begin
  if exists (select 1 from envios.estado_envio where codigo = new.estado_destino and es_inicial) then
    raise exception 'El estado inicial % no puede ser destino de una transición', new.estado_destino
      using errcode = '23514';
  end if;
  if exists (select 1 from envios.estado_envio where codigo = new.estado_origen and es_final) then
    raise exception 'El estado final % no admite transiciones de salida', new.estado_origen
      using errcode = '23514';
  end if;
  return new;
end $$;

create trigger trg_transicion_coherente
  before insert or update on envios.transicion_valida
  for each row execute function envios.verificar_transicion();

-- -----------------------------------------------------------------------------
-- Servicios y SLA versionado por vigencia. Exclusivo de MS-Envíos: MS-Eventos
-- no calcula plazos, así que no lo replica.
-- -----------------------------------------------------------------------------
create table envios.tipo_servicio (
  codigo       text primary key,
  nombre       text not null,
  descripcion  text,
  activo       boolean not null default true
);

create table envios.sla_servicio (
  tipo_servicio  text not null references envios.tipo_servicio(codigo),
  vigente_desde  date not null default current_date,
  horas_max      integer not null check (horas_max > 0),
  primary key (tipo_servicio, vigente_desde)
);

comment on table envios.sla_servicio is 'Horas máximas esperadas por servicio y vigencia. Sostiene HU-05 y HU-06.';

create or replace function envios.sla_horas(p_tipo_servicio text, p_momento timestamptz)
returns integer
language sql stable as $$
  select s.horas_max
    from envios.sla_servicio s
   where s.tipo_servicio = p_tipo_servicio
     and s.vigente_desde <= (p_momento at time zone 'America/Bogota')::date
   order by s.vigente_desde desc
   limit 1;
$$;

comment on function envios.sla_horas(text, timestamptz) is 'SLA vigente al momento dado. Cambiar el SLA de hoy no reescribe el juicio sobre ayer.';

-- -----------------------------------------------------------------------------
-- Versión del catálogo: le dice al sync qué tan atrás quedó la réplica sin
-- tener que comparar fila por fila.
-- -----------------------------------------------------------------------------
create table envios.catalogo_version (
  recurso        text primary key,
  version        bigint not null default 1,
  actualizado_en timestamptz not null default now()
);

comment on table envios.catalogo_version is 'Se incrementa cuando cambia un catálogo replicable. La lee el sync.';

create or replace function envios.marcar_catalogo_cambiado() returns trigger
language plpgsql as $$
begin
  insert into envios.catalogo_version (recurso, version, actualizado_en)
  values (tg_argv[0], 1, now())
  on conflict (recurso) do update
     set version = envios.catalogo_version.version + 1,
         actualizado_en = now();
  return null;
end $$;

create trigger trg_ver_punto_red after insert or update or delete on envios.punto_red
  for each statement execute function envios.marcar_catalogo_cambiado('punto_red');
create trigger trg_ver_operador after insert or update or delete on envios.operador
  for each statement execute function envios.marcar_catalogo_cambiado('operador');
create trigger trg_ver_estado after insert or update or delete on envios.estado_envio
  for each statement execute function envios.marcar_catalogo_cambiado('estado_envio');
create trigger trg_ver_tipo_evento after insert or update or delete on envios.tipo_evento
  for each statement execute function envios.marcar_catalogo_cambiado('tipo_evento');
create trigger trg_ver_transicion after insert or update or delete on envios.transicion_valida
  for each statement execute function envios.marcar_catalogo_cambiado('transicion_valida');
