// Baskı Maliyeti – Android "Paylaş" hedefi.
// Paylaşılan dosyaları kısa süreliğine önbelleğe koyar ve sayfayı açar; sayfa onları okuyup siler.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "POST" || !url.pathname.endsWith("/paylas")) return;
  e.respondWith((async () => {
    let n = 0;
    try {
      const fd = await e.request.formData();
      const files = fd.getAll("dosya").filter((f) => f && typeof f === "object" && f.size > 0).slice(0, 3);
      const c = await caches.open("paylasilan");
      for (const k of await c.keys()) await c.delete(k);
      for (const f of files) {
        await c.put(new Request(new URL("paylasilan/" + n++, self.registration.scope)),
          new Response(f, { headers: { "content-type": f.type || "application/octet-stream", "x-name": encodeURIComponent(f.name || "dosya") } }));
      }
    } catch (_) {}
    return Response.redirect(new URL("./?paylas=" + n, self.registration.scope).href, 303);
  })());
});
