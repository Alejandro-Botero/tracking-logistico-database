-- =====================================================================
-- pruebas.sql · Sprint 3
-- Prueba cada trigger y cada función documentada en el README (secciones 8 y 9).
--
-- Cómo correrlo: en una base creada con schema.sql, con el mismo usuario que
-- ejecutó schema.sql (el dueño de los objetos):
--     psql -d <base> -f pruebas.sql
-- Cada prueba imprime "OK ..." con RAISE NOTICE. Si algo falla, el script se
-- detiene con un error que empieza por "FALLO" o con un ASSERT. Todo se revierte
-- al final (ROLLBACK): no deja datos en la base.
-- =====================================================================

BEGIN;

SELECT catalogo.registrar_operador('op-prueba', 'Operador de prueba');

-- ---------------------------------------------------------------------
-- T6 · trg_transicion_coherente (catalogo.transicion_valida, HU-02)
-- ---------------------------------------------------------------------
DO $$
BEGIN
  INSERT INTO catalogo.transicion_valida (estado_origen, tipo_evento, estado_destino)
  VALUES ('REGISTRADO', 'LIBERACION', 'REGISTRADO');   -- el estado inicial no puede ser destino
  RAISE EXCEPTION 'FALLO: se aceptó una transición hacia el estado inicial';
EXCEPTION WHEN SQLSTATE '23514' THEN
  RAISE NOTICE 'OK trg_transicion_coherente (destino inicial): %', SQLERRM;
END $$;

DO $$
BEGIN
  INSERT INTO catalogo.transicion_valida (estado_origen, tipo_evento, estado_destino)
  VALUES ('ENTREGADO', 'LIBERACION', 'EN_TRANSITO');   -- un estado final no tiene salida
  RAISE EXCEPTION 'FALLO: se aceptó una transición desde un estado final';
EXCEPTION WHEN SQLSTATE '23514' THEN
  RAISE NOTICE 'OK trg_transicion_coherente (origen final): %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------
-- T2 · trg_envio_completo (envios.envio, HU-01): sin partes ni paquete se rechaza
-- ---------------------------------------------------------------------
DO $$
BEGIN
  INSERT INTO envios.envio (tipo_servicio, punto_origen_id, registrado_por)
  SELECT 'EXPRESS', id, 'op-prueba' FROM catalogo.punto_red WHERE codigo = 'PV-MED-01';
  SET CONSTRAINTS trg_envio_completo IMMEDIATE;        -- fuerza la revisión que haría el COMMIT
  RAISE EXCEPTION 'FALLO: se aceptó un envío sin remitente, destinatario ni paquete';
EXCEPTION WHEN SQLSTATE '23514' THEN
  RAISE NOTICE 'OK trg_envio_completo: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------
-- Envío de prueba completo (Medellín -> Bogotá, servicio EXPRESS)
-- actualizado_en arranca 2 días atrás para poder probar trg_envio_actualizado.
-- ---------------------------------------------------------------------
INSERT INTO envios.envio (id, tipo_servicio, punto_origen_id, registrado_por, actualizado_en)
SELECT '00000000-0000-0000-0000-0000000000a1', 'EXPRESS', id, 'op-prueba', now() - interval '2 days'
  FROM catalogo.punto_red WHERE codigo = 'PV-MED-01';

INSERT INTO envios.parte (envio_id, rol, nombre, telefono, direccion, ciudad_codigo) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'REMITENTE',    'Ana Remitente', '3001234567', 'Calle 10 # 5-20',    '05001'),
  ('00000000-0000-0000-0000-0000000000a1', 'DESTINATARIO', 'Luis Destino',  '3109876543', 'Carrera 7 # 72-41',  '11001');

INSERT INTO envios.paquete (envio_id, consecutivo, peso_kg, contenido)
VALUES ('00000000-0000-0000-0000-0000000000a1', 1, 2.500, 'Libros');

-- T2 (caso válido): con 2 partes y 1 paquete la revisión pasa
SET CONSTRAINTS trg_envio_completo IMMEDIATE;
SET CONSTRAINTS trg_envio_completo DEFERRED;

-- ---------------------------------------------------------------------
-- T1 · trg_envio_sla (HU-01): el envío se lleva el SLA vigente de su servicio
-- ---------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT horas_sla FROM envios.envio
           WHERE id = '00000000-0000-0000-0000-0000000000a1') = 24,
         'trg_envio_sla: un envío EXPRESS debe quedar con horas_sla = 24';
  RAISE NOTICE 'OK trg_envio_sla: horas_sla = 24';
END $$;

-- ---------------------------------------------------------------------
-- T3 · trg_envio_actualizado (HU-01): sella actualizado_en en cada UPDATE
-- ---------------------------------------------------------------------
UPDATE envios.envio
   SET punto_destino_id = (SELECT id FROM catalogo.punto_red WHERE codigo = 'CD-BOG')
 WHERE id = '00000000-0000-0000-0000-0000000000a1';

