// OrcaSlicer dilimleme motoru (WebAssembly) – arka plan işçisi.
// Motor: OrcaSlicer 2.4.2 libslic3r, OrcaWasm derlemesi (AGPL-3.0).
// Kaynak: https://github.com/Hiosdra/OrcaWasm  ·  https://github.com/SoftFever/OrcaSlicer
importScripts("slicer.js");

let derli = null; // derlenmiş WebAssembly modülü (bir kez indirilir)
// Motor dosyası barındırma sınırları için 7 MB'lık parçalara bölündü; burada birleştirilir
const PARCA = 5;
async function wasmAl() {
  if (derli) return derli;
  const parcalar = await Promise.all(Array.from({ length: PARCA }, async (_, i) => {
    const r = await fetch("slicer.wasm.part" + i);
    if (!r.ok) throw new Error("motor indirilemedi (" + r.status + ")");
    return new Uint8Array(await r.arrayBuffer());
  }));
  const tum = new Uint8Array(parcalar.reduce((a, p) => a + p.length, 0));
  let o = 0; for (const p of parcalar) { tum.set(p, o); o += p.length; }
  derli = await WebAssembly.compile(tum);
  return derli;
}
// Her dilimleme için temiz bir motor örneği: önceki yazıcının ayarları karışmasın
async function yeniMotor() {
  const wm = await wasmAl();
  return await OrcaModule({
    instantiateWasm: (imports, ok) => { WebAssembly.instantiate(wm, imports).then((i) => ok(i, wm)); return {}; },
    print: () => {}, printErr: () => {},
  });
}
const enc = new TextEncoder(), dec = new TextDecoder();
function yaz(M, b) { const p = M._malloc(b.length || 1); if (!p) throw new Error("bellek yetmedi"); M.HEAPU8.set(b, p); return p; }
function hata(M, s) { try { const p = M._onewasm_last_error(s); return p ? M.UTF8ToString(p) : ""; } catch (e) { return ""; } }
function cikti(M, s, fn, ...args) {
  const pp = M._malloc(4), lp = M._malloc(4);
  try {
    const rc = M[fn](s, ...args, pp, lp);
    if (rc !== 0) throw new Error(hata(M, s) || fn + " başarısız (" + rc + ")");
    const d = M.getValue(pp, "i32"), n = M.getValue(lp, "i32");
    try { return M.HEAPU8.slice(d, d + n); } finally { M._onewasm_free(d); }
  } finally { M._free(lp); M._free(pp); }
}
function istek(M, s, fn, obj) {
  const b = enc.encode(JSON.stringify(obj)), p = yaz(M, b);
  try { return JSON.parse(dec.decode(cikti(M, s, fn, p, b.length))); } finally { M._free(p); }
}
function profilUygula(M, s, obj) {
  const f = enc.encode("orca.profile-json"), b = enc.encode(JSON.stringify(obj));
  const fp = yaz(M, f), bp = yaz(M, b);
  try { const rc = M._onewasm_apply_profile(s, fp, f.length, bp, b.length); if (rc) throw new Error(hata(M, s) || "ayar uygulanamadı"); }
  finally { M._free(bp); M._free(fp); }
}
function projeYukle(M, s, bytes) {
  const f = enc.encode("project.3mf"), fp = yaz(M, f), bp = yaz(M, bytes);
  try { const rc = M._onewasm_init_profile(s, fp, f.length, bp, bytes.length); if (rc) throw new Error(hata(M, s) || "3MF okunamadı"); }
  finally { M._free(bp); M._free(fp); }
}
function nesneler(M, s, stl, man) {
  const mb = enc.encode(JSON.stringify(man)), bp = yaz(M, stl), mp = yaz(M, mb);
  try { const rc = M._onewasm_project_set_objects(s, bp, stl.length, mp, mb.length); if (rc) throw new Error(hata(M, s) || "model yüklenemedi"); }
  finally { M._free(mp); M._free(bp); }
}

async function dilimle(is) {
  const M = await yeniMotor(), s = M._onewasm_session_create();
  try {
    if (is.proje) {
      projeYukle(M, s, new Uint8Array(is.proje));
    } else {
      for (const p of is.profiller) profilUygula(M, s, p);
      const stl = new Uint8Array(is.stl);
      const man = { schemaVersion: "0.3", plates: [{ id: "p0", label: "Plaka 1", index: 0 }],
        meshes: [{ id: "m0", format: "stl", dataRange: { offset: 0, length: stl.length } }],
        objects: [{ id: "o0", meshId: "m0", extruderId: 0 }],
        instances: Array.from({ length: Math.max(1, Math.min(64, is.adet | 0 || 1)) }, (_, i) =>
          ({ id: "i" + i, objectId: "o0", plateId: "p0", transform: { matrix: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1] } })) };
      nesneler(M, s, stl, man);
      const yer = istek(M, s, "_onewasm_project_prepare", { schemaVersion: "0.3", operation: "arrange" });
      nesneler(M, s, stl, yer);
    }
    const r = istek(M, s, "_onewasm_project_slice", { schemaVersion: "0.3", plateSelection: "all", includeGcode: false, includeStatistics: true });
    const tablalar = (r.plateResults || []).map((p) => ({ sn: p.statistics?.timeSeconds?.normal || 0, g: p.statistics?.filament?.totalMassG || 0 }));
    if (!tablalar.length) throw new Error("dilimleme sonuç vermedi");
    return { sn: tablalar.reduce((a, t) => a + t.sn, 0), g: tablalar.reduce((a, t) => a + t.g, 0), tablalar };
  } finally {
    try { M._onewasm_session_destroy(s); } catch (e) {}
  }
}

onmessage = async (e) => {
  const is = e.data;
  if (is.hazirla) { try { await wasmAl(); postMessage({ id: is.id, hazir: true }); } catch (err) { postMessage({ id: is.id, hata: err.message }); } return; }
  const nabiz = setInterval(() => postMessage({ id: is.id, nabiz: true }), 3000);
  try { postMessage({ id: is.id, sonuc: await dilimle(is) }); }
  catch (err) { postMessage({ id: is.id, hata: String(err && err.message || err) }); }
  finally { clearInterval(nabiz); }
};
