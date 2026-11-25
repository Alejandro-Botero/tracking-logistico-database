-- ---------------------------------------------------------------------
-- SPRINT 1
-- ---------------------------------------------------------------------

-- S1-1 · HU-03 · ¿En qué estado está un envío y cuál fue su último movimiento?
-- (reemplazar 'FDX000000012345' por un número de seguimiento existente)
SELECT e.tracking_number,
       est.nombre          AS estado,
       pr.nombre           AS ultimo_punto,
       e.ultimo_evento_en
FROM envios.envio e
JOIN catalogo.estado_envio est ON est.codigo = e.estado_actual
LEFT JOIN catalogo.punto_red pr ON pr.id = e.ultimo_punto_id
WHERE e.tracking_number = 'FDX000000012345';

-- S1-2 · HU-01 · ¿Quiénes son el remitente y el destinatario de un envío y en qué ciudad está cada uno?
SELECT e.tracking_number,
       p.rol,
       p.nombre,
       p.telefono,
       p.direccion,
       c.nombre AS ciudad
FROM envios.envio e
JOIN envios.parte p     ON p.envio_id = e.id
JOIN catalogo.ciudad c  ON c.codigo = p.ciudad_codigo
WHERE e.tracking_number = 'FDX000000012345'
ORDER BY p.rol;

-- S1-3 · HU-01 · ¿Cuántos paquetes y cuánto peso tiene cada envío registrado en un periodo?
SELECT e.tracking_number,
       COUNT(pq.id)     AS paquetes,
       SUM(pq.peso_kg)  AS peso_total_kg
FROM envios.envio e
JOIN envios.paquete pq ON pq.envio_id = e.id
WHERE e.registrado_en >= '2026-10-01'
  AND e.registrado_en <  '2026-11-01'
GROUP BY e.tracking_number
ORDER BY peso_total_kg DESC;

-- S1-4 · HU-02 · ¿Qué envíos se entregaron, quién los recibió y en qué punto?
SELECT e.tracking_number,
       ev.recibido_por,
       ev.ocurrido_en AS entregado_en,
       pr.nombre      AS punto
FROM eventos.evento ev
JOIN envios.envio e         ON e.id = ev.envio_id
JOIN catalogo.punto_red pr  ON pr.id = ev.punto_red_id
WHERE ev.tipo_evento = 'ENTREGA'
ORDER BY ev.ocurrido_en DESC;

-- S1-5 · HU-03 · ¿Cuántos envíos hay en cada estado?
SELECT est.nombre        AS estado,
       COUNT(e.id)       AS envios
FROM catalogo.estado_envio est
LEFT JOIN envios.envio e ON e.estado_actual = est.codigo
GROUP BY est.codigo, est.nombre, est.orden
ORDER BY est.orden NULLS LAST, est.nombre;

-- ---------------------------------------------------------------------
-- SPRINT 2
-- ---------------------------------------------------------------------

-- S2-1 · HU-04 · ¿Por qué puntos pasó mi envío, en qué orden y qué estado dejó cada movimiento?
SELECT ev.ocurrido_en,
       te.nombre   AS evento,
       est.nombre  AS estado,
       pr.nombre   AS punto
FROM eventos.evento ev
JOIN catalogo.tipo_evento te   ON te.codigo = ev.tipo_evento
JOIN catalogo.estado_envio est ON est.codigo = ev.estado_resultante
JOIN catalogo.punto_red pr     ON pr.id = ev.punto_red_id
WHERE ev.tracking_number = 'FDX000000012345'
  AND te.visible_cliente
ORDER BY ev.ocurrido_en, ev.secuencia;

-- S2-2 · HU-05 · ¿Cuál es el tiempo promedio de tránsito de los envíos entregados en un periodo?
SELECT COUNT(*)                       AS envios_entregados,
       ROUND(AVG(horas_en_red), 2)    AS horas_promedio_en_red,
       ROUND(AVG(horas_totales), 2)   AS horas_promedio_totales
FROM eventos.v_tiempo_transito_envio
WHERE entregado_en >= '2026-10-01'
  AND entregado_en <  '2026-11-01';

-- S2-3 · HU-05 · ¿En qué tramos de la red se pierde más tiempo?
SELECT t.tipo_tramo,
       t.punto_origen,
       t.punto_destino,
       COUNT(*)                         AS envios,
       ROUND(AVG(t.horas)::numeric, 2)  AS horas_promedio
FROM eventos.v_tramo t
JOIN envios.envio e ON e.id = t.envio_id
WHERE t.punto_origen IS NOT NULL
  AND e.entregado_en >= '2026-10-01'
  AND e.entregado_en <  '2026-11-01'
GROUP BY t.tipo_tramo, t.punto_origen, t.punto_destino
ORDER BY horas_promedio DESC;

-- S2-4 · HU-06 · ¿Qué envíos van retrasados, dónde están detenidos y cuánto exceden el tiempo esperado?
SELECT tracking_number,
       estado,
       punto_actual_nombre,
       ultimo_evento_en,
       horas_de_exceso,
       horas_sin_moverse
FROM eventos.v_envio_retrasado
ORDER BY horas_de_exceso DESC;

-- S2-5 · HU-06 · ¿En qué puntos se concentran los retrasos?
SELECT punto_actual_nombre,
       COUNT(*)                        AS envios_retrasados,
       ROUND(AVG(horas_de_exceso), 2)  AS exceso_promedio_horas
FROM eventos.v_envio_retrasado
GROUP BY punto_actual_nombre
ORDER BY envios_retrasados DESC;

