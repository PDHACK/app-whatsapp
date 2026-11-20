-- Ejemplo para cargar la info de un negocio. Pegalo en:
--   .\scripts\cliente.ps1 <slug> sql
-- (o desde un nodo Postgres en n8n). Editá los textos a gusto.

UPDATE bot_config SET
    business_name = 'Panadería San José',
    system_prompt = 'Sos el asistente de WhatsApp de {{negocio}}. Respondé en español rioplatense, '
                 || 'breve y cálido (máximo 3 oraciones). Usá solo la información del negocio. '
                 || 'Para encargos tomá nombre, producto, cantidad y día de retiro, y decí que un humano lo confirma. '
                 || 'Si no sabés algo, decí que en breve lo atiende alguien del equipo.',
    human_pause_minutes = 60,
    updated_at = now()
WHERE id = 1;

INSERT INTO knowledge (title, content) VALUES
  ('Horarios',  'Lunes a sábado de 7 a 20. Domingos de 8 a 13. Feriados consultar.'),
  ('Dirección', 'Av. Siempreviva 742. No hacemos envíos, solo retiro en el local.'),
  ('Precios',   'Pan francés $3000 el kilo. Medialunas $900 c/u, docena $9500. Torta grande $25000.'),
  ('Encargos',  'Tortas con 48 hs de anticipación. Se paga 50% de seña por transferencia.');

-- Ver / apagar cosas:
--   SELECT * FROM knowledge;                         -- lo que sabe el bot
--   UPDATE knowledge SET enabled = false WHERE id = 3;
--   UPDATE bot_config SET active = false;            -- apaga el bot del cliente entero
--   SELECT jid, name, paused_until FROM contacts;    -- quién está en pausa
--   SELECT * FROM messages ORDER BY id DESC LIMIT 20;
