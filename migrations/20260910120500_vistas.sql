-- =============================================================================
-- 06 · Vistas de consulta y reporte
--
-- Cada vista vive en el schema del servicio que la sirve y no cruza la
-- frontera. Que HU-04 y HU-07b se puedan resolver enteras dentro de `eventos`
-- es justamente lo que compra la réplica: sin ref_punto_red, pintar el
-- historial de un envío con 8 eventos serían 8 lookups contra MS-Envíos.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- MS-Envíos
-- -----------------------------------------------------------------------------

-- HU-03 · rastreo público. Ni un dato personal (NFR-08). El nombre del vehículo
-- se oculta: diría cuántos móviles hay y por dónde andan.
create view envios.v_envio_publico as
select
  e.tracking_number,
  e.estado_actual                           as estado_codigo,
  est.nombre                                as estado_nombre,
  est.orden                                 as estado_orden,
  est.es_final                              as cerrado,
  est.es_excepcion                          as en_excepcion,
  est.resultado,
  coalesce(est.resultado = 'EXITOSO', false) as entregado,
  e.registrado_en,
  e.admitido_en,
  e.ultimo_evento_en,
  case when p.tipo = 'VEHICULO' then null else p.nombre end as ultimo_punto,
  c.nombre                                  as ultimo_punto_ciudad,
  (e.ultimo_evento_en is null)              as sin_movimientos,
  (select count(*) from envios.estado_envio x where x.orden is not null and not x.es_inicial)
                                            as etapas_totales
from envios.envio e
join envios.estado_envio est on est.codigo = e.estado_actual
left join envios.punto_red p on p.id = e.ultimo_punto_id
left join envios.ciudad    c on c.codigo = p.ciudad_codigo;

comment on view envios.v_envio_publico is 'HU-03. sin_movimientos distingue el envío recién registrado del que ya circuló.';

-- HU-05 · tiempo puerta a puerta contra el SLA congelado del envío.
-- El reloj arranca en admitido_en, no en registrado_en: un envío dado de alta a
-- las 5 p.m. y recogido al otro día no gastó 15 horas de servicio en el mostrador.
create view envios.v_tiempo_transito as
select
  e.tracking_number,
  e.tipo_servicio,
  e.registrado_en,
  e.admitido_en,
  e.entregado_en,
  round((extract(epoch from (e.admitido_en  - e.registrado_en)) / 3600.0)::numeric, 2) as horas_mostrador,
  round((extract(epoch from (e.entregado_en - e.admitido_en))   / 3600.0)::numeric, 2) as horas_en_red,
  round((extract(epoch from (e.entregado_en - e.registrado_en)) / 3600.0)::numeric, 2) as horas_totales,
  e.horas_sla,
  (extract(epoch from (e.entregado_en - e.admitido_en)) / 3600.0) > e.horas_sla        as fuera_de_sla
from envios.envio e
where e.entregado_en is not null and e.admitido_en is not null;

comment on view envios.v_tiempo_transito is 'HU-05. Solo envíos entregados; los que siguen en tránsito distorsionarían el promedio.';

-- HU-06 · envíos vivos que ya pasaron su tiempo esperado.
create view envios.v_envio_retrasado as
select
  e.tracking_number,
  e.estado_actual,
  est.nombre        as estado,
  est.es_excepcion  as en_excepcion,
  e.tipo_servicio,
  e.registrado_en,
  e.admitido_en,
  e.ultimo_evento_en,
  pr.codigo         as punto_actual,
  pr.nombre         as punto_actual_nombre,
  e.horas_sla       as horas_esperadas,
  round((extract(epoch from (now() - coalesce(e.admitido_en, e.registrado_en))) / 3600.0)::numeric, 2)
    as horas_en_red,
  round((extract(epoch from (now() - coalesce(e.admitido_en, e.registrado_en))) / 3600.0 - e.horas_sla)::numeric, 2)
    as horas_de_exceso,
  round((extract(epoch from (now() - coalesce(e.ultimo_evento_en, e.registrado_en))) / 3600.0)::numeric, 2)
    as horas_sin_moverse
