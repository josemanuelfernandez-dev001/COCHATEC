# Pocket Card MVP — Contexto técnico de implementación

### 1. Visión general del sistema

Pocket es una billetera digital del ecosistema VIVA/ALVA. El MVP introduce una tarjeta virtual prepagada (Pocket Card) como puente entre el saldo en bolivianos de la billetera y los pagos cotidianos, conectando ese flujo con los beneficios del ecosistema VIVA (puntos ALVA OMG, megas, Gift Cards).

El loop central de valor es:

`usuario carga saldo BOB → activa Pocket Card → paga (QR/online)
→ genera puntos + megas + cashback según tier → canjea Gift Cards
o convierte puntos ALVA OMG en saldo de tarjeta`

Stack: Flutter (frontend) + PostgreSQL (BD) + backend REST a definir (Node/Express o FastAPI).

---

### 2. Modelo de datos — qué representa cada tabla

`users` — identidad del usuario. El campo `kyc_nivel` (0, 1, 2) es el gobernador maestro de qué puede hacer. `modo_facil` activa la UI simplificada.

`wallets` — única por usuario, contiene `saldo_bob`, `saldo_viva` y `puntos` (puntos Pocket propios, distintos de los puntos ALVA OMG que viven en `viva_link`).

`cards` — una tarjeta virtual por usuario. `tier` define los beneficios. `saldo_disponible` es lo gastable de la tarjeta (alimentado desde `wallets.saldo_bob`). `limite_mensual` y `consumo_mes` controlan el techo mensual.

`viva_link` — representa el vínculo simulado con una línea VIVA. Guarda `megas_acumuladas` (megas ganadas por pagar con tarjeta tier VIVA) y `puntos_alva_omg` (puntos del ecosistema ALVA, convertibles a puntos Pocket).

`transactions` — log de cada operación con la tarjeta. Cada transacción registra el monto, el tipo, y los beneficios que generó (`puntos_generados`, `megas_generadas`, `cashback_viva`). Esto se calcula en backend al momento del pago y se guarda para auditoría e historial.

`points_log` — historial detallado de movimientos de puntos. Cada cambio de puntos (positivo o negativo) deja registro con su origen. Permite mostrar "de dónde vino cada punto" en la UI.

`gift_cards_catalog` — catálogo seeded con 5 opciones (Bs 25, 50, 100, 200, 500) y su costo en puntos.

`rewards` — cada canje de gift card hecho por un usuario. Genera un `codigo_canje` único.

---

### 3. Reglas de negocio (todas viven en el backend, no en la BD)

### 3.1 Niveles KYC y permisos

| Nivel | Cómo se alcanza | Qué desbloquea |
| --- | --- | --- |
| 0 | Registro inicial sin verificación | Recibir saldo, ver wallet |
| 1 | Vincula línea VIVA (datos pre-cargados) o KYC básico manual | Activar Pocket Card Basic, pagar con tarjeta, canjear Gift Cards |
| 2 | KYC completo con CI + selfie | Tarjeta tier VIVA, límites mensuales más altos |

Cuando un usuario vincula su línea VIVA y está en `kyc_nivel = 0`, el backend lo sube automáticamente a `kyc_nivel = 1` y otorga un bono inicial de puntos (registrado en `points_log` con `origen = 'bono_vinculacion'`).

### 3.2 Activación de la tarjeta

Cuando un usuario solicita activar su tarjeta:

- Si tiene `viva_link` registrado → tier se asigna como `'viva'`, límite mensual Bs 5.000
- Si no tiene línea vinculada → tier `'basic'`, límite mensual Bs 2.000
- `numero_virtual` se genera con un prefijo fijo (ej. `4000`) + 12 dígitos aleatorios
- `saldo_disponible` arranca en 0 hasta que el usuario cargue saldo desde su wallet

### 3.3 Cálculo de beneficios por transacción

Esta es la lógica central del backend al procesar un pago con tarjeta:

`Si tier = 'viva':
  puntos_generados = monto * 2          (2 puntos por cada Bs)
  megas_generadas  = monto * 0.5        (0.5 MB por cada Bs)
  cashback_viva    = monto * 0.01       (1% del monto en $VIVA)

Si tier = 'basic':
  puntos_generados = monto * 1          (1 punto por cada Bs)
  megas_generadas  = 0
  cashback_viva    = 0`

