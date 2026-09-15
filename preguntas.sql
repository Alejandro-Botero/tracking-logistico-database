1. ¿Qué envíos siguen activos (no entregados) en la red?

SELECT numero_seguimiento, estado, fecha_registro
FROM envios.envio
WHERE estado <> 'ENTREGADO';

2. ¿Quién es el remitente y el destinatario de un envío dado su número de seguimiento?

SELECT numero_seguimiento,
       remitente_nombre, remitente_telefono,
       destinatario_nombre, destinatario_telefono
FROM envios.envio
WHERE numero_seguimiento = 'ENV-20260914-UDQXT';

3. ¿Cuántos envíos hay en cada estado actualmente?

SELECT estado, COUNT(*) AS total
FROM envios.envio
GROUP BY estado
ORDER BY total DESC;

4. ¿Qué envíos fueron entregados en un periodo específico?

SELECT e.numero_seguimiento, ev.fecha_hora, ev.receptor
FROM eventos.evento ev
JOIN envios.envio e ON e.id = ev.envio_id
WHERE ev.tipo_evento = 'ENTREGADO'
  AND ev.fecha_hora >= '2026-09-01'
  AND ev.fecha_hora <  '2026-09-14';

5. ¿Cuál fue el último evento registrado para cada envío?

SELECT DISTINCT ON (ev.envio_id)
       ev.envio_id, e.numero_seguimiento, ev.tipo_evento, ev.fecha_hora
FROM eventos.evento ev
JOIN envios.envio e ON e.id = ev.envio_id
ORDER BY ev.envio_id, ev.fecha_hora DESC;
