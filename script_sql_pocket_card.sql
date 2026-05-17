-- ============================================================
-- POCKET CARD MVP — Esquema PostgreSQL
-- ============================================================

-- ============================================================
-- Función reutilizable para updated_at automático
-- ============================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- TABLA: users
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
  id            SERIAL PRIMARY KEY,
  nombre        VARCHAR(120) NOT NULL,
  ci            VARCHAR(20) UNIQUE NOT NULL,
  telefono      VARCHAR(20) UNIQUE NOT NULL,
  pin           VARCHAR(255) NOT NULL,
  kyc_nivel     SMALLINT NOT NULL DEFAULT 0
                CHECK (kyc_nivel IN (0, 1, 2)),
  modo_facil    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_ci       ON users(ci);
CREATE INDEX IF NOT EXISTS idx_users_telefono ON users(telefono);


-- ============================================================
-- TABLA: wallets
-- ============================================================
CREATE TABLE IF NOT EXISTS wallets (
  id          SERIAL PRIMARY KEY,
  user_id     INTEGER NOT NULL UNIQUE
              REFERENCES users(id) ON DELETE CASCADE,
  saldo_bob   NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (saldo_bob >= 0),
  saldo_viva  NUMERIC(18, 8) NOT NULL DEFAULT 0 CHECK (saldo_viva >= 0),
  puntos      INTEGER NOT NULL DEFAULT 0 CHECK (puntos >= 0),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallets_user_id ON wallets(user_id);

CREATE TRIGGER trg_wallets_updated_at
  BEFORE UPDATE ON wallets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ============================================================
-- TABLA: cards
-- ============================================================
CREATE TABLE IF NOT EXISTS cards (
  id               SERIAL PRIMARY KEY,
  user_id          INTEGER NOT NULL UNIQUE
                   REFERENCES users(id) ON DELETE CASCADE,
  numero_virtual   VARCHAR(16) NOT NULL UNIQUE,
  tier             VARCHAR(10) NOT NULL DEFAULT 'basic'
                   CHECK (tier IN ('basic', 'viva')),
  saldo_disponible NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (saldo_disponible >= 0),
  limite_mensual   NUMERIC(12, 2) NOT NULL DEFAULT 2000,
  consumo_mes      NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (consumo_mes >= 0),
  activa           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cards_user_id ON cards(user_id);


-- ============================================================
-- TABLA: viva_link
-- Simula la línea VIVA vinculada al usuario dentro de Pocket.
-- No es una BD separada — es la representación de ese vínculo.
-- ============================================================
CREATE TABLE IF NOT EXISTS viva_link (
  id                  SERIAL PRIMARY KEY,
  user_id             INTEGER NOT NULL UNIQUE
                      REFERENCES users(id) ON DELETE CASCADE,
  numero_linea        VARCHAR(20) NOT NULL,
  tipo_plan           VARCHAR(20) NOT NULL DEFAULT 'prepago'
                      CHECK (tipo_plan IN ('prepago', 'postpago')),
  megas_acumuladas    NUMERIC(10, 3) NOT NULL DEFAULT 0 CHECK (megas_acumuladas >= 0),
  puntos_alva_omg     INTEGER NOT NULL DEFAULT 0 CHECK (puntos_alva_omg >= 0),
  vinculado_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_viva_link_user_id ON viva_link(user_id);


-- ============================================================
-- TABLA: transactions
-- ============================================================
CREATE TABLE IF NOT EXISTS transactions (
  id                 SERIAL PRIMARY KEY,
  user_id            INTEGER NOT NULL
                     REFERENCES users(id) ON DELETE CASCADE,
  card_id            INTEGER
                     REFERENCES cards(id) ON DELETE SET NULL,
  tipo               VARCHAR(30) NOT NULL
                     CHECK (tipo IN (
                       'pago_qr',
                       'pago_online',
                       'carga_saldo',
                       'cashback',
                       'conversion_puntos',
                       'conversion_megas'
                     )),
  monto              NUMERIC(12, 2) NOT NULL CHECK (monto > 0),
  moneda             VARCHAR(10) NOT NULL DEFAULT 'BOB'
                     CHECK (moneda IN ('BOB', '$VIVA', 'USDT')),
  puntos_generados   INTEGER NOT NULL DEFAULT 0,
  megas_generadas    NUMERIC(10, 3) NOT NULL DEFAULT 0,
  cashback_viva      NUMERIC(18, 8) NOT NULL DEFAULT 0,
  fecha              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_transactions_user_fecha
  ON transactions(user_id, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_transactions_card_id
  ON transactions(card_id);


-- ============================================================
-- TABLA: points_log
-- Historial detallado de cada movimiento de puntos.
-- delta positivo = ganó puntos / delta negativo = gastó puntos
-- ============================================================
CREATE TABLE IF NOT EXISTS points_log (
  id                 SERIAL PRIMARY KEY,
  user_id            INTEGER NOT NULL
                     REFERENCES users(id) ON DELETE CASCADE,
  transaction_id     INTEGER
                     REFERENCES transactions(id) ON DELETE SET NULL,
  origen             VARCHAR(30) NOT NULL
                     CHECK (origen IN (
                       'pago_tarjeta',
                       'canje_gift_card',
                       'conversion_alva',
                       'bono_vinculacion',
                       'bono_kyc'
                     )),
  delta_puntos       INTEGER NOT NULL DEFAULT 0,
  delta_puntos_alva  INTEGER NOT NULL DEFAULT 0,
  fecha              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_points_log_user_fecha
  ON points_log(user_id, fecha DESC);


-- ============================================================
-- TABLA: gift_cards_catalog
-- Catálogo de gift cards canjeables con puntos Pocket.
-- ============================================================
CREATE TABLE IF NOT EXISTS gift_cards_catalog (
  id            SERIAL PRIMARY KEY,
  nombre        VARCHAR(100) NOT NULL,
  valor_bob     NUMERIC(10, 2) NOT NULL CHECK (valor_bob > 0),
  costo_puntos  INTEGER NOT NULL CHECK (costo_puntos > 0),
  activa        BOOLEAN NOT NULL DEFAULT TRUE
);


-- ============================================================
-- TABLA: rewards
-- Cada canje de gift card realizado por un usuario.
-- ============================================================
CREATE TABLE IF NOT EXISTS rewards (
  id                    SERIAL PRIMARY KEY,
  user_id               INTEGER NOT NULL
                        REFERENCES users(id) ON DELETE CASCADE,
  gift_card_catalog_id  INTEGER NOT NULL
                        REFERENCES gift_cards_catalog(id) ON DELETE RESTRICT,
  puntos_usados         INTEGER NOT NULL CHECK (puntos_usados > 0),
  codigo_canje          VARCHAR(20) NOT NULL UNIQUE,
  canjeada              BOOLEAN NOT NULL DEFAULT FALSE,
  fecha                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rewards_user_id ON rewards(user_id);
CREATE INDEX IF NOT EXISTS idx_rewards_codigo  ON rewards(codigo_canje);


-- ============================================================
-- VISTA: v_user_home
-- Todo lo necesario para el home en una sola query.
-- ============================================================
CREATE OR REPLACE VIEW v_user_home AS
SELECT
  u.id                      AS user_id,
  u.nombre,
  u.kyc_nivel,
  u.modo_facil,
  w.saldo_bob,
  w.saldo_viva,
  w.puntos,
  c.numero_virtual,
  c.tier,
  c.saldo_disponible        AS card_saldo,
  c.limite_mensual          AS card_limite,
  c.consumo_mes             AS card_consumo_mes,
  c.activa                  AS card_activa,
  vl.numero_linea,
  vl.tipo_plan,
  vl.megas_acumuladas,
  vl.puntos_alva_omg
FROM users u
JOIN    wallets   w  ON w.user_id  = u.id
LEFT JOIN cards   c  ON c.user_id  = u.id
LEFT JOIN viva_link vl ON vl.user_id = u.id;


-- ============================================================
-- VISTA: v_transaction_history
-- Historial enriquecido para mostrar en la app.
-- ============================================================
CREATE OR REPLACE VIEW v_transaction_history AS
SELECT
  t.id,
  t.user_id,
  t.tipo,
  t.monto,
  t.moneda,
  t.puntos_generados,
  t.megas_generadas,
  t.cashback_viva,
  t.fecha,
  c.tier AS card_tier
FROM transactions t
LEFT JOIN cards c ON c.id = t.card_id
ORDER BY t.fecha DESC;


-- ============================================================
-- SEED: catálogo de gift cards
-- ============================================================
INSERT INTO gift_cards_catalog (nombre, valor_bob, costo_puntos, activa)
VALUES
  ('Gift Card Bs 25',  25,   500,  TRUE),
  ('Gift Card Bs 50',  50,   900,  TRUE),
  ('Gift Card Bs 100', 100,  1700, TRUE),
  ('Gift Card Bs 200', 200,  3200, TRUE),
  ('Gift Card Bs 500', 500,  7500, TRUE)
ON CONFLICT DO NOTHING;


-- ============================================================
-- SEED: usuario demo para desarrollo
-- PIN: 1234 (en producción siempre hashear con bcrypt/argon2)
-- ============================================================
INSERT INTO users (nombre, ci, telefono, pin, kyc_nivel)
VALUES ('Demo Pocket', '12345678', '70000001', '1234', 2)
ON CONFLICT DO NOTHING;

INSERT INTO wallets (user_id, saldo_bob, saldo_viva, puntos)
SELECT id, 500.00, 50.00000000, 1200
FROM users WHERE ci = '12345678'
ON CONFLICT DO NOTHING;

INSERT INTO cards (user_id, numero_virtual, tier, saldo_disponible, limite_mensual)
SELECT id, '4000000000000001', 'viva', 500.00, 5000.00
FROM users WHERE ci = '12345678'
ON CONFLICT DO NOTHING;

INSERT INTO viva_link (user_id, numero_linea, tipo_plan, megas_acumuladas, puntos_alva_omg)
SELECT id, '71234567', 'postpago', 120.500, 850
FROM users WHERE ci = '12345678'
ON CONFLICT DO NOTHING;


-- ============================================================
-- RESET (solo para desarrollo — descomenta cuando necesites)
-- ============================================================
-- DROP VIEW IF EXISTS v_transaction_history CASCADE;
-- DROP VIEW IF EXISTS v_user_home CASCADE;
-- DROP TABLE IF EXISTS rewards CASCADE;
-- DROP TABLE IF EXISTS gift_cards_catalog CASCADE;
-- DROP TABLE IF EXISTS points_log CASCADE;
-- DROP TABLE IF EXISTS transactions CASCADE;
-- DROP TABLE IF EXISTS viva_link CASCADE;
-- DROP TABLE IF EXISTS cards CASCADE;
-- DROP TABLE IF EXISTS wallets CASCADE;
-- DROP TABLE IF EXISTS users CASCADE;
-- DROP FUNCTION IF EXISTS set_updated_at CASCADE;