### 3.4 Flujo transaccional de un pago (operación atómica)

Cada pago debe ejecutarse en una **transacción de BD** que asegure consistencia. Si cualquier paso falla, todo se revierte:

1. Validar `cards.activa = TRUE` y `cards.saldo_disponible >= monto`
2. Validar `cards.consumo_mes + monto <= cards.limite_mensual`
3. Validar `users.kyc_nivel >= 1` para tarjeta basic, `>= 2` para tier viva si aplica
4. Calcular `puntos_generados`, `megas_generadas`, `cashback_viva` según tier
5. `UPDATE cards SET saldo_disponible = saldo_disponible - monto, consumo_mes = consumo_mes + monto WHERE id = ?`
6. `INSERT INTO transactions (...)` con todos los valores calculados
7. `UPDATE wallets SET puntos = puntos + puntos_generados, saldo_viva = saldo_viva + cashback_viva WHERE user_id = ?`
8. Si `tier = 'viva'`: `UPDATE viva_link SET megas_acumuladas = megas_acumuladas + megas_generadas WHERE user_id = ?`
9. `INSERT INTO points_log (origen='pago_tarjeta', delta_puntos=puntos_generados, transaction_id=...)`
10. `COMMIT`

### 3.5 Carga de saldo de tarjeta desde wallet

Operación atómica:

1. Validar `wallets.saldo_bob >= monto_a_cargar`
2. `UPDATE wallets SET saldo_bob = saldo_bob - monto_a_cargar`
3. `UPDATE cards SET saldo_disponible = saldo_disponible + monto_a_cargar`
4. `INSERT INTO transactions (tipo='carga_saldo', monto, puntos_generados=0, ...)` para que aparezca en el historial
5. `COMMIT`

### 3.6 Conversión de puntos ALVA OMG → puntos Pocket

Ratio configurable (ej. 100 ALVA = 50 Pocket). Operación atómica:

1. Validar `viva_link.puntos_alva_omg >= cantidad_alva`
2. Calcular `puntos_pocket_resultado = cantidad_alva * ratio`
3. `UPDATE viva_link SET puntos_alva_omg = puntos_alva_omg - cantidad_alva`
4. `UPDATE wallets SET puntos = puntos + puntos_pocket_resultado`
5. `INSERT INTO points_log (origen='conversion_alva', delta_puntos=+pocket, delta_puntos_alva=-alva)`
6. `INSERT INTO transactions (tipo='conversion_puntos', ...)` para trazabilidad
7. `COMMIT`

### 3.7 Canje de Gift Card

Operación atómica:

1. Obtener `gift_card.costo_puntos` del catálogo
2. Validar `wallets.puntos >= costo_puntos` y `gift_card.activa = TRUE`
3. Generar `codigo_canje` único (formato sugerido: `GC-XXXX-XXXX` aleatorio)
4. `UPDATE wallets SET puntos = puntos - costo_puntos`
5. `INSERT INTO rewards (user_id, gift_card_catalog_id, puntos_usados, codigo_canje)`
6. `INSERT INTO points_log (origen='canje_gift_card', delta_puntos=-costo)`
7. `COMMIT` y devolver `codigo_canje` al frontend para mostrarlo

### 3.8 Reset mensual de consumo

Job programado el día 1 de cada mes a las 00:00:

sql

`UPDATE cards SET consumo_mes = 0;`

En el MVP esto puede hacerse con un endpoint manual `POST /admin/reset-monthly` que el equipo dispara antes de la demo.

---

### 4. Endpoints sugeridos del backend

Los nombres son orientativos. El stack final decidirá la implementación, pero la responsabilidad de cada uno es clara:

**Autenticación**

- `POST /auth/register` — crea usuario, wallet (saldos en 0), kyc_nivel = 0
- `POST /auth/login` — devuelve token + datos básicos del usuario
- `POST /auth/verify-pin` — para confirmar pagos

**Usuario y home**

- `GET /me/home` — consume `v_user_home`, devuelve todo lo necesario para el home
- `PATCH /me/modo-facil` — toggle del modo fácil
- `POST /me/vincular-viva` — registra línea VIVA, sube kyc_nivel a 1 si era 0