-- S2-6 · HU-07 · ¿Cuántos envíos se registraron en un periodo y cómo se reparten por punto de la red?
-- Antes de ejecutarla: SELECT eventos.refrescar_reportes();
SELECT punto,
       ciudad,
       SUM(envios_registrados) AS envios
FROM eventos.v_volumen_registro
WHERE dia >= '2026-10-01'
  AND dia <  '2026-11-01'
GROUP BY punto, ciudad
ORDER BY envios DESC;

-- S2-7 · HU-07 · ¿Cuántos envíos se han registrado hoy en cada punto?
SELECT pr.nombre AS punto,
       COUNT(*)  AS envios_hoy
FROM envios.envio e
JOIN catalogo.punto_red pr ON pr.id = e.punto_origen_id
WHERE e.registrado_en >= date_trunc('day', now())
GROUP BY pr.nombre
ORDER BY envios_hoy DESC;

-- S2-8 · HU-07 · ¿Cuánta carga de trabajo tuvo cada punto?
SELECT punto,
       SUM(eventos)           AS eventos,
       SUM(envios_distintos)  AS envios_atendidos
FROM eventos.v_volumen_movimiento
WHERE dia >= '2026-10-01'
  AND dia <  '2026-11-01'
GROUP BY punto
ORDER BY eventos DESC;

-- ---------------------------------------------------------------------
-- SPRINT 3
-- ---------------------------------------------------------------------

-- S3-1 · HU-03 · ¿Qué ve el destinatario al rastrear su envío con el número y el segundo factor?
-- (reemplazar el número y los 4 últimos dígitos del teléfono o del documento del destinatario)
SELECT tracking_number,
       estado_nombre AS estado,
       ultimo_punto,
       ultimo_punto_ciudad,
       ultimo_evento_en,
       sin_movimientos
FROM envios.rastrear('FDX000000012345', '4567');

-- S3-2 · HU-05 · ¿Los tramos entre ciudades tardan más de lo que dice la red de rutas?
-- (usa catalogo.ruta_tramo; la puede correr ms_eventos o el dueño, rol_lectura no lee esa tabla)
SELECT co.nombre                                    AS ciudad_origen,
       cd.nombre                                    AS ciudad_destino,
       rt.horas                                     AS horas_ruta,
       COUNT(*)                                     AS envios,
       ROUND(AVG(t.horas)::numeric, 2)              AS horas_reales_promedio,
       ROUND(AVG(t.horas)::numeric - rt.horas, 2)   AS exceso_promedio
FROM eventos.v_tramo t
JOIN catalogo.punto_red po  ON po.codigo = t.punto_origen
JOIN catalogo.punto_red pd  ON pd.codigo = t.punto_destino
JOIN catalogo.ciudad co     ON co.codigo = po.ciudad_codigo
JOIN catalogo.ciudad cd     ON cd.codigo = pd.ciudad_codigo
JOIN catalogo.ruta_tramo rt ON rt.ciudad_origen_codigo  = po.ciudad_codigo
                           AND rt.ciudad_destino_codigo = pd.ciudad_codigo
WHERE t.tipo_tramo = 'TRANSITO'
  AND rt.activo
GROUP BY co.nombre, cd.nombre, rt.horas
ORDER BY exceso_promedio DESC;

-- S3-3 · HU-08 · ¿Qué sesiones están abiertas, de quién y cuánto llevan inactivas?
SELECT s.username,
       s.creada_en,
       s.ultima_actividad_en,
       s.expira_en,
       ROUND(EXTRACT(epoch FROM (now() - s.ultima_actividad_en)) / 60) AS minutos_inactiva,
       (s.expira_en < now())                                           AS vencida
FROM acceso.sesion s
WHERE s.cerrada_en IS NULL
ORDER BY s.ultima_actividad_en;

-- S3-4 · HU-08 · ¿Qué usuarios tienen cada rol de aplicación y están activos?
SELECT ur.rol,
       u.username,
       u.activo
FROM acceso.usuario u
JOIN acceso.usuario_rol ur ON ur.username = u.username
ORDER BY ur.rol, u.username;

-- ---------------------------------------------------------------------
-- VERIFICACIONES DE INTEGRIDAD (resultado sano: cero filas)
-- ---------------------------------------------------------------------

-- V-1 · ¿El estado guardado en cada envío coincide con su historial de eventos?
SELECT * FROM eventos.v_envio_incoherente;

-- V-2 · ¿Alguna tabla quedó sin RLS, sin política o abierta a PUBLIC?
SELECT * FROM catalogo.verificar_rls();

-- V-3 · HU-02 · ¿Algún envío pasó de una ciudad a otra sin un tramo en la red de rutas?
-- (no filtra por activo: un tramo cerrado después no invalida el historial que pasó por él)
SELECT t.tracking_number,
       co.nombre   AS ciudad_origen,
       cd.nombre   AS ciudad_destino,
       t.llegada_en
FROM eventos.v_tramo t
JOIN catalogo.punto_red po ON po.codigo = t.punto_origen
JOIN catalogo.punto_red pd ON pd.codigo = t.punto_destino
JOIN catalogo.ciudad co    ON co.codigo = po.ciudad_codigo
JOIN catalogo.ciudad cd    ON cd.codigo = pd.ciudad_codigo
LEFT JOIN catalogo.ruta_tramo rt ON rt.ciudad_origen_codigo  = po.ciudad_codigo
                                AND rt.ciudad_destino_codigo = pd.ciudad_codigo
WHERE t.tipo_tramo = 'TRANSITO'
  AND po.ciudad_codigo <> pd.ciudad_codigo
  AND rt.ciudad_origen_codigo IS NULL
ORDER BY t.llegada_en;