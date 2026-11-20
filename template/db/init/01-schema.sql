-- =====================================================================
-- Base de datos del cliente (una por cliente).
--   * schema "evolution": lo crea y migra Evolution API sola (sesión de WhatsApp).
--   * schema "public":    datos del chatbot (este archivo).
-- Se ejecuta solo la primera vez que se crea el volumen de Postgres.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS evolution;

-- Configuración del bot (una sola fila, id = 1). Editable desde n8n o SQL.
CREATE TABLE IF NOT EXISTS bot_config (
    id                   smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    business_name        text        NOT NULL DEFAULT 'Mi negocio',
    system_prompt        text        NOT NULL DEFAULT
        'Sos el asistente virtual de WhatsApp de {{negocio}}. Respondé en español rioplatense, '
        'breve y amable (máximo 3 oraciones). Usá solo la información del negocio que se te da. '
        'Si no sabés algo o el cliente pide hablar con una persona, decí que en breve lo atiende alguien del equipo.',
    ai_provider          text        NOT NULL DEFAULT 'ollama',      -- ollama | anthropic | openai (los pagos se agregan al final)
    ai_model             text        NOT NULL DEFAULT 'llama3.2:3b',
    history_limit        int         NOT NULL DEFAULT 12,            -- mensajes previos que ve la IA
    human_pause_minutes  int         NOT NULL DEFAULT 60,            -- pausa del bot cuando el dueño responde desde el celu
    active               boolean     NOT NULL DEFAULT true,          -- apagado general del bot
    updated_at           timestamptz NOT NULL DEFAULT now()
);
INSERT INTO bot_config (id) VALUES (1) ON CONFLICT DO NOTHING;