DO $$
BEGIN
  ASSERT (SELECT actualizado_en FROM envios.envio
           WHERE id = '00000000-0000-0000-0000-0000000000a1') = now(),
         'trg_envio_actualizado: actualizado_en debe quedar en now() tras el UPDATE';
  RAISE NOTICE 'OK trg_envio_actualizado';
END $$;

-- ---------------------------------------------------------------------
-- T4 · trg_evento_validar (HU-02)
-- ---------------------------------------------------------------------
-- a) transición no permitida: un envío REGISTRADO no admite ENTREGA
DO $$
BEGIN
  INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por, recibido_por)
  SELECT '00000000-0000-0000-0000-0000000000a1', 'ENTREGA', id, 'op-prueba', 'Luis Destino'
    FROM catalogo.punto_red WHERE codigo = 'PV-MED-01';
  RAISE EXCEPTION 'FALLO: se aceptó una ENTREGA sobre un envío REGISTRADO';
EXCEPTION WHEN SQLSTATE '23514' THEN
  RAISE NOTICE 'OK trg_evento_validar (transición no permitida): %', SQLERRM;
END $$;

-- b) evento anterior al registro del envío
DO $$
BEGIN
  INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por, ocurrido_en)
  SELECT '00000000-0000-0000-0000-0000000000a1', 'ADMISION', id, 'op-prueba', now() - interval '1 day'
    FROM catalogo.punto_red WHERE codigo = 'PV-MED-01';
  RAISE EXCEPTION 'FALLO: se aceptó un evento anterior al registro del envío';
EXCEPTION WHEN SQLSTATE '22007' THEN
  RAISE NOTICE 'OK trg_evento_validar (evento antes del registro): %', SQLERRM;
END $$;

-- c) recorrido normal hasta EN_REPARTO (un evento por sentencia)
INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por)
SELECT '00000000-0000-0000-0000-0000000000a1', 'ADMISION', id, 'op-prueba'
  FROM catalogo.punto_red WHERE codigo = 'PV-MED-01';
INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por)
SELECT '00000000-0000-0000-0000-0000000000a1', 'SALIDA_CENTRO', id, 'op-prueba'
  FROM catalogo.punto_red WHERE codigo = 'CD-MED';
INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por)
SELECT '00000000-0000-0000-0000-0000000000a1', 'LLEGADA_CENTRO', id, 'op-prueba'
  FROM catalogo.punto_red WHERE codigo = 'CD-BOG';
INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por)
SELECT '00000000-0000-0000-0000-0000000000a1', 'SALIDA_REPARTO', id, 'op-prueba'
  FROM catalogo.punto_red WHERE codigo = 'VEH-101';

-- d) la entrega exige quién recibió
DO $$
BEGIN
  INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por)
  SELECT '00000000-0000-0000-0000-0000000000a1', 'ENTREGA', id, 'op-prueba'
    FROM catalogo.punto_red WHERE codigo = 'VEH-101';
  RAISE EXCEPTION 'FALLO: se aceptó una ENTREGA sin constancia de quién recibió';
EXCEPTION WHEN SQLSTATE '23514' THEN
  RAISE NOTICE 'OK trg_evento_validar (entrega sin receptor): %', SQLERRM;
END $$;

INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por, recibido_por)
SELECT '00000000-0000-0000-0000-0000000000a1', 'ENTREGA', id, 'op-prueba', 'Luis Destino'
  FROM catalogo.punto_red WHERE codigo = 'VEH-101';

-- e) un envío en estado final no admite más eventos
DO $$
BEGIN
  INSERT INTO eventos.evento (envio_id, tipo_evento, punto_red_id, registrado_por, observaciones)
  SELECT '00000000-0000-0000-0000-0000000000a1', 'RETENCION', id, 'op-prueba', 'prueba'
    FROM catalogo.punto_red WHERE codigo = 'VEH-101';
  RAISE EXCEPTION 'FALLO: se aceptó un evento sobre un envío ya entregado';
EXCEPTION WHEN SQLSTATE '23514' THEN
  RAISE NOTICE 'OK trg_evento_validar (envío en estado final): %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------
-- T5 · trg_evento_aplicar_estado (HU-03): el envío refleja su último evento
-- ---------------------------------------------------------------------
DO $$
DECLARE v envios.envio%rowtype;
BEGIN
  SELECT * INTO v FROM envios.envio WHERE id = '00000000-0000-0000-0000-0000000000a1';
  ASSERT v.estado_actual = 'ENTREGADO', 'estado_actual debe ser ENTREGADO';
  ASSERT v.entregado_en IS NOT NULL AND v.entregado_en = v.cerrado_en, 'entregado_en debe ser igual a cerrado_en';
  ASSERT v.ultimo_evento_en IS NOT NULL AND v.admitido_en IS NOT NULL, 'ultimo_evento_en y admitido_en deben quedar llenos';
  ASSERT NOT EXISTS (SELECT 1 FROM eventos.v_envio_incoherente), 'v_envio_incoherente debe devolver cero filas';
  RAISE NOTICE 'OK trg_evento_aplicar_estado: ENTREGADO, caché coherente con el historial';
