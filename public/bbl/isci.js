// Bambu Studio 02.07.01.62 dilimleme motoru (WebAssembly) – arka plan işçisi.
// Bambu Studio'nun kendi komut satırı programı tarayıcı için derlendi (AGPL-3.0).
// Kaynak: https://github.com/bambulab/BambuStudio (v02.07.01.62) · derleme değişiklikleri: KAYNAK.txt
importScripts("bambu_slicer.js");

const PARCA = 3;
let derli = null, kaynak = null;
async function wasmAl() {
  if (derli) return derli;
  const parcalar = await Promise.all(Array.from({ length: PARCA }, async (_, i) => {
    const r = await fetch("bambu_slicer.wasm.part" + i);
    if (!r.ok) throw new Error("motor indirilemedi (" + r.status + ")");
    return new Uint8Array(await r.arrayBuffer());
  }));
  const tum = new Uint8Array(parcalar.reduce((a, p) => a + p.length, 0));
  let o = 0; for (const p of parcalar) { tum.set(p, o); o += p.length; }
  derli = await WebAssembly.compile(tum);
  return derli;
}
// Bambu Studio'nun dilimlerken okuduğu 3 küçük kaynak dosyası
const KAYNAKLAR = ["info/filament_info.json", "profiles/BBL/cli_config.json", "profiles/BBL/filament/filament_name_map.json"];
async function kaynakAl() {
  if (kaynak) return kaynak;
  kaynak = await Promise.all(KAYNAKLAR.map(async (p) => {
    const r = await fetch("res/" + p); if (!r.ok) throw new Error("kaynak dosya yok: " + p);
    return [p, new Uint8Array(await r.arrayBuffer())];
  }));
  return kaynak;
}
async function yeniMotor() {
  const wm = await wasmAl();
  return await BambuModule({
    instantiateWasm: (imports, ok) => { WebAssembly.instantiate(wm, imports).then((i) => ok(i, wm)); return {}; },
    print: () => {}, printErr: () => {},
  });
}

async function dilimle(is) {
  const [M, res] = await Promise.all([yeniMotor(), kaynakAl()]);
  const FS = M.FS;
  FS.mkdirTree("/bbl/bin"); FS.writeFile("/bbl/bin/bambu-studio", "");
  for (const [p, d] of res) { FS.mkdirTree("/bbl/resources/" + p.replace(/\/[^/]*$/, "")); FS.writeFile("/bbl/resources/" + p, d); }
  FS.mkdirTree("/work/out");
  const modelYol = "/work/" + (is.proje ? "model.3mf" : "model.stl");
  FS.writeFile(modelYol, new Uint8Array(is.proje || is.stl));
  const arg = ["--outputdir", "/work/out"];
  if (!is.proje) {
    FS.writeFile("/work/m.json", JSON.stringify(is.m));
    FS.writeFile("/work/p.json", JSON.stringify(is.p));
    FS.writeFile("/work/f.json", JSON.stringify(is.f));
    arg.push("--arrange", "1", "--orient", "0", "--load-settings", "/work/m.json;/work/p.json", "--load-filaments", "/work/f.json");
  }
  arg.push("--slice", "0", "--export-3mf", "r.3mf");
  // Adet: Bambu Studio'da kopya eklemek gibi; aynı model n kez yüklenir, --arrange tablaya dizer
  const n = is.proje ? 1 : Math.max(1, Math.min(64, is.adet | 0 || 1));
  for (let i = 0; i < n; i++) arg.push(modelYol);
  let rc;
  try { rc = M.callMain(arg); } catch (e) { rc = e && e.status !== undefined ? e.status : String(e && e.message || e); }
  let sonuc = null;
  try { sonuc = JSON.parse(new TextDecoder().decode(FS.readFile("/work/out/result.json"))); } catch (e) {}
  if (!sonuc || !Array.isArray(sonuc.sliced_plates) || !sonuc.sliced_plates.length)
    throw new Error((sonuc && sonuc.error_string) || ("Bambu Studio dilimleyemedi (kod " + rc + ")"));
  const tablalar = sonuc.sliced_plates.map((p) => ({
    sn: Math.floor(p.total_predication || 0),
    g: (p.filaments || []).reduce((a, f) => a + (f.total_used_g || 0), 0),
  }));
  return { sn: tablalar.reduce((a, t) => a + t.sn, 0), g: tablalar.reduce((a, t) => a + t.g, 0), tablalar, kod: sonuc.return_code };
}

onmessage = async (e) => {
  const is = e.data;
  if (is.hazirla) { try { await wasmAl(); postMessage({ id: is.id, hazir: true }); } catch (err) { postMessage({ id: is.id, hata: err.message }); } return; }
  try { postMessage({ id: is.id, sonuc: await dilimle(is) }); }
  catch (err) { postMessage({ id: is.id, hata: String(err && err.message || err) }); }
};