**Tarjeta**

- `POST /card/activate` — crea la tarjeta según tier correspondiente
- `POST /card/load` — carga saldo desde wallet hacia tarjeta
- `GET /card/details` — info de la tarjeta

**Transacciones**

- `POST /transactions/pay` — endpoint maestro, aplica toda la lógica de la sección 3.4
- `GET /transactions/history` — consume `v_transaction_history` paginado

**Puntos y canjes**

- `GET /points/log` — historial de movimientos de puntos
- `POST /points/convert-alva` — conversión ALVA OMG → Pocket
- `GET /gift-cards/catalog` — catálogo
- `POST /gift-cards/redeem` — canje
- `GET /me/rewards` — gift cards canjeadas

---

### 5. Datos derivados — qué calcular y dónde

**Calcular en backend, no guardar:**

- "Próximo premio disponible" — depende del catálogo y del saldo actual de puntos
- "Total ganado este mes" — `SUM(puntos_generados) FROM transactions WHERE fecha >= primer_día_mes`
- "Megas ganadas hoy" — agrupación por fecha sobre `transactions`

**Guardar siempre:**

- Cada transacción con sus beneficios ya calculados (no recalcular después con la regla actual — los porcentajes pueden cambiar y las transacciones viejas deben mantener su valor histórico)
- Cada movimiento de puntos en `points_log`

---

### 6. Aspectos críticos a respetar

**Consistencia financiera.** Todos los flujos que tocan dinero (pago, carga, canje, conversión) deben ser transacciones atómicas con `BEGIN/COMMIT/ROLLBACK`. Si un `UPDATE` falla, ningún paso anterior debe haberse aplicado. Esto no es opcional.

**Precisión decimal.** Nunca usar `FLOAT` o `REAL` para dinero. `NUMERIC(12,2)` para BOB, `NUMERIC(18,8)` para $VIVA/USDT. Las operaciones aritméticas en PostgreSQL preservan precisión correctamente con `NUMERIC`.

**Validaciones en dos capas.** Backend valida saldos, límites y KYC antes de cada operación. La BD valida con `CHECK constraints` como red de seguridad. No confiar solo en una capa.

**PIN nunca en claro.** El campo `pin` está como `VARCHAR(255)` pensando en hash bcrypt/argon2. En desarrollo puede guardarse plano para demo rápida, pero el código debe estar preparado para hashing.

**Idempotencia de canjes.** El `codigo_canje` debe ser único. Si el usuario hace doble-tap en "canjear", el segundo intento debe fallar limpiamente (la `UNIQUE constraint` lo bloquea).

**Manejo del `consumo_mes`.** En el MVP basta con resetear vía endpoint manual o seed. En producción se vuelve un cron job.

---

### 7. Flujo de demo completo (qué debe demostrar el MVP)

`1. Registro → usuario llega con kyc_nivel = 0, wallet en 0
2. Vincula línea VIVA → kyc_nivel sube a 1, recibe bono de puntos
3. Carga saldo BOB en wallet (simulado vía endpoint, sin pasarela real)
4. Activa Pocket Card → tier 'viva' por estar vinculado
5. Transfiere saldo de wallet a tarjeta
6. Hace 2-3 pagos con la tarjeta (montos varios)
7. Ve en el home: puntos crecieron, megas crecieron, cashback en $VIVA
8. Convierte puntos ALVA OMG → puntos Pocket
9. Canjea una Gift Card → recibe código de canje
10. Revisa historial completo con todos los movimientos`

Este flujo es lo que se le mostrará al jurado en la demo. La UI debe permitir hacer cada paso en menos de 30 segundos cada uno.

---

### 8. Lo que NO está en el MVP

Para mantener el scope, estas cosas quedan fuera y el código no debe asumirlas:

- KYC real con foto y reconocimiento facial (solo simulado por nivel)
- Integración real con APIs de VIVA o ALVA OMG (todo simulado en `viva_link`)
- Pasarela de pago real (la carga de saldo es vía endpoint directo)
- QR escaneable real (el "pago QR" es un formulario donde se ingresa monto)
- Pasanaku, modo offline, asistente IA TATA, mascota, racha, misión, ruleta
- Notificaciones push reales
- Comercios identificables (todas las transacciones son genéricas)