END $$;

-- ---------------------------------------------------------------------
-- T7 · trg_evento_inmutable (HU-04): el historial no se modifica ni se borra
-- ---------------------------------------------------------------------
DO $$
BEGIN
  UPDATE eventos.evento SET observaciones = 'cambio'
   WHERE envio_id = '00000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FALLO: se permitió modificar un evento';
EXCEPTION WHEN SQLSTATE '0A000' THEN
  RAISE NOTICE 'OK trg_evento_inmutable (UPDATE): %', SQLERRM;
END $$;

DO $$
BEGIN
  DELETE FROM eventos.evento WHERE envio_id = '00000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FALLO: se permitió borrar un evento';
EXCEPTION WHEN SQLSTATE '0A000' THEN
  RAISE NOTICE 'OK trg_evento_inmutable (DELETE): %', SQLERRM;
END $$;

-- =====================================================================
-- FUNCIONES
-- =====================================================================

-- F1 · gen_tracking_number() y tracking_valido() (HU-01)
DO $$
DECLARE v text;
BEGIN
  v := envios.gen_tracking_number();
  ASSERT envios.tracking_valido(v), 'gen_tracking_number() debe producir un número válido';
  ASSERT NOT envios.tracking_valido('FDX000000000000'), 'un dígito verificador errado debe rechazarse';
  ASSERT NOT envios.tracking_valido('ABC123'), 'un formato errado debe rechazarse';
  RAISE NOTICE 'OK gen_tracking_number / tracking_valido: %', v;
END $$;

-- F2 · sla_horas() (HU-01 y HU-05)
DO $$
BEGIN
  ASSERT catalogo.sla_horas('EXPRESS') = 24, 'EXPRESS = 24 h';
  ASSERT catalogo.sla_horas('ESTANDAR', '2026-03-01') = 96, 'ESTANDAR antes de julio = 96 h';
  ASSERT catalogo.sla_horas('ESTANDAR', '2026-08-01') = 72, 'ESTANDAR desde julio = 72 h';
  ASSERT catalogo.sla_horas('NO_EXISTE') IS NULL, 'un servicio sin SLA devuelve NULL';
  RAISE NOTICE 'OK sla_horas';
END $$;

-- F3 · rastrear() (HU-03): número + 4 últimos dígitos del teléfono o documento del destinatario
DO $$
DECLARE v_t text;
BEGIN
  SELECT tracking_number INTO v_t FROM envios.envio WHERE id = '00000000-0000-0000-0000-0000000000a1';
  ASSERT (SELECT count(*) FROM envios.rastrear(v_t, '6543')) = 1, 'con el segundo factor correcto devuelve 1 fila';
  ASSERT (SELECT count(*) FROM envios.rastrear(v_t, '0000')) = 0, 'con un segundo factor errado devuelve 0 filas';
  ASSERT (SELECT count(*) FROM envios.rastrear(v_t, '65'))   = 0, 'con un factor de longitud distinta de 4 devuelve 0 filas';
  ASSERT (SELECT estado_codigo FROM envios.rastrear(v_t, '6543')) = 'ENTREGADO', 'el estado debe ser ENTREGADO';
  RAISE NOTICE 'OK rastrear';
END $$;

-- F4 · registrar_operador() (HU-02 y HU-08): alta idempotente
DO $$
BEGIN
  ASSERT catalogo.registrar_operador('op-prueba-2', 'Primer nombre') = 'op-prueba-2';
  ASSERT catalogo.registrar_operador('op-prueba-2') = 'op-prueba-2', 'repetir la llamada no falla';
  ASSERT (SELECT nombre FROM catalogo.operador WHERE codigo = 'op-prueba-2') = 'Primer nombre',
         'una llamada sin nombre no borra el nombre guardado';
  RAISE NOTICE 'OK registrar_operador';
END $$;

-- F5 · refrescar_reportes() (HU-07)
DO $$
BEGIN
  PERFORM eventos.refrescar_reportes();
  ASSERT (SELECT coalesce(sum(envios_registrados), 0) FROM eventos.v_volumen_registro WHERE dia = current_date) >= 1,
         'tras refrescar, el envío de prueba debe contarse en el volumen de hoy';
  RAISE NOTICE 'OK refrescar_reportes';
END $$;

-- F6 · verificar_rls(): cero filas = seguridad sana
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM catalogo.verificar_rls()), 'verificar_rls() debe devolver cero filas';
  RAISE NOTICE 'OK verificar_rls';
END $$;

ROLLBACK;
