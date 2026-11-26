// Goleo Telegram bot webhook: Telegram'ın gönderdiği her güncellemeyi veritabanındaki tg_isle fonksiyonuna iletir.
// Supabase > Edge Functions > "telegram" adıyla oluşturun ve "Verify JWT" ayarını KAPATIN.
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  let update: unknown;
  try { update = await req.json(); } catch { return new Response("bad request", { status: 400 }); }
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const headers: Record<string, string> = { apikey: key, "Content-Type": "application/json" };
  if (key.startsWith("eyJ")) headers.Authorization = "Bearer " + key;
  const r = await fetch(Deno.env.get("SUPABASE_URL") + "/rest/v1/rpc/tg_isle", {
    method: "POST",
    headers,
    body: JSON.stringify({ u: update, sec: req.headers.get("x-telegram-bot-api-secret-token") ?? "" }),
  });
  if (!r.ok) console.error("tg_isle hata", r.status, await r.text());
  return new Response("ok");
});