-- Información del negocio que se le pasa a la IA (horarios, precios, FAQ, catálogo...).
CREATE TABLE IF NOT EXISTS knowledge (
    id         serial PRIMARY KEY,
    title      text NOT NULL,
    content    text NOT NULL,
    enabled    boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS contacts (
    jid          text PRIMARY KEY,            -- id de WhatsApp (xxx@s.whatsapp.net o xxx@lid)
    name         text,
    phone        text,
    paused_until timestamptz,                 -- si > now() el bot no responde a este contacto
    bot_enabled  boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS messages (
    id         bigserial PRIMARY KEY,
    jid        text NOT NULL REFERENCES contacts(jid) ON DELETE CASCADE,
    direction  text NOT NULL CHECK (direction IN ('in', 'out')),
    source     text NOT NULL CHECK (source IN ('contact', 'bot', 'owner')),
    content    text NOT NULL,
    wa_id      text UNIQUE,                   -- id del mensaje en WhatsApp (evita duplicados)
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS messages_jid_created_idx ON messages (jid, created_at DESC);

-- ---------------------------------------------------------------------
-- bot_ingest: guarda un mensaje entrante y devuelve todo el contexto que
-- n8n necesita para decidir si responder y armar el prompt.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_ingest(p_jid text, p_name text, p_text text, p_wa_id text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_new     boolean;
    v_cfg     bot_config%ROWTYPE;
    v_contact contacts%ROWTYPE;
    v_history jsonb;
    v_know    text;
BEGIN
    INSERT INTO contacts (jid, name, phone, last_seen)
    VALUES (p_jid, NULLIF(p_name, ''),
            CASE WHEN p_jid LIKE '%@s.whatsapp.net' THEN split_part(p_jid, '@', 1) END, now())
    ON CONFLICT (jid) DO UPDATE
        SET name = COALESCE(NULLIF(EXCLUDED.name, ''), contacts.name),
            last_seen = now();

    SELECT * INTO v_cfg FROM bot_config WHERE id = 1;
    SELECT * INTO v_contact FROM contacts WHERE jid = p_jid;

    -- Historial ANTES de insertar el mensaje actual (en orden cronológico).
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'role', CASE WHEN h.direction = 'in' THEN 'user' ELSE 'assistant' END,
               'content', h.content) ORDER BY h.created_at, h.id), '[]'::jsonb)
      INTO v_history
      FROM (SELECT * FROM messages WHERE jid = p_jid
            ORDER BY created_at DESC, id DESC LIMIT v_cfg.history_limit) h;

    INSERT INTO messages (jid, direction, source, content, wa_id)
    VALUES (p_jid, 'in', 'contact', p_text, NULLIF(p_wa_id, ''))
    ON CONFLICT (wa_id) DO NOTHING;
    v_new := FOUND;

    SELECT string_agg('## ' || title || E'\n' || content, E'\n\n' ORDER BY id)
      INTO v_know FROM knowledge WHERE enabled;

    RETURN jsonb_build_object(
        'jid',           p_jid,
        'text',          p_text,
        'name',          v_contact.name,
        'is_new',        v_new,
        'paused',        COALESCE(v_contact.paused_until > now(), false),
        'should_reply',  v_new AND v_cfg.active AND v_contact.bot_enabled
                         AND NOT COALESCE(v_contact.paused_until > now(), false),
        'business_name', v_cfg.business_name,
        'system_prompt', replace(v_cfg.system_prompt, '{{negocio}}', v_cfg.business_name),
        'ai_provider',   v_cfg.ai_provider,
        'ai_model',      v_cfg.ai_model,
        'knowledge',     COALESCE(v_know, ''),
        'history',       v_history
    );
END $$;

-- ---------------------------------------------------------------------
-- bot_save_reply: guarda la respuesta que mandó el bot.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_save_reply(p_jid text, p_text text, p_wa_id text)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO messages (jid, direction, source, content, wa_id)
    VALUES (p_jid, 'out', 'bot', p_text, NULLIF(p_wa_id, ''))
    ON CONFLICT (wa_id) DO UPDATE SET source = 'bot';
$$;

-- ---------------------------------------------------------------------
-- bot_owner_message: un mensaje "fromMe" que NO mandó el bot => lo escribió
-- el dueño desde el celular. Se guarda y se pausa el bot para ese contacto.
-- Comandos que el dueño puede escribir en el chat del cliente:
--   #bot      -> reactiva el bot para ese contacto ya mismo
--   #nobot    -> desactiva el bot para ese contacto (hasta escribir #bot)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_owner_message(p_jid text, p_text text, p_wa_id text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_minutes int;
    v_cmd     text := lower(trim(coalesce(p_text, '')));
BEGIN
    -- Si es un mensaje que mandó el bot, no hacer nada.
    IF EXISTS (SELECT 1 FROM messages WHERE wa_id = p_wa_id AND source = 'bot') THEN
        RETURN jsonb_build_object('action', 'ignored_bot_message');
    END IF;

    INSERT INTO contacts (jid, phone)
    VALUES (p_jid, CASE WHEN p_jid LIKE '%@s.whatsapp.net' THEN split_part(p_jid, '@', 1) END)
    ON CONFLICT (jid) DO NOTHING;

    IF v_cmd = '#bot' THEN
        UPDATE contacts SET paused_until = NULL, bot_enabled = true WHERE jid = p_jid;
        RETURN jsonb_build_object('action', 'bot_resumed');
    ELSIF v_cmd = '#nobot' THEN
        UPDATE contacts SET bot_enabled = false WHERE jid = p_jid;
        RETURN jsonb_build_object('action', 'bot_disabled');
    END IF;

    INSERT INTO messages (jid, direction, source, content, wa_id)
    VALUES (p_jid, 'out', 'owner', p_text, NULLIF(p_wa_id, ''))
    ON CONFLICT (wa_id) DO NOTHING;

    SELECT human_pause_minutes INTO v_minutes FROM bot_config WHERE id = 1;
    UPDATE contacts SET paused_until = now() + make_interval(mins => v_minutes) WHERE jid = p_jid;
    RETURN jsonb_build_object('action', 'paused', 'minutes', v_minutes);
END $$;
