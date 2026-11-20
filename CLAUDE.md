# CLAUDE.md

Entorno multicliente de chatbot de WhatsApp con IA. Documentación para humanos en `README.md` (en español; el dueño escribe en español).

- Un cliente = `clients/<slug>/` generado desde `template/` por `scripts/nuevo-cliente.ps1` (Windows/PowerShell, Docker Compose).
- Por cliente: Postgres (`db`), Evolution API (`evolution`, WhatsApp vía Baileys, multi-dispositivo para que el celular siga funcionando) y cloudflared (`tunel-cf` con token o `tunel` temporal; mismos perfiles que panaderia-reservas).
- n8n NO está en este repo: es un contenedor existente del usuario, conectado a la red externa `wa-net`. Un workflow por cliente, importado por CLI (`n8n import:credentials`, `import:workflow`, `publish:workflow`).
- La lógica del bot vive en funciones SQL (`bot_ingest`, `bot_save_reply`, `bot_owner_message`) en `template/db/init/01_schema.sql`.
- Costo cero: IA local con Ollama (`host.docker.internal:11434`). La IA paga se agrega al final.
- En nodos Postgres de n8n, pasar parámetros como array (`={{ [$json.a, $json.b] }}`): la forma separada por comas rompe si el texto tiene comas.
- `clients/` está en `.gitignore`: contiene contraseñas.
- Scripts `.ps1` guardados en UTF-8 con BOM (Windows PowerShell 5.1 los lee mal sin BOM).
