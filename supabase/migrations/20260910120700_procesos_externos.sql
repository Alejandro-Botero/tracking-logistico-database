-- =============================================================================
-- 08 · Los tres procesos que viven FUERA de los microservicios
--
-- Estas funciones no pertenecen a ningún servicio, y por eso están en `public`
-- y no en `envios` ni en `eventos`: son la maqueta local de lo que mañana son
-- dos endpoints HTTP y un worker.
--
--   public.sincronizar_catalogo()   ->  worker de replicación
--                                       (GET /catalogo/* en MS-Envíos,
--                                        POST al ingestor de MS-Eventos)
--   public.resolver_envio(tracking) ->  GET /envios/{tracking}
--   public.consumir_outbox()        ->  worker del outbox
--                                       (PATCH /envios/{id}/estado)
--
-- Corren como `postgres`, nunca como svc_envios ni svc_eventos: ninguno de los
-- dos usuarios de servicio tiene con qué. Que estas tres funciones sean las
-- únicas que nombran los dos schemas a la vez es, literalmente, la propuesta.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Costura nº 1 · replicación del catálogo.
-- Idempotente: correrlo de más nunca hace daño, y es la forma de arreglar una
-- réplica que quedó atrás.
-- -----------------------------------------------------------------------------
create or replace function public.sincronizar_catalogo()
returns table (recurso text, filas integer)
language plpgsql as $$
declare
  r         record;
  v_version bigint;
  v_filas   integer;
begin
  -- punto_red: la ciudad se aplana al copiarla
  v_filas := 0;
  for r in
    select p.id, p.codigo, p.nombre, p.tipo, c.nombre as ciudad, p.activo
      from envios.punto_red p
      join envios.ciudad    c on c.codigo = p.ciudad_codigo
  loop
    perform eventos.sync_punto_red(r.id, r.codigo, r.nombre, r.tipo, r.ciudad, r.activo);
    v_filas := v_filas + 1;
  end loop;
  select coalesce(max(v.version), 1) into v_version
    from envios.catalogo_version v where v.recurso = 'punto_red';
  perform eventos.sync_marcar('punto_red', v_version, v_filas);
  recurso := 'punto_red'; filas := v_filas; return next;

  -- operador
  v_filas := 0;
  for r in select o.codigo, o.nombre, o.activo from envios.operador o loop
    perform eventos.sync_operador(r.codigo, r.nombre, r.activo);
    v_filas := v_filas + 1;
  end loop;
  select coalesce(max(v.version), 1) into v_version
    from envios.catalogo_version v where v.recurso = 'operador';
  perform eventos.sync_marcar('operador', v_version, v_filas);
  recurso := 'operador'; filas := v_filas; return next;

  -- estado_envio
  v_filas := 0;
  for r in
    select e.codigo, e.nombre, e.es_final, e.es_excepcion, e.resultado, e.orden
      from envios.estado_envio e
  loop
    perform eventos.sync_estado_envio(r.codigo, r.nombre, r.es_final, r.es_excepcion, r.resultado, r.orden);
    v_filas := v_filas + 1;
  end loop;
  select coalesce(max(v.version), 1) into v_version
    from envios.catalogo_version v where v.recurso = 'estado_envio';
  perform eventos.sync_marcar('estado_envio', v_version, v_filas);
  recurso := 'estado_envio'; filas := v_filas; return next;

  -- tipo_evento
  v_filas := 0;
  for r in
    select t.codigo, t.nombre, t.requiere_receptor, t.requiere_observaciones, t.visible_cliente
      from envios.tipo_evento t
  loop
    perform eventos.sync_tipo_evento(r.codigo, r.nombre, r.requiere_receptor,
                                     r.requiere_observaciones, r.visible_cliente);
    v_filas := v_filas + 1;
  end loop;
  select coalesce(max(v.version), 1) into v_version
    from envios.catalogo_version v where v.recurso = 'tipo_evento';
  perform eventos.sync_marcar('tipo_evento', v_version, v_filas);
  recurso := 'tipo_evento'; filas := v_filas; return next;

  -- transicion_valida (va después de estados y tipos: son sus FK en la réplica)
  v_filas := 0;
  for r in
    select t.estado_origen, t.tipo_evento, t.estado_destino from envios.transicion_valida t
  loop
    perform eventos.sync_transicion(r.estado_origen, r.tipo_evento, r.estado_destino);
    v_filas := v_filas + 1;
  end loop;
  select coalesce(max(v.version), 1) into v_version
    from envios.catalogo_version v where v.recurso = 'transicion_valida';
  perform eventos.sync_marcar('transicion_valida', v_version, v_filas);
  recurso := 'transicion_valida'; filas := v_filas; return next;

  return;
end $$;

comment on function public.sincronizar_catalogo() is
  'Worker de replicación del catálogo. Idempotente. En producción son dos llamadas HTTP.';

-- -----------------------------------------------------------------------------
-- Costura nº 2 · GET /envios/{tracking} + ingesta en MS-Eventos.
-- Una vez por envío. Si ya estaba resuelto, no hace nada: MS-Eventos va igual o
-- más adelantado que MS-Envíos, y pisarle la proyección sería hacerla retroceder.
-- -----------------------------------------------------------------------------
create or replace function public.resolver_envio(p_tracking text)
returns uuid
language plpgsql as $$
declare
  r record;
begin
  select * into r from envios.referencia_envio(p_tracking);
  if not found then
    raise exception 'GET /envios/% -> 404', p_tracking using errcode = 'P0002';
  end if;

  if exists (select 1 from eventos.envio_seguido s where s.envio_id = r.envio_id) then
    return r.envio_id;
  end if;

  perform eventos.resolver_envio(
    r.envio_id, r.tracking_number, r.estado_actual, r.version,
    r.admitido_en, r.ultimo_evento_en, r.ultimo_punto_id, r.cerrado);

  return r.envio_id;
end $$;

comment on function public.resolver_envio(text) is
  'GET /envios/{tracking} seguido de la ingesta en MS-Eventos. Una llamada por envío, no por evento.';

-- -----------------------------------------------------------------------------
-- Costura nº 3 · consumidor del outbox.
--
-- Aquí se ve para qué sirve `version`: el PATCH exige la versión que MS-Eventos
-- creía vigente. Si otra instancia se adelantó, `aplicar_estado` devuelve NULL
-- —el 409— y el consumidor relee la versión y reintenta una vez. Si vuelve a
-- fallar, la fila queda en la cola con su error, visible en v_outbox_pendiente.
-- -----------------------------------------------------------------------------
create or replace function public.consumir_outbox(p_max integer default 1000)
returns table (publicadas integer, conflictos integer)
language plpgsql as $$
declare
  o           record;
  v_esperada  integer;
  v_nueva     integer;
  v_real      integer;
  v_pub       integer := 0;
  v_conf      integer := 0;
begin
  for o in
    select * from eventos.outbox
     where publicado_en is null
     order by id
     limit p_max
  loop
    select s.version into v_esperada
      from eventos.envio_seguido s where s.envio_id = o.envio_id;

    v_nueva := envios.aplicar_estado(
      o.envio_id, o.estado_resultante, o.ocurrido_en, o.punto_red_id, v_esperada);

    if v_nueva is null then
      -- 409 Conflict: releer la versión y reintentar una sola vez.
      select e.version into v_real from envios.envio e where e.id = o.envio_id;
      perform eventos.refrescar_version(o.envio_id, v_real);

      v_nueva := envios.aplicar_estado(
        o.envio_id, o.estado_resultante, o.ocurrido_en, o.punto_red_id, v_real);
    end if;

    if v_nueva is null then
      perform eventos.fallo_publicacion(o.id, '409 Conflict tras reintento');
      v_conf := v_conf + 1;
    else
      perform eventos.confirmar_publicacion(o.id, v_nueva);
      v_pub := v_pub + 1;
    end if;
  end loop;

  publicadas := v_pub;
  conflictos := v_conf;
  return next;
end $$;

comment on function public.consumir_outbox(integer) is
  'Worker del outbox: PATCH /envios/{id}/estado con bloqueo optimista y un reintento por 409.';

-- -----------------------------------------------------------------------------
-- Atajo para la demostración y las pruebas: registrar un evento como lo haría
-- la API de MS-Eventos, resolviendo el envío antes si hiciera falta.
-- -----------------------------------------------------------------------------
create or replace function public.registrar_evento(
  p_tracking       text,
  p_tipo_evento    text,
  p_punto_codigo   text,
  p_operador       text,
  p_ocurrido_en    timestamptz default now(),
  p_recibido_por   text default null,
  p_observaciones  text default null,
  p_idempotencia   text default null
) returns uuid
language plpgsql as $$
declare
  v_envio_id uuid;
  v_punto_id uuid;
  v_evento   uuid;
begin
  v_envio_id := public.resolver_envio(p_tracking);

  select id into v_punto_id from eventos.ref_punto_red where codigo = p_punto_codigo;
  if v_punto_id is null then
    raise exception 'El punto % no está en la réplica de MS-Eventos', p_punto_codigo
      using errcode = '23503', hint = 'Correr public.sincronizar_catalogo().';
  end if;

  insert into eventos.evento
    (envio_id, tipo_evento, punto_red_id, ocurrido_en, registrado_en,
     registrado_por, recibido_por, observaciones, clave_idempotencia)
  values
    (v_envio_id, p_tipo_evento, v_punto_id, p_ocurrido_en, p_ocurrido_en,
     p_operador, p_recibido_por, p_observaciones, p_idempotencia)
  returning id into v_evento;

  return v_evento;
end $$;

comment on function public.registrar_evento(text, text, text, text, timestamptz, text, text, text) is
  'POST /eventos de la demostración: resuelve el envío si hace falta y registra. La validación la hace la base.';
