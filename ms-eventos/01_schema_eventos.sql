-- =============================================================
-- Schema y tabla del modulo eventos (monolito modular)
-- Proyecto: Fabrica Escuela - Sprint 1
-- Historia de usuario cubierta: HU-02 (Registrar un evento logistico)
--
-- Requiere que 01_schema_envios.sql ya haya corrido (crea envios.envio
-- y app_user).
-- =============================================================

CREATE SCHEMA IF NOT EXISTS eventos;

CREATE TABLE eventos.evento (
    id              BIGSERIAL PRIMARY KEY,
    envio_id        BIGINT NOT NULL REFERENCES envios.envio(id),
    tipo_evento     VARCHAR(30) NOT NULL
                    CHECK (tipo_evento IN ('RECOGIDO', 'EN_TRANSITO', 'EN_CENTRO_DISTRIBUCION', 'ENTREGADO')),
    punto           VARCHAR(150),
    fecha_hora      TIMESTAMP NOT NULL DEFAULT now(),
    receptor        VARCHAR(150),
    -- HU-02: la entrega exige constancia de quien recibio.
    CHECK (tipo_evento <> 'ENTREGADO' OR receptor IS NOT NULL)
);

CREATE INDEX idx_evento_envio_id ON eventos.evento (envio_id);

ALTER TABLE eventos.evento DISABLE ROW LEVEL SECURITY;

GRANT USAGE ON SCHEMA eventos TO app_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA eventos TO app_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA eventos TO app_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA eventos GRANT ALL ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA eventos GRANT ALL ON SEQUENCES TO app_user;