from envios.envio e
join envios.estado_envio est on est.codigo = e.estado_actual
left join envios.punto_red pr on pr.id = e.ultimo_punto_id
where e.cerrado_en is null
  and now() - coalesce(e.admitido_en, e.registrado_en) > make_interval(hours => e.horas_sla);

comment on view envios.v_envio_retrasado is 'HU-06. Solo retrasos activos; horas_sin_moverse cubre el envío detenido en un punto.';

-- HU-07a · volumen dado de alta, por punto de origen y día.
create view envios.v_volumen_registro as
select
  e.registrado_en::date as dia,
  pr.codigo             as punto_codigo,
  pr.nombre             as punto,
  c.nombre              as ciudad,
  count(*)              as envios_registrados
from envios.envio e
join envios.punto_red pr on pr.id = e.punto_origen_id
join envios.ciudad     c on c.codigo = pr.ciudad_codigo
group by 1, 2, 3, 4;

comment on view envios.v_volumen_registro is 'HU-07, mitad de MS-Envíos: altas por punto de origen.';

-- Estado del catálogo, para poder contestar "¿la réplica está al día?".
create view envios.v_catalogo_estado as
select 'punto_red'         as recurso, count(*) as filas from envios.punto_red
union all select 'operador',          count(*) from envios.operador
union all select 'estado_envio',      count(*) from envios.estado_envio
union all select 'tipo_evento',       count(*) from envios.tipo_evento
union all select 'transicion_valida', count(*) from envios.transicion_valida;

comment on view envios.v_catalogo_estado is 'Lo que el sync debe dejar replicado en MS-Eventos.';

-- -----------------------------------------------------------------------------
-- MS-Eventos
-- -----------------------------------------------------------------------------

-- HU-04 · historial cronológico, resuelto entero contra tablas locales.
create view eventos.v_historial as
select
  ev.envio_id,
  ev.tracking_number,
  ev.secuencia,
  ev.ocurrido_en,
  te.codigo            as tipo_evento,
  te.nombre            as evento,
  ev.estado_resultante as estado_codigo,
  est.nombre           as estado,
  est.es_excepcion     as estado_excepcion,
  pr.codigo            as punto_codigo,
  pr.nombre            as punto,
  pr.ciudad_nombre     as punto_ciudad,
  te.visible_cliente,
  ev.recibido_por,
  ev.observaciones,
  op.nombre            as operador
from eventos.evento ev
join eventos.ref_tipo_evento  te  on te.codigo = ev.tipo_evento
join eventos.ref_estado_envio est on est.codigo = ev.estado_resultante
join eventos.ref_punto_red    pr  on pr.id = ev.punto_red_id
join eventos.ref_operador     op  on op.codigo = ev.registrado_por;

comment on view eventos.v_historial is 'HU-04. Cinco joins, todos locales. Filtrar visible_cliente = true para la vista pública.';

-- HU-07b · eventos y envíos distintos por punto y día.
create view eventos.v_volumen_movimiento as
select
  ev.ocurrido_en::date        as dia,
  pr.codigo                   as punto_codigo,
  pr.nombre                   as punto,
  pr.ciudad_nombre            as ciudad,
  count(*)                    as eventos,
  count(distinct ev.envio_id) as envios_distintos
from eventos.evento ev
join eventos.ref_punto_red pr on pr.id = ev.punto_red_id
group by 1, 2, 3, 4;

comment on view eventos.v_volumen_movimiento is 'HU-07, mitad de MS-Eventos: movimientos por punto.';

-- Salud de la réplica y de la cola: lo primero que se mira cuando algo falla.
create view eventos.v_replica_estado as
select
  s.recurso,
  s.version,
  s.filas          as filas_sincronizadas,
  s.sincronizado_en,
  now() - s.sincronizado_en as antiguedad
from eventos.ref_sync s;

create view eventos.v_outbox_pendiente as
select
  o.id, o.envio_id, o.estado_resultante, o.ocurrido_en,
  o.intentos, o.creado_en, o.ultimo_error,
  now() - o.creado_en as esperando
from eventos.outbox o
where o.publicado_en is null
order by o.id;

comment on view eventos.v_outbox_pendiente is 'Lo que todavía no llegó a MS-Envíos. Si crece, el consumidor está caído.';
