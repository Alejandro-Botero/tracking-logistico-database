-- =============================================================
-- Consultas de referencia sobre envios.envio
-- Microservicio: ms-envios
-- =============================================================

-- -------------------------------------------------------------
-- 1. Consultar un envio por su numero de seguimiento (HU-03)
-- Es la consulta principal del microservicio: dado un numero de
-- seguimiento, devuelve el estado actual y la fecha de registro.
-- -------------------------------------------------------------
SELECT numero_seguimiento, estado, fecha_registro
FROM envios.envio
WHERE numero_seguimiento = 'ENV-20260914-UDQXT';


-- -------------------------------------------------------------
-- 2. Listar los envios mas recientes primero
-- Util para revisar rapidamente la actividad reciente del
-- microservicio (por ejemplo, para verificar pruebas o demos).
-- -------------------------------------------------------------
SELECT numero_seguimiento, remitente_nombre, destinatario_nombre, estado, fecha_registro
FROM envios.envio
ORDER BY fecha_registro DESC
LIMIT 20;


-- -------------------------------------------------------------
-- 3. Contar cuantos envios hay por cada estado
-- Sirve como base para reportes de operacion (cuantos envios
-- estan registrados, en transito, entregados, etc. a medida
-- que el catalogo de estados crezca en proximos sprints).
-- -------------------------------------------------------------
SELECT estado, COUNT(*) AS cantidad
FROM envios.envio
GROUP BY estado
ORDER BY cantidad DESC;


-- -------------------------------------------------------------
-- 4. Buscar envios registrados en un rango de fechas
-- Util para auditorias o para ver cuantos envios entraron al
-- sistema en un periodo especifico (por ejemplo, un dia de pruebas).
-- -------------------------------------------------------------
SELECT numero_seguimiento, remitente_nombre, destinatario_nombre, fecha_registro
FROM envios.envio
WHERE fecha_registro BETWEEN '2026-09-13 00:00:00' AND '2026-09-14 23:59:59'
ORDER BY fecha_registro;


-- -------------------------------------------------------------
-- 5. Buscar envios por nombre de remitente o destinatario
-- Busqueda de texto parcial (case-insensitive) sobre los nombres,
-- util para ubicar un envio cuando no se tiene el numero de
-- seguimiento a la mano.
-- -------------------------------------------------------------
SELECT numero_seguimiento, remitente_nombre, destinatario_nombre, estado
FROM envios.envio
WHERE remitente_nombre ILIKE '%ana%'
   OR destinatario_nombre ILIKE '%ana%';
