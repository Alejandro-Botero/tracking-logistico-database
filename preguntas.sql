1. ¿Qué envíos siguen activos (sin cerrar) en la red?

SELECT tracking_number, estado_actual, registrado_en
FROM envios.envio
WHERE cerrado_en IS NULL;

2. ¿Quién es el remitente y el destinatario de un envío dado su número de seguimiento?

SELECT e.tracking_number, p.rol, p.nombre, p.telefono
FROM envios.envio e
JOIN envios.parte p ON p.envio_id = e.id
WHERE e.tracking_number = 'FDX000000000001';

3. ¿Cuántos envíos hay en cada estado actualmente?

SELECT estado_actual, COUNT(*) AS total
FROM envios.envio
GROUP BY estado_actual
ORDER BY total DESC;

4. ¿Qué envíos fueron entregados en un periodo específico?

SELECT tracking_number, ocurrido_en, recibido_por
FROM eventos.evento
WHERE tipo_evento = 'ENTREGADO'
  AND ocurrido_en >= '2026-09-01'
  AND ocurrido_en <  '2026-09-14';

5. ¿Cuál fue el último evento registrado para cada envío?

SELECT DISTINCT ON (envio_id) envio_id, tracking_number, tipo_evento, ocurrido_en
FROM eventos.evento
ORDER BY envio_id, ocurrido_en DESC